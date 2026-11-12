// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class ScopeWorker {
    let queue = DispatchQueue(label: "ScopeMac.USB", qos: .userInitiated)
    private let cancelLock = NSLock()
    private var cancellation = false
    private func canceled() -> Bool { cancelLock.lock(); defer { cancelLock.unlock() }; return cancellation }
    private func setCanceled(_ value: Bool) { cancelLock.lock(); cancellation = value; cancelLock.unlock() }
    private var refreshInterval=0.0,lastCaptureStart=0.0
    private var pendingCapture: DispatchWorkItem?
    func setRefreshInterval(_ seconds: Double) {queue.async {
        self.refreshInterval=seconds.isFinite ? min(60,max(0,seconds)):0
        self.generation += 1;self.pendingCapture?.cancel();self.pendingCapture=nil
        if self.repeating {self.scheduleCapture()}
    }}
    private func scheduleCapture() {
        let cycle=generation
        let delay=refreshDelay(interval:refreshInterval,elapsed:monotonic()-lastCaptureStart)
        let item=DispatchWorkItem { [weak self] in guard let self,self.repeating,self.generation==cycle else{return};self.pendingCapture=nil;self.capture() }
        pendingCapture=item;queue.asyncAfter(deadline:.now()+delay,execute:item)
    }
    private var scopeIdentity="",settingsReadUTC=0.0
    private var diagnostics: DiagnosticLog?
    private var connection: Connection?, settings = Settings(), repeating = false, generation = 0
    private var overlapUSB = false
    func setOverlap(_ enabled: Bool) { queue.async { self.overlapUSB=enabled; self.connection?.setOverlap(enabled); self.diagnostics?.record("Overlapped waveform USB: \(enabled)") } }
    private var pollStatus = true
    func setStatusPolling(_ value: Bool) { queue.async { self.pollStatus=value } }
    private var previous: Capture?, previousSettings: Settings?, lastPoll = Date.distantPast, lastState = "Unknown"
    var onCapture: ((Capture, Bool, String) -> Void)?, onStatus: ((String) -> Void)?, onSettings: ((Settings) -> Void)?, onConnected: ((Bool) -> Void)?, onRun: ((String) -> Void)?
    var onRunCommandDone:(()->Void)?
    var onFailure: ((String)->Void)?
    var onTrigger: ((TriggerSettings) -> Void)?, onTriggerBusy: ((Bool) -> Void)?
    func status(_ text: String) { DispatchQueue.main.async { self.onStatus?(text) } }
    func publishSettings(_ s: Settings) { settingsReadUTC=Date().timeIntervalSince1970;DispatchQueue.main.async { self.onSettings?(s) } }
    func connect() { setCanceled(false); queue.async {
        guard self.connection == nil else { return }
        do {
            let log = DiagnosticLog(); self.diagnostics = log
            let c = Connection(); c.diagnostics = log; try c.open(); c.setOverlap(self.overlapUSB); self.connection = c
            let id = try c.text("*IDN?"); guard id.contains("DSO2D15") else { throw ScopeError("This release supports DSO2D15 only: \(id)") }
            self.scopeIdentity=id;self.settings = try c.settings(); self.previous = nil; self.previousSettings = nil
            self.publishSettings(self.settings); self.lastState = try c.runState(); self.lastPoll = Date()
            let state = self.lastState
            DispatchQueue.main.async { self.onConnected?(true); self.onRun?(state) }; self.status(id)
            self.capture()
        } catch { self.fail(error) }
    } }
    func fail(_ error: Error) {
        repeating = false; generation += 1; pendingCapture?.cancel();pendingCapture=nil;connection?.close(); connection = nil
        diagnostics?.record("ERROR: " + error.localizedDescription)
        status(error.localizedDescription + (diagnostics.map { " · Diagnostics: " + $0.directory.path } ?? ""))
        let detail=error.localizedDescription
        DispatchQueue.main.async { self.onConnected?(false);self.onRun?("Unknown");self.onFailure?(detail) }
    }
    func disconnect(_ done: (() -> Void)? = nil) { setCanceled(true); queue.async {
        self.repeating = false; self.generation += 1;self.pendingCapture?.cancel();self.pendingCapture=nil
        var message="Disconnected."
        if let c = self.connection {
            do {try c.returnToLocal();message="Local-control requests completed; USB closed."}
            catch {message="USB closed; local-control cleanup warning: "+error.localizedDescription}
            c.close();self.diagnostics?.record("Cleanup: USB handle closed")
        }; self.connection = nil
        let result=message
        DispatchQueue.main.async { self.onConnected?(false); self.onRun?("Unknown"); self.onStatus?(result); done?() }
    } }
    func setRepeat(_ enabled: Bool) { queue.async {
        guard enabled != self.repeating else { return }; self.repeating = enabled; self.generation += 1;self.pendingCapture?.cancel();self.pendingCapture=nil
        if enabled { self.capture() }
    } }
    func once() { queue.async { if !self.repeating { self.capture() } } }
    private func capture() {
        guard let c = connection else { return }; let cycle = generation
        do {
            let start = monotonic(), assembler = Assembler()
            lastCaptureStart=start
            var usbMS = 0.0, assemblyMS = 0.0
            var transfer = TransferTrace()
            diagnostics?.beginCapture()
            while true {
                if canceled() { return }
                if monotonic()-start > 120 { throw ScopeError("Capture timed out") }
                let before = assembler.covered
                let queryStart = monotonic()
                let packet = try c.query(":PRIVate:WAVeform:DATA:ALL?")
                usbMS += (monotonic()-queryStart)*1000
                diagnostics?.packet(packet)
                let assemblyStart = monotonic()
                let skippedBefore=assembler.skipped
                let complete = try assembler.append(packet)
                assemblyMS += (monotonic()-assemblyStart)*1000
                transfer.append(c.lastQuery,noProgress:before == assembler.covered,stalePacket:assembler.skipped > skippedBefore)
                diagnostics?.record("Waveform packet \(transfer.packets): "+c.lastQuery.summary+"; assembled \(assembler.covered)/\(assembler.samples.count); stale \(assembler.skipped)")
                if complete { break }
                if before == assembler.covered { Thread.sleep(forTimeInterval: 0.02) }
            }
            let decodeStart = monotonic()
            var frame = try assembler.decode(settings)
            frame.metadata=CaptureMetadata(identity:scopeIdentity,settings:settings,settingsReadUTC:settingsReadUTC)
            frame.decodeMS = (monotonic()-decodeStart)*1000
            frame.usbMS = usbMS; frame.assemblyMS = assemblyMS; frame.transport=transfer
            let changed = previous?.raw != frame.raw || previous?.volts.map(\.count) != frame.volts.map(\.count) || previous?.rate != frame.rate || previous?.trigger != frame.trigger || previousSettings != settings
            diagnostics?.record(String(format:"Capture %.1f ms, %.0f samples/s, CH1 %d, CH2 %d, changed %@", frame.usbMS,frame.rate,frame.volts[0].count,frame.volts[1].count,changed ? "yes":"no"))
            previous = frame; previousSettings = settings
            if pollStatus && Date().timeIntervalSince(lastPoll) >= 2 { let pollStart=monotonic(); lastState = try c.runState(); frame.statusMS=(monotonic()-pollStart)*1000; lastPoll = Date() }
            frame.totalMS=(monotonic()-start)*1000
            diagnostics?.record(String(format:"Timing: USB query %.3f / assembly %.3f / decode %.3f / status query %.3f / cycle %.3f ms",frame.usbMS,frame.assemblyMS,frame.decodeMS,frame.statusMS,frame.totalMS))
            let state = lastState
            DispatchQueue.main.async { self.onCapture?(frame, changed, state) }
        } catch { fail(error); return }
        if repeating && cycle == generation {scheduleCapture()}
    }
    func readSettings() { queue.async { guard let c = self.connection else { return }; do { self.settings = try c.settings(); self.publishSettings(self.settings); self.status("Settings read from the scope.") } catch { self.fail(error) } } }
    func run(_ enabled: Bool) { queue.async { defer{DispatchQueue.main.async{self.onRunCommandDone?()}};guard let c = self.connection else { return }; do { try c.write(":RUNning \(enabled ? "ON" : "OFF")"); self.lastState = try c.runState(); self.lastPoll = Date(); let state = self.lastState; DispatchQueue.main.async { self.onRun?(state) } } catch { self.fail(error) } } }
    func readRun() {queue.async{defer{DispatchQueue.main.async{self.onRunCommandDone?()}};guard let c=self.connection else{return};do{self.lastState=try c.runState();self.lastPoll=Date();let state=self.lastState;DispatchQueue.main.async{self.onRun?(state)}}catch{self.fail(error)}}}
    private func triggerBusy(_ value: Bool) { DispatchQueue.main.async { self.onTriggerBusy?(value) } }
    func readTriggerSettings() { queue.async { guard let c=self.connection else { return };self.triggerBusy(true);defer{self.triggerBusy(false)}
        do { let result=try readTrigger(query:c.text);DispatchQueue.main.async { self.onTrigger?(result) };self.status("Trigger settings read from the scope.") } catch { self.fail(error) }
    } }
    func applyTriggerSettings(_ desired: TriggerSettings) { queue.async { guard let c=self.connection else { return }
        do { try desired.validate() } catch { self.status(error.localizedDescription);return }
        self.triggerBusy(true);defer{self.triggerBusy(false)}
        do { let actual=try applyTrigger(desired,write:c.write,query:c.text);DispatchQueue.main.async { self.onTrigger?(actual) };self.status("EDGE trigger applied; scope readback replaces the inputs.") } catch { self.fail(error) }
    } }
    func forceTrigger() { queue.async { guard let c=self.connection else { return };self.triggerBusy(true);defer{self.triggerBusy(false)}
        do { try c.write(":TRIGger:FORCe");self.lastState=try c.runState();self.lastPoll=Date();let state=self.lastState;DispatchQueue.main.async { self.onRun?(state) };self.status("Force Trigger sent; acquisition state read back.") } catch { self.fail(error) }
    } }
    func apply(_ desired: Settings) { queue.async { guard let c = self.connection else { return }
        var performingIO = false
        do {
            guard desired.timebase.isFinite, desired.timebase >= 1e-9, desired.timebase <= 100 else { throw ScopeError("Timebase must be 1 ns to 100 s/div") }
            guard desired.channels.contains(where: \.enabled) else { throw ScopeError("Keep at least one input enabled") }
            for ch in desired.channels { guard ch.scale.isFinite, ch.scale > 0, ch.scale <= 10000, ch.offset.isFinite, abs(ch.offset) <= 1e6, [1.0,10,100,1000].contains(ch.probe), ["DC","AC","GND"].contains(ch.coupling) else { throw ScopeError("Invalid channel settings") } }
            performingIO = true
            for i in 0..<2 {
                let p = ":CHANnel\(i+1)", a = self.settings.channels[i], b = desired.channels[i]
                if a.probe != b.probe { try c.write(p+":PROBe \(b.probe)") }
                if a.scale != b.scale { try c.write(p+":SCALe \(b.scale)") }
                if a.offset != b.offset { try c.write(p+":OFFSet \(b.offset)") }
                if a.coupling != b.coupling { try c.write(p+":COUPling \(b.coupling)") }
                if a.enabled != b.enabled { try c.write(p+":DISPlay \(b.enabled ? "ON" : "OFF")") }
            }
            if desired.timebase != self.settings.timebase { try c.write(":TIMebase:SCALe \(desired.timebase)") }
            self.settings = try c.settings(); self.publishSettings(self.settings); self.status("Settings applied and read back.")
            if !self.repeating { self.capture() }
        } catch { if !performingIO { self.status(error.localizedDescription) } else { self.fail(error) } }
    } }
}

