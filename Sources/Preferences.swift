// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct DisplayPreferences: Codable, Equatable {
    var version=1
    var mode="Waveform"
    var fftSource=0
    var showCH1=true, showCH2=true, cursors=false, inspector=true
    var selectedCursor=0
    var refreshInterval: Double? = nil
    var fftBand: Double? = nil
    var fftAverage: Int? = nil
    var showFFTPeaks: Bool? = nil
    var voltageLocked:Bool? = nil
    var voltageMinimum:Double? = nil
    var voltageMaximum:Double? = nil
    var summarySelection:[String]? = nil
    var sidebarWidth:Double? = nil
    var expandedPanels:[String]? = nil
    var theme:String? = nil
    func validated() -> DisplayPreferences {
        guard version == 1 else { return DisplayPreferences() }
        var copy=self
        if let theme=copy.theme,ScopeTheme(rawValue:theme) == nil{copy.theme="Dark"}
        if !["Waveform","CH1 + CH2","FFT"].contains(copy.mode) { copy.mode="Waveform" }
        if !(0...1).contains(copy.fftSource) { copy.fftSource=0 }
        if !(0...1).contains(copy.selectedCursor) { copy.selectedCursor=0 }
        if let interval=copy.refreshInterval,!interval.isFinite || ![0.0,0.5,1,2,5,10,30,60].contains(interval) {copy.refreshInterval=0}
        if let band=copy.fftBand,![0.0,1000,10000,100000,1000000,10000000].contains(band){copy.fftBand=10000}
        if let average=copy.fftAverage,![1,4,16].contains(average){copy.fftAverage=1}
        let lo=copy.voltageMinimum ?? -1,hi=copy.voltageMaximum ?? 6
        if !lo.isFinite || !hi.isFinite || lo>=hi || abs(lo)>1e9 || abs(hi)>1e9{copy.voltageLocked=false;copy.voltageMinimum = -1;copy.voltageMaximum=6}
        if let selection=copy.summarySelection {let valid=SummaryMeasurement.allCases.map(\.rawValue).filter{selection.contains($0)};copy.summarySelection=valid.isEmpty ? SummaryMeasurement.defaults:valid}
        if let width=copy.sidebarWidth{copy.sidebarWidth=width.isFinite ? min(460,max(260,width)):280}
        if let panels=copy.expandedPanels{copy.expandedPanels=Array(Set(panels).intersection(["measurements","trigger","trends","info","comparison","bookmarks","experimental"]))}
        return copy
    }
    static func decode(_ data: Data?) -> DisplayPreferences {
        guard let data, let decoded=try? JSONDecoder().decode(Self.self,from:data) else { return Self() }
        return decoded.validated()
    }
}
struct PreferenceStore {
    var load: () -> Data?
    var save: (Data?) -> Void
    static var standard: PreferenceStore {
        let key="ScopeMac.displayPreferences.v1"
        return PreferenceStore(load:{UserDefaults.standard.data(forKey:key)},save:{ value in
            if let value {UserDefaults.standard.set(value,forKey:key)} else {UserDefaults.standard.removeObject(forKey:key)}
        })
    }
    static var transient: PreferenceStore { PreferenceStore(load:{nil},save:{_ in}) }
}
