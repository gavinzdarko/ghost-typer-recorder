import AppKit
import ApplicationServices
import Carbon
import RecorderCore

/// Passive event tap: never modifies or synthesizes input. All methods run on main.
final class Capture {
    var record: ((InputRecord) -> Void)?
    var statusChanged: ((String?) -> Void)?
    var includeText = true
    var includeTitles = true
    var sessionID = UUID().uuidString
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var contextTimer: Timer?
    private var appObserver: NSObjectProtocol?
    private var inputSourceObserver: NSObjectProtocol?
    private var inputSource = KeyboardInputSource(id: nil, name: nil)
    private var appID: String?
    private var appName: String?
    private var title: String?
    private var secure = false
    private var epoch: UInt64 = 0

    func start() throws {
        epoch = DispatchTime.now().uptimeNanoseconds
        guard CGPreflightListenEventAccess() else {
            CGRequestListenEventAccess()
            throw NSError(domain: "GhostRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Enable Ghost Recorder in System Settings → Privacy & Security → Input Monitoring, then quit and reopen it."])
        }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                Unmanaged<Capture>.fromOpaque(info).takeUnretainedValue().receive(type, event)
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw NSError(domain: "GhostRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "macOS refused the input listener. Check Input Monitoring and reopen the app."])
        }
        tap = port
        guard let runSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port); tap = nil
            throw NSError(domain: "GhostRecorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create the input run loop source."])
        }
        source = runSource
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        secure = IsSecureEventInputEnabled()
        refreshInputSource(markChange: false)
        sampleContext()
        boundary("recording_started; secure_input=\(secure); text=\(includeText); titles=\(includeTitles)")
        recordDisplays()
        contextTimer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.sampleContext()
        }
        if let contextTimer { RunLoop.main.add(contextTimer, forMode: .common) }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] _ in self?.sampleContext() }
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in self?.refreshInputSource(markChange: true) }
    }

    private func refreshInputSource(markChange: Bool) {
        let next = KeyboardInputSource.current()
        guard !markChange || next != inputSource else { return }
        if markChange { boundary("keyboard_input_source_changed") }
        inputSource = next
        record?(InputRecord(kind: "keyboard_layout", sessionID: sessionID,
            details: "Selected input source; event text remains distinct from committed IME text.",
            inputSourceID: next.id, inputSourceName: next.name))
    }

    func stop(_ reason: String) {
        guard tap != nil else { return }
        boundary(reason)
        contextTimer?.invalidate(); contextTimer = nil
        if let appObserver { NSWorkspace.shared.notificationCenter.removeObserver(appObserver) }
        appObserver = nil
        if let inputSourceObserver { DistributedNotificationCenter.default().removeObserver(inputSourceObserver) }
        inputSourceObserver = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
    }

    func boundary(_ reason: String) {
        epoch = DispatchTime.now().uptimeNanoseconds
        record?(InputRecord(kind: "boundary", sessionID: sessionID, details: reason))
    }

    func checkHealth() -> Bool {
        guard let tap else { return false }
        if !CGEvent.tapIsEnabled(tap: tap) {
            boundary("tap_disabled_detected; timing continuity lost")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    func recordDisplays() {
        // CGEvent coordinates are global display points, origin at primary display's upper left.
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids.prefix(Int(count)) {
            let b = CGDisplayBounds(id)
            record?(InputRecord(kind: "display", sessionID: sessionID,
                x: b.origin.x, y: b.origin.y,
                details: "display_id=\(id);width=\(b.width);height=\(b.height);pixels_w=\(CGDisplayPixelsWide(id));pixels_h=\(CGDisplayPixelsHigh(id))",
                coordinateSystem: "quartz_global_points_top_left"))
        }
    }

    private func sampleContext() {
        checkSecureInput()
        let app = NSWorkspace.shared.frontmostApplication
        let newID = app?.bundleIdentifier
        let newName = app?.localizedName
        var newTitle: String?
        if includeTitles && !secure, let pid = app?.processIdentifier, AXIsProcessTrusted() {
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.02)
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &value) == .success {
                    newTitle = value as? String
                }
            }
        }
        if appID != newID || appName != newName || title != newTitle {
            appID = newID; appName = newName; title = newTitle
            record?(InputRecord(kind: "context", sessionID: sessionID,
                appBundleID: appID, appName: appName, windowTitle: title,
                details: "sampled_500ms; window title may be unavailable; not document contents"))
        }
    }

    private func checkSecureInput() {
        let now = IsSecureEventInputEnabled()
        if secure != now {
            secure = now
            title = nil
            boundary(now ? "secure_input_started" : "secure_input_ended")
            statusChanged?(now ? "Protected input — paused" : nil)
        }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            boundary("tap_disabled_\(type.rawValue); timing continuity lost")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        checkSecureInput()
        guard !secure else { return }
        guard event.timestamp >= epoch else { return } // queued input from before a gap
        // App metadata is sampled and refreshed on activation; never query AX here.
        var item = InputRecord(kind: "", timestampNS: event.timestamp, sessionID: sessionID,
            flags: event.flags.rawValue, sourcePID: Int(event.getIntegerValueField(.eventSourceUnixProcessID)),
            appBundleID: appID, appName: appName, windowTitle: title)
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            item.kind = type == .keyDown ? "key_down" : (type == .keyUp ? "key_up" : "flags_changed")
            item.keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            item.isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            item.inputSourceID = inputSource.id; item.inputSourceName = inputSource.name
            item.keyboardType = Int(event.getIntegerValueField(.keyboardEventKeyboardType))
            if type == .keyDown && includeText {
                var chars = [UniChar](repeating: 0, count: 64)
                var length = 0
                event.keyboardGetUnicodeString(maxStringLength: chars.count, actualStringLength: &length, unicodeString: &chars)
                if length > 0 { item.text = String(utf16CodeUnits: chars, count: min(length, chars.count)) }
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: item.kind = "mouse_down"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: item.kind = "mouse_up"
        case .mouseMoved: item.kind = "mouse_move"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: item.kind = "mouse_drag"
        case .scrollWheel:
            item.kind = "scroll"
            item.scrollX = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            item.scrollY = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        default: return
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
        record?(item)
    }
}
