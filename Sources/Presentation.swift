// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
func channelTint(_ index:Int,theme:ScopeTheme = .dark)->Color {let c=traceColor(index,theme:theme);return Color(red:Double(c.x),green:Double(c.y),blue:Double(c.z))}
struct HoverSample:Equatable {var channel:Int;var time:Double;var value:Double}
func hoverSamples(plot:PlotData,fraction:Double)->[HoverSample]{
    let x=plot.xMin+min(1,max(0,fraction))*(plot.xMax-plot.xMin)
    return plot.values.enumerated().compactMap{ch,values in
        let origin=ch<plot.traceStarts.count ? plot.traceStarts[ch]:plot.sampleStart,step=ch<plot.traceSteps.count ? plot.traceSteps[ch]:plot.sampleStep
        guard !values.isEmpty,step>0 else{return nil};let position=(x-origin)/step
        guard position>=0,position<=Double(values.count-1) else{return nil};let i=Int(position.rounded())
        guard values[i].isFinite else{return nil};return HoverSample(channel:ch,time:origin+Double(i)*step,value:values[i])
    }
}
enum SummaryMeasurement:String,CaseIterable {case vpp="Vpp",rms="RMS",frequency="Frequency",mean="DC",acRMS="AC RMS",minimum="Min",maximum="Max",period="Period",duty="Duty",width="Pulse width",samples="Samples"
    func text(_ m:Metrics)->String {switch self{
        case .vpp:return String(format:"%.4g Vpp",m.vpp);case .rms:return String(format:"%.4g V RMS",m.rms)
        case .frequency:return m.frequency>0 ? String(format:"%.5g Hz",m.frequency):"— Hz"
        case .mean:return String(format:"DC %.4g V",m.mean);case .acRMS:return String(format:"AC %.4g V RMS",m.acRMS)
        case .minimum:return String(format:"Min %.4g V",m.minimum);case .maximum:return String(format:"Max %.4g V",m.maximum)
        case .period:return m.period.map{String(format:"%.4g ms",$0*1000)} ?? "— ms"
        case .duty:return m.dutyCycle.map{String(format:"%.4g %%",$0)} ?? "— %"
        case .width:return m.positiveWidth.map{String(format:"%.4g µs",$0*1e6)} ?? "— µs"
        case .samples:return "\(m.sampleCount) points"
    }}
    static let defaults=["Vpp","RMS","Frequency","Samples"]
}
struct RecordingOverview {
    var name:String,size:Int,count:Int,duration:Double,bookmarks:Int,firstUTC:Double
    var summary:String {String(format:"%d snapshots · %.3f seconds · %@ · %d bookmarks",count,duration,ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file),bookmarks)}
}
struct VoltageControls:View {
    @ObservedObject var model:ScopeModel
    @State private var limits=false
    @State private var lower = -1.0
    @State private var upper=6.0
    @State private var axisError=""
    var body:some View{HStack(spacing:8){
        Toggle("Lock voltage axis",isOn:Binding(get:{model.voltageLocked},set:{model.setVoltageLock($0)})).disabled(!model.hasCapture)
        Button("Limits…"){lower=model.voltageLocked ? model.voltageMinimum:model.plot.yMin;upper=model.voltageLocked ? model.voltageMaximum:model.plot.yMax;axisError="";limits=true}.popover(isPresented:$limits){VStack(alignment:.leading,spacing:12){Text("Display voltage limits").font(.headline);TextField("Minimum V",value:$lower,format:.number);TextField("Maximum V",value:$upper,format:.number);if !axisError.isEmpty{Text(axisError).font(.caption).foregroundStyle(.orange)};HStack{Button("Auto scale"){model.setVoltageLock(false);limits=false};Button("Apply"){if model.setVoltageLimits(lower,upper){limits=false}else{axisError="Enter finite limits with minimum below maximum."}}}}.textFieldStyle(.roundedBorder).padding(18).frame(width:260)}
        if model.voltageLocked{Text(String(format:"%.4g … %.4g V",model.voltageMinimum,model.voltageMaximum)).font(.caption).foregroundStyle(.secondary)}
    }.font(.caption)}
}
struct SummaryView:View {
    @ObservedObject var model:ScopeModel
    var body:some View{HStack(alignment:.top,spacing:12){
        ForEach(0..<min(2,model.channelMetrics.count),id:\.self){ch in if model.channelMetrics[ch].sampleCount>0{
            VStack(alignment:.leading,spacing:8){
                HStack(spacing:6){Circle().fill(channelTint(ch,theme:model.theme)).frame(width:6,height:6);Text("CH\(ch+1)").font(.caption.weight(.semibold)).foregroundStyle(channelTint(ch,theme:model.theme))}
                LazyVGrid(columns:[GridItem(.adaptive(minimum:85),spacing:12,alignment:.leading)],alignment:.leading,spacing:10){
                    ForEach(SummaryMeasurement.allCases.filter{model.summarySelection.contains($0.rawValue)},id:\.self){metric in
                        VStack(alignment:.leading,spacing:3){Text(metric.rawValue).font(.system(size:10,weight:.medium)).foregroundStyle(.secondary);Text(metric.text(model.channelMetrics[ch])).font(.system(size:12,weight:.medium,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)}
                    }
                }
            }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(model.theme.panel,in:RoundedRectangle(cornerRadius:9))
        }}
        Menu{ForEach(SummaryMeasurement.allCases,id:\.self){metric in Toggle(metric.rawValue,isOn:Binding(get:{model.summarySelection.contains(metric.rawValue)},set:{model.selectSummary(metric.rawValue,enabled:$0)}))}}label:{Image(systemName:"slider.horizontal.3")}.menuStyle(.borderlessButton).fixedSize().padding(.top,10).help("Choose visible measurements").accessibilityLabel("Choose summary measurements")
    }.frame(minHeight:30)}
}
struct RecordingOverviewView:View {
    @ObservedObject var model:ScopeModel
    var body:some View{VStack(alignment:.leading,spacing:18){Text("Recording overview").font(.title2.bold());if let info=model.recordingOverview{Text(info.name).font(.headline);Text(info.summary);Text("First receipt: "+ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:info.firstUTC))).font(.caption).foregroundStyle(.secondary);Text("Separate USB snapshots; gaps between captures contain no data.").font(.caption)};HStack{Button("Cancel"){model.cancelRecordingPreview()};Spacer();Button("Open playback"){model.confirmRecordingPreview()}.buttonStyle(.borderedProminent)}}.padding(24).frame(width:560)}
}

