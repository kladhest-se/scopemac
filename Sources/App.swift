// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var model: ScopeModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model else { return .terminateNow }
        model.shutdown { sender.reply(toApplicationShouldTerminate:true) }; return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct ScopeMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject var model = ScopeModel()
    var body: some Scene {
        WindowGroup("ScopeMac · DSO2D15") { ContentView(model:model).onAppear { AppDelegate.model=model; if CommandLine.arguments.contains("--demo") { model.startDemo() } } }
            .defaultSize(width:1180,height:800)
            .commands {
                CommandGroup(replacing:.newItem) {}
                CommandGroup(replacing:.appInfo){Button("About ScopeMac"){AboutWindow.show(model:model)}}
                CommandMenu("Release"){Button("What's New…"){model.releaseNotesVisible=true}}
                CommandGroup(after:.appSettings) { Button("Reset Display Preferences") { model.resetDisplayPreferences() } }
                CommandGroup(after:.importExport) {
                    Button("Open Recording…") {model.openRecording()}.keyboardShortcut("o").disabled(model.connected || model.connecting || model.savingRecording)
                    Button("Export Chart Image…") {model.exportScreenshot()}.keyboardShortcut("s",modifiers:[.command,.shift]).disabled(!model.hasCapture)
                    Button("Export Samples as CSV…") {model.exportCSV()}.keyboardShortcut("s").disabled(!model.hasCapture)
                }
                CommandMenu("Display") {
                    Button("Fit Capture") {model.fitPlot()}.keyboardShortcut("0")
                    Button("Zoom In") {model.zoomPlot(factor:2,anchor:0.5)}.keyboardShortcut("+")
                    Button("Zoom Out") {model.zoomPlot(factor:0.5,anchor:0.5)}.keyboardShortcut("-")
                    Divider()
                    Button("Waveform") {model.mode="Waveform"}.keyboardShortcut("1")
                    Button("Math") {model.mode="CH1 + CH2"}.keyboardShortcut("2")
                    Button("FFT") {model.mode="FFT"}.keyboardShortcut("3")
                    Toggle("Time Cursors",isOn:$model.cursors).keyboardShortcut("c",modifiers:[.command,.shift])
                    Button("Freeze Reference") {model.freezeReference()}.keyboardShortcut("r",modifiers:[.command,.shift]).disabled(!model.hasCapture)
                    Toggle("Instrument Sidebar",isOn:$model.inspectorVisible).keyboardShortcut("i",modifiers:[.command,.option])
                    Button("Diagnostics…") {model.diagnosticsVisible.toggle()}.keyboardShortcut("d",modifiers:[.command,.option])
                }
                CommandMenu("Scope") {
                    Button("Run Acquisition") {model.requestAcquisition(true)}.keyboardShortcut("g",modifiers:[.command,.shift]).disabled(!model.acquisitionControls.canRun)
                    Button("Stop Acquisition") {model.requestAcquisition(false)}.keyboardShortcut(".",modifiers:[.command,.shift]).disabled(!model.acquisitionControls.canStop)
                    Button("Read Instrument Settings") {model.worker.readSettings()}.keyboardShortcut("r").disabled(!model.connected)
                }
            }
    }
}
struct ContentView: View {
    @ObservedObject var model: ScopeModel
    @State private var measurementsVisible=false
    let timebases: [Double] = [1e-9,2e-9,5e-9,1e-8,2e-8,5e-8,1e-7,2e-7,5e-7,1e-6,2e-6,5e-6,1e-5,2e-5,5e-5,1e-4,2e-4,5e-4,0.001,0.002,0.005,0.01,0.02,0.05,0.1,0.2,0.5,1,2,5,10,20,50,100]
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(systemName:"waveform.path.ecg").font(.system(size:22,weight:.medium)).foregroundStyle(channelTint(0,theme:model.theme))
                VStack(alignment:.leading) { Text("ScopeMac").font(.headline); Text("DSO2D15").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Picker("Theme",selection:$model.theme){ForEach(ScopeTheme.allCases,id:\.self){Text($0.rawValue).tag($0)}}.frame(width:140).help("Saved appearance for the app, plot and exports")
                if model.connected {
                    AcquisitionButtons(model:model)
                } else {
                    Text(model.connecting ? "Connecting…":model.playbackLoaded ? "PLAYBACK":model.demo ? "DEMO":"Not connected").font(.system(.callout,design:.monospaced).bold()).padding(.horizontal,12).padding(.vertical,6).background(Color.gray.opacity(0.2)).clipShape(Capsule())
                }
                if model.connected { Button("Disconnect") { model.worker.disconnect() } } else { Button(model.recoveryMessage.isEmpty ? "Connect USB":"Reconnect") { model.connect() }.buttonStyle(.borderedProminent).disabled(model.savingRecording || model.connecting || model.recording); Button("Demo") { model.startDemo() }.disabled(model.savingRecording || model.connecting || model.recording) }
            }.padding(.horizontal,18).padding(.vertical,11)
            Divider()
            HStack(spacing:12) {
                
                Button { model.setRepeat(!model.repeating) } label: { Label(model.repeating ? "Pause view":"Live view",systemImage:model.repeating ? "pause.fill":"play.fill") }.disabled(!(model.connected || model.demo)).help("Start or pause Mac snapshot downloads without changing scope acquisition")
                Button("Capture") { model.captureOnce() }.keyboardShortcut(.return,modifiers:[.command]).help("Download one snapshot; does not change scope acquisition").disabled(!(model.connected || model.demo) || model.repeating)
                Picker("Refresh",selection:$model.refreshInterval) {
                    Text("Fastest").tag(0.0)
                    ForEach([0.5,1.0,2,5,10,30,60],id:\.self) {Text($0<1 ? "0.5 seconds":"\(Int($0)) second\($0 == 1 ? "":"s")").tag($0)}
                }.frame(width:175).disabled(model.playbackLoaded).help("Target interval between capture starts. USB transfer time limits the actual rate. Does not change the scope's sample rate.")
                Divider().frame(height:20)
                Spacer()
                Button(model.recording ? "Stop & save":"Record",systemImage:model.recording ? "stop.circle":"record.circle") {
                    if model.recording {model.finishRecording()} else {model.startRecording()}
                }.disabled(!(model.connected || model.demo) || model.savingRecording)
                Button("Open recording…") {model.openRecording()}.disabled(model.connected || model.connecting || model.savingRecording || model.recording).help("Disconnect the scope before opening a recording")
                Divider().frame(height:18)
                Menu { Button("Chart Image (PNG)…") {model.exportScreenshot()};Button("Samples (CSV)…") {model.exportCSV()} } label:{Label("Export",systemImage:"square.and.arrow.up")}.menuStyle(.borderlessButton).fixedSize().disabled(!model.hasCapture)
                Button("Insights",systemImage:"chart.xyaxis.line"){model.insightsVisible.toggle()}.popover(isPresented:$model.insightsVisible){InsightsPopover(model:model)}
                Button {model.diagnosticsVisible.toggle()} label:{Image(systemName:"info.circle")}.help("Diagnostics")
                    .popover(isPresented:$model.diagnosticsVisible) {DiagnosticsView(model:model)}
                Button { model.inspectorVisible.toggle() } label: { Image(systemName:"sidebar.right") }.help("Show or hide instrument controls (⌥⌘I)")
            }.padding(.horizontal,18).padding(.vertical,10)
            if model.recording || model.savingRecording || model.playbackLoaded { HStack(spacing:12) {
                if model.recording {Text("REC · \(model.recordingCount) snapshots · \(String(format:"%.1f s",model.recordingElapsed)) · \(ByteCountFormatter.string(fromByteCount:Int64(model.recordingBytes),countStyle:.file))").foregroundStyle(.red).font(.caption)}
                if model.savingRecording {ProgressView().controlSize(.small);Text(model.loadingRecording ? "Loading recording…":"Recording file…").font(.caption);if model.loadingRecording{Button("Cancel"){model.cancelRecordingLoad()}}}
                if model.playbackLoaded {
                    Button(model.playing ? "Pause":"Play") {model.togglePlayback()}.disabled(model.playbackCount<2)
                    Button {model.seekPlayback(max(0,model.playbackIndex-1))} label:{Image(systemName:"backward.frame")}
                    Slider(value:Binding(get:{Double(model.playbackIndex)},set:{model.seekPlayback(Int($0))}),in:0...Double(max(1,model.playbackCount-1)),step:1).frame(minWidth:100,maxWidth:240).disabled(model.playbackCount<2)
                    Button {model.seekPlayback(min(model.playbackCount-1,model.playbackIndex+1))} label:{Image(systemName:"forward.frame")}
                    Text("\(model.playbackIndex+1)/\(model.playbackCount)").font(.caption.monospacedDigit())
                    Button("Close playback") {model.closePlayback()}.disabled(model.savingRecording)
                }
                Spacer()
            }.padding(.horizontal,18).padding(.bottom,10) }
            if !model.recoveryMessage.isEmpty{
                HStack{Image(systemName:"exclamationmark.triangle").foregroundStyle(.orange);Text(model.recoveryMessage).font(.caption);Spacer();Button("Reconnect"){model.connect()}.disabled(model.connecting || model.savingRecording);Button("Dismiss"){model.recoveryMessage=""}}.padding(12).background(Color.orange.opacity(0.1))
            }
            HSplitView {
                VStack(alignment:.leading,spacing:12) {
                    HStack {
                        Picker("View",selection:$model.mode) { Text("Waveform").tag("Waveform"); Text("CH1 + CH2").tag("CH1 + CH2"); Text("FFT").tag("FFT") }.pickerStyle(.segmented).frame(maxWidth:380)
                        Spacer()
                        if model.mode == "FFT" { Picker("Source",selection:$model.fftSource) { Text("CH1").foregroundStyle(channelTint(0,theme:model.theme)).tag(0);Text("CH2").foregroundStyle(channelTint(1,theme:model.theme)).tag(1) }.frame(width:140) }
                        else { Text("Show").font(.caption).foregroundStyle(.secondary);Toggle("CH1",isOn:$model.showCH1).foregroundStyle(channelTint(0,theme:model.theme)).tint(channelTint(0,theme:model.theme)).help("Display only; does not change the CH1 input"); Toggle("CH2",isOn:$model.showCH2).foregroundStyle(channelTint(1,theme:model.theme)).tint(channelTint(1,theme:model.theme)).help("Display only; does not change the CH2 input") }
                    }
                    if model.mode == "FFT" {
                        HStack {
                            Picker("Range",selection:$model.fftBand) {Text("Full spectrum").tag(0.0);ForEach([1000.0,10000,100000,1000000,10000000],id:\.self){Text($0<1000000 ? "\(Int($0/1000)) kHz":"\(Int($0/1000000)) MHz").tag($0)}}.frame(width:200)
                            Picker("Average",selection:$model.fftAverage){Text("Off").tag(1);Text("4 snapshots").tag(4);Text("16 snapshots").tag(16)}.frame(width:200)
                            Toggle("Peak markers",isOn:$model.showFFTPeaks);Spacer()
                        }
                        Text(model.fftPeakText.isEmpty ? "No spectral peaks available":model.fftPeakText).font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                    }
                    if model.mode == "Waveform" {
                        HStack {
                            Button(model.hasReference ? "Replace reference":"Freeze reference",systemImage:"square.on.square") {model.freezeReference()}.disabled(!model.hasCapture)
                            if model.hasReference {
                                Toggle("Show reference",isOn:Binding(get:{model.referenceVisible},set:{model.referenceVisible=$0;model.rebuild()}))
                                HStack(spacing:6){Text("Ref CH1").foregroundStyle(channelTint(2,theme:model.theme));Text("Ref CH2").foregroundStyle(channelTint(3,theme:model.theme));Text("Trigger aligned").foregroundStyle(.secondary)}.font(.caption)
                                Button("Clear") {model.clearReference()}
                            }
                            Spacer()
                        }
                    }
                    if model.mode != "FFT"{VoltageControls(model:model)}
                    Chart(model:model).background(model.theme.plot).clipShape(RoundedRectangle(cornerRadius:10))
                    if model.mode != "FFT" {
                        HStack {
                            Toggle("Cursors",isOn:$model.cursors).frame(width:90)
                            if model.cursors {
                                Picker("Move",selection:$model.selectedCursor) { Text("Move A").tag(0);Text("Move B").tag(1) }.pickerStyle(.segmented).labelsHidden().frame(width:160).help("Choose which cursor dragging moves")
                                Button("Snap period CH1") { model.snapPeriod() }
                                let dt = abs(model.cursorB-model.cursorA)
                                Text(String(format:"Δt %.4g ms · %.5g Hz",dt*1000,dt > 0 ? 1/dt:0)).font(.system(.caption,design:.monospaced))
                            }
                            Spacer()
                            Text("Zoom").font(.caption); Slider(value:Binding(get:{log2(max(1,model.zoom))},set:{model.setZoom(pow(2,$0))}),in:0...log2(1000)).frame(width:100); Button("Fit") { model.fitPlot() }
                        }
                    }
                    Text(model.mode == "FFT" ? "Scroll or pinch to zoom at pointer · Drag to pan · Double-click to Fit":"Scroll or pinch to zoom at pointer · Drag to pan · Option-drag pans with cursors · Double-click to Fit").font(.caption).foregroundStyle(.secondary)
                    SummaryView(model:model)
                    // Details open in a popover: expanding them inline overflowed the window and pushed the header off-screen.
                    HStack{Button("All measurements…",systemImage:"list.bullet.rectangle"){measurementsVisible.toggle()}.disabled(!model.channelMetrics.contains{$0.sampleCount>0}).help("Minimum, maximum, DC, AC RMS, period, pulse width and duty cycle")
                        .popover(isPresented:$measurementsVisible,arrowEdge:.top){VStack(alignment:.leading,spacing:8){Text("All measurements").font(.headline);MeasurementDetails(metrics:model.channelMetrics,theme:model.theme)}.font(.caption).padding(18).frame(minWidth:360)};Spacer()}.font(.caption)
                    HStack { Text(model.connected && !model.repeating ? "View paused":model.displayStatus).font(.caption.monospacedDigit()).foregroundStyle(.secondary); Spacer();Text(model.syntheticCapture ? "Synthetic snapshots":model.playbackLoaded ? "Recorded snapshots":"USB snapshots").font(.caption).foregroundStyle(.tertiary) }
                }.padding(16).frame(minWidth:660)
                if model.inspectorVisible { ScrollView {
                    VStack(alignment:.leading,spacing:16) {
                        HStack { Text("Instrument").font(.headline); Spacer(); Button { model.worker.readSettings() } label: { Image(systemName:"arrow.clockwise") }.help("Read settings from scope") }
                        Text("Apply updates the scope and reads the settings back.").font(.caption).foregroundStyle(.secondary)
                        ForEach(0..<2) { ch in ChannelSettingsCard(model:model,channel:ch) }
                        HStack { Text("Time/div"); Spacer(); Picker("Time/div",selection:$model.settings.timebase) { ForEach(Array(Set(timebases+[model.settings.timebase])).sorted(),id:\.self) { Text(timeLabel($0)).tag($0) } }.labelsHidden().frame(width:120) }
                        Button("Apply settings") { model.worker.apply(model.settings) }.buttonStyle(.borderedProminent).frame(maxWidth:.infinity)
                        Divider()
                        DisclosureGroup("Trigger",isExpanded:model.expansion("trigger")) {
                            VStack(alignment:.leading,spacing:10) {
                                Text("Read mode: \(model.triggerReadMode)").font(.caption).foregroundStyle(.secondary)
                                Button(model.triggerBusy ? "Working…":"Read trigger") { model.worker.readTriggerSettings() }.disabled(model.triggerBusy)
                                Group {
                                    Picker("Source",selection:$model.trigger.source) { Text("CH1").tag("CHANnel1");Text("CH2").tag("CHANnel2");Text("EXT/10").tag("EXT/10") }
                                    Picker("Edge",selection:$model.trigger.slope) { Text("Rising").tag("RISIng");Text("Falling").tag("FALLing");Text("Either").tag("EITHer") }
                                    Picker("Sweep",selection:$model.trigger.sweep) { Text("Auto").tag("AUTO");Text("Normal").tag("NORMal");Text("Single").tag("SINGle") }
                                    HStack { Text("Level V");Spacer();TextField("Level",value:$model.trigger.level,format:.number).frame(width:90) }
                                    Button("Apply EDGE trigger") { model.worker.applyTriggerSettings(model.trigger) }.buttonStyle(.borderedProminent)
                                }.disabled(!model.triggerRead || model.triggerBusy)
                                Button("Force Trigger") { model.worker.forceTrigger() }.disabled(model.triggerBusy)
                                Text("Apply selects EDGE trigger and reads settings back. Other trigger types are read by name only; their edge fields are not read.").font(.caption).foregroundStyle(.secondary)
                            }.padding(.top,8)
                        }
                        Text("Waveforms are snapshots over USB, with gaps between captures. Sample rate and USB refresh rate are different.").font(.caption).foregroundStyle(.secondary)
                    }.textFieldStyle(.roundedBorder).padding(16).disabled(!model.connected)
                }.background(model.theme.background).frame(minWidth:260,idealWidth:model.sidebarWidth,maxWidth:460) }
            }
            Divider()
            HStack(spacing:8){Circle().fill(model.connected ? Color.green:Color.gray).frame(width:5,height:5);Text(model.connected ? "USB connected":model.playbackLoaded ? "Playback":model.demo ? "Demo":"Disconnected").font(.caption.weight(.medium));Divider().frame(height:12);Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(model.status);Spacer()}.padding(.horizontal,18).padding(.vertical,8)
        }.frame(minWidth:1100,minHeight:650).background(model.theme.background).preferredColorScheme(model.theme.scheme)
        .background(WindowLayoutBridge(model:model).frame(width:0,height:0))
        .sheet(isPresented:$model.recordingPreviewVisible,onDismiss:{model.cancelRecordingPreview()}){RecordingOverviewView(model:model)}
        .sheet(isPresented:$model.releaseNotesVisible){ReleaseNotesView(model:model)}
        .onChange(of:model.mode) { model.fitPlot() }
        .onChange(of:model.fftSource) { model.resetSpectrum() }
        .onChange(of:model.fftAverage) {model.resetSpectrum()}
        .onChange(of:model.fftBand) {model.fitPlot()}
        .onChange(of:model.showFFTPeaks) {model.rebuild()}
        .onChange(of:model.showCH1) { model.rebuild() }.onChange(of:model.showCH2) { model.rebuild() }

    }
    func timeLabel(_ value: Double) -> String { if value < 1e-6 { return String(format:"%.3g ns",value*1e9) }; if value < 0.001 { return String(format:"%.3g µs",value*1e6) }; if value < 1 { return String(format:"%.3g ms",value*1e3) }; return String(format:"%.3g s",value) }
}

