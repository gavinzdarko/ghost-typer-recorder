import CoreGraphics
import Foundation
import XCTest
@testable import RecorderCore

final class NativeEventDecoderTests: XCTestCase {
    private func key(_ down: Bool = true, text: String = "") throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: down))
        let chars = Array(text.utf16)
        chars.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: $0.baseAddress) }
        event.timestamp = 123_456_789
        return event
    }
    private func decode(_ type: CGEventType, _ event: CGEvent, text: Bool = true) throws -> InputRecord {
        try XCTUnwrap(NativeEventDecoder.decode(type, event: event,
            metadata: InputRecord(kind: "", timestampNS: event.timestamp, sessionID: "synthetic",
                                  appBundleID: "test.app", inputSourceID: "test.layout"), includeText: text))
    }
    func testUnicodeTimingAndPersonalContextSurviveNativeDecoding() throws {
        let event = try key(text: "é👻e\u{301}")
        let record = try decode(.keyDown, event)
        XCTAssertEqual(record.text, "é👻e\u{301}")
        XCTAssertEqual(record.timestampNS, event.timestamp)
        XCTAssertEqual(record.keyCode, 12)
        XCTAssertEqual(record.appBundleID, "test.app")
        XCTAssertEqual(record.inputSourceID, "test.layout")
    }
    func testTextOptOutAndReleaseNeverPersistCharacters() throws {
        let event = try key(text: "synthetic private text")
        XCTAssertNil(try decode(.keyDown, event, text: false).text)
        XCTAssertNil(try decode(.keyUp, event).text)
        XCTAssertNil(try decode(.flagsChanged, event).text)
    }
    func testOptOutRejectsTextEvenIfMetadataContainsAPreviousPayload() throws {
        let event = try key(text: "new text")
        let old = InputRecord(kind: "key_down", timestampNS: 0, sessionID: "synthetic", text: "old private text")
        let decoded = try XCTUnwrap(NativeEventDecoder.decode(.keyDown, event: event, metadata: old, includeText: false))
        XCTAssertNil(decoded.text)
        XCTAssertEqual(decoded.timestampNS, event.timestamp)
        XCTAssertNil(NativeEventDecoder.decode(.keyUp, event: event, metadata: old, includeText: true)?.text)
    }
    func testUnicodePayloadLongerThanTheOldFixedBufferIsPreserved() throws {
        let text = String(repeating: "👻", count: 100)
        let event = try key(text: text)
        XCTAssertEqual(try decode(.keyDown, event).text, text)
    }

    func testRepeatAndModifierTransitionsKeepTheirNativeFields() throws {
        let event = try key()
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        event.setIntegerValueField(.keyboardEventKeyboardType, value: 40)
        XCTAssertEqual(try decode(.keyDown, event).isRepeat, true)
        XCTAssertEqual(try decode(.flagsChanged, event).kind, "flags_changed")
        XCTAssertEqual(try decode(.keyDown, event).keyboardType, 40)
    }
    func testMouseButtonHoldsAndDragKeepSignedGlobalCoordinates() throws {
        let event = try XCTUnwrap(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                         mouseCursorPosition: CGPoint(x: -120, y: 430), mouseButton: .center))
        event.setIntegerValueField(.mouseEventClickState, value: 2)
        event.setIntegerValueField(.mouseEventDeltaX, value: -4)
        let down = try decode(.otherMouseDown, event)
        XCTAssertEqual(down.kind, "mouse_down")
        XCTAssertEqual(down.button, 2)
        XCTAssertEqual(down.x, -120)
        XCTAssertEqual(down.y, 430)
        XCTAssertEqual(down.clickCount, 2)
        XCTAssertEqual(down.deltaX, -4)
        XCTAssertEqual(try decode(.otherMouseUp, event).kind, "mouse_up")
        XCTAssertEqual(try decode(.otherMouseDragged, event).kind, "mouse_drag")
        XCTAssertNil(try decode(.mouseMoved, event).button)
    }
    func testOversizedNativeKeyFieldPreservesOSNormalizedCode() throws {
        let event = try key(text: "synthetic text")
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64.max)
        // Quartz normalizes this setter to a 16-bit native code before delivery.
        let delivered = event.getIntegerValueField(.keyboardEventKeycode)
        XCTAssertTrue((0...Int64(UInt16.max)).contains(delivered))
        let record = try decode(.keyDown, event)
        XCTAssertEqual(record.keyCode, UInt16(delivered))
        XCTAssertEqual(record.text, "synthetic text")
    }
    func testScrollPreservesBothAxes() throws {
        let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                         wheelCount: 2, wheel1: 12, wheel2: -8, wheel3: 0))
        let record = try decode(.scrollWheel, event)
        XCTAssertEqual(record.kind, "scroll")
        XCTAssertEqual(record.scrollY, event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
        XCTAssertEqual(record.scrollX, event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2))
        XCTAssertNil(record.button)
    }
    func testUnsupportedEventsAreNeverSavedAsInput() throws {
        let event = try key()
        XCTAssertNil(NativeEventDecoder.decode(.null, event: event,
            metadata: InputRecord(kind: "", sessionID: "synthetic"), includeText: true))
    }
    func testOFFSleepWakeAndSecureGapsRejectLateInput() {
        var gate = CaptureInputGate()
        XCTAssertFalse(gate.accepts(timestamp: 10, secureInputEnabled: false))
        gate.start(at: 20)
        XCTAssertFalse(gate.accepts(timestamp: 19, secureInputEnabled: false))
        XCTAssertTrue(gate.accepts(timestamp: 20, secureInputEnabled: false))
        XCTAssertFalse(gate.accepts(timestamp: 21, secureInputEnabled: true))
        gate.boundary(at: 30)
        XCTAssertFalse(gate.accepts(timestamp: 29, secureInputEnabled: false))
        gate.stop() // OFF or lid/sleep pause
        XCTAssertFalse(gate.accepts(timestamp: 100, secureInputEnabled: false))
        gate.start(at: 200) // explicit successful listener resume
        XCTAssertFalse(gate.accepts(timestamp: 150, secureInputEnabled: false))
        XCTAssertTrue(gate.accepts(timestamp: 201, secureInputEnabled: false))
        gate.stop()
        XCTAssertFalse(gate.accepts(timestamp: UInt64.max, secureInputEnabled: false))
    }
}
