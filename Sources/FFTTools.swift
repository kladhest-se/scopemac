// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct SpectralPeak {var frequency: Double;var db: Double}
struct SpectrumAverage {
    private var history=[[Double]]()
    mutating func clear(){history=[]}
    mutating func add(_ db: [Double],count: Int) -> [Double] {
        let limit=max(1,min(16,count))
        if history.first?.count != db.count{history=[]}
        let power=db.map{pow(10,$0/10)};history.append(power)
        if history.count>limit{history.removeFirst(history.count-limit)}
        guard !db.isEmpty else{return []}
        var mean=[Double](repeating:0,count:db.count)
        for frame in history{for i in mean.indices{mean[i] += frame[i]/Double(history.count)}}
        return mean.map{10*log10(max(1e-30,$0))}
    }
}
func spectralPeaks(_ db: [Double],spacing: Double,limit: Double) -> [SpectralPeak] {
    guard db.count>=3,spacing>0 else{return []}
    var peaks=[SpectralPeak]()
    for i in 1..<db.count-1 where Double(i)*spacing<=limit {
        guard db[i]>db[i-1],db[i]>=db[i+1] else{continue}
        let denominator=db[i-1]-2*db[i]+db[i+1]
        let delta=abs(denominator)>1e-12 ? min(0.5,max(-0.5,0.5*(db[i-1]-db[i+1])/denominator)):0
        peaks.append(SpectralPeak(frequency:(Double(i)+delta)*spacing,db:db[i]))
    }
    return Array(peaks.sorted{$0.db>$1.db}.prefix(3))
}
