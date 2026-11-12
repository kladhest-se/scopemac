// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
private struct StreamHeader: Codable { var format="ScopeMac snapshot stream";var version=2 }
final class StreamRecordingWriter {
    let url: URL
    private var handle: FileHandle?
    private var lastComplete: UInt64=0
    var bytes: UInt64 {lastComplete}
    private(set) var count=0
    private var previousElapsed = -Double.infinity
    private var failed=false
    init(url: URL) throws {
        self.url=url
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else {throw ScopeError("Cannot create recording file")}
        handle=try FileHandle(forWritingTo:url)
        try line(try JSONEncoder().encode(StreamHeader()))
    }
    private func line(_ data: Data) throws {
        guard let handle else{throw ScopeError("Recording file is closed")}
        guard data.count<=CaptureRecording.maxBytes,lastComplete+UInt64(data.count)+1<=2_147_483_648 else{throw ScopeError("Recording reached its 2 GB file limit")}
        guard !failed else{throw ScopeError("Recording writer stopped after an earlier write failure")}
        do {try handle.write(contentsOf:data);try handle.write(contentsOf:Data([10]));lastComplete += UInt64(data.count+1)}catch{failed=true;throw error}
    }
    func append(_ frame: RecordedFrame) throws {
        try CaptureRecording(frames:[frame]).validate()
        guard frame.elapsed>=previousElapsed,count<100_000 else{throw ScopeError("Invalid recording timeline or 100,000 snapshot limit reached")}
        try line(try JSONEncoder().encode(frame));previousElapsed=frame.elapsed;count += 1
    }
    func finish() throws {
        guard let handle else{return};self.handle=nil
        // A failed write cannot leave a partial JSON record at the end.
        defer{try? handle.close()}
        try handle.truncate(atOffset:lastComplete);try handle.synchronize()
    }
    deinit{try? finish()}
}
final class StreamRecordingReader {
    private struct Entry {var offset: UInt64;var length: Int;var elapsed: Double}
    private let handle: FileHandle
    private var entries=[Entry]()
    private(set) var trends=[TrendPoint]()
    private(set) var recoveredTail=false
    var count: Int {entries.count}
    func elapsed(at index: Int) -> Double {entries[index].elapsed}
    init(url: URL,cancelled:()->Bool = {false}) throws {
        handle=try FileHandle(forReadingFrom:url)
        let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size<=2_147_483_648 else{throw ScopeError("Recording exceeds 2 GB limit")}
        var buffer=Data(),offset: UInt64=0,headerRead=false,previous = -Double.infinity
        while true {
            if cancelled(){throw ScopeError("Recording load canceled")}
            let chunk=try handle.read(upToCount:65536) ?? Data()
            if chunk.isEmpty {break};buffer.append(chunk)
            while let end=buffer.firstIndex(of:10) {
                let data=Data(buffer[..<end]);let consumed=data.count+1
                if !headerRead {
                    let header=try JSONDecoder().decode(StreamHeader.self,from:data)
                    guard header.format == "ScopeMac snapshot stream",header.version==2 else{throw ScopeError("Unsupported stream recording")};headerRead=true
                } else {
                    let frame=try JSONDecoder().decode(RecordedFrame.self,from:data);try CaptureRecording(frames:[frame]).validate()
                    guard frame.elapsed>=previous,entries.count<100_000 else{throw ScopeError("Invalid timeline or recording index too large")}
                    trends.append(TrendPoint(frame));entries.append(Entry(offset:offset,length:data.count,elapsed:frame.elapsed));previous=frame.elapsed
                }
                buffer.removeFirst(consumed);offset += UInt64(consumed)
            }
            guard buffer.count<=CaptureRecording.maxBytes else{throw ScopeError("Recorded snapshot exceeds 64 MB limit")}
        }
        recoveredTail = !buffer.isEmpty
        guard headerRead,!entries.isEmpty else{throw ScopeError("Recording is empty or ends with an incomplete snapshot")}
    }
    static func isStream(_ url: URL) throws -> Bool {
        let file=try FileHandle(forReadingFrom:url);defer{try? file.close()}
        let data=try file.read(upToCount:4096) ?? Data()
        guard let end=data.firstIndex(of:10),let header=try? JSONDecoder().decode(StreamHeader.self,from:Data(data[..<end])) else{return false}
        return header.format == "ScopeMac snapshot stream"
    }
    func frame(at index: Int) throws -> RecordedFrame {
        guard entries.indices.contains(index) else{throw ScopeError("Snapshot index out of bounds")}
        let entry=entries[index];try handle.seek(toOffset:entry.offset)
        guard let data=try handle.read(upToCount:entry.length),data.count==entry.length else{throw ScopeError("Recording was truncated after opening")}
        let frame=try JSONDecoder().decode(RecordedFrame.self,from:data);try CaptureRecording(frames:[frame]).validate();return frame
    }
    deinit{try? handle.close()}
}
