// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct RecordedFrame: Codable, Equatable {
    var receivedUTC: Double
    var elapsed: Double
    var sampleRate: Double
    var triggerTime: Double
    var metadata: CaptureMetadata?
    var synthetic: Bool?
    var volts: [[Double]]
    init(_ capture: Capture, elapsed: Double) {
        synthetic=capture.synthetic ? true:nil;metadata=capture.metadata;receivedUTC=capture.completedUTC;self.elapsed=max(0,elapsed);sampleRate=capture.rate;triggerTime=capture.trigger;volts=capture.volts
    }
    var capture: Capture {var result=Capture(volts:volts,rate:sampleRate,trigger:triggerTime,raw:Data());result.completedUTC=receivedUTC;result.metadata=metadata;result.synthetic=synthetic ?? false;return result}
}
struct CaptureRecording: Codable, Equatable {
    static let maxSamples=2_000_000, maxFrames=1000, maxBytes=64*1024*1024
    var format="ScopeMac snapshots",version=1
    var frames: [RecordedFrame]
    func validate() throws {
        guard format == "ScopeMac snapshots",version == 1,!frames.isEmpty,frames.count<=Self.maxFrames else { throw ScopeError("Unsupported or empty ScopeMac recording") }
        var samples=0, previous = -Double.infinity
        for frame in frames {
            guard frame.receivedUTC.isFinite,frame.elapsed.isFinite,frame.elapsed>=0,frame.elapsed>=previous,frame.sampleRate.isFinite,frame.sampleRate>0,frame.triggerTime.isFinite,frame.volts.count==2,frame.volts.contains(where:{!$0.isEmpty}),frame.volts.allSatisfy({$0.allSatisfy(\.isFinite)}) else { throw ScopeError("Invalid recorded waveform or timeline") }
            previous=frame.elapsed;samples += frame.volts.reduce(0){$0+$1.count}
            guard samples<=Self.maxSamples else { throw ScopeError("Recording exceeds sample limit") }
        }
    }
    func encoded() throws -> Data { try validate();let data=try JSONEncoder().encode(self);guard data.count<=Self.maxBytes else { throw ScopeError("Recording exceeds file size limit") };return data }
    static func decoded(_ data: Data) throws -> CaptureRecording {
        guard data.count<=maxBytes else { throw ScopeError("Recording exceeds 64 MB limit") }
        let recording=try JSONDecoder().decode(Self.self,from:data);try recording.validate();return recording
    }
    static func load(_ url: URL) throws -> CaptureRecording {
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=maxBytes else { throw ScopeError("Recording exceeds 64 MB limit") }
        return try decoded(Data(contentsOf:url))
    }
}
