// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

struct ScopeError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ text: String) { message = text } }
struct Channel: Codable, Equatable { var enabled = true; var scale = 1.0; var offset = 0.0; var probe = 10.0; var coupling = "DC" }
struct Settings: Codable, Equatable { var channels = [Channel(), Channel()]; var timebase = 0.0005 }
struct Capture {
    var volts: [[Double]]; var rate: Double; var trigger: Double; var raw: Data
    var metadata: CaptureMetadata?
    var synthetic = false
    var completedUTC=Date().timeIntervalSince1970
    var completedMonotonic=monotonic()
    var usbMS = 0.0
    var assemblyMS = 0.0
    var decodeMS = 0.0
    var statusMS = 0.0
    var totalMS = 0.0
    var transport = TransferTrace()
    var duration: Double { Double(max(0, (volts.map(\.count).max() ?? 1) - 1)) / rate }
}
func ascii(_ bytes: ArraySlice<UInt8>) -> String { String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0"))) }
final class Assembler {
    var metadata = [UInt8](), samples = [UInt8](), coverage = [Bool](); var covered = 0, skipped = 0; var inclusive = false
    func append(_ data: Data) throws -> Bool {
        let p = [UInt8](data)
        func decimal(_ start: Int, _ size: Int) throws -> Int {
            guard p.count >= start + size, p[start..<start+size].allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int(ascii(p[start..<start+size])) else { throw ScopeError("Invalid waveform packet length") }; return n
        }
        guard p.count >= 11, p[0] == 35, p[1] == 57 else { throw ScopeError("Expected #9 waveform block") }
        if try decimal(2, 9) == 0 { return false }
        let total = try decimal(11, 9), position = try decimal(20, 9)
        guard total > 0, total <= 16_000_000, position <= total else { throw ScopeError("Waveform bounds exceeded") }
        if metadata.isEmpty && position != 0 { skipped += 1; guard skipped <= 4096 else { throw ScopeError("Cannot synchronize waveform") }; return false }
        let first = metadata.isEmpty
        if first {
            guard p.count >= 128 else { throw ScopeError("Truncated metadata") }
            inclusive = total % 2000 == 99
            metadata = Array(p[29..<128]); samples = .init(repeating: 0, count: total); coverage = .init(repeating: false, count: total)
        }
        guard samples.count == total else { throw ScopeError("Capture depth changed during transfer") }
        let repeated = p.count >= 128 && Array(p[29..<94]) == Array(metadata.prefix(65))
        let start = first ? (inclusive ? 29 : 128) : (repeated || !inclusive ? 128 : 29)
        guard p.count >= start else { throw ScopeError("Truncated packet") }
        var payload = Array(p.dropFirst(start)); let remaining = total - position
        if payload.count > remaining {
            let trailer = Array(payload.dropFirst(remaining)); guard trailer == [10] || trailer == [13,10] else { throw ScopeError("Waveform exceeds declared size") }; payload = Array(payload.prefix(remaining))
        }
        for (i, byte) in payload.enumerated() {
            let at = position + i
            if coverage[at] && samples[at] != byte { throw ScopeError("Conflicting waveform packets") }
            if !coverage[at] { coverage[at] = true; covered += 1 }; samples[at] = byte
        }
        return covered == total
    }
    func decode(_ settings: Settings) throws -> Capture {
        guard metadata.count == 99, covered == samples.count, covered > 0 else { throw ScopeError("Incomplete capture") }
        func number(_ at: Int) -> Double? { guard at + 9 <= metadata.count else { return nil }; guard let d = Double(ascii(metadata[at..<at+9])), d.isFinite else { return nil }; return d }
        var candidates = [Int]()
        for i in 46...62 where i + 19 <= metadata.count {
            let flags = metadata[i..<i+4].allSatisfy { $0 == 48 || $0 == 49 }
            let digits = metadata[i+13..<i+19].allSatisfy { $0 >= 48 && $0 <= 57 }
            let text = ascii(metadata[i+4..<i+13]).lowercased()
            if flags && digits && text.contains(".") && text.contains("e"), let rate = number(i+4), rate > 0 { candidates.append(i) }
        }
        guard candidates.count == 1, let i = candidates.first, let rate = number(i+4), let time = number(i+19) ?? number(i+28) else { throw ScopeError("Unsupported waveform metadata") }
        let enabled = (0..<4).filter { metadata[i+$0] == 49 }
        guard !enabled.isEmpty, enabled.allSatisfy({ $0 < 2 }) else { throw ScopeError("Enable CH1 or CH2") }
        let raw = inclusive ? Array(samples.dropFirst(99)) : samples
        guard raw.count % (2000 * enabled.count) == 0 else { throw ScopeError("Invalid channel block length") }
        var volts = [[Double](), [Double]()]
        for block in 0..<(raw.count/2000) {
            let ch = enabled[block % enabled.count], calibration = settings.channels[ch]
            guard calibration.scale.isFinite, calibration.scale > 0, calibration.offset.isFinite else { throw ScopeError("Invalid channel calibration") }
            for byte in raw[block*2000..<(block+1)*2000] { volts[ch].append(Double(Int8(bitPattern: byte)) * calibration.scale / 25 - calibration.offset) }
        }
        return Capture(volts: volts, rate: rate, trigger: time, raw: Data(raw))
    }
}
struct Metrics {
    var vpp = 0.0, mean = 0.0, rms = 0.0, frequency = 0.0
    var minimum=0.0,maximum=0.0,acRMS=0.0
    var sampleCount=0
    var period: Double?
    var positiveWidth: Double?
    var dutyCycle: Double?
    init(_ values: [Double], rate: Double) {
        guard let low = values.min(), let high = values.max(), !values.isEmpty else { return }
        sampleCount=values.count;minimum=low;maximum=high
        vpp = high-low; mean = values.reduce(0,+)/Double(values.count); rms = sqrt(values.reduce(0){$0+$1*$1}/Double(values.count))
        acRMS=sqrt(values.reduce(0){$0+($1-mean)*($1-mean)}/Double(values.count))
        var edges = [Int](), armed = values[0] < low+vpp*0.4
        for i in 1..<values.count { if values[i] < low+vpp*0.4 { armed = true }; if armed && values[i] >= low+vpp*0.6 { edges.append(i); armed = false } }
        if edges.count >= 4 { let period = Double(edges.last!-edges.first!)/Double(edges.count-1); if period > 0 && zip(edges.dropFirst(),edges).allSatisfy({ abs(Double($0.0-$0.1)-period) <= period*0.05 }) {
            frequency = rate/period;self.period=period/rate
            let midpoint=(low+high)/2;var rise: Double?,widths=[Double]()
            for i in 1..<values.count {
                let a=values[i-1],b=values[i]
                if a<midpoint && b>=midpoint {rise=Double(i-1)+(midpoint-a)/(b-a)}
                if a>=midpoint && b<midpoint,let start=rise {
                    let end=Double(i-1)+(a-midpoint)/(a-b);widths.append(end-start);rise=nil
                }
            }
            if widths.count>=3 {
                let average=widths.reduce(0,+)/Double(widths.count)
                if average>0 && average<period && widths.allSatisfy({abs($0-average)<=period*0.05}) {positiveWidth=average/rate;dutyCycle=average/period*100}
            }
        } }
    }
}
final class Connection {
    var diagnostics: DiagnosticLog?
    private(set) var lastQuery = QueryTrace()
    private var handle: UnsafeMutableRawPointer?
    func open() throws {
        var error = [CChar](repeating: 0, count: 1024)
        handle = scope_open(&error, 1024); if handle == nil { throw ScopeError(String(cString: error)) }
    }
    func setOverlap(_ enabled: Bool) { if let handle { scope_set_overlap(handle,enabled ? 1:0) } }
    func write(_ command: String) throws {
        guard let handle else { throw ScopeError("Not connected") }; var error = [CChar](repeating: 0, count: 1024)
        diagnostics?.record("WRITE " + command)
        if scope_write(handle, command, &error, 1024) < 0 { throw ScopeError(String(cString: error)) }
    }
    func query(_ command: String) throws -> Data {
        guard let handle else { throw ScopeError("Not connected") }; var error = [CChar](repeating: 0, count: 1024), bytes = [UInt8](repeating: 0, count: 65536+512)
        var profile=ScopeQueryTiming()
        let n = scope_query_profiled(handle, command, &bytes, Int32(bytes.count), &profile, &error, 1024)
        lastQuery=QueryTrace(profile)
        if !command.contains("WAVeform") || n < 0 { diagnostics?.record("USB "+command+": "+lastQuery.summary+"; "+lastQuery.link) }
        if n < 0 { throw ScopeError(String(cString: error)) }; return Data(bytes.prefix(Int(n)))
    }
    func text(_ command: String) throws -> String { let result = String(decoding: try query(command), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); diagnostics?.record(command + " → " + result); return result }
    func number(_ command: String) throws -> Double { guard let d = Double(try text(command)), d.isFinite else { throw ScopeError("Invalid number: \(command)") }; return d }
    func settings() throws -> Settings {
        var result = Settings(); result.timebase = try number(":TIMebase:SCALe?")
        for i in 0..<2 {
            let p = ":CHANnel\(i+1)"; let on = try text(p+":DISPlay?").uppercased()
            guard ["ON","OFF","1","0"].contains(on) else { throw ScopeError("Invalid channel readback") }
            result.channels[i] = Channel(enabled: on == "ON" || on == "1", scale: try number(p+":SCALe?"), offset: try number(p+":OFFSet?"), probe: try number(p+":PROBe?"), coupling: try text(p+":COUPling?").uppercased())
            guard result.channels[i].scale > 0, [1.0,10,100,1000].contains(result.channels[i].probe), ["DC","AC","GND"].contains(result.channels[i].coupling) else { throw ScopeError("Invalid scale") }
        }; return result
    }
    func runState() throws -> String {
        let s = try text(":RUNning?").uppercased()
        if ["1","ON","RUN","RUNNING"].contains(s) { return "RUN" }; if ["0","OFF","STOP","STOPPED"].contains(s) { return "STOP" }; return "Unknown"
    }
    func returnToLocal() throws {
        var issues=[String]()
        diagnostics?.record("Cleanup: unlock keyboard, verify lock readback, Go To Local, REN off, then close USB")
        do {try write(":SYSTem:LOCKed OFF");let locked=try text(":SYSTem:LOCKed?").uppercased();if !["OFF","0"].contains(locked){issues.append("Keyboard lock readback: "+locked)}} catch {issues.append(error.localizedDescription)}
        if let handle {
            var error=[CChar](repeating:0,count:1024)
            if scope_return_local(handle,&error,1024)<0 {issues.append(String(cString:error))}
            else {diagnostics?.record("Cleanup: USB488 Go To Local / REN off completed")}
        }
        if !issues.isEmpty {let message=issues.joined(separator:"; ");diagnostics?.record("Cleanup warning: "+message);throw ScopeError(message)}
        diagnostics?.record("Cleanup: keyboard unlock readback OFF; local-control sequence completed")
    }
    func close() { if let handle { scope_close(handle) }; handle = nil }
    deinit { close() }
}
