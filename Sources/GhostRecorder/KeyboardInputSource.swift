import Carbon
import Foundation

/// Metadata only: never changes the user's selected layout or requests input access.
struct KeyboardInputSource: Equatable {
    let id: String?
    let name: String?

    static func current() -> KeyboardInputSource {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return KeyboardInputSource(id: nil, name: nil)
        }
        func property(_ key: CFString) -> String? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            let value = Unmanaged<CFTypeRef>.fromOpaque(pointer).takeUnretainedValue()
            guard CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
            return (value as! CFString) as String
        }
        return KeyboardInputSource(id: property(kTISPropertyInputSourceID),
                                   name: property(kTISPropertyLocalizedName))
    }
}
