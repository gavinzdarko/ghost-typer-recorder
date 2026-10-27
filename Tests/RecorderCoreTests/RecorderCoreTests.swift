import Foundation
import XCTest
@testable import RecorderCore

final class RecorderCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GhostRecorderTests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func stop(_ writer: JSONLWriter) {
        let done = expectation(description: "durable stop")
        writer.finish { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func records() throws -> [InputRecord] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.flatMap { url in
            try Data(contentsOf: url).split(separator: 0x0a).map { try JSONDecoder().decode(InputRecord.self, from: Data($0)) }
        }
    }

    func testAcceptedEventsRemainOrderedAndPrivateThroughRotation() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, maxFileBytes: 500))
        for index in 0..<40 {
            XCTAssertTrue(writer.enqueue(InputRecord(kind: index % 2 == 0 ? "key_down" : "key_up",
                timestampNS: UInt64(index), sessionID: "test", keyCode: 12, text: "é\n\"")))
        }
        stop(writer)
        XCTAssertEqual(try records().map(\.timestampNS), Array(0..<40).map(UInt64.init))
        XCTAssertEqual(writer.snapshot().writtenRecords, 40)
        XCTAssertEqual(writer.snapshot().state, "finished")
        XCTAssertFalse(writer.enqueue(InputRecord(kind: "late", sessionID: "test")))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(files.count, 1)
        for url in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testBoundedOverloadEmitsGapAfterAcceptedEvents() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory,
            maxPendingRecords: 2, batchSize: 1, flushInterval: 30))
        for index in 0..<5 {
            let accepted = writer.enqueue(InputRecord(kind: "key_down", timestampNS: UInt64(index),
                sessionID: "test", keyCode: 0, pressure: 0.3, clickCount: 2,
                deltaX: 3, deltaY: -1, sourcePID: 123, keyboardType: 40))
            XCTAssertEqual(accepted, index < 2)
        }
        XCTAssertEqual(writer.snapshot().pendingRecords, 2)
        stop(writer)
        let events = try records()
        XCTAssertEqual(events.map(\.kind), ["key_down", "key_down", "data_loss"])
        XCTAssertEqual(events.last?.droppedRecordCount, 3)
        XCTAssertNil(events.last?.keyCode)
        XCTAssertNil(events.last?.pressure)
        XCTAssertNil(events.last?.clickCount)
        XCTAssertNil(events.last?.deltaX)
        XCTAssertNil(events.last?.deltaY)
        XCTAssertNil(events.last?.sourcePID)
        XCTAssertNil(events.last?.keyboardType)
        XCTAssertEqual(writer.snapshot().droppedRecords, 3)
        XCTAssertEqual(writer.snapshot().acceptedRecords, 2)
        XCTAssertEqual(writer.snapshot().writtenRecords, 3)
    }

    func testDiskFailureIsSurfacedAndRejectsFurtherCapture() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        // Simulate the recording directory disappearing after recording starts.
        try FileManager.default.removeItem(at: directory)
        writer.enqueue(InputRecord(kind: "key_down", sessionID: "test"))
        stop(writer)
        XCTAssertEqual(writer.snapshot().state, "failed")
        XCTAssertNotNil(writer.snapshot().lastError)
        XCTAssertFalse(writer.enqueue(InputRecord(kind: "key_up", sessionID: "test")))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func testSchemaUsesNanosecondIntegerAndOmitsUnknownValues() throws {
        let source = InputRecord(kind: "key_down", timestampNS: 9_000_000_000_000_001,
                                 sessionID: "test", keyCode: 12, text: "\n")
        let data = try JSONEncoder().encode(source)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema_version"] as? Int, 1)
        XCTAssertEqual((json["timestamp_ns"] as? NSNumber)?.uint64Value, 9_000_000_000_000_001)
        XCTAssertNil(json["window_title"])
        XCTAssertEqual(try JSONDecoder().decode(InputRecord.self, from: data), source)
    }

    func testOptionalDeviceMetadataRoundTripsWithStableFieldNames() throws {
        let source = InputRecord(kind: "mouse_down", sessionID: "test", pressure: 0.5,
            clickCount: 2, deltaX: -4, deltaY: 8, sourcePID: 1234, keyboardType: 40)
        let data = try JSONEncoder().encode(source)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["pressure"] as? Double, 0.5)
        XCTAssertEqual(json["click_count"] as? Int, 2)
        XCTAssertEqual(json["delta_x"] as? Double, -4)
        XCTAssertEqual(json["delta_y"] as? Double, 8)
        XCTAssertEqual(json["source_pid"] as? Int, 1234)
        XCTAssertEqual(json["keyboard_type"] as? Int, 40)
        XCTAssertEqual(try JSONDecoder().decode(InputRecord.self, from: data), source)
    }

    func testConcurrentProducersDoNotLoseOrDuplicateAcceptedRecords() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory,
            maxPendingRecords: 2048, batchSize: 37, flushInterval: 30))
        DispatchQueue.concurrentPerform(iterations: 8) { producer in
            for index in 0..<100 {
                writer.enqueue(InputRecord(kind: "key_down", timestampNS: UInt64(producer * 100 + index),
                    sessionID: "producer-\(producer)"))
            }
        }
        stop(writer)
        let events = try records()
        XCTAssertEqual(events.count, 800)
        XCTAssertEqual(Set(events.map(\.timestampNS)).count, 800)
        XCTAssertEqual(writer.snapshot().droppedRecords, 0)
        for producer in 0..<8 {
            XCTAssertEqual(events.filter { $0.sessionID == "producer-\(producer)" }.map(\.timestampNS),
                Array((producer * 100)..<(producer * 100 + 100)).map(UInt64.init))
        }
    }

    func testAutomaticFlushPersistsWhileStillRecording() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 0.01))
        writer.enqueue(InputRecord(kind: "key_down", sessionID: "test"))
        let flushed = expectation(description: "automatic flush")
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(5)
            while writer.snapshot().writtenRecords == 0 && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            flushed.fulfill()
        }
        wait(for: [flushed], timeout: 6)
        XCTAssertEqual(try records().count, 1)
        XCTAssertEqual(writer.snapshot().state, "running")
        stop(writer)
    }

    func testPersonalInputSourceSurvivesRoundTripAndLegacyRecordsRemainReadable() throws {
        let recorded = InputRecord(kind: "key_down", sessionID: "personal-session", keyCode: 12,
            inputSourceID: "com.apple.keylayout.Dvorak", inputSourceName: "Dvorak")
        let data = try JSONEncoder().encode(recorded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["input_source_id"] as? String, "com.apple.keylayout.Dvorak")
        XCTAssertEqual(try JSONDecoder().decode(InputRecord.self, from: data), recorded)
        let legacy = InputRecord(kind: "key_up", sessionID: "older-session", keyCode: 12)
        let legacyData = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(InputRecord.self, from: legacyData).inputSourceID)
    }

    func testOFFFlushesEveryBufferedRecordAndReopenCannotOverwriteOldSession() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        for index in 0..<5000 {
            XCTAssertTrue(writer.enqueue(InputRecord(kind: "diagnostic", timestampNS: UInt64(index), sessionID: "first")))
        }
        XCTAssertTrue(writer.enqueue(InputRecord(kind: "boundary", timestampNS: 5000, sessionID: "first", details: "recording_stopped")))
        stop(writer)
        let oldFile = try XCTUnwrap(writer.snapshot().currentFile)
        let saved = try Data(contentsOf: oldFile)
        XCTAssertEqual(try records().count, 5001)
        XCTAssertEqual(writer.snapshot().writtenRecords, writer.snapshot().acceptedRecords)
        XCTAssertEqual(writer.snapshot().pendingRecords, 0)
        XCTAssertFalse(writer.enqueue(InputRecord(kind: "key_down", sessionID: "after-OFF")))
        let reopened = try JSONLWriter(configuration: .init(directory: directory))
        reopened.enqueue(InputRecord(kind: "boundary", sessionID: "second", details: "recording_started"))
        stop(reopened)
        XCTAssertNotEqual(oldFile, reopened.snapshot().currentFile)
        XCTAssertEqual(try Data(contentsOf: oldFile), saved)
        XCTAssertEqual(try records().count, 5002)
    }

    func testSleepCheckpointPersistsBufferedBoundaryAndWriterCanResume() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        writer.enqueue(InputRecord(kind: "key_down", timestampNS: 1, sessionID: "sleep", keyCode: 0))
        writer.enqueue(InputRecord(kind: "boundary", timestampNS: 2, sessionID: "sleep", details: "sleep_or_session_inactive"))
        XCTAssertTrue(writer.checkpoint(timeout: 2))
        XCTAssertEqual(try records().map(\.kind), ["key_down", "boundary"])
        XCTAssertEqual(writer.snapshot().state, "running")
        writer.enqueue(InputRecord(kind: "boundary", timestampNS: 3, sessionID: "sleep", details: "recording_started"))
        writer.enqueue(InputRecord(kind: "key_up", timestampNS: 4, sessionID: "sleep", keyCode: 0))
        stop(writer)
        XCTAssertEqual(try records().map(\.timestampNS), [1, 2, 3, 4])
        XCTAssertFalse(writer.checkpoint(timeout: .nan))
    }

    func testEncodingFailureCannotReportACompletedSave() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        writer.enqueue(InputRecord(kind: "mouse_down", sessionID: "invalid", pressure: .nan))
        stop(writer)
        XCTAssertEqual(writer.snapshot().state, "failed")
        XCTAssertNotNil(writer.snapshot().lastError)
        XCTAssertFalse(writer.checkpoint(timeout: 1))
        XCTAssertFalse(writer.enqueue(InputRecord(kind: "late", sessionID: "invalid")))
    }

    func testUTCMidnightRotationPreservesBothDays() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        let midnight = Date(timeIntervalSince1970: 1_700_006_400)
        writer.enqueue(InputRecord(kind: "key_down", timestampNS: 1, wallTime: midnight.addingTimeInterval(-1), sessionID: "midnight", keyCode: 0))
        writer.enqueue(InputRecord(kind: "key_up", timestampNS: 2, wallTime: midnight.addingTimeInterval(1), sessionID: "midnight", keyCode: 0))
        stop(writer)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try records().map(\.timestampNS), [1, 2])
    }

    func testSustainedSyntheticStreamSurvivesRepeatedCheckpointsWithoutLoss() throws {
        let writer = try JSONLWriter(configuration: .init(directory: directory))
        for batch in 0..<40 {
            for index in 0..<500 {
                XCTAssertTrue(writer.enqueue(InputRecord(kind: "diagnostic", timestampNS: UInt64(batch * 500 + index), sessionID: "synthetic-load")))
            }
            XCTAssertTrue(writer.checkpoint(timeout: 5))
        }
        stop(writer)
        XCTAssertEqual(writer.snapshot().writtenRecords, 20_000)
        XCTAssertEqual(writer.snapshot().droppedRecords, 0)
        XCTAssertEqual(try records().map(\.timestampNS), Array(0..<20_000).map(UInt64.init))
    }

    func testUTCFormattingIsStableAcrossConcurrentCalls() {
        let date = Date(timeIntervalSince1970: 0.125)
        DispatchQueue.concurrentPerform(iterations: 1000) { _ in
            XCTAssertEqual(InputRecord.utcString(date), "1970-01-01T00:00:00.125Z")
        }
    }
}
