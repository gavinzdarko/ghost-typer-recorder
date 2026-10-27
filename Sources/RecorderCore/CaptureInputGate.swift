/// Explicitly rejects queued callbacks after OFF and across sleep/privacy gaps.
public struct CaptureInputGate {
    private var active = false
    private var epoch: UInt64 = 0
    public init() {}
    public mutating func start(at timestamp: UInt64) { active = true; epoch = timestamp }
    public mutating func boundary(at timestamp: UInt64) { epoch = timestamp }
    public mutating func stop() { active = false }
    public func accepts(timestamp: UInt64, secureInputEnabled: Bool) -> Bool {
        active && !secureInputEnabled && timestamp >= epoch
    }
}
