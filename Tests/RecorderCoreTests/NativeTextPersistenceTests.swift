import CoreGraphics
import Foundation
import XCTest
@testable import RecorderCore

final class NativeTextPersistenceTests: XCTestCase {
    private func decoded(_ type: CGEventType, text: String, timestamp: UInt64,
                         includeText: Bool, repeatKey: Bool = false) throws -> InputRecord {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0,
                                        keyDown: type == .keyDown))
        let chars = Array(text.utf16)
        chars.withUnsafeBufferPointer {
            event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress)
        }
        event.timestamp = timestamp
        event.flags = [.maskShift]
        event.setIntegerValueField(.keyboardEventAutorepeat, value: repeatKey ? 1 : 0)
        return try XCTUnwrap(NativeEventDecoder.decode(type, event: event,
            metadata: InputRecord(kind: "", sessionID: "synthetic-text-persistence",
                flags: event.flags.rawValue, appBundleID: "synthetic.editor",
                inputSourceID: "synthetic.layout"), includeText: includeText))
    }

    private func finish(_ writer: JSONLWriter) {
        let done = expectation(description: "finished saving")
        writer.finish { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    func testNativeTextAndExactTimingSurviveOFFAndReopening() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        // These events are constructed only; never posted or captured globally.
        let payloads = ["A", "z", " ", "!?\"\\", "\t", "\r", "\u{8}", "é👻e\u{301}",
                        String(repeating: "👻", count: 100)]
        var expected: [InputRecord] = []
        for (index, payload) in payloads.enumerated() {
            let down = UInt64(index + 1) * 200_000_000
            expected.append(try decoded(.keyDown, text: payload, timestamp: down, includeText: true))
            expected.append(try decoded(.keyUp, text: payload, timestamp: down + 60_000_000, includeText: true))
        }
        expected.append(try decoded(.keyDown, text: "z", timestamp: 2_100_000_000,
                                    includeText: true, repeatKey: true))
        for record in expected { XCTAssertTrue(writer.enqueue(record)) }
        finish(writer)
        let snapshot = writer.snapshot()
        XCTAssertEqual(snapshot.state, "finished")
        XCTAssertNil(snapshot.lastError)
        XCTAssertEqual(snapshot.droppedRecords, 0)
        XCTAssertEqual(snapshot.pendingRecords, 0)
        let file = try XCTUnwrap(snapshot.currentFile)
        let bytes = try Data(contentsOf: file)
        XCTAssertEqual(bytes.last, 10)
        let saved = try bytes.split(separator: 10).map {
            try JSONDecoder().decode(InputRecord.self, from: Data($0))
        }
        XCTAssertEqual(saved, expected)
        XCTAssertEqual(saved.filter { $0.kind == "key_down" }.compactMap(\.text), payloads + ["z"])
        XCTAssertTrue(saved.filter { $0.kind == "key_up" }.allSatisfy { $0.text == nil })
        for index in payloads.indices {
            XCTAssertEqual(saved[2 * index + 1].timestampNS - saved[2 * index].timestampNS, 60_000_000)
        }
        XCTAssertEqual(saved.last?.isRepeat, true)
        XCTAssertFalse(writer.enqueue(try decoded(.keyDown, text: "after OFF",
                                                  timestamp: 3_000_000_000, includeText: true)))
        let reopened = try JSONLWriter(configuration: .init(directory: directory))
        XCTAssertTrue(reopened.enqueue(InputRecord(kind: "boundary", sessionID: "new-session")))
        finish(reopened)
        XCTAssertNotEqual(reopened.snapshot().currentFile, file)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testTextOptOutStillSavesTimingWithoutCharactersOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try JSONLWriter(configuration: .init(directory: directory, flushInterval: 30))
        for (type, timestamp): (CGEventType, UInt64) in [(.keyDown, 100), (.keyUp, 160)] {
            XCTAssertTrue(writer.enqueue(try decoded(type, text: "synthetic omitted payload",
                                                     timestamp: timestamp, includeText: false)))
        }
        finish(writer)
        let bytes = try Data(contentsOf: XCTUnwrap(writer.snapshot().currentFile))
        let saved = try bytes.split(separator: 10).map {
            try JSONDecoder().decode(InputRecord.self, from: Data($0))
        }
        XCTAssertEqual(saved.map(\.timestampNS), [100, 160])
        XCTAssertTrue(saved.allSatisfy { $0.text == nil })
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic omitted payload"))
    }
}
