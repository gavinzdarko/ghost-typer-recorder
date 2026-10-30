import CoreGraphics
import CryptoKit
import Foundation
import RecorderCore

/// Explicit storage-only diagnostic. Never installs an input listener, requests
/// permissions, reads personal recordings, or changes the recorder's settings.
@main struct StorageProbe {
    static func finish(_ writer: JSONLWriter) async {
        await withCheckedContinuation { continuation in writer.finish { continuation.resume() } }
    }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "StorageProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func main() async throws {
        guard CommandLine.arguments.dropFirst().elementsEqual(["--probe-default-storage"]) else {
            print("Usage: RecorderStorageProbe --probe-default-storage (synthetic storage probe only)")
            return
        }
        let writer = try JSONLWriter()
        let date = Date()
        let session = "SYNTHETIC-PREFLIGHT-" + UUID().uuidString
        func row(_ kind: String, _ ms: UInt64, key: UInt16? = nil, button: Int? = nil, detail: String? = nil) -> InputRecord {
            InputRecord(kind: kind, timestampNS: ms * 1_000_000, wallTime: date, sessionID: session,
                        keyCode: key, x: button == nil ? nil : 100, y: button == nil ? nil : 200,
                        button: button, appBundleID: "synthetic.preflight", details: detail)
        }
        func nativeText(_ text: String, _ ms: UInt64, key: UInt16) throws -> InputRecord {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true) else {
                throw NSError(domain: "StorageProbe", code: 4)
            }
            let chars = Array(text.utf16)
            chars.withUnsafeBufferPointer {
                event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress)
            }
            event.timestamp = ms * 1_000_000
            guard let decoded = NativeEventDecoder.decode(.keyDown, event: event,
                metadata: row("key_down", ms, key: key), includeText: true) else {
                throw NSError(domain: "StorageProbe", code: 5)
            }
            try require(decoded.text == text, "Native synthetic text did not match")
            return decoded
        }
        let rows = [row("boundary", 0, detail: "recording_started;synthetic_only"),
                    try nativeText("A", 1000, key: 0), try nativeText("é👻e\u{301}", 1050, key: 1),
                    row("key_up", 1080, key: 0), row("key_up", 1100, key: 1),
                    row("mouse_down", 2000, button: 0), row("mouse_up", 2200, button: 0),
                    row("key_down", 3000, key: 2), row("boundary", 3100, detail: "sleep_or_session_inactive"),
                    row("boundary", 10000, detail: "recording_started;synthetic_only"),
                    row("key_up", 10100, key: 2), row("key_down", 10200, key: 3),
                    row("key_up", 10240, key: 3), row("boundary", 10250, detail: "recording_stopped")]
        for record in rows { try require(writer.enqueue(record), "Probe enqueue failed") }
        try require(writer.checkpoint(timeout: 5), "Probe checkpoint failed")
        await finish(writer)
        let snapshot = writer.snapshot()
        try require(snapshot.state == "finished" && snapshot.lastError == nil, "Probe did not finish cleanly")
        try require(snapshot.writtenRecords == UInt64(rows.count) && snapshot.droppedRecords == 0, "Probe count/loss mismatch")
        guard let originalFile = snapshot.currentFile else { throw NSError(domain: "StorageProbe", code: 2) }
        let saved = try Data(contentsOf: originalFile)
        let decoded = try saved.split(separator: 10).map { try JSONDecoder().decode(InputRecord.self, from: Data($0)) }
        try require(decoded == rows, "Fresh disk read differs from enqueued data")
        try require(!writer.enqueue(row("key_down", 10300, key: 4)), "OFF accepted new input")
        let reopened = try JSONLWriter()
        reopened.enqueue(InputRecord(kind: "boundary", wallTime: date, sessionID: session + "-REOPEN", details: "synthetic_reopen_only"))
        await finish(reopened)
        guard let reopenedFile = reopened.snapshot().currentFile else { throw NSError(domain: "StorageProbe", code: 3) }
        try require(reopenedFile != originalFile, "Reopen reused the old file")
        try require(try Data(contentsOf: originalFile) == saved, "Reopen altered the saved session")
        let directory = JSONLWriter.Configuration.defaultDirectory
        let mode = try FileManager.default.attributesOfItem(atPath: originalFile.path)[.posixPermissions] as? NSNumber
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600 && dirMode?.intValue == 0o700, "Private permissions mismatch")
        let diagnostics = directory.deletingLastPathComponent().appendingPathComponent("Diagnostics/" + session, isDirectory: true)
        try FileManager.default.createDirectory(at: diagnostics, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let kept = diagnostics.appendingPathComponent("synthetic-session.jsonl")
        try FileManager.default.moveItem(at: originalFile, to: kept)
        try FileManager.default.moveItem(at: reopenedFile, to: diagnostics.appendingPathComponent("synthetic-reopen.jsonl"))
        let report: [String: Any] = ["synthetic_only": true, "recordings_directory": directory.path,
            "diagnostics_directory": diagnostics.path, "kept_probe_file": kept.path,
            "records_verified": rows.count, "dropped_records": snapshot.droppedRecords,
            "off_rejects_input": true, "reopen_preserves_old_session": true,
            "native_text_payloads_exact_after_disk_read": true, "native_text_payloads_verified": 2,
            "file_mode": "0600", "directory_mode": "0700",
            "sha256": SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined()]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
