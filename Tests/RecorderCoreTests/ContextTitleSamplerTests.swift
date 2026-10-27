import Foundation
import XCTest
@testable import RecorderCore

private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32] = []
    func append(_ value: Int32) { lock.lock(); values.append(value); lock.unlock() }
    func snapshot() -> [Int32] { lock.lock(); defer { lock.unlock() }; return values }
}

final class ContextTitleSamplerTests: XCTestCase {
    func testSlowLookupDoesNotBlockCallerAndPendingRequestsStayBounded() {
        let gate = DispatchSemaphore(value: 0)
        let reads = Reads()
        let done = expectation(description: "latest result")
        let sampler = ContextTitleSampler { pid in
            reads.append(pid)
            if pid == 1 { _ = gate.wait(timeout: .now() + 3) }
            return "title-\(pid)"
        }
        sampler.sample(pid: 1) { _ in XCTFail("Old lookup must not overwrite newer context") }
        for pid in 2...200 {
            sampler.sample(pid: Int32(pid)) { value in
                XCTAssertTrue(Thread.isMainThread)
                XCTAssertEqual(pid, 200)
                XCTAssertEqual(value, "title-200")
                done.fulfill()
            }
        }
        // Reaching this point before releasing the worker proves sample() did not block.
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reads.snapshot(), [1, 200])
    }

    func testInvalidationRejectsAReplyEvenWhenTheSameAppPIDIsReused() {
        let gate = DispatchSemaphore(value: 0)
        let reads = Reads()
        let done = expectation(description: "new session result")
        let sampler = ContextTitleSampler { pid in
            reads.append(pid)
            if reads.snapshot().count == 1 { _ = gate.wait(timeout: .now() + 3) }
            return reads.snapshot().count == 1 ? "old private title" : "new title"
        }
        sampler.sample(pid: 1) { _ in XCTFail("Stop/privacy boundary must reject old result") }
        sampler.invalidate()
        sampler.sample(pid: 1) { value in
            XCTAssertEqual(value, "new title")
            done.fulfill()
        }
        gate.signal()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(reads.snapshot(), [1, 1])
    }

    func testInvalidationDropsPendingQueriesAndSuppressesLateResult() {
        let gate = DispatchSemaphore(value: 0)
        let reads = Reads()
        let readFinished = expectation(description: "worker returns")
        let unexpected = expectation(description: "no invalidated completion")
        unexpected.isInverted = true
        let sampler = ContextTitleSampler { pid in
            reads.append(pid)
            _ = gate.wait(timeout: .now() + 3)
            readFinished.fulfill()
            return "private title"
        }
        sampler.sample(pid: 1) { _ in unexpected.fulfill() }
        sampler.sample(pid: 2) { _ in unexpected.fulfill() }
        sampler.invalidate()
        gate.signal()
        wait(for: [readFinished], timeout: 5)
        wait(for: [unexpected], timeout: 0.1)
        XCTAssertEqual(reads.snapshot(), [1])
    }
}