/// Frequency with an SI unit and a fixed number of significant digits, never in exponent form
/// ("1.002 kHz", "999.6 Hz", "12.50 MHz").
func formatFrequency(_ hertz: Double, digits: Int = 4) -> String {
    guard hertz.isFinite else { return "— Hz" }
    let magnitude=abs(hertz)
    let (scale,unit): (Double,String) = magnitude>=1e9 ? (1e9,"GHz"):magnitude>=1e6 ? (1e6,"MHz"):magnitude>=1e3 ? (1e3,"kHz"):(1,"Hz")
    let value=hertz/scale
    let integerDigits=value == 0 ? 1:Int(floor(log10(abs(value))))+1
    let decimals=max(0,min(6,digits-integerDigits))
    return String(format:"%.*f %@",decimals,value,unit)
}

/// Greedy, priority-ordered placement of small labels next to anchor points.
/// Each label tries above, below, right, left, then further above/below; a label that cannot be
/// placed inside `bounds` without overlapping an earlier label or any anchor marker returns nil.
/// `yDown` is true for flipped (screen) coordinates and false for bottom-left origins.
func layoutPointLabels(anchors: [CGPoint], sizes: [CGSize], bounds: CGRect, yDown: Bool = true, marker: CGFloat = 10) -> [CGPoint?] {
    let up: CGFloat = yDown ? -1:1
    let markers=anchors.map { CGRect(x:$0.x-marker/2,y:$0.y-marker/2,width:marker,height:marker) }
    var placed=[CGRect](), result=[CGPoint?]()
    for (anchor,size) in zip(anchors,sizes) {
        let vertical=size.height/2+marker/2+3, horizontal=size.width/2+marker/2+4
        let candidates=[CGPoint(x:0,y:up*vertical),CGPoint(x:0,y:-up*vertical),CGPoint(x:horizontal,y:0),CGPoint(x:-horizontal,y:0),
                        CGPoint(x:0,y:up*(vertical+size.height+3)),CGPoint(x:0,y:-up*(vertical+size.height+3))]
        var chosen: CGPoint?
        for offset in candidates {
            var center=CGPoint(x:anchor.x+offset.x,y:anchor.y+offset.y)
            // Slide horizontally inside the plot; vertical overflow rejects the candidate.
            center.x=min(bounds.maxX-size.width/2,max(bounds.minX+size.width/2,center.x))
            let rect=CGRect(x:center.x-size.width/2,y:center.y-size.height/2,width:size.width,height:size.height)
            guard rect.minY>=bounds.minY,rect.maxY<=bounds.maxY else { continue }
            let padded=rect.insetBy(dx:-2,dy:-1)
            if placed.contains(where:{$0.intersects(padded)}) || markers.contains(where:{$0.intersects(rect)}) { continue }
            chosen=center;placed.append(rect);break
        }
        result.append(chosen)
    }
    return result
}
