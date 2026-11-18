import Foundation
import Testing

@testable import PipitLocalAI

/// A sleep the test controls: it returns only when `open()` is called, so the
/// idle delay passes exactly when the test says.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isOpen {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let all = waiting
        waiting = []
        lock.unlock()
        for continuation in all { continuation.resume() }
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

@Suite("Idle model release")
struct ModelIdleReleaseTests {
    private func makeTracker(gate: Gate, counter: ReleaseCounter) -> ModelUseTracker {
        let tracker = ModelUseTracker(delay: .seconds(120), sleep: { try await gate.sleep($0) })
        tracker.setRelease { counter.increment() }
        return tracker
    }

    @Test("releases once the delay passes with no work")
    func releasesWhenIdle() async {
        let gate = Gate()
        let counter = ReleaseCounter()
        let tracker = makeTracker(gate: gate, counter: counter)
        tracker.begin()
        tracker.end()
        #expect(counter.count == 0)
        gate.open()
        await tracker.waitForPendingRelease()
        #expect(counter.count == 1)
    }

    @Test("does not release while a job holds a lease, however long it runs")
    func keepsWhileInFlight() async {
        let gate = Gate()
        let counter = ReleaseCounter()
        let tracker = makeTracker(gate: gate, counter: counter)
        tracker.begin()
        tracker.begin()
        tracker.end()  // one of two jobs finished; its timer must not start
        gate.open()
        await tracker.waitForPendingRelease()
        #expect(tracker.isBusy)
        #expect(counter.count == 0)
        tracker.end()
        await tracker.waitForPendingRelease()
        #expect(counter.count == 1)
    }

    @Test("a job that starts during the delay cancels the pending release")
    func backToBackJobsReuse() async {
        let gate = Gate()
        let counter = ReleaseCounter()
        let tracker = makeTracker(gate: gate, counter: counter)
        tracker.begin()
        tracker.end()
        tracker.begin()  // the next meeting in the queue starts before the delay ends
        gate.open()
        await tracker.waitForPendingRelease()
        #expect(counter.count == 0)
        tracker.end()
        await tracker.waitForPendingRelease()
        #expect(counter.count == 1)
    }

    @Test("a dropped lease releases its claim")
    func droppedLeaseReleases() async {
        let gate = Gate()
        let counter = ReleaseCounter()
        let tracker = makeTracker(gate: gate, counter: counter)
        var lease: ModelLease? = ModelLease(tracker: tracker)
        #expect(tracker.isBusy)
        lease?.release()
        lease?.release()  // idempotent: a second call must not underflow the count
        lease = nil
        #expect(!tracker.isBusy)
        gate.open()
        await tracker.waitForPendingRelease()
        #expect(counter.count == 1)
    }

    @Test("an abandoned lease does not pin the models")
    func abandonedLease() async {
        let tracker = ModelUseTracker()
        do { _ = ModelLease(tracker: tracker) }
        #expect(!tracker.isBusy)
    }

    @Test("the manager refuses to release while one of its leases is held")
    func managerLease() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-idle-\(UUID().uuidString)")
        let tracker = ModelUseTracker()
        let manager = LocalModelManager(applicationSupport: root, useTracker: tracker)
        let lease = manager.lease()
        #expect(tracker.isBusy)
        #expect(await manager.releaseLoadedModels() == false, "a job holds the models")
        lease.release()
        #expect(!tracker.isBusy)
        #expect(await manager.releaseLoadedModels() == true, "nothing holds them now")
        #expect(await manager.loadedUnits.isEmpty)
    }
}
