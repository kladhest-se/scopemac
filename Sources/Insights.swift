// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct TrendValues {var available:Bool;var vpp: Double;var rms: Double;var frequency: Double?;init(_ m: Metrics){available=m.sampleCount>0;vpp=m.vpp;rms=m.rms;frequency=m.frequency>0 ? m.frequency:nil}}
struct TrendPoint {var elapsed: Double;var channels: [TrendValues];init(elapsed:Double,metrics:[Metrics]){self.elapsed=elapsed;channels=metrics.map{TrendValues($0)}};init(_ frame: RecordedFrame){elapsed=frame.elapsed;channels=frame.volts.map{TrendValues(Metrics($0,rate:frame.sampleRate))}}}
enum TrendMetric: String,CaseIterable {case vpp="Vpp",rms="RMS",frequency="Frequency";var unit:String{self == .frequency ? "Hz":"V"};func value(_ v:TrendValues)->Double?{guard v.available else{return nil};switch self{case .vpp:return v.vpp;case .rms:return v.rms;case .frequency:return v.frequency}}}
struct ReferenceComparison {
    var deltaVpp:Double,deltaMean:Double,deltaFrequency:Double?,delay:Double?,correlation:Double
    static func compare(live:Capture,reference:Capture,channel:Int)->ReferenceComparison?{
        let a=live.volts[channel],b=reference.volts[channel];guard a.count>3,b.count>3 else{return nil}
        let am=Metrics(a,rate:live.rate),bm=Metrics(b,rate:reference.rate)
        var result=ReferenceComparison(deltaVpp:am.vpp-bm.vpp,deltaMean:am.mean-bm.mean,deltaFrequency:am.frequency>0 && bm.frequency>0 ? am.frequency-bm.frequency:nil,delay:nil,correlation:0)
        let lower=max(-live.trigger,-reference.trigger),upper=min(Double(a.count-1)/live.rate-live.trigger,Double(b.count-1)/reference.rate-reference.trigger)
        guard upper>lower else{return result}
        let count=Int(min(1024,max(0,(upper-lower)*min(live.rate,reference.rate)+1)));guard count>=32 else{return result}
        let step=(upper-lower)/Double(count-1)
        func resample(_ frame:Capture)->[Double]{(0..<count).map{i in let position=min(Double(frame.volts[channel].count-1),max(0,(lower+Double(i)*step+frame.trigger)*frame.rate));let lo=max(0,min(frame.volts[channel].count-2,Int(floor(position))));let f=min(1,max(0,position-Double(lo)));return frame.volts[channel][lo]*(1-f)+frame.volts[channel][lo+1]*f}}
        let x=resample(live),y=resample(reference);let xm=x.reduce(0,+)/Double(count),ym=y.reduce(0,+)/Double(count)
        var best = -Double.infinity,bestLag=0
        for lag in (-min(128,count/4))...min(128,count/4){var xy=0.0,xx=0.0,yy=0.0
            for i in max(0,-lag)..<min(count,count-lag){let av=x[i+lag]-xm,bv=y[i]-ym;xy += av*bv;xx += av*av;yy += bv*bv}
            let score=xx>1e-18 && yy>1e-18 ? xy/sqrt(xx*yy):0
            if score>best+1e-6 || (abs(score-best)<=1e-6 && abs(lag)<abs(bestLag)){best=score;bestLag=lag}
        }
        result.correlation=best;if best>=0.8{result.delay=Double(bestLag)*step};return result
    }
}
struct CaptureMetadata:Codable,Equatable {var identity:String;var settings:Settings;var settingsReadUTC:Double}
struct SnapshotBookmark:Codable,Identifiable,Equatable {var index:Int;var elapsed:Double;var note:String;var id:Int{index}}
struct RecordingNotes:Codable {
    var version=1;var identity:String;var bookmarks:[SnapshotBookmark]
    func encoded()throws->Data{_=try validated(identity:identity,count:Int.max);let data=try JSONEncoder().encode(self);guard data.count<=16*1024*1024 else{throw ScopeError("Recording notes exceed 16 MB")};return data}
    static func load(url:URL,identity:String,count:Int)throws->RecordingNotes{let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=16*1024*1024 else{throw ScopeError("Recording notes exceed 16 MB")};return try JSONDecoder().decode(Self.self,from:Data(contentsOf:url)).validated(identity:identity,count:count)}
    func validated(identity expected:String,count:Int)throws->RecordingNotes{
        guard version==1,!identity.isEmpty,identity==expected,bookmarks.count<=1000 else{throw ScopeError("Notes belong to another recording or use an unsupported format")}
        guard Set(bookmarks.map(\.index)).count==bookmarks.count,bookmarks.allSatisfy({$0.index>=0 && $0.index<count && $0.elapsed.isFinite && $0.elapsed>=0 && $0.note.count<=10000}) else{throw ScopeError("Invalid recording notes")};return self
    }
}
