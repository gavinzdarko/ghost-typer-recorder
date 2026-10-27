import Foundation

/// ISO8601DateFormatter is expensive to create and is not safe to share without
/// synchronization. Keep one formatter for the high-frequency capture path.
private final class UTCFormatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }
}

/// Monotonic time is used for intervals; UTC wall time is for human-readable correlation.
/// Optional fields are omitted rather than suggesting unavailable measurements are zero.
public struct InputRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var kind: String
    public var timestampNS: UInt64
    public var wallTime: String
    public var sessionID: String
    public var keyCode: UInt16?
    public var text: String?
    public var isRepeat: Bool?
    public var flags: UInt64?
    public var x: Double?
    public var y: Double?
    public var button: Int?
    public var scrollX: Double?
    public var scrollY: Double?
    public var pressure: Double?
    public var clickCount: Int?
    public var deltaX: Double?
    public var deltaY: Double?
    public var sourcePID: Int?
    public var keyboardType: Int?
    public var inputSourceID: String?
    public var inputSourceName: String?
    public var appBundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var details: String?
    public var coordinateSystem: String?
    public var droppedRecordCount: UInt64?
    private static let utcFormatter = UTCFormatter()

    public init(
        kind: String, timestampNS: UInt64 = DispatchTime.now().uptimeNanoseconds,
        wallTime: Date = Date(), sessionID: String,
        keyCode: UInt16? = nil, text: String? = nil, isRepeat: Bool? = nil,
        flags: UInt64? = nil, x: Double? = nil, y: Double? = nil,
        button: Int? = nil, scrollX: Double? = nil, scrollY: Double? = nil,
        pressure: Double? = nil, clickCount: Int? = nil,
        deltaX: Double? = nil, deltaY: Double? = nil,
        sourcePID: Int? = nil, keyboardType: Int? = nil,
        appBundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        details: String? = nil, coordinateSystem: String? = nil,
        droppedRecordCount: UInt64? = nil, inputSourceID: String? = nil,
        inputSourceName: String? = nil
    ) {
        self.kind = kind
        self.timestampNS = timestampNS
        self.wallTime = Self.utcString(wallTime)
        self.sessionID = sessionID
        self.keyCode = keyCode
        self.text = text
        self.isRepeat = isRepeat
        self.flags = flags
        self.x = x
        self.y = y
        self.button = button
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.pressure = pressure
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.sourcePID = sourcePID
        self.keyboardType = keyboardType
        self.inputSourceID = inputSourceID
        self.inputSourceName = inputSourceName
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.details = details
        self.coordinateSystem = coordinateSystem
        self.droppedRecordCount = droppedRecordCount
    }

    public static func utcString(_ date: Date) -> String {
        utcFormatter.string(from: date)
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", kind, timestampNS = "timestamp_ns"
        case wallTime = "wall_time", sessionID = "session_id", keyCode = "key_code"
        case text, isRepeat = "is_repeat", flags, x, y, button
        case scrollX = "scroll_x", scrollY = "scroll_y"
        case pressure, clickCount = "click_count", deltaX = "delta_x", deltaY = "delta_y"
        case sourcePID = "source_pid", keyboardType = "keyboard_type"
        case inputSourceID = "input_source_id", inputSourceName = "input_source_name"
        case appBundleID = "app_bundle_id", appName = "app_name", windowTitle = "window_title"
        case details, coordinateSystem = "coordinate_system", droppedRecordCount = "dropped_record_count"
    }
}
