// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import AppKit
func runTests() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws { if !condition() { throw ScopeError(message) } }
    let root = CommandLine.arguments.drop(while: { $0 != "--fixtures" }).dropFirst().first ?? "Fixtures"
    var settings = Settings(); settings.channels[0].scale=10; settings.channels[0].offset=0; settings.channels[1].scale=1; settings.channels[1].offset = -2.36
    let assembler = Assembler()
    for i in 1...2 { let data = try Data(contentsOf:URL(fileURLWithPath:"\(root)/dso2d15-private-220831/capture-001-packet-0\(i).bin")); let done = try assembler.append(data); try check(done == (i == 2),"private completion") }
    let frame = try assembler.decode(settings)
    try check(frame.volts[0].count == 4000 && frame.volts[1].count == 4000,"channel lengths")
    let ch1 = Metrics(frame.volts[0],rate:frame.rate), ch2 = Metrics(frame.volts[1],rate:frame.rate)
    try check(ch1.frequency == 0,"noise must not report frequency"); try check(abs(ch2.frequency-1000)<5,"CH2 fixture frequency")
    try check(abs(ch2.vpp-5.4)<0.001,"CH2 calibration")
    let publicAssembler = Assembler()
    for i in 1...3 { let data = try Data(contentsOf:URL(fileURLWithPath:"\(root)/dso2d15-220831/capture-001-packet-0\(i).bin")); let done = try publicAssembler.append(data); try check(done == (i == 3),"public completion") }
    let publicFrame = try publicAssembler.decode(settings); try check(publicFrame.volts[0].count == 4000,"metadata-inclusive samples")
    let stale = Assembler(); let staleData = try Data(contentsOf:URL(fileURLWithPath:"\(root)/dso2d15-220831/stale-continuation.bin")); let staleDone = try stale.append(staleData); try check(!staleDone && stale.metadata.isEmpty,"discard stale continuation")
    var rejected = false; do { _ = try Assembler().append(Data("not a waveform".utf8)) } catch { rejected=true }; try check(rejected,"reject malformed packets")
    let sine = (0..<4096).map { sqrt(2)*sin(2 * .pi * 128 * Double($0)/4096) }; let spectrum = fftDB(sine)
    let peak = spectrum.enumerated().max(by:{$0.element<$1.element})!
    try check(peak.offset == 128 && abs(peak.element)<0.01,"1 Vrms sine spectrum")
    let dc = fftDB([Double](repeating:2,count:4000)); try check(dc.allSatisfy{$0 <= -299},"FFT DC removal")
    let square = (0..<4000).map { ($0/250)%2 == 0 ? 5.0:0.0 }; let metrics = Metrics(square,rate:500000)
    try check(abs(metrics.frequency-1000)<1 && abs(metrics.rms-sqrt(12.5))<0.001,"square measurements")
    var onlyCH2 = [UInt8](try Data(contentsOf:URL(fileURLWithPath:"\(root)/dso2d15-private-220831/capture-001-packet-01.bin")))
    onlyCH2.replaceSubrange(11..<20,with:Array("000004000".utf8)); onlyCH2[29+46]=48; onlyCH2[29+47]=49
    let single=Assembler(); let singleDone=try single.append(Data(onlyCH2)); try check(singleDone,"CH2-only complete")
    let singleFrame=try single.decode(settings); try check(singleFrame.volts[0].isEmpty && singleFrame.volts[1].count == 4000,"active channel slot mapping")
    let overlap=Assembler(); let firstPacket=try Data(contentsOf:URL(fileURLWithPath:"\(root)/dso2d15-private-220831/capture-001-packet-01.bin")); _=try overlap.append(firstPacket)
    var conflicting=[UInt8](firstPacket); conflicting[128] ^= 1; var conflictRejected=false
    do { _=try overlap.append(Data(conflicting)) } catch { conflictRejected=true }; try check(conflictRejected,"conflicting overlap rejected")
    let model=ScopeModel(preferences:.transient); model.receive(frame,changed:true,state:"RUN"); let plotID=model.plot.id
    model.receive(frame,changed:false,state:"STOP"); try check(model.plot.id == plotID && model.runState == "STOP","identical frames skip plot rebuild but update acquisition state")
    model.startDemo(); model.snapPeriod(); try check(abs(abs(model.cursorB-model.cursorA)-0.001)<0.000002,"cursor period snap")
    let demoFirst=demoCapture(elapsed:0),demoLater=demoCapture(elapsed:3)
    try check(demoFirst.volts.allSatisfy{$0.count == 4000},"demo provides both channels")
    try check(demoFirst.volts != demoLater.volts,"demo evolves over time")
    try check(abs(Metrics(demoFirst.volts[1],rate:demoFirst.rate).frequency-1000)<5,"demo CH2 sine frequency")
    model.setRepeat(false);let pausedID=model.plot.id
    try check(model.demo && !model.repeating,"demo pauses without leaving demo mode")
    model.captureOnce();try check(model.plot.id != pausedID,"paused demo supports single capture")
    model.stopDemo();try check(!model.demo && !model.repeating,"demo stops cleanly")
    let stoppedDemoID=model.plot.id;model.captureDemo()
    try check(model.plot.id == stoppedDemoID,"stopped demo rejects queued timer captures")
    let demoArchive=CaptureRecording(frames:[RecordedFrame(demoFirst,elapsed:0),RecordedFrame(demoLater,elapsed:3)])
    try demoArchive.validate()
    let restoredDemo=try CaptureRecording.decoded(demoArchive.encoded())
    try check(restoredDemo.frames.allSatisfy{$0.capture.synthetic},"demo provenance survives recording round trip")
    let provenanceModel=ScopeModel(preferences:.transient);try provenanceModel.installPlayback(restoredDemo)
    try check(provenanceModel.syntheticCapture && provenanceModel.displayStatus.contains("Demo") && provenanceModel.captureInfo.contains("synthetic demo") && provenanceModel.transportPerformance.contains("synthetic"),"demo playback remains labelled synthetic")
    var legacyObject=try JSONSerialization.jsonObject(with:JSONEncoder().encode(RecordedFrame(frame,elapsed:0))) as! [String:Any]
    legacyObject.removeValue(forKey:"synthetic")
    let legacyFrame=try JSONDecoder().decode(RecordedFrame.self,from:JSONSerialization.data(withJSONObject:legacyObject))
    try check(!legacyFrame.capture.synthetic,"older recordings remain readable without provenance field")
    let demoStreamURL=FileManager.default.temporaryDirectory.appendingPathComponent("ScopeMac-demo-provenance-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:demoStreamURL)}
    let demoWriter=try StreamRecordingWriter(url:demoStreamURL);try demoWriter.append(RecordedFrame(demoFirst,elapsed:0));try demoWriter.finish()
    let demoReader=try StreamRecordingReader(url:demoStreamURL)
    let streamedDemo=try demoReader.frame(at:0)
    try check(streamedDemo.capture.synthetic,"streaming recording retains synthetic provenance")


    model.mode="FFT"; model.rebuild(); try check(model.plot.isFFT && !model.plot.values[0].isEmpty,"FFT view data")
    let full=Viewport(lower:-2,upper:8), initial=Viewport(lower:0,upper:4)
    let anchored=initial.zoomed(factor:2,anchor:0.25,within:full)
    try check(abs((anchored.lower+anchored.width*0.25)-1)<1e-12,"pointer anchor preserved")
    try check(abs(anchored.width-2)<1e-12,"zoom span")
    let right=anchored.panned(fraction:100,within:full)
    try check(abs(right.upper-8)<1e-12 && abs(right.width-2)<1e-12,"pan clamps without changing scale")
    let tiny=initial.zoomed(factor:1e9,anchor:0.5,within:full)
    try check(abs(tiny.width-full.width/1000)<1e-12,"maximum zoom")
    let fit=initial.zoomed(factor:0.001,anchor:0.5,within:full)
    try check(fit.lower == full.lower && fit.upper == full.upper,"zoom out bounds")
    model.mode="Waveform"; model.fitPlot(); let original=model.plot
    let pivot=original.xMin+(original.xMax-original.xMin)*0.25
    model.zoomPlot(factor:4,anchor:0.25)
    try check(abs(model.plot.xMin+(model.plot.xMax-model.plot.xMin)*0.25-pivot)<1e-12,"model pointer zoom")
    try check(model.plot.values[0].count == 4000 && model.plot.sampleStart == 0 && model.plot.sampleStep == 1.0/500000,"zoom retains original sample coordinates")
    let zoomWidth=model.plot.xMax-model.plot.xMin
    model.panPlot(fraction:0.2); try check(abs(model.plot.xMax-model.plot.xMin-zoomWidth)<1e-12,"model pan retains zoom")
    model.fitPlot(); try check(abs(model.plot.xMax-original.xMax)<1e-12,"Fit restores full capture")
    let silent=Capture(volts:[[Double](repeating:0,count:4000),[]],rate:500000,trigger:0,raw:Data([0]))
    model.mode="FFT"; model.receive(silent,changed:true,state:"STOP")
    try check(model.plot.yMin < model.plot.yMax,"silent FFT axis remains valid")
    model.recordRender(RenderTiming(geometryMS:0.4,submitMS:0.2,gpuMS:0.1,rebuilt:true))
    try check(model.performance.contains("GPU 0.10"),"GPU completion timing displayed")
    print("Pointer anchoring, pan limits, zoom limits, exact sample coordinates, Fit, silent FFT axes and timing display verified.")
    var profile=ScopeQueryTiming(); profile.command_ms=0.2;profile.request_ms=0.1;profile.read_ms=100;profile.total_ms=100.4
    profile.read_calls=1;profile.payload_bytes=4128;profile.wire_bytes=4140;profile.link_speed=3;profile.max_packet_bytes=512
    profile.overlapped=1
    let query=QueryTrace(profile);var transfer=TransferTrace()
    transfer.append(query,noProgress:false,stalePacket:false);transfer.append(query,noProgress:true,stalePacket:true)
    try check(transfer.overlapped && query.summary.contains("OVERLAPPED"),"overlapped timing labeling")
    try check(transfer.packets == 2 && transfer.reads == 2 && transfer.payload == 8256,"USB query counters")
    try check(abs(transfer.readMS-200)<1e-12 && abs(transfer.commandMS-0.4)<1e-12,"USB stage aggregation")
    try check(transfer.empty == 1 && transfer.stale == 1 && transfer.firstMS == 100.4 && transfer.remainingMS == 100.4,"packet sequence timing")
    try check(query.link.contains("480") && transfer.maxPacket == 512,"negotiated USB speed")
    model.receive(frame,changed:false,state:"RUN");try check(model.transportPerformance.contains("USB reads"),"transport detail display")
    print("Per-query stage aggregation, packet counters, negotiated link speed and transport detail display verified.")
    var replies=[":TRIGger:MODE?":"EDGE",":TRIGger:SWEep?":"AUTO",":TRIGger:EDGe:SOURce?":"CHAN1",":TRIGger:EDGe:SLOPe?":"RIS",":TRIGger:EDGe:LEVel?":"2.36"]
    var triggerQueries=[String](),triggerWrites=[String]()
    func triggerQuery(_ command: String) throws -> String {triggerQueries.append(command);return replies[command] ?? ""}
    let actualTrigger=try readTrigger(query:triggerQuery)
    try check(actualTrigger.source == "CHANnel1" && actualTrigger.slope == "RISIng" && actualTrigger.level == 2.36,"trigger aliases and actual level")
    var desiredTrigger=actualTrigger;desiredTrigger.level=2.4;desiredTrigger.slope="FALLing"
    let returnedTrigger=try applyTrigger(desiredTrigger,write:{triggerWrites.append($0)},query:triggerQuery)
    try check(returnedTrigger.level == 2.36 && returnedTrigger.slope == "RISIng","trigger readback wins over requested values")
    try check(triggerWrites.first == ":TRIGger:MODE EDGE" && triggerWrites.count == 5,"explicit EDGE selection")
    triggerWrites=[];desiredTrigger.level = .nan;var invalidTriggerRejected=false
    do { _=try applyTrigger(desiredTrigger,write:{triggerWrites.append($0)},query:triggerQuery) } catch {invalidTriggerRejected=true}
    try check(invalidTriggerRejected && triggerWrites.isEmpty,"invalid trigger values cause no writes")
    replies[":TRIGger:MODE?"]="PULSE";triggerQueries=[];let pulse=try readTrigger(query:triggerQuery)
    try check(pulse.mode == "PULSE" && triggerQueries.count == 2,"non-edge read avoids unsupported edge queries")
    replies[":TRIGger:MODE?"]="EDGE";replies[":TRIGger:EDGe:SOURce?"]="garbage";var badReadback=false
    do { _=try readTrigger(query:triggerQuery) } catch {badReadback=true};try check(badReadback,"unsupported trigger readback rejected")
    print("Trigger aliases, explicit EDGE selection, actual readback, non-edge query handling and pre-write validation verified.")
    var savedPreferences: Data?
    let preferenceStore=PreferenceStore(load:{savedPreferences},save:{savedPreferences=$0})
    let firstModel=ScopeModel(preferences:preferenceStore)
    firstModel.showCH2=false;firstModel.mode="FFT";firstModel.fftSource=1;firstModel.cursors=true;firstModel.selectedCursor=1;firstModel.inspectorVisible=false
    let restored=ScopeModel(preferences:preferenceStore)
    try check(!restored.showCH2 && restored.mode == "FFT" && restored.fftSource == 1 && restored.cursors && restored.selectedCursor == 1 && !restored.inspectorVisible,"display preference restoration")
    try check(!restored.connected && !restored.repeating && !restored.overlapUSB && restored.settings == Settings(),"preferences never restore hardware state, auto-connect or experimental transport")
    restored.resetDisplayPreferences();try check(savedPreferences == nil && restored.mode == "Waveform" && restored.inspectorVisible,"reset preferences")
    try check(DisplayPreferences.decode(Data("bad".utf8)) == DisplayPreferences(),"corrupt preferences use defaults")
    var invalidPreferences=DisplayPreferences();invalidPreferences.fftSource=99;invalidPreferences.mode="invalid";invalidPreferences.selectedCursor = -1
    let validatedPreferences=DisplayPreferences.decode(try JSONEncoder().encode(invalidPreferences))
    try check(validatedPreferences.mode == "Waveform" && validatedPreferences.fftSource == 0 && validatedPreferences.selectedCursor == 0,"validate saved selections")
    invalidPreferences.version=99
    let unsupportedData=try JSONEncoder().encode(invalidPreferences)
    try check(DisplayPreferences.decode(unsupportedData) == DisplayPreferences(),"unsupported preference version")
    print("Display preference restoration, validation, reset and separation from instrument state verified.")
    let recordedA=RecordedFrame(frame,elapsed:0.2)
    let recordedB=RecordedFrame(frame,elapsed:0.7)
    let archive=CaptureRecording(frames:[recordedA,recordedB])
    let recordingData=try archive.encoded(), decodedArchive=try CaptureRecording.decoded(recordingData)
    try check(decodedArchive == archive,"recording preserves samples, scale-independent volts and timing")
    var corruptArchive=archive;corruptArchive.frames[1].elapsed=0.1;var invalidTimeline=false
    do {_=try corruptArchive.encoded()}catch{invalidTimeline=true};try check(invalidTimeline,"backwards recording timeline rejected")
    corruptArchive=archive;corruptArchive.version=999;var unsupportedArchive=false
    do {_=try corruptArchive.encoded()}catch{unsupportedArchive=true};try check(unsupportedArchive,"unsupported recording version")
    corruptArchive=archive;corruptArchive.frames[0].sampleRate=0;var badRate=false
    do {_=try corruptArchive.encoded()}catch{badRate=true};try check(badRate,"invalid recorded sample rate")
    let playbackModel=ScopeModel(preferences:.transient);try playbackModel.installPlayback(decodedArchive)
    try check(playbackModel.playbackLoaded && !playbackModel.connected && playbackModel.playbackCount == 2 && playbackModel.plot.values[0] == frame.volts[0],"offline playback reconstructs waveform")
    playbackModel.seekPlayback(1);try check(playbackModel.playbackIndex == 1 && playbackModel.dashboard.contains("0.700"),"timeline seek preserves capture gaps")
    playbackModel.connected=true;var rejectedLivePlayback=false
    do{try playbackModel.installPlayback(decodedArchive)}catch{rejectedLivePlayback=true};try check(rejectedLivePlayback,"playback cannot replace live hardware data")
    playbackModel.connected=false;playbackModel.closePlayback();try check(!playbackModel.playbackLoaded && playbackModel.plot.values.allSatisfy(\.isEmpty),"playback closes cleanly")
    print("Recording round trip, sample/timeline validation, offline playback, seeking, capture gaps and live/playback isolation verified.")
    let referenceModel=ScopeModel(preferences:.transient);referenceModel.startDemo();referenceModel.freezeReference()
    var slower=frame;slower.rate=250000;slower.trigger=0.001
    referenceModel.receive(slower,changed:true,state:"RUN")
    try check(referenceModel.hasReference && referenceModel.plot.values.count == 4,"reference overlay retained with new capture")
    try check(referenceModel.plot.traceSteps[0] == 1.0/250000 && referenceModel.plot.traceSteps[2] == 1.0/500000,"independent reference sample rates")
    try check(referenceModel.plot.traceStarts[0] == -0.001 && referenceModel.plot.traceStarts[2] == 0,"reference trigger alignment")
    let png=try ChartExport.png(plot:referenceModel.plot,title:"Waveform",measurements:referenceModel.measurements,receivedUTC:frame.completedUTC,cursors:(0.002,0.003))
    try check(Array(png.prefix(8)) == [137,80,78,71,13,10,26,10],"PNG encoding")
    let image=NSBitmapImageRep(data:png)
    try check(image?.pixelsWide == 1600 && image?.pixelsHigh == 1000,"export image dimensions")
    if let position=CommandLine.arguments.firstIndex(of:"--export-preview"),position+1<CommandLine.arguments.count {try png.write(to:URL(fileURLWithPath:CommandLine.arguments[position+1]),options:.atomic)}
    referenceModel.clearReference();try check(!referenceModel.hasReference && referenceModel.plot.values.count == 2,"clear reference")
    print("Reference freezing, independent sample rates, trigger alignment, clearing and 1600×1000 PNG export verified.")
    try check(abs(refreshDelay(interval:1,elapsed:0.4)-0.6)<1e-12,"1s cadence subtracts capture duration")
    try check(abs(refreshDelay(interval:2,elapsed:0.4)-1.6)<1e-12,"2s cadence")
    try check(refreshDelay(interval:0,elapsed:0.4) == 0.005,"fastest cadence")
    try check(refreshDelay(interval:1,elapsed:1.5) == 0.005,"slow USB does not overlap or build a catch-up queue")
    firstModel.refreshInterval=2
    let cadenceRestored=ScopeModel(preferences:preferenceStore)
    try check(cadenceRestored.refreshInterval == 2,"refresh preference restoration")
    print("Start-to-start refresh cadence, fastest mode, slow-transfer behavior and saved interval verified.")
    let streamURL=FileManager.default.temporaryDirectory.appendingPathComponent("ScopeMac-test-"+UUID().uuidString+".scopemac")
    defer{try? FileManager.default.removeItem(at:streamURL)}
    let streamWriter=try StreamRecordingWriter(url:streamURL)
    var longFrame=RecordedFrame(Capture(volts:[[Double](repeating:0,count:4000),[]],rate:500000,trigger:0,raw:Data()),elapsed:0)
    for index in 0..<520{longFrame.elapsed=Double(index);try streamWriter.append(longFrame)}
    try streamWriter.finish();try streamWriter.finish()
    let streamDetected=try StreamRecordingReader.isStream(streamURL)
    try check(streamDetected,"stream format detection")
    let streamReader=try StreamRecordingReader(url:streamURL),lastSnapshot=try streamReader.frame(at:519)
    try check(streamReader.count == 520 && lastSnapshot.elapsed == 519 && lastSnapshot.volts[0].count == 4000,"indexed recording beyond old total-sample limit")
    let interrupted=try FileHandle(forWritingTo:streamURL);try interrupted.seekToEnd();try interrupted.write(contentsOf:Data("{unfinished".utf8));try interrupted.close()
    let recovered=try StreamRecordingReader(url:streamURL)
    try check(recovered.count == 520 && recovered.recoveredTail,"recover complete snapshots after an interrupted final write")
    print("Streaming recording beyond the old memory limit, indexed seeking and interrupted-tail recovery verified.")
    let dutySignal=(0..<4000).map{($0%500)<125 ? 5.0:0.0}, duty=Metrics(dutySignal,rate:500000)
    try check(abs((duty.period ?? 0)-0.001)<1e-9 && abs((duty.positiveWidth ?? 0)-0.00025)<1e-9 && abs((duty.dutyCycle ?? 0)-25)<1e-9,"25 percent duty and positive pulse width")
    let constant=Metrics([Double](repeating:2,count:4000),rate:500000)
    try check(constant.minimum == 2 && constant.maximum == 2 && constant.acRMS == 0 && constant.period == nil,"DC measurement and unavailable timing")
    let sineMetrics=Metrics(sine,rate:4096)
    try check(abs(sineMetrics.acRMS-1)<1e-9,"AC RMS normalization")
    var averager=SpectrumAverage();_=averager.add([0],count:4);let averaged=averager.add([20],count:4)
    try check(abs(averaged[0]-10*log10(50.5))<1e-9,"FFT averages power rather than dB")
    for _ in 0..<4{_=averager.add([-20],count:4)}
    let settled=averager.add([-20],count:4);try check(abs(settled[0]+20)<1e-9,"rolling average discards old spectra")
    let peakList=spectralPeaks(spectrum,spacing:1,limit:1000)
    try check(abs((peakList.first?.frequency ?? 0)-128)<0.01,"FFT interpolated peak frequency")
    let fftModel=ScopeModel(preferences:.transient);fftModel.startDemo();fftModel.mode="FFT";fftModel.fftBand=1000;fftModel.fftAverage=4;fftModel.resetSpectrum()
    try check(fftModel.plot.xMax<=1000,"FFT range")
    fftModel.fftBand=10000;fftModel.fitPlot();try check(!fftModel.plot.peaks.isEmpty,"FFT marker data")
    if let index=CommandLine.arguments.firstIndex(of:"--export-fft-preview"),index+1<CommandLine.arguments.count{let image=try ChartExport.png(plot:fftModel.plot,title:"FFT CH1",measurements:fftModel.measurements,receivedUTC:frame.completedUTC);try image.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))}
    print("Duty cycle, pulse width, AC RMS, unavailable timing, FFT power averaging, rolling-window decay, peak frequency and range verified.")
    let refSignal=(0..<1024).map{sin(2 * Double.pi * 8 * Double($0)/1024)}
    let delayedSignal=(0..<2048).map{1+1.1*sin(2 * Double.pi * 8 * Double($0-10)/2048)}
    let comparison=ReferenceComparison.compare(live:Capture(volts:[delayedSignal,[]],rate:2048,trigger:0,raw:Data()),reference:Capture(volts:[refSignal,[]],rate:1024,trigger:0,raw:Data()),channel:0)
    try check(abs((comparison?.delay ?? 0)-5.0/1024)<1e-8,"reference delay with different sample rates")
    try check(abs((comparison?.deltaMean ?? 0)-1)<1e-8 && abs((comparison?.deltaVpp ?? 0)-0.2)<1e-8,"reference voltage differences")
    let noteURL=FileManager.default.temporaryDirectory.appendingPathComponent("ScopeMac-notes-test-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:noteURL)}
    let notes=RecordingNotes(identity:"recording-A",bookmarks:[SnapshotBookmark(index:1,elapsed:0.7,note:"Check this edge")])
    try notes.encoded().write(to:noteURL)
    let loadedNotes=try RecordingNotes.load(url:noteURL,identity:"recording-A",count:2)
    try check(loadedNotes.bookmarks == notes.bookmarks,"bookmark notes persist")
    var wrongRecording=false;do{_=try RecordingNotes.load(url:noteURL,identity:"recording-B",count:2)}catch{wrongRecording=true};try check(wrongRecording,"notes cannot attach to another recording")
    let disabledTrend=TrendValues(Metrics([],rate:500000));try check(TrendMetric.vpp.value(disabledTrend) == nil,"disabled channels do not create zero trend values")
    var described=frame;described.metadata=CaptureMetadata(identity:"DSO2D15 test",settings:Settings(),settingsReadUTC:100)
    let describedRecord=RecordedFrame(described,elapsed:1);let describedRoundTrip=try JSONDecoder().decode(RecordedFrame.self,from:JSONEncoder().encode(describedRecord))
    try check(describedRoundTrip.capture.metadata == described.metadata,"instrument metadata survives recording")
    let recoveryModel=ScopeModel(preferences:.transient);recoveryModel.startDemo();let retainedID=recoveryModel.plot.id
    recoveryModel.worker.onConnected?(false);recoveryModel.worker.onRun?("Unknown");recoveryModel.worker.onFailure?("USB disconnected")
    try check(recoveryModel.hasCapture && recoveryModel.plot.id == retainedID && recoveryModel.recoveryMessage.contains("Reconnect") && recoveryModel.runState == "Unknown","connection failure retains data and exposes recovery")
    recoveryModel.receive(described,changed:true,state:"RUN");try check(recoveryModel.captureInfo.contains("DSO2D15 test") && recoveryModel.captureInfo.contains("cached"),"capture information identifies cached settings")
    var canceledLoad=false;do{_=try StreamRecordingReader(url:streamURL,cancelled:{true})}catch{canceledLoad=true};try check(canceledLoad,"large recording indexing can be canceled")
    print("Bookmarks/notes, trend availability, reference delay/voltage comparisons, metadata round trip and connection recovery verified.")
    if Bundle.main.bundleURL.pathExtension == "app" {
        let iconURL=Bundle.main.resourceURL!.appendingPathComponent("AppIcon.icns")
        try check(NSImage(contentsOf:iconURL) != nil,"release app icon loads")
        try check(Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") as? String == "AppIcon","release icon registered")
        let license=try String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("LICENSE"),encoding:.utf8)
        let notice=try String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("NOTICE.md"),encoding:.utf8)
        try check(license.contains("GNU GENERAL PUBLIC LICENSE") && notice.contains("libusb") && notice.contains("OpenHantek6022"),"About license and attribution resources bundled")
        print("Packaged app icon, license, attribution resources and bundle registration verified.")
    }
    let runningControls=AcquisitionControls(connected:true,state:"RUN",busy:false),stoppedControls=AcquisitionControls(connected:true,state:"STOP",busy:false)
    try check(!runningControls.canRun && runningControls.canStop,"RUN state only enables STOP")
    try check(stoppedControls.canRun && !stoppedControls.canStop,"STOP state only enables RUN")
    for controls in [AcquisitionControls(connected:false,state:"RUN",busy:false),AcquisitionControls(connected:true,state:"Unknown",busy:false),AcquisitionControls(connected:true,state:"RUN",busy:true)]{try check(!controls.canRun && !controls.canStop,"disconnected, unknown or pending state prevents acquisition writes")}
    print("Acquisition current-state actions, pending readback and disconnected/unknown state guards verified.")
    let display=ScopeModel(preferences:.transient);display.startDemo()
    try check(display.setVoltageLimits(-2,8),"valid manual voltage limits")
    display.receive(frame,changed:true,state:"RUN")
    try check(display.plot.yMin == -2 && display.plot.yMax == 8,"voltage limits survive new captures")
    try check(!display.setVoltageLimits(8,-2) && !display.setVoltageLimits(.nan,8) && display.plot.yMax == 8,"invalid voltage limits preserve range")
    display.setVoltageLock(false);try check(!display.voltageLocked && display.plot.yMax != 8,"automatic voltage scaling restored")
    var hoverPlot=PlotData();hoverPlot.values=[[1,2,3],[4,5]];hoverPlot.xMin=0;hoverPlot.xMax=2;hoverPlot.traceStarts=[0,1];hoverPlot.traceSteps=[1,0.5]
    let hovered=hoverSamples(plot:hoverPlot,fraction:0.5)
    try check(hovered == [HoverSample(channel:0,time:1,value:2),HoverSample(channel:1,time:1,value:4)],"hover uses independent original sample timing")
    try check(hoverSamples(plot:hoverPlot,fraction:0).count == 1,"hover omits traces outside their captured range")
    display.updateHover(0.5);try check(!display.hoverReadouts.isEmpty,"model publishes hover samples");display.updateHover(nil);try check(display.hoverReadouts.isEmpty,"pointer exit clears readout")
    display.selectSummary("DC",enabled:true);display.selectSummary("Vpp",enabled:false)
    try check(display.summaryText(1).contains("DC") && !display.summaryText(1).contains("Vpp"),"summary measurement selection")
    for choice in SummaryMeasurement.allCases{display.selectSummary(choice.rawValue,enabled:false)}
    try check(display.summarySelection.count == 1,"summary retains at least one measurement")
    var layout=DisplayPreferences();layout.voltageLocked=true;layout.voltageMinimum=10;layout.sidebarWidth=900;layout.expandedPanels=["trigger","invalid"];layout.summarySelection=["unknown"]
    let safe=layout.validated();try check(safe.voltageLocked == false && safe.sidebarWidth == 460 && safe.expandedPanels == ["trigger"] && safe.summarySelection == SummaryMeasurement.defaults,"layout and partial axis preferences validated")
    layout.voltageMinimum = -2;layout.voltageMaximum=8;layout.summarySelection=["DC","RMS"]
    let savedLayout=DisplayPreferences.decode(try JSONEncoder().encode(layout))
    try check(savedLayout.voltageMinimum == -2 && savedLayout.voltageMaximum == 8 && savedLayout.summarySelection == ["RMS","DC"],"new display preferences round trip")
    let overview=RecordingOverview(name:"test.scopemac",size:4096,count:11,duration:5.4,bookmarks:2,firstUTC:100)
    try check(overview.summary.contains("11 snapshots") && overview.summary.contains("2 bookmarks"),"recording overview summary")
    fftModel.fftSource=1;fftModel.resetSpectrum();try check(fftModel.plot.colorIndices == [1],"CH2 FFT keeps channel color")
    display.stopDemo();fftModel.stopDemo()
    print("Manual voltage bounds, actual-sample hover, configurable summary, layout preferences, recording overview and FFT channel color verified.")
    let timeTicks=axisTicks(0,0.007998,target:6,scale:1000)
    try check(timeTicks.map(\.label) == ["0","2","4","6"],"rounded millisecond axis ticks")
    let voltageTicks=axisTicks(-0.6,5.7,target:8)
    try check(voltageTicks.contains{$0.value == 0 && $0.label == "0"} && voltageTicks.allSatisfy{$0.value >= -0.6 && $0.value <= 5.7},"zero line and in-range voltage ticks")
    let closeTicks=axisTicks(0.003681,0.004317,target:6,scale:1000)
    try check(Set(closeTicks.map(\.label)).count == closeTicks.count && closeTicks.count>=3,"zoomed axis labels remain distinct")
    try check(axisTicks(.nan,1).isEmpty && axisTicks(1,1).isEmpty,"invalid axes produce no ticks")
    print("Rounded axes, zero tick, zoom precision and invalid-range guards verified.")
    var themePreferences=DisplayPreferences();themePreferences.theme="Light"
    let lightStore=PreferenceStore(load:{try? JSONEncoder().encode(themePreferences)},save:{_ in})
    let lightModel=ScopeModel(preferences:lightStore)
    try check(lightModel.theme == .light && lightModel.plot.theme == .light,"theme restores before first capture")
    lightModel.startDemo();let themedID=lightModel.plot.id;lightModel.theme = .medium
    try check(lightModel.plot.theme == .medium && lightModel.plot.id != themedID,"theme change invalidates retained Metal geometry")
    themePreferences.theme="invalid";try check(themePreferences.validated().theme == "Dark","invalid theme falls back safely")
    for theme in ScopeTheme.allCases{
        let yellow=traceColor(0,theme:theme),green=traceColor(1,theme:theme)
        try check(yellow.x>yellow.z && yellow.y>yellow.z && green.y>green.x && green.y>green.z,"CH1 yellow and CH2 green in every theme")
        if let index=CommandLine.arguments.firstIndex(of:"--export-theme-previews"),index+1<CommandLine.arguments.count{
            var themed=lightModel.plot;themed.theme=theme
            themed.values=[square,square.map{$0*0.5}];themed.traceStarts=[0,0];themed.traceSteps=[0.000002,0.000002]
            let png=try ChartExport.png(plot:themed,title:"Waveform · \(theme.rawValue)",measurements:"CH1 Yellow · CH2 Green",receivedUTC:frame.completedUTC)
            try png.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]).appendingPathComponent("ScopeMac-theme-"+theme.rawValue.lowercased()+".png"))
        }
    }
    lightModel.stopDemo()
    print("Saved themes, empty plot restoration, Metal invalidation and yellow/green channel palettes verified.")
    try check(formatFrequency(1001.6) == "1.002 kHz" && formatFrequency(999.6) == "999.6 Hz" && formatFrequency(12_500_000) == "12.50 MHz" && formatFrequency(122.07) == "122.1 Hz","frequency labels avoid exponent notation")
    let crowdedAnchors=[CGPoint(x:79,y:248),CGPoint(x:94,y:274),CGPoint(x:109,y:282)],labelSize=CGSize(width:70,height:18)
    let crowded=layoutPointLabels(anchors:crowdedAnchors,sizes:Array(repeating:labelSize,count:3),bounds:CGRect(x:64,y:215,width:820,height:260))
    let crowdedRects=crowded.compactMap{$0}.map{CGRect(x:$0.x-35,y:$0.y-9,width:70,height:18)}
    try check(crowdedRects.count == 3,"crowded peak labels all placed")
    for i in crowdedRects.indices { for j in crowdedRects.indices where j>i { try check(!crowdedRects[i].intersects(crowdedRects[j]),"peak labels do not overlap") } }
    try check(crowdedRects.allSatisfy{rect in crowdedAnchors.allSatisfy{!rect.contains($0)}},"peak labels leave markers visible")
    print("Frequency formatting and non-overlapping peak labels verified.")
    let start=Date(); for _ in 0..<100 { _ = fftDB(square) }; print(String(format:"FFT benchmark: %.3f ms per 4000-sample spectrum",Date().timeIntervalSince(start)*10))
    print("Real private/public packets, stale cursor recovery, calibration, independent channel decoding, corrupt packet rejection, FFT RMS/DC, square-wave measurements verified.")
}
