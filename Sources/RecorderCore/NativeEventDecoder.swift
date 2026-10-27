import CoreGraphics
import Foundation

/// Pure decoding of supplied events: never installs a listener or posts input.
public enum NativeEventDecoder {
    public static func decode(_ type: CGEventType, event: CGEvent,
                              metadata: InputRecord, includeText: Bool) -> InputRecord? {
        var item = metadata
        item.text = nil // Never let reused metadata bypass text opt-out or release privacy.
        item.timestampNS = event.timestamp
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            item.kind = type == .keyDown ? "key_down" : (type == .keyUp ? "key_up" : "flags_changed")
            guard let code = UInt16(exactly: event.getIntegerValueField(.keyboardEventKeycode)) else {
                item.kind = "boundary"; item.keyCode = nil
                item.details = "invalid_native_key_code; timing continuity lost"
                return item
            }
            item.keyCode = code
            item.isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            item.keyboardType = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
            if type == .keyDown && includeText {
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: 0, actualStringLength: &length, unicodeString: nil)
                if length > 0 {
                    let capacity = min(length, 4096)
                    var chars = [UniChar](repeating: 0, count: capacity)
                    var copied = 0
                    event.keyboardGetUnicodeString(maxStringLength: capacity, actualStringLength: &copied, unicodeString: &chars)
                    item.text = String(utf16CodeUnits: chars, count: min(copied, capacity))
                    if length > capacity { item.details = "event_text_truncated;utf16_count=\(length);limit=4096" }
                }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: item.kind = "mouse_down"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: item.kind = "mouse_up"
        case .mouseMoved: item.kind = "mouse_move"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: item.kind = "mouse_drag"
        case .scrollWheel:
            item.kind = "scroll"
            item.scrollX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            item.scrollY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        default: return nil
        }
        if item.kind.hasPrefix("mouse") || item.kind == "scroll" {
            item.x = event.location.x; item.y = event.location.y
            item.coordinateSystem = "quartz_global_points_top_left"
            if item.kind.hasPrefix("mouse") {
                item.deltaX = event.getDoubleValueField(.mouseEventDeltaX)
                item.deltaY = event.getDoubleValueField(.mouseEventDeltaY)
                item.pressure = event.getDoubleValueField(.mouseEventPressure)
                item.clickCount = Int(event.getIntegerValueField(.mouseEventClickState))
            }
            if item.kind != "mouse_move" && item.kind != "scroll" {
                item.button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            }
        }
        return item
    }
}