struct DiagnosticsView: View {
    @ObservedObject var model: ScopeModel
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {Text("Diagnostics").font(.headline);Spacer();Button("Done") {model.diagnosticsVisible=false}}
            Text(model.dashboard).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text(model.performance).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            Divider()
            Text(model.transportPerformance).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
            if model.connected {
                TimelineView(.periodic(from:.now,by:1)){context in
                    Text(model.runVerifiedAt.map{"Acquisition: \(model.runState) · read \(Int(max(0,context.date.timeIntervalSince($0)))) s ago"} ?? "Acquisition state has not been verified.").font(.caption)
                }
                Button("Read acquisition state"){model.refreshAcquisition()}.disabled(model.acquisitionBusy)
            }
            Toggle("Poll Run/Stop every 2 seconds",isOn:Binding(get:{model.pollStatus},set:{model.pollStatus=$0;model.worker.setStatusPolling($0)})).disabled(!model.connected)
            DisclosureGroup("Experimental transport",isExpanded:model.expansion("experimental")) {
                Toggle("Overlap USB request/read",isOn:Binding(get:{model.overlapUSB},set:{model.overlapUSB=$0;model.worker.setOverlap($0)}))
                Text("Testing found no clear refresh-rate benefit. Sequential transport is the default.").font(.caption).foregroundStyle(.secondary)
            }
            Text("ScopeMac \(AppVersion.marketing) · Metal rendering · USB snapshots with gaps").font(.caption).foregroundStyle(.secondary)
        }.padding(20).frame(width:560)
    }
}

