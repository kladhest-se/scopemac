// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct QueryTrace {
    var overlapped=false
    var commandMS=0.0, requestMS=0.0, readMS=0.0, totalMS=0.0
    var reads=0, payload=0, wire=0, speed=0, maxPacket=0
    init() {}
    init(_ p: ScopeQueryTiming) {
        commandMS=p.command_ms; requestMS=p.request_ms; readMS=p.read_ms; totalMS=p.total_ms
        overlapped=p.overlapped != 0
        reads=Int(p.read_calls);payload=Int(p.payload_bytes);wire=Int(p.wire_bytes);speed=Int(p.link_speed);maxPacket=Int(p.max_packet_bytes)
    }
    var link: String { switch speed { case 1:return "USB Low Speed 1.5 Mb/s";case 2:return "USB Full Speed 12 Mb/s";case 3:return "USB High Speed 480 Mb/s";case 4:return "USB SuperSpeed 5 Gb/s";case 5:return "USB SuperSpeed+";default:return "USB speed unknown" } }
    var summary: String { String(format:"command %.3f / read-request %.3f / bulk-read %.3f / total %.3f ms; %d reads; %d payload / %d wire bytes",commandMS,requestMS,readMS,totalMS,reads,payload,wire)+(overlapped ? "; OVERLAPPED":"; sequential") }
}
struct TransferTrace {
    var overlapped=false
    var packets=0, reads=0, payload=0, empty=0, stale=0
    var commandMS=0.0, requestMS=0.0, readMS=0.0
    var firstMS=0.0, remainingMS=0.0
    var link="USB speed unknown", maxPacket=0
    mutating func append(_ query: QueryTrace, noProgress: Bool, stalePacket: Bool) {
        overlapped = overlapped || query.overlapped
        packets += 1; reads += query.reads;payload += query.payload
        commandMS += query.commandMS;requestMS += query.requestMS;readMS += query.readMS
        if packets == 1 { firstMS=query.totalMS } else { remainingMS += query.totalMS }
        if noProgress { empty += 1 };if stalePacket { stale += 1 };link=query.link;maxPacket=query.maxPacket
    }
    var summary: String {
        String(format:"%d waveform queries · %d USB reads · %.1f KB · OUT %.2f ms · IN %.2f ms",packets,reads,Double(payload)/1000,commandMS+requestMS,readMS)+(overlapped ? " · OVERLAPPED":" · sequential")
    }
    var detail: String { String(format:"First query %.2f ms · remaining %.2f ms · no-progress %d · stale %d · %@ · endpoint %d B",firstMS,remainingMS,empty,stale,link,maxPacket) }
}
