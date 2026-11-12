// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

enum ScopeTheme:String,CaseIterable,Codable {
    case dark="Dark",medium="Medium",light="Light"
    var scheme:ColorScheme{self == .light ? .light:.dark}
    var background:Color{color(self == .dark ? [0.055,0.06,0.07]:self == .medium ? [0.19,0.20,0.22]:[0.94,0.945,0.95])}
    var panel:Color{color(self == .dark ? [0.09,0.10,0.115]:self == .medium ? [0.235,0.245,0.265]:[1,1,1])}
    var plotRGB:[Double]{self == .dark ? [0.025,0.035,0.045]:self == .medium ? [0.13,0.145,0.16]:[0.985,0.99,0.995]}
    var plot:Color{color(plotRGB)}
    var grid:SIMD4<Float>{self == .light ? SIMD4(0.81,0.84,0.87,1):self == .medium ? SIMD4(0.23,0.27,0.31,1):SIMD4(0.11,0.15,0.20,1)}
    var zero:SIMD4<Float>{self == .light ? SIMD4(0.50,0.55,0.60,1):SIMD4(0.38,0.43,0.48,1)}
    private func color(_ rgb:[Double])->Color{Color(red:rgb[0],green:rgb[1],blue:rgb[2])}
}
struct AxisTick:Identifiable {var value:Double;var label:String;var id:Double{value}}
func axisTicks(_ lower:Double,_ upper:Double,target:Int=6,scale:Double=1)->[AxisTick]{
    guard lower.isFinite,upper.isFinite,upper>lower,scale>0 else{return []}
    let lo=lower*scale,hi=upper*scale,raw=(hi-lo)/Double(max(2,target)),power=pow(10,floor(log10(raw)))
    guard power.isFinite,power>0 else{return []}
    let ratio=raw/power,factor=ratio<=1 ? 1.0:ratio<=2 ? 2.0:ratio<=2.5 ? 2.5:ratio<=5 ? 5.0:10.0,step=factor*power
    let start=ceil(lo/step-1e-10)*step,decimals=max(0,min(9,Int(ceil(-log10(step)))+(factor == 2.5 ? 1:0)))
    return (0..<32).compactMap{i in
        var value=start+Double(i)*step;guard value<=hi+step*1e-8 else{return nil};if abs(value)<step*1e-8{value=0}
        let label=abs(value)>=1e7 || (value != 0 && abs(value)<1e-6) ? String(format:"%.2g",value):String(format:"%.*f",decimals,value)
        return AxisTick(value:value/scale,label:label)
    }
}
struct ChannelSettingsCard:View {
    @ObservedObject var model:ScopeModel
    let channel:Int
    var body:some View{VStack(alignment:.leading,spacing:12){
        HStack(spacing:8){Circle().fill(channelTint(channel,theme:model.theme)).frame(width:7,height:7);Text("Channel \(channel+1)").font(.subheadline.weight(.semibold));Spacer();Toggle("Channel \(channel+1) input",isOn:$model.settings.channels[channel].enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(channelTint(channel,theme:model.theme))}
        VStack(spacing:9){
            HStack{Text("Scale").foregroundStyle(.secondary);Spacer();TextField("Volts per division",value:$model.settings.channels[channel].scale,format:.number).multilineTextAlignment(.trailing).frame(width:84);Text("V/div").font(.caption).foregroundStyle(.secondary).frame(width:34,alignment:.leading)}
            HStack{Text("Offset").foregroundStyle(.secondary);Spacer();TextField("Offset voltage",value:$model.settings.channels[channel].offset,format:.number).multilineTextAlignment(.trailing).frame(width:84);Text("V").font(.caption).foregroundStyle(.secondary).frame(width:34,alignment:.leading)}
            HStack{Text("Probe").foregroundStyle(.secondary);Spacer();Picker("Probe",selection:$model.settings.channels[channel].probe){ForEach([1.0,10,100,1000],id:\.self){Text("\(Int($0))×").tag($0)}}.labelsHidden().frame(width:84);Color.clear.frame(width:34,height:1)}
            HStack{Text("Coupling").foregroundStyle(.secondary);Spacer();Picker("Coupling",selection:$model.settings.channels[channel].coupling){ForEach(["DC","AC","GND"],id:\.self){Text($0).tag($0)}}.labelsHidden().frame(width:84);Color.clear.frame(width:34,height:1)}
        }.font(.callout).opacity(model.settings.channels[channel].enabled ? 1:0.45)
    }.padding(12).background(model.theme.panel,in:RoundedRectangle(cornerRadius:10))}
}