struct MeasurementDetails: View {
    let metrics: [Metrics]
    let theme:ScopeTheme
    var body: some View {
        HStack(alignment:.top,spacing:24) {
            ForEach(Array(metrics.indices),id:\.self) {ch in
                if metrics[ch].sampleCount>0 {let m=metrics[ch]
                    GroupBox("CH\(ch+1)") {
                        Grid(alignment:.leading,horizontalSpacing:18,verticalSpacing:6) {
                            row("Minimum / maximum",String(format:"%.4g / %.4g V",m.minimum,m.maximum))
                            row("Mean (DC)",String(format:"%.4g V",m.mean))
                            row("AC RMS",String(format:"%.4g V",m.acRMS))
                            row("Period",m.period.map{String(format:"%.4g ms",$0*1000)} ?? "—")
                            row("Positive width",m.positiveWidth.map{String(format:"%.4g µs",$0*1e6)} ?? "—")
                            row("Duty cycle",m.dutyCycle.map{String(format:"%.3g %%",$0)} ?? "—")
                        }.font(.system(.caption,design:.monospaced)).padding(6)
                    }.foregroundStyle(channelTint(ch,theme:theme))
                }
            }
            Spacer()
        }.padding(.top,8)
        Text("Timing measurements require a stable periodic signal; — means unavailable or unreliable.").font(.caption).foregroundStyle(.secondary)
    }
    func row(_ title: String,_ value: String) -> some View {GridRow{Text(title).foregroundStyle(.secondary);Text(value)}}
}

