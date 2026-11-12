// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
struct InsightsView:View {
    @ObservedObject var model:ScopeModel
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            DisclosureGroup("Measurement trends",isExpanded:model.expansion("trends")){
                HStack{Picker("Metric",selection:$model.trendMetric){ForEach(TrendMetric.allCases,id:\.self){Text($0.rawValue).tag($0)}}.frame(width:180);Picker("Channel",selection:$model.trendChannel){Text("CH1").tag(0);Text("CH2").tag(1)}.frame(width:140);Spacer();if !model.playbackLoaded{Button("Clear history"){model.clearTrends()}}}
                TrendChart(points:model.trends,metric:model.trendMetric,channel:model.trendChannel,theme:model.theme).frame(height:170)
                Text("Each dot is a separate snapshot; gaps contain no recorded samples. Live history retains 2,000 captures.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Capture information",isExpanded:model.expansion("info")){Text(model.captureInfo).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
            if model.hasReference{
                DisclosureGroup("Reference comparison",isExpanded:model.expansion("comparison")){
                    Text(model.comparisonText.isEmpty ? "No matching captured channels to compare.":model.comparisonText).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                    Text("Differences are current minus reference. Positive delay means the current signal lags the reference. Delay uses normalized correlation; periodic signals are ambiguous by whole cycles.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.recording || model.playbackLoaded{
                DisclosureGroup("Bookmarks and notes",isExpanded:model.expansion("bookmarks")){
                    if !model.notesWarning.isEmpty{Text(model.notesWarning).foregroundStyle(.orange)}
                    HStack{TextField("Note for this snapshot",text:$model.bookmarkNote).textFieldStyle(.roundedBorder);Button(model.playbackLoaded ? "Save bookmark":model.recordingBookmarkTarget == nil ? "Bookmark latest saved":"Save note"){model.saveBookmark()}.disabled(model.recording && model.recordingCount==0)}
                    if model.recording && model.recordingBookmarkTarget != nil{Button("New bookmark on latest saved snapshot"){model.newRecordingBookmark()}}
                    if model.playbackLoaded && !model.bookmarks.isEmpty{
                        Menu("Jump to bookmark (\(model.bookmarks.count))"){ForEach(model.bookmarks){mark in Button("\(mark.index+1) · "+String(format:"%.2f s",mark.elapsed)+" · "+String(mark.note.prefix(60))){model.seekPlayback(mark.index)}}}
                    }
                    if model.bookmarks.contains(where:{$0.index==(model.playbackLoaded ? model.playbackIndex:(model.recordingBookmarkTarget ?? model.recordingCount-1))}){Button("Remove bookmark"){model.removeBookmark()}}
                    Text("Notes are saved in a .notes.json file beside the recording. Keep both files together.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.font(.caption)
    }
}
struct TrendChart:View{
    let points:[TrendPoint];let metric:TrendMetric;let channel:Int;let theme:ScopeTheme
    var body:some View{
        Canvas{context,size in
            let data=points.compactMap{point -> (Double,Double)? in guard point.channels.indices.contains(channel),let value=metric.value(point.channels[channel]),value.isFinite else{return nil};return(point.elapsed,value)}
            guard let first=data.first,let last=data.last else{context.draw(Text("No reliable trend data yet").foregroundColor(.secondary),at:CGPoint(x:size.width/2,y:size.height/2));return}
            let lo=data.map{$0.1}.min()!,hi=data.map{$0.1}.max()!,pad=max(1e-6,(hi-lo)*0.1),minY=lo-pad,maxY=hi+pad
            let area=CGRect(x:70,y:8,width:max(1,size.width-85),height:max(1,size.height-38)),span=max(1,last.0-first.0)
            for i in 0...4{let y=area.minY+area.height*Double(i)/4;var line=Path();line.move(to:CGPoint(x:area.minX,y:y));line.addLine(to:CGPoint(x:area.maxX,y:y));context.stroke(line,with:.color(.gray.opacity(0.2)));context.draw(Text(String(format:"%.4g",maxY-(maxY-minY)*Double(i)/4)).font(.system(size:10,design:.monospaced)),at:CGPoint(x:34,y:y))}
            // Keep each screen bucket's extrema, preserving excursions in large recordings.
            let strideSize=max(1,data.count/max(1,Int(area.width)))
            for begin in stride(from:0,to:data.count,by:strideSize){let bucket=data[begin..<min(data.count,begin+strideSize)];let samples=[bucket.min{$0.1<$1.1}!,bucket.max{$0.1<$1.1}!]
                for (t,v) in samples{let x=area.minX+(t-first.0)/span*area.width,y=area.maxY-(v-minY)/(maxY-minY)*area.height;context.fill(Path(ellipseIn:CGRect(x:x-1.5,y:y-1.5,width:3,height:3)),with:.color(channelTint(channel,theme:theme)))}
            }
            context.draw(Text(String(format:"%.2f → %.2f s · %@",first.0,last.0,metric.unit)).font(.caption),at:CGPoint(x:area.midX,y:size.height-12))
        }.background(theme.plot).clipShape(RoundedRectangle(cornerRadius:6))
    }
}

struct InsightsPopover:View{
    @ObservedObject var model:ScopeModel
    var body:some View{VStack(alignment:.leading,spacing:12){HStack{Text("Capture Insights").font(.headline);Spacer();Button("Done"){model.insightsVisible=false}};ScrollView{InsightsView(model:model).padding(.trailing,8)}}.padding(18).frame(width:660,height:500)}
}