struct PlotData {
    var theme:ScopeTheme = .dark
    var id = UUID(); var values: [[Double]] = [[],[]]; var xMin = 0.0, xMax = 0.008, yMin = -1.0, yMax = 6.0
    var isFFT = false
    var peaks=[SpectralPeak]()
    var colorIndices=[Int]()
    var sampleStart = 0.0, sampleStep = 0.000002
    var traceStarts=[Double](),traceSteps=[Double]()
}
func fftDB(_ input: [Double]) -> [Double] {
    guard input.count >= 4 else { return [] }; let count = min(input.count, 65536)
    var n = 1; while n < count { n *= 2 }
    var re = [Double](repeating:0,count:n), im = re
    let mean = input.prefix(count).reduce(0,+)/Double(count); var gain = 0.0
    for i in 0..<count { let w = 0.5-0.5*cos(2 * .pi * Double(i)/Double(count-1)); gain += w; re[i] = (input[i]-mean)*w }
    var j = 0
    for i in 1..<n { var bit = n>>1; while j & bit != 0 { j ^= bit; bit >>= 1 }; j ^= bit; if i < j { re.swapAt(i,j); im.swapAt(i,j) } }
    var length = 2
    while length <= n {
        let angle = -2 * Double.pi/Double(length), wr = cos(angle), wi = sin(angle)
        for base in stride(from:0,to:n,by:length) { var r = 1.0, s = 0.0
            for k in 0..<length/2 { let a = base+k,b = a+length/2,t = r*re[b]-s*im[b],u = r*im[b]+s*re[b]; re[b] = re[a]-t; im[b] = im[a]-u; re[a] += t; im[a] += u; let next = r*wr-s*wi; s = r*wi+s*wr; r = next }
        }; length *= 2
    }
    return (0...n/2).map { i in 20*log10(max(1e-15,hypot(re[i],im[i])/gain * (i == 0 || i == n/2 ? 1 : sqrt(2)))) }
}
final class ScopeModel: ObservableObject {
    @Published var theme:ScopeTheme = .dark {didSet{saveDisplayPreferences();rebuild()}}
    @Published var voltageLocked=false
    @Published var voltageMinimum = -1.0
    @Published var voltageMaximum=6.0
    @Published var hoverReadouts=[HoverSample]()
    private var hoverFraction:Double?
    @Published var summarySelection=SummaryMeasurement.defaults
    @Published var sidebarWidth=280.0 {didSet{saveDisplayPreferences()}}
    @Published var expandedPanels=[String]() {didSet{saveDisplayPreferences()}}
    @Published var recordingOverview:RecordingOverview?
    @Published var recordingPreviewVisible=false
    private var pendingArchive:CaptureRecording?,pendingReader:StreamRecordingReader?,pendingURL:URL?
    @Published var insightsVisible=false
    @Published var releaseNotesVisible=false
    @Published var recoveryMessage=""
        @Published var trendMetric=TrendMetric.vpp
    @Published var trendChannel=0
    @Published var trends=[TrendPoint]()
    private var trendEpoch:Double?
    @Published var comparisonText=""
    @Published var captureInfo="No capture yet."
    @Published var notesWarning=""
    @Published var bookmarks=[SnapshotBookmark]()
    @Published var bookmarkNote=""
    @Published var recordingBookmarkTarget:Int?
    private var notesURL:URL?,notesIdentity="",recordingSavedElapsed=0.0
    @Published var refreshInterval=0.0 {didSet{saveDisplayPreferences();worker.setRefreshInterval(refreshInterval);if demo{scheduleDemo()}}}
    @Published var diagnosticsVisible=false
    @Published var hasReference=false
    @Published var referenceVisible=true
    private var reference: Capture?
    var hasCapture: Bool {frame != nil}
    @Published var recording=false
    @Published var recordingCount=0
    @Published var savingRecording=false
    @Published var loadingRecording=false
    private let loadLock=NSLock()
    private var loadCancelled=false
    func cancelRecordingLoad(){loadLock.lock();loadCancelled=true;loadLock.unlock()}
    private func loadIsCancelled()->Bool{loadLock.lock();defer{loadLock.unlock()};return loadCancelled}
    @Published var playbackLoaded=false
    @Published var playbackCount=0
    @Published var playbackIndex=0
    @Published var playing=false
    private var recordStart=0.0, recordURL: URL?
    private var playback: CaptureRecording?, playbackTimer: Timer?
    private var playbackStream: StreamRecordingReader?, playbackLoadGeneration=0
    private var streamWriter: StreamRecordingWriter?, pendingRecordWrites=0
    private var streamFailure: String?
    private var shuttingDown=false
    @Published var recordingBytes: UInt64=0
    @Published var recordingElapsed=0.0
    private let recordingQueue=DispatchQueue(label:"ScopeMac.Recordings",qos:.utility)
    @Published var inspectorVisible=true { didSet { saveDisplayPreferences() } }
    private let preferenceStore: PreferenceStore
    private var preferencesReady=false
    @Published var connecting=false
    @Published var connected = false
    @Published var repeating = false
    @Published var demo = false
    @Published var status = "Connect your DSO2D15 using its rear USB port, or explore Demo."
    @Published var acquisitionBusy=false
    var acquisitionControls:AcquisitionControls{AcquisitionControls(connected:connected,state:runState,busy:acquisitionBusy)}
    func requestAcquisition(_ running:Bool){guard running ? acquisitionControls.canRun:acquisitionControls.canStop else{return};acquisitionBusy=true;worker.run(running)}
    func refreshAcquisition(){guard connected,!acquisitionBusy else{return};acquisitionBusy=true;worker.readRun()}
    @Published var runState = "Unknown"
    @Published var runVerifiedAt: Date?
    @Published var pollStatus = true
    @Published var overlapUSB = false
    @Published var displayStatus = "No capture yet"
    @Published var dashboard = "No capture yet"
    @Published var measurements = ""
    @Published var channelMetrics=[Metrics([],rate:0),Metrics([],rate:0)]
    @Published var settings = Settings()
    @Published var trigger = TriggerSettings()
    @Published var triggerRead = false
    @Published var triggerBusy = false
    @Published var triggerReadMode = "Unread"
    @Published var plot = PlotData()
    @Published var mode = "Waveform" { didSet { saveDisplayPreferences() } }
    @Published var fftBand=10000.0 {didSet{saveDisplayPreferences()}}
    @Published var fftAverage=1 {didSet{saveDisplayPreferences()}}
    @Published var showFFTPeaks=true {didSet{saveDisplayPreferences()}}
    @Published var fftPeakText=""
    private var spectrumAverage=SpectrumAverage(),cachedSpectrum=[Double]()
    private var spectrumSource = -1,spectrumCount=0
    private var spectrumRate=0.0
    @Published var fftSource = 0 { didSet { saveDisplayPreferences() } }
    @Published var showCH1 = true { didSet { saveDisplayPreferences() } }
    @Published var showCH2 = true { didSet { saveDisplayPreferences() } }
    @Published var cursors = false { didSet { saveDisplayPreferences() } }
    @Published var selectedCursor = 0 { didSet { saveDisplayPreferences() } }
    @Published var cursorA = 0.002
    @Published var cursorB = 0.003
    @Published var zoom = 1.0
    @Published var transportPerformance = ""
    @Published var performance = "Timing available after first capture and Metal draw."
    private var viewport: Viewport?
    private var fullViewport = Viewport(lower:0,upper:0.008)
    private var renderTiming = RenderTiming(), analysisMS = 0.0
    private var displayChanged = false
    private var frame: Capture?, times = [Date](), changedAt = Date(), demoTimer: Timer?
    let worker = ScopeWorker()
    init(preferences: PreferenceStore = .standard) {
        preferenceStore=preferences
        let saved=DisplayPreferences.decode(preferences.load())
        theme=ScopeTheme(rawValue:saved.theme ?? "Dark") ?? .dark
        fftBand=saved.fftBand ?? 10000;fftAverage=saved.fftAverage ?? 1;showFFTPeaks=saved.showFFTPeaks ?? true
        voltageLocked=saved.voltageLocked ?? false;voltageMinimum=saved.voltageMinimum ?? -1;voltageMaximum=saved.voltageMaximum ?? 6
        summarySelection=saved.summarySelection ?? SummaryMeasurement.defaults;sidebarWidth=saved.sidebarWidth ?? 280;expandedPanels=saved.expandedPanels ?? []
        mode=saved.mode;fftSource=saved.fftSource;showCH1=saved.showCH1;showCH2=saved.showCH2
        refreshInterval=saved.refreshInterval ?? 0
        worker.setRefreshInterval(refreshInterval)
        cursors=saved.cursors;selectedCursor=saved.selectedCursor;inspectorVisible=saved.inspector
        plot.theme=theme;preferencesReady=true
        worker.onFailure = { [weak self] message in
            guard let self else{return}
            self.displayStatus="Downloads paused";self.dashboard=self.hasCapture ? "Disconnected · last displayed trace retained":"No capture yet"
            self.recoveryMessage="Connection error: "+message+(self.hasCapture ? ". Last displayed trace retained.":".")+" Check the cable, close other scope apps, then Reconnect. Live downloads resume only when you press Live view."
        }
        worker.onTrigger = { [weak self] value in self?.trigger=value; self?.triggerRead=true;self?.triggerReadMode=value.mode }
        worker.onTriggerBusy = { [weak self] in self?.triggerBusy=$0 }
        worker.onStatus = { [weak self] in self?.status = $0 }
        worker.onSettings = { [weak self] in self?.settings = $0 }
        worker.onConnected = { [weak self] value in self?.connected = value; self?.connecting=false;if value{self?.recoveryMessage=""}; if !value { self?.displayStatus="Disconnected · trace retained";if self?.recording == true { self?.finishRecording() }; self?.repeating = false;self?.acquisitionBusy=false; self?.triggerRead=false; self?.triggerReadMode="Unread" } }
        worker.onRunCommandDone = {[weak self] in self?.acquisitionBusy=false}
        worker.onRun = { [weak self] state in self?.runState = state; self?.runVerifiedAt = state == "Unknown" ? nil:Date() }
        worker.onCapture = { [weak self] in self?.receive($0, changed:$1, state:$2) }
    }
    private func saveDisplayPreferences() {
        guard preferencesReady else { return }
        let saved=DisplayPreferences(mode:mode,fftSource:fftSource,showCH1:showCH1,showCH2:showCH2,cursors:cursors,inspector:inspectorVisible,selectedCursor:selectedCursor,refreshInterval:refreshInterval,fftBand:fftBand,fftAverage:fftAverage,showFFTPeaks:showFFTPeaks,voltageLocked:voltageLocked,voltageMinimum:voltageMinimum,voltageMaximum:voltageMaximum,summarySelection:summarySelection,sidebarWidth:sidebarWidth,expandedPanels:expandedPanels,theme:theme.rawValue)
        preferenceStore.save(try? JSONEncoder().encode(saved))
    }
    func resetDisplayPreferences() {
        theme = .dark;voltageLocked=false;summarySelection=SummaryMeasurement.defaults;sidebarWidth=280;expandedPanels=[];refreshInterval=0;fftBand=10000;fftAverage=1;showFFTPeaks=true;mode="Waveform";fftSource=0;showCH1=true;showCH2=true;cursors=false;selectedCursor=0;inspectorVisible=true
        preferenceStore.save(nil);fitPlot();status="Display preferences reset. Instrument settings unchanged."
    }
    func connect() { guard !savingRecording,!connecting,!recording else{return};recoveryMessage="";connecting=true;closePlayback(); stopDemo(); status = "Connecting and reading settings…"; worker.connect() }
    func receive(_ capture: Capture, changed: Bool, state: String) {
        if recording { appendRecording(capture) }
        if frame?.rate != capture.rate || frame?.volts.map(\.count) != capture.volts.map(\.count){spectrumAverage.clear();cachedSpectrum=[]}
        frame = capture; runState = state; if capture.statusMS > 0 { runVerifiedAt=Date() }; let now = Date(); analysisMS=0; times.append(now); if times.count > 21 { times.removeFirst() }; if changed { changedAt = now;if mode != "FFT"{cachedSpectrum=[];spectrumAverage.clear()}; rebuild(advanceSpectrum:true) } else if mode == "FFT" && fftAverage>1 {rebuild(advanceSpectrum:true)}
        let fps = times.count > 1 ? Double(times.count-1)/max(0.001,now.timeIntervalSince(times[0])) : 0
        displayStatus = String(format:"%.2f updates/s",fps)
        dashboard = String(format:"%.2f updates/s  ·  USB %.1f ms  ·  content unchanged %.1f s",fps,capture.usbMS,now.timeIntervalSince(changedAt))
        let analysisStart = monotonic()
        if changed {
            let metrics=capture.volts.map{Metrics($0,rate:capture.rate)};channelMetrics=metrics
            measurements=capture.volts.enumerated().filter{!$0.element.isEmpty}.map {ch,v in
                let m=metrics[ch];return String(format:"CH%d   %.3g Vpp   %.3g V RMS   %@   %d points",ch+1,m.vpp,m.rms,m.frequency>0 ? String(format:"%.4g Hz",m.frequency):"— Hz",v.count)
            }.joined(separator:"     |     ")
        }
        if !playbackLoaded {
            if trendEpoch==nil{trendEpoch=capture.completedMonotonic}
            let point=TrendPoint(elapsed:max(0,capture.completedMonotonic-trendEpoch!),metrics:channelMetrics)
            trends.append(point);if trends.count>2000{trends.removeFirst(trends.count-2000)}
        }
        updateCaptureInfo(capture);if changed{updateComparison()}
        updateSummary()
        analysisMS += (monotonic()-analysisStart)*1000
        displayChanged=changed; transportPerformance=capture.transport.summary+"\n"+capture.transport.detail; updatePerformance()
    }
    func resetSpectrum(){spectrumAverage.clear();cachedSpectrum=[];rebuild()}
    func rebuild(advanceSpectrum: Bool=false) {
        guard let frame else { plot.theme=theme;plot.id=UUID();return }; let begin=monotonic(); var p = PlotData(); p.xMin = -frame.trigger; p.xMax = frame.duration-frame.trigger
        if mode == "FFT" {
            if spectrumSource != fftSource || spectrumRate != frame.rate || spectrumCount != frame.volts[fftSource].count {
                spectrumAverage.clear();cachedSpectrum=[];spectrumSource=fftSource;spectrumRate=frame.rate;spectrumCount=frame.volts[fftSource].count
            }
            if advanceSpectrum || cachedSpectrum.isEmpty {cachedSpectrum=spectrumAverage.add(fftDB(frame.volts[fftSource]),count:fftAverage)}
            let v=cachedSpectrum;p.values=[v,[]];p.colorIndices=[fftSource];p.isFFT=true
            p.sampleStart=0
            p.xMin = 0; p.xMax = fftBand==0 ? frame.rate/2:min(fftBand,frame.rate/2)
            let n = max(1,(v.count-1)*2); p.sampleStep=frame.rate/Double(n);
            let peaks=spectralPeaks(v,spacing:p.sampleStep,limit:p.xMax);p.peaks=showFFTPeaks ? peaks:[]
            fftPeakText=v.isEmpty ? "Selected channel has no samples.":peaks.map{formatFrequency($0.frequency,digits:5)+String(format:" · %.3g dBV",$0.db)}.joined(separator:"   |   ")+"  ·  "+formatFrequency(p.sampleStep)+" bins"
             let visible = v.prefix(Int(p.xMax*Double(n)/frame.rate)+1); let peak = visible.max() ?? 0
            p.yMax = peak+6; p.yMin = min(peak-10,max(-300,peak-100))
            // Keep uniform bin coordinates when cropping to the selected frequency range.
            let count = min(v.count,Int(p.xMax*Double(n)/frame.rate)+1); p.values[0] = Array(v.prefix(count));if count>1 {p.xMax = Double(count-1)*frame.rate/Double(n)}
        } else {
            p.values = [showCH1 ? frame.volts[0]:[], showCH2 ? frame.volts[1]:[]]
            if mode == "CH1 + CH2" && !frame.volts[0].isEmpty && frame.volts[0].count == frame.volts[1].count { p.values = [zip(frame.volts[0],frame.volts[1]).map(+),[]] }
            if mode == "Waveform",referenceVisible,let reference {
                p.traceStarts=[-frame.trigger,-frame.trigger,-reference.trigger,-reference.trigger]
                p.traceSteps=[1/frame.rate,1/frame.rate,1/reference.rate,1/reference.rate]
                p.values += [showCH1 ? reference.volts[0]:[],showCH2 ? reference.volts[1]:[]]
            }
            let all = p.values.flatMap{$0}; let low = all.min() ?? -1, high = all.max() ?? 1, margin = max(0.01,(high-low)*0.12)
            p.yMin = low-margin; p.yMax = high+margin

            p.sampleStart = -frame.trigger; p.sampleStep = 1/frame.rate
        }
        if !p.isFFT && voltageLocked{p.yMin=voltageMinimum;p.yMax=voltageMaximum}
        fullViewport=Viewport(lower:p.xMin,upper:max(p.xMax,p.xMin+1e-12))
        if let range=viewport { let bounded=range.clamped(to:fullViewport); viewport=bounded; p.xMin=bounded.lower; p.xMax=bounded.upper }
        zoom=fullViewport.width/(p.xMax-p.xMin)
        p.theme=theme;plot = p;if let fraction=hoverFraction{updateHover(fraction)}; analysisMS=(monotonic()-begin)*1000
        updatePerformance()
    }
    func updateHover(_ fraction:Double?){hoverFraction=fraction;let values=fraction.map{hoverSamples(plot:plot,fraction:$0)} ?? [];if values != hoverReadouts{hoverReadouts=values}}
    func setVoltageLock(_ value:Bool){if value{voltageMinimum=plot.yMin;voltageMaximum=plot.yMax};voltageLocked=value;saveDisplayPreferences();rebuild()}
    @discardableResult func setVoltageLimits(_ lower:Double,_ upper:Double)->Bool{guard lower.isFinite,upper.isFinite,lower<upper,abs(lower)<=1e9,abs(upper)<=1e9 else{status="Voltage limits must be finite, ordered and within ±1 billion V.";return false};voltageMinimum=lower;voltageMaximum=upper;voltageLocked=true;saveDisplayPreferences();rebuild();return true}
    func summaryText(_ channel:Int)->String{guard channelMetrics.indices.contains(channel) else{return ""};return SummaryMeasurement.allCases.filter{summarySelection.contains($0.rawValue)}.map{$0.text(channelMetrics[channel])}.joined(separator:" · ")}
    func selectSummary(_ name:String,enabled:Bool){var selection=summarySelection;if enabled{if !selection.contains(name){selection.append(name)}}else{selection.removeAll{$0==name}};guard !selection.isEmpty else{return};summarySelection=selection;saveDisplayPreferences();updateSummary()}
    private func updateSummary(){measurements=(0..<channelMetrics.count).filter{channelMetrics[$0].sampleCount>0}.map{"CH\($0+1)   "+summaryText($0)}.joined(separator:" | ")}
    func expansion(_ name:String)->Binding<Bool>{Binding(get:{self.expandedPanels.contains(name)},set:{value in if value{if !self.expandedPanels.contains(name){self.expandedPanels.append(name)}}else{self.expandedPanels.removeAll{$0==name}}})}
    func fitPlot() { viewport=nil; zoom=1; rebuild() }
    func zoomPlot(factor: Double, anchor: Double) {
        viewport=Viewport(lower:plot.xMin,upper:plot.xMax).zoomed(factor:factor,anchor:anchor,within:fullViewport); rebuild()
    }
    func panPlot(fraction: Double) {
        viewport=Viewport(lower:plot.xMin,upper:plot.xMax).panned(fraction:fraction,within:fullViewport); rebuild()
    }
    func setZoom(_ value: Double) { zoomPlot(factor:value/max(1,zoom),anchor:0.5) }
    func recordRender(_ timing: RenderTiming) { renderTiming=timing; updatePerformance() }
    private func updatePerformance() {
        let f=frame
        if playbackLoaded {
            performance=String(format:"Playback analysis %.2f ms · last GPU %@ ms",analysisMS,renderTiming.gpuMS.map{String(format:"%.2f",$0)} ?? "—");return
        }
        performance=String(format:"USB query %.2f · assemble %.2f · decode %.2f · analysis %.2f ms",f?.usbMS ?? 0,f?.assemblyMS ?? 0,f?.decodeMS ?? 0,analysisMS)
        performance += String(format:"\nLast draw: geometry %.2f · CPU submit %.2f · GPU %@ ms · %@",renderTiming.geometryMS,renderTiming.submitMS,renderTiming.gpuMS.map { String(format:"%.2f",$0) } ?? "—",displayChanged ? "new data":"data reused")
        if let f, f.statusMS > 0 { performance += String(format:" · status query %.2f ms",f.statusMS) }
    }
    func setRepeat(_ value: Bool) {
        repeating=value
        if demo { displayStatus=value ? "Demo · live":"Demo · paused";scheduleDemo() } else { worker.setRepeat(value) }
    }
    var syntheticCapture: Bool { frame?.synthetic ?? false }
    private var demoStarted = Date()
    func stopDemo() {
        demoTimer?.invalidate();demoTimer=nil
        if demo { if recording {finishRecording()};repeating=false }
        demo=false
    }
    private func scheduleDemo() {
        demoTimer?.invalidate();demoTimer=nil
        guard demo,repeating else{return}
        // Keep synthesis responsive without running faster than useful UI updates.
        let interval=refreshInterval.isFinite ? max(0.1,min(60,refreshInterval)):0.1
        demoTimer=Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { [weak self] _ in self?.captureDemo() }
    }
    func captureOnce() { if demo {captureDemo()} else if connected {worker.once()} }
    func captureDemo() {
        guard demo,!shuttingDown else{return}
        let capture=demoCapture(elapsed:Date().timeIntervalSince(demoStarted))
        receive(capture,changed:true,state:"DEMO")
        displayStatus=repeating ? "Demo · live":"Demo · paused"
        dashboard="Synthetic CH1 pulse + CH2 sine · no USB transfers"
    }
    func startDemo() {
        guard !connected,!connecting,!savingRecording,!recording else{return}
        stopDemo();closePlayback();recoveryMessage="";demo=true;repeating=true
        demoStarted=Date();times=[];trends=[];trendEpoch=nil;viewport=nil
        settings.channels[0].enabled=true;settings.channels[1].enabled=true
        status="Dynamic demo · synthetic signals. Instrument controls require USB."
        captureDemo();scheduleDemo()
    }
    func snapPeriod() {
        guard let frame, !frame.volts[0].isEmpty else { return }; let v = frame.volts[0], threshold = ((v.min() ?? 0)+(v.max() ?? 1))/2
        let edges = (1..<v.count).filter { v[$0-1] < threshold && v[$0] >= threshold }
        guard edges.count > 1 else { status = "CH1 needs two rising edges for period cursors."; return }
        let middle = edges.count/2; cursorA = Double(edges[max(0,middle-1)])/frame.rate-frame.trigger; cursorB = Double(edges[middle])/frame.rate-frame.trigger; cursors = true
    }
    func freezeReference() {
        guard let frame else{return};reference=frame;hasReference=true;referenceVisible=true;rebuild();updateComparison();status="Reference frozen. Traces align using their trigger-time coordinates."
    }
    func clearReference() {reference=nil;hasReference=false;comparisonText="";rebuild()}
    func toggleReference() {referenceVisible.toggle();rebuild()}
    func exportScreenshot() {
        guard let frame else{return};let panel=NSSavePanel();panel.nameFieldStringValue=frame.synthetic ? "ScopeMac-demo.png":"ScopeMac-waveform.png";panel.allowedContentTypes=[.png]
        guard panel.runModal() == .OK,let url=panel.url else{return}
        let displayed=plot, text=measurements, title=(frame.synthetic ? "Demo · ":"")+(mode == "FFT" ? "FFT CH\(fftSource+1)":mode), received=frame.completedUTC
        let markers: (Double,Double)?=cursors && mode != "FFT" ? (cursorA,cursorB):nil
        recordingQueue.async { [weak self] in
            do {let png=try ChartExport.png(plot:displayed,title:title,measurements:text,receivedUTC:received,cursors:markers);try png.write(to:url,options:.atomic);DispatchQueue.main.async{self?.status="Saved chart image to \(url.lastPathComponent)."}}
            catch {let message=error.localizedDescription;DispatchQueue.main.async{self?.status="Image export failed: "+message}}
        }
    }
    func startRecording() {
        guard (connected || demo),!recording,!savingRecording,!shuttingDown else { return }
        let panel=NSSavePanel();panel.nameFieldStringValue=demo ? "ScopeMac-demo.scopemac":"ScopeMac-session.scopemac"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        bookmarks=[];bookmarkNote="";recordingBookmarkTarget=nil;notesWarning="";notesURL=url.appendingPathExtension("notes.json");notesIdentity=""
        recordingCount=0;recordingBytes=0;recordingElapsed=0;recordURL=url;recordStart=monotonic();pendingRecordWrites=0;streamFailure=nil;savingRecording=true
        recordingQueue.async { [weak self] in
            do {let writer=try StreamRecordingWriter(url:url);DispatchQueue.main.async {guard let self else{return};// The instrument may have disconnected while the file was being created; never enter a recording state with no source.
                if self.shuttingDown || !(self.connected || self.demo){try? writer.finish();self.savingRecording=false;if !self.shuttingDown{self.status="Recording not started: the instrument disconnected."};return};self.streamWriter=writer;self.savingRecording=false;self.recording=true;self.status="Recording snapshots directly to disk. Gaps are preserved."}}
            catch {let message=error.localizedDescription;DispatchQueue.main.async {self?.savingRecording=false;self?.status="Cannot start recording: "+message}}
        }
    }
    private func appendRecording(_ capture: Capture) {
        guard let writer=streamWriter else{return}
        guard pendingRecordWrites<8 else {streamFailure="Disk writes could not keep up";finishRecording();return}
        let saved=RecordedFrame(capture,elapsed:capture.completedMonotonic-recordStart);if notesIdentity.isEmpty{notesIdentity=String(saved.receivedUTC)};recordingElapsed=saved.elapsed;pendingRecordWrites += 1
        recordingQueue.async { [weak self] in
            do {try writer.append(saved);let count=writer.count,bytes=writer.bytes
                DispatchQueue.main.async {self?.pendingRecordWrites -= 1;self?.recordingCount=count;self?.recordingSavedElapsed=saved.elapsed;self?.recordingBytes=bytes}
            } catch {let message=error.localizedDescription;DispatchQueue.main.async {guard let self else{return};self.pendingRecordWrites -= 1;if self.streamFailure==nil{self.streamFailure=message};if self.recording{self.finishRecording()}}}
        }
    }
    func finishRecording() {
        recording=false;guard let writer=streamWriter,!savingRecording else{return};streamWriter=nil;savingRecording=true
        recordingQueue.async { [weak self] in
            var failure: String?
            do {try writer.finish()}catch{failure=error.localizedDescription}
            let count=writer.count,url=writer.url,issue=failure
            DispatchQueue.main.async {guard let self else{return};self.savingRecording=false;self.recordingCount=count
                if let problem=issue ?? self.streamFailure {self.status="Recording stopped: "+problem+". Completed snapshots remain at "+url.path}
                else {self.status="Saved \(count) snapshots to \(url.lastPathComponent)."}
            }
        }
    }
    func shutdown(_ done: @escaping () -> Void) {
        shuttingDown=true;stopDemo();cancelRecordingLoad();pausePlayback();if recording {finishRecording()}
        worker.disconnect { self.recordingQueue.async { DispatchQueue.main.async(execute:done) } }
    }
    func openRecording() {
        guard !connected,!connecting,!recording,!savingRecording,!recordingPreviewVisible else{return}
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        pausePlayback();savingRecording=true;loadingRecording=true;loadLock.lock();loadCancelled=false;loadLock.unlock()
        recordingQueue.async { [weak self] in
            do {
                if try StreamRecordingReader.isStream(url) {
                    let reader=try StreamRecordingReader(url:url,cancelled:{self?.loadIsCancelled() ?? true})
                    let first=try reader.frame(at:0),size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    let marks=(try? RecordingNotes.load(url:url.appendingPathExtension("notes.json"),identity:String(first.receivedUTC),count:reader.count).bookmarks.count) ?? 0
                    let overview=RecordingOverview(name:url.lastPathComponent,size:size,count:reader.count,duration:reader.elapsed(at:reader.count-1)-reader.elapsed(at:0),bookmarks:marks,firstUTC:first.receivedUTC)
                    DispatchQueue.main.async{guard let self else{return};self.savingRecording=false;self.loadingRecording=false;self.pendingReader=reader;self.pendingArchive=nil;self.pendingURL=url;self.recordingOverview=overview;self.recordingPreviewVisible=true}
                } else {
                    let archive=try CaptureRecording.load(url);if self?.loadIsCancelled() ?? true{throw ScopeError("Recording load canceled")}
                    let first=archive.frames[0],size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    let marks=(try? RecordingNotes.load(url:url.appendingPathExtension("notes.json"),identity:String(first.receivedUTC),count:archive.frames.count).bookmarks.count) ?? 0
                    let overview=RecordingOverview(name:url.lastPathComponent,size:size,count:archive.frames.count,duration:archive.frames.last!.elapsed-first.elapsed,bookmarks:marks,firstUTC:first.receivedUTC)
                    DispatchQueue.main.async{guard let self else{return};self.savingRecording=false;self.loadingRecording=false;self.pendingArchive=archive;self.pendingReader=nil;self.pendingURL=url;self.recordingOverview=overview;self.recordingPreviewVisible=true}
                }
            }
            catch {let message=error.localizedDescription;DispatchQueue.main.async {self?.savingRecording=false;self?.loadingRecording=false;self?.status="Cannot open recording: "+message}}
        }
    }
    func cancelRecordingPreview(){recordingPreviewVisible=false;pendingReader=nil;pendingArchive=nil;pendingURL=nil}
    func confirmRecordingPreview(){
        guard let url=pendingURL,let info=recordingOverview,!connected else{return}
        if let reader=pendingReader{stopDemo();playback=nil;playbackStream=reader;playbackLoaded=true;playbackCount=reader.count;trends=reader.trends;loadNotes(url:url,firstUTC:info.firstUTC,count:reader.count);viewport=nil;displayPlayback(0)}
        else if let archive=pendingArchive{do{try installPlayback(archive);loadNotes(url:url,firstUTC:info.firstUTC,count:archive.frames.count)}catch{status=error.localizedDescription;return}}
        status="Opened \(url.lastPathComponent). Playback sends no instrument commands."+((pendingReader?.recoveredTail ?? false) ? " Incomplete final snapshot skipped.":"");cancelRecordingPreview()
    }
    func installPlayback(_ archive: CaptureRecording) throws {
        guard !connected,!recording else{throw ScopeError("Disconnect the instrument before playback")}
        try archive.validate();stopDemo();playbackStream=nil;playback=archive;playbackLoaded=true;playbackCount=archive.frames.count;trends=archive.frames.map{TrendPoint($0)};viewport=nil;displayPlayback(0)
    }
    func seekPlayback(_ index: Int) {guard !savingRecording else{return};pausePlayback();spectrumAverage.clear();cachedSpectrum=[];displayPlayback(index)}
    private func displayPlayback(_ index: Int,completion: (() -> Void)? = nil) {
        guard index>=0,index<playbackCount else{return};playbackLoadGeneration += 1;let generation=playbackLoadGeneration
        playbackIndex=index;bookmarkNote=bookmarks.first{$0.index==index}?.note ?? ""
        if let reader=playbackStream {
            recordingQueue.async { [weak self] in
                do {let saved=try reader.frame(at:index);DispatchQueue.main.async {guard let self,self.playbackLoaded,self.playbackLoadGeneration==generation else{return};self.renderPlayback(saved,index:index);completion?()}}
                catch {let message=error.localizedDescription;DispatchQueue.main.async {self?.pausePlayback();self?.status="Cannot read snapshot: "+message}}
            }
        } else if let archive=playback {renderPlayback(archive.frames[index],index:index);completion?()}
    }
    private func renderPlayback(_ saved: RecordedFrame,index: Int) {
        receive(saved.capture,changed:true,state:"PLAYBACK")
        displayStatus=(saved.capture.synthetic ? "Demo · ":"")+"Snapshot \(index+1)/\(playbackCount)"
        dashboard=String(format:"Snapshot %d/%d · +%.3f s · received %@",index+1,playbackCount,saved.elapsed,ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:saved.receivedUTC)))
        transportPerformance=saved.capture.synthetic ? "Recorded synthetic demo snapshot. No instrument data.":"Recorded snapshot. Gaps between snapshots contain no recorded samples."
    }
    private func playbackElapsed(_ index: Int) -> Double {playbackStream?.elapsed(at:index) ?? playback!.frames[index].elapsed}
    func togglePlayback() {
        guard !savingRecording else{return}
        if playing {pausePlayback();return};guard playbackCount>1 else{return}
        playing=true;if playbackIndex>=playbackCount-1 {displayPlayback(0){self.schedulePlayback()}}else{schedulePlayback()}
    }
    private func schedulePlayback() {
        guard playing,playbackIndex+1<playbackCount else{pausePlayback();return}
        let delay=max(0.02,playbackElapsed(playbackIndex+1)-playbackElapsed(playbackIndex))
        playbackTimer=Timer.scheduledTimer(withTimeInterval:delay,repeats:false){[weak self] _ in guard let self,self.playing else{return};self.displayPlayback(self.playbackIndex+1){self.schedulePlayback()}}
    }
    func pausePlayback() {playing=false;playbackTimer?.invalidate();playbackTimer=nil}
    func closePlayback() {
        guard playbackLoaded else{return};pausePlayback();bookmarks=[];bookmarkNote="";notesWarning="";notesURL=nil;notesIdentity="";trends=[];trendEpoch=nil;playbackLoadGeneration += 1;playbackStream=nil;playback=nil;playbackLoaded=false;playbackCount=0;playbackIndex=0;frame=nil;plot=PlotData();plot.theme=theme;viewport=nil;captureInfo="No capture yet.";comparisonText="";channelMetrics=[Metrics([],rate:0),Metrics([],rate:0)];measurements="";dashboard="No capture yet";displayStatus="No capture yet";runState="Unknown";runVerifiedAt=nil;status="Playback closed."
    }
    func clearTrends(){trends=[];trendEpoch=nil}
    private func updateCaptureInfo(_ capture:Capture){
        captureInfo=String(format:"Sample rate: %.6g samples/s\nSample spacing: %.6g s\nCapture duration: %.6g s\nPoints: CH1 %d · CH2 %d\nHost receipt: %@\nInstrument acquisition timestamp: unavailable",capture.rate,1/capture.rate,capture.duration,capture.volts[0].count,capture.volts[1].count,ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:capture.completedUTC)))
        if capture.synthetic {captureInfo += "\n\nSource: synthetic demo signals. No instrument data.";return}
        if let metadata=capture.metadata{
            captureInfo += "\n\n"+metadata.identity+"\nSettings read: "+ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:metadata.settingsReadUTC))
            for (i,ch) in metadata.settings.channels.enumerated(){captureInfo += String(format:"\nCH%d: %.6g V/div · offset %.6g V · probe setting %.0f× · %@",i+1,ch.scale,ch.offset,ch.probe,ch.coupling)}
            captureInfo += String(format:"\nTimebase: %.6g s/div",metadata.settings.timebase)
            captureInfo += "\nCalibration/settings were read from the instrument at the time above; they are cached between reads."
        }else{captureInfo += "\n\nInstrument settings/probe metadata were not saved with this capture."}
    }
    private func updateComparison(){
        guard let frame,let reference else{comparisonText="";return}
        comparisonText=(0..<2).compactMap{ch -> String? in
            guard let c=ReferenceComparison.compare(live:frame,reference:reference,channel:ch) else{return nil}
            return String(format:"CH%d ΔVpp %.4g V · ΔDC %.4g V · Δf %@ · delay %@",ch+1,c.deltaVpp,c.deltaMean,c.deltaFrequency.map{String(format:"%.4g Hz",$0)} ?? "—",c.delay.map{String(format:"%.4g µs",$0*1e6)} ?? "unreliable")
        }.joined(separator:"\n")
    }
    private func loadNotes(url:URL,firstUTC:Double,count:Int){
        notesURL=url.appendingPathExtension("notes.json");notesIdentity=String(firstUTC);bookmarks=[];bookmarkNote=""
        notesWarning=""
        if let file=notesURL,FileManager.default.fileExists(atPath:file.path){
            do{bookmarks=try RecordingNotes.load(url:file,identity:notesIdentity,count:count).bookmarks}
            catch{notesWarning="Notes were not loaded: "+error.localizedDescription}
        }
        bookmarkNote=bookmarks.first{$0.index==playbackIndex}?.note ?? ""
    }
    func newRecordingBookmark(){recordingBookmarkTarget=nil;bookmarkNote="";saveBookmark()}
    func removeBookmark(){
        let index=playbackLoaded ? playbackIndex:(recordingBookmarkTarget ?? recordingCount-1)
        guard index>=0,let url=notesURL,!notesIdentity.isEmpty,bookmarks.contains(where:{$0.index==index}) else{return};bookmarks.removeAll{$0.index==index};bookmarkNote="";recordingBookmarkTarget=nil
        let notes=RecordingNotes(identity:notesIdentity,bookmarks:bookmarks)
        recordingQueue.async{[weak self] in do{try notes.encoded().write(to:url,options:.atomic);DispatchQueue.main.async{self?.status="Bookmark removed."}}catch{let message=error.localizedDescription;DispatchQueue.main.async{self?.status="Cannot update notes: "+message}}}
    }
    func saveBookmark(){
        let index=playbackLoaded ? playbackIndex:(recordingBookmarkTarget ?? recordingCount-1)
        guard index>=0,let url=notesURL,!notesIdentity.isEmpty else{return}
        guard bookmarkNote.count<=10000 else{status="Notes are limited to 10,000 characters.";return}
        guard bookmarks.count<1000 || bookmarks.contains(where:{$0.index==index}) else{status="Bookmark limit reached (1,000). Remove an existing bookmark first.";return}
        let elapsed=playbackLoaded ? playbackElapsed(index):(bookmarks.first{$0.index==index}?.elapsed ?? recordingSavedElapsed)
        if !playbackLoaded{recordingBookmarkTarget=index}
        bookmarks.removeAll{$0.index==index};bookmarks.append(SnapshotBookmark(index:index,elapsed:elapsed,note:bookmarkNote));bookmarks.sort{$0.index<$1.index}
        let notes=RecordingNotes(identity:notesIdentity,bookmarks:bookmarks)
        recordingQueue.async{[weak self] in do{try notes.encoded().write(to:url,options:.atomic);DispatchQueue.main.async{self?.notesWarning="";self?.status="Bookmark and note saved beside the recording."}}catch{let message=error.localizedDescription;DispatchQueue.main.async{self?.status="Cannot save notes: "+message}}}
    }
    func exportCSV() {
        guard let frame else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = frame.synthetic ? "ScopeMac-demo.csv":"ScopeMac-capture.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { var text = "time_s,CH1_V,CH2_V\n"; for i in 0..<(frame.volts.map(\.count).max() ?? 0) { text += "\(Double(i)/frame.rate-frame.trigger),\(i < frame.volts[0].count ? String(frame.volts[0][i]):""),\(i < frame.volts[1].count ? String(frame.volts[1][i]):"")\n" }; try text.write(to:url,atomically:true,encoding:.utf8); status = "Saved \(url.lastPathComponent)" } catch { status = error.localizedDescription }
    }
}