struct AcquisitionButtons:View {
    @ObservedObject var model:ScopeModel
    var body:some View {
        HStack(spacing:5){
            stateControl("RUN",selected:model.runState == "RUN",enabled:model.acquisitionControls.canRun,color:.green){model.requestAcquisition(true)}
            stateControl("STOP",selected:model.runState == "STOP",enabled:model.acquisitionControls.canStop,color:.orange){model.requestAcquisition(false)}
            if model.acquisitionBusy{ProgressView().controlSize(.small).help("Waiting for scope readback")}
        }.help(model.runState == "Unknown" ? "State unknown. Read acquisition state in Diagnostics.":"Scope acquisition; current state is highlighted")
    }
    @ViewBuilder func stateControl(_ title:String,selected:Bool,enabled:Bool,color:Color,action:@escaping()->Void)->some View {
        if selected {
            Text(title).font(.system(.callout,design:.monospaced).bold()).frame(width:52,height:26).background(color.opacity(0.25)).overlay(RoundedRectangle(cornerRadius:7).stroke(color.opacity(0.25))).clipShape(RoundedRectangle(cornerRadius:7)).accessibilityLabel(title+", current acquisition state")
        } else {
            Button(action:action){Text(title).font(.system(.callout,design:.monospaced).bold()).frame(width:52,height:26).background(Color.gray.opacity(0.15)).overlay(RoundedRectangle(cornerRadius:7).stroke(Color.gray.opacity(0.15))).clipShape(RoundedRectangle(cornerRadius:7))}.buttonStyle(.plain).disabled(!enabled).help(title == "RUN" ? "Start scope acquisition":"Stop scope acquisition")
        }
    }
}
