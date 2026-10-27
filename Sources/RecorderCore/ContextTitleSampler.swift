import Foundation

/// One background lookup plus one replaceable pending request. Main-thread API;
/// invalidation rejects late replies across app changes, secure input and Stop.
public final class ContextTitleSampler {
    private struct Request {
        let token: UInt64
        let pid: Int32
        let completion: (String?) -> Void
    }
    private let worker = DispatchQueue(label: "GhostRecorder.WindowTitle", qos: .utility)
    private let readTitle: @Sendable (Int32) -> String?
    private var token: UInt64 = 0
    private var pending: Request?
    private var inFlight = false

    public init(readTitle: @escaping @Sendable (Int32) -> String?) { self.readTitle = readTitle }

    public func sample(pid: Int32, completion: @escaping (String?) -> Void) {
        precondition(Thread.isMainThread)
        token &+= 1
        pending = Request(token: token, pid: pid, completion: completion)
        drain()
    }

    public func invalidate() {
        precondition(Thread.isMainThread)
        token &+= 1
        pending = nil
    }

    private func drain() {
        guard !inFlight, let request = pending else { return }
        pending = nil; inFlight = true
        worker.async { [self] in
            let title = readTitle(request.pid)
            DispatchQueue.main.async { [self] in
                inFlight = false
                if request.token == token { request.completion(title) }
                drain()
            }
        }
    }
}
