// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
final class DiagnosticLog {
    let directory: URL
    private let file: URL
    private var capture = 0, packetIndex = 0
    init() {
        let formatter = DateFormatter(); formatter.locale=Locale(identifier:"en_US_POSIX"); formatter.dateFormat="yyyyMMdd-HHmmss-SSS"
        // ~/Library/Logs/ScopeMac/<session>. Never beside the app bundle: /Applications
        // must not be written to, and a translocated bundle's parent is read-only.
        let fm = FileManager.default
        let logs = fm.urls(for:.libraryDirectory,in:.userDomainMask).first?.appendingPathComponent("Logs/ScopeMac") ?? fm.temporaryDirectory.appendingPathComponent("ScopeMac-diagnostics")
        DiagnosticLog.prune(logs,keeping:DiagnosticLog.retainedSessions-1)
        let desired = logs.appendingPathComponent(formatter.string(from:Date()))
        if (try? fm.createDirectory(at:desired,withIntermediateDirectories:true)) != nil { directory=desired }
        else { directory=fm.temporaryDirectory.appendingPathComponent("ScopeMac-"+UUID().uuidString); try? fm.createDirectory(at:directory,withIntermediateDirectories:true) }
        file=directory.appendingPathComponent("session.log")
        record("ScopeMac \(AppVersion.marketing) (build \(AppVersion.build)) — native SwiftUI/Metal, DSO2D15 private waveform protocol")
    }
    static let retainedSessions = 20
    /// Removes the oldest session folders so at most `keeping` remain (names sort chronologically).
    static func prune(_ root: URL, keeping: Int) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles]) else { return }
        let sessions = entries.filter { (try? $0.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in sessions.dropLast(max(0,keeping)) { try? fm.removeItem(at:old) }
    }
    func record(_ text: String) {
        let bytes=Data((ISO8601DateFormatter().string(from:Date())+" "+text+"\n").utf8)
        if let size=(try? file.resourceValues(forKeys:[.fileSizeKey]))?.fileSize, size > 2_000_000 { try? FileManager.default.removeItem(at:directory.appendingPathComponent("previous.log")); try? FileManager.default.moveItem(at:file,to:directory.appendingPathComponent("previous.log")) }
        if let handle=try? FileHandle(forWritingTo:file) { defer { try? handle.close() }; _ = try? handle.seekToEnd(); try? handle.write(contentsOf:bytes) }
        else { try? bytes.write(to:file) }
    }
    func beginCapture() {
        capture=capture%8+1; packetIndex=0
        for index in 1...4 { try? FileManager.default.removeItem(at:directory.appendingPathComponent(String(format:"capture-%02d-packet-%02d.bin",capture,index))) }
    }
    func packet(_ data: Data) {
        packetIndex += 1
        if packetIndex <= 4 { try? Data(data.prefix(1_048_576)).write(to:directory.appendingPathComponent(String(format:"capture-%02d-packet-%02d.bin",capture,packetIndex)),options:.atomic) }
    }
}
