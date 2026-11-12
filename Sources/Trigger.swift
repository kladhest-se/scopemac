// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct TriggerSettings: Equatable {
    var mode="EDGE", source="CHANnel1", slope="RISIng", sweep="AUTO"
    var level=0.0
    func validate() throws {
        guard ["CHANnel1","CHANnel2","EXT/10"].contains(source),["RISIng","FALLing","EITHer"].contains(slope),["AUTO","NORMal","SINGle"].contains(sweep),level.isFinite,abs(level)<=1e6 else { throw ScopeError("Invalid edge trigger settings; nothing sent.") }
    }
}
func readTrigger(query: (String) throws -> String) throws -> TriggerSettings {
    func text(_ command: String) throws -> String { try query(command).trimmingCharacters(in:.whitespacesAndNewlines).uppercased() }
    var result=TriggerSettings();result.mode=try text(":TRIGger:MODE?")
    guard !result.mode.isEmpty else { throw ScopeError("Empty trigger mode response") }
    switch try text(":TRIGger:SWEep?") {
        case "AUTO":result.sweep="AUTO"
        case "NORM","NORMAL":result.sweep="NORMal"
        case "SING","SINGLE":result.sweep="SINGle"
        default:throw ScopeError("Unsupported trigger sweep readback")
    }
    guard result.mode == "EDGE" else { return result }
    switch try text(":TRIGger:EDGe:SOURce?") {
        case "CH1","CHAN1","CHANNEL1":result.source="CHANnel1"
        case "CH2","CHAN2","CHANNEL2":result.source="CHANnel2"
        case "EXT/10":result.source="EXT/10"
        default:throw ScopeError("Unsupported trigger source readback")
    }
    switch try text(":TRIGger:EDGe:SLOPe?") {
        case "RIS","RISING":result.slope="RISIng"
        case "FALL","FALLING":result.slope="FALLing"
        case "EITH","EITHER":result.slope="EITHer"
        default:throw ScopeError("Unsupported trigger slope readback")
    }
    guard let level=Double(try text(":TRIGger:EDGe:LEVel?")),level.isFinite else { throw ScopeError("Invalid trigger level readback") }
    result.level=level;try result.validate();return result
}
func applyTrigger(_ settings: TriggerSettings,write: (String) throws -> Void,query: (String) throws -> String) throws -> TriggerSettings {
    try settings.validate()
    try write(":TRIGger:MODE EDGE")
    try write(":TRIGger:EDGe:SOURce "+settings.source)
    try write(":TRIGger:EDGe:SLOPe "+settings.slope)
    try write(":TRIGger:EDGe:LEVel \(settings.level)")
    try write(":TRIGger:SWEep "+settings.sweep)
    return try readTrigger(query:query)
}
