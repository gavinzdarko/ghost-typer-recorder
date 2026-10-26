import Darwin
import Foundation

/// A bounded producer queue. No encoding or disk I/O takes place inside enqueue.
/// One serial queue owns file handles and preserves accepted event ordering.
public final class JSONLWriter: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var directory: URL
        public var maxPendingRecords: Int
        public var batchSize: Int
        public var flushInterval: TimeInterval
        public var maxFileBytes: UInt64

        public init(directory: URL? = nil, maxPendingRecords: Int = 8192,
                    batchSize: Int = 256, flushInterval: TimeInterval = 0.25,
                    maxFileBytes: UInt64 = 64 * 1024 * 1024) {
            self.directory = directory ?? Self.defaultDirectory
            self.maxPendingRecords = max(2, maxPendingRecords)
            self.batchSize = max(1, batchSize)
            self.flushInterval = max(0.01, flushInterval)
            self.maxFileBytes = max(1, maxFileBytes)
        }

        public static var defaultDirectory: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ghost Recorder/Recordings", isDirectory: true)
        }
    }

    public struct Snapshot: Sendable {
        public let state: String
        public let acceptedRecords: UInt64
        public let writtenRecords: UInt64
        public let droppedRecords: UInt64
        public let pendingRecords: Int
        public let lastError: String?
        public let currentFile: URL?
    }

    private let configuration: Configuration
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "GhostRecorder.JSONLWriter", qos: .utility)
    private var pending: [InputRecord] = []
    private var state = "running"
    private var scheduled = false
    private var accepted: UInt64 = 0
    private var written: UInt64 = 0
    private var dropped: UInt64 = 0
    private var pendingDrops: UInt64 = 0
    private var dropAnchor: InputRecord?
    private var errorMessage: String?
    private var visibleFile: URL?
    // The following are accessed only from queue.
    private var handle: FileHandle?
    private var fileBytes: UInt64 = 0
    private var fileDay: String?
    private var part = 0
    private let writerID = UUID().uuidString
    private let encoder = JSONEncoder()

    public init(configuration: Configuration = Configuration()) throws {
        self.configuration = configuration
        let directory = configuration.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Secure the app-specific parent as well when using the default location.
        if directory.standardizedFileURL == Configuration.defaultDirectory.standardizedFileURL {
            try FileManager.default.setAttributes([.posixPermissions: 0o700],
                ofItemAtPath: directory.deletingLastPathComponent().path)
        }
        pending.reserveCapacity(configuration.maxPendingRecords)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    /// Returns false after stop/failure or if capacity is exhausted. Loss is counted and
    /// a data_loss marker appears at the corresponding stream boundary.
    @discardableResult public func enqueue(_ record: InputRecord) -> Bool {
        lock.lock()
        guard state == "running" else { lock.unlock(); return false }
        materializeGapIfPossible()
        guard pending.count < configuration.maxPendingRecords else {
            dropped += 1
            pendingDrops += 1
            dropAnchor = record
            lock.unlock()
            return false
        }
        pending.append(record)
        accepted += 1
        let shouldSchedule = !scheduled
        scheduled = true
        lock.unlock()
        if shouldSchedule {
            queue.asyncAfter(deadline: .now() + configuration.flushInterval) { [self] in drain() }
        }
        return true
    }

    public func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(state: state, acceptedRecords: accepted, writtenRecords: written,
                        droppedRecords: dropped, pendingRecords: pending.count,
                        lastError: errorMessage, currentFile: visibleFile)
    }

    /// Disallows new events immediately. Completion runs on main after all accepted
    /// events and any loss marker have been flushed, or an error has been recorded.
    public func finish(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        if state == "running" { state = "finishing" }
        lock.unlock()
        queue.async { [self] in
            drain()
            do { try closeFile() } catch { fail(error) }
            lock.lock()
            if state != "failed" { state = "finished" }
            lock.unlock()
            DispatchQueue.main.async(execute: completion)
        }
    }

    // Caller holds lock. A gap follows all accepted records before the loss and
    // precedes any accepted records after the loss.
    private func materializeGapIfPossible() {
        guard pendingDrops > 0, pending.count < configuration.maxPendingRecords,
              var anchor = dropAnchor else { return }
        anchor.kind = "data_loss"
        anchor.keyCode = nil; anchor.text = nil; anchor.isRepeat = nil
        anchor.flags = nil; anchor.x = nil; anchor.y = nil; anchor.button = nil
        anchor.scrollX = nil; anchor.scrollY = nil
        anchor.pressure = nil; anchor.clickCount = nil
        anchor.deltaX = nil; anchor.deltaY = nil
        anchor.sourcePID = nil; anchor.keyboardType = nil
        anchor.details = "Writer queue overflow; treat held keys/buttons and intervals across this boundary as unknown."
        anchor.droppedRecordCount = pendingDrops
        pending.append(anchor)
        pendingDrops = 0
        dropAnchor = nil
    }

    private func drain() {
        while true {
            lock.lock()
            guard state != "failed" else { scheduled = false; lock.unlock(); return }
            materializeGapIfPossible()
            guard !pending.isEmpty else { scheduled = false; lock.unlock(); return }
            let count = min(configuration.batchSize, pending.count)
            let batch = Array(pending.prefix(count))
            pending.removeFirst(count)
            materializeGapIfPossible()
            lock.unlock()
            do {
                for record in batch {
                    var data = try encoder.encode(record)
                    data.append(0x0a)
                    try openFileIfNeeded(day: String(record.wallTime.prefix(10)), nextBytes: UInt64(data.count))
                    try handle!.write(contentsOf: data)
                    fileBytes += UInt64(data.count)
                    lock.lock(); written += 1; lock.unlock()
                }
                try handle?.synchronize()
            } catch { fail(error); return }
        }
    }

    private func openFileIfNeeded(day: String, nextBytes: UInt64) throws {
        if handle != nil && (fileDay != day || fileBytes + nextBytes > configuration.maxFileBytes) {
            try closeFile()
        }
        guard handle == nil else { return }
        part += 1
        let url = configuration.directory.appendingPathComponent("\(day)_\(writerID)_\(String(format: "%04d", part)).jsonl")
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        fileBytes = 0
        fileDay = day
        lock.lock(); visibleFile = url; lock.unlock()
    }

    private func closeFile() throws {
        guard let current = handle else { return }
        handle = nil
        try current.synchronize()
        try current.close()
    }

    private func fail(_ error: Error) {
        lock.lock()
        errorMessage = error.localizedDescription
        state = "failed"
        pending.removeAll(keepingCapacity: false)
        scheduled = false
        lock.unlock()
        try? closeFile()
    }
}
