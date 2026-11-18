import Foundation

/// Counts the work that is using the loaded speech models and calls `release`
/// once none has been for `delay`.
///
/// The manager would otherwise keep every model it ever loaded, and the
/// prepared diarization of the last meeting, for as long as the app runs.
/// Releasing them returns the memory Pipit's own objects hold. It does not
/// return the GPU buffers CoreML allocates for a model loaded with the GPU
/// allowed: measured on macOS 27.2, the diarizer's 620 MB stays with the
/// process after every reference is gone, and the next load reuses it.
/// The delay is 2 minutes by default: queued meetings and a re-analysis
/// started right after processing begin within seconds of the previous job
/// ending and so reuse the loaded models, while an app left idle for a few
/// minutes returns to its small baseline. A job that starts after the delay
/// pays the load again, and a re-analysis after it also pays the full
/// diarization pass, because the prepared segmentation is released with the
/// models.
///
/// The count is synchronous (a lock, not an actor) so a lease can be taken and
/// dropped from a `defer` and from `deinit`, and so a job holding a lease
/// across its own suspension points keeps `isBusy` true the whole time.
final class ModelUseTracker: @unchecked Sendable {
    static let defaultDelay: Duration = .seconds(120)

    private let lock = NSLock()
    private let delay: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private var leases = 0
    /// Bumped by every begin and end, so a timer that woke after the state
    /// changed can tell it is stale.
    private var generation: UInt64 = 0
    private var timer: Task<Void, Never>?
    private var release: (@Sendable () async -> Void)?

    init(
        delay: Duration = ModelUseTracker.defaultDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.delay = delay
        self.sleep = sleep
    }

    /// Set after the owner is built, since the handler refers to the owner.
    func setRelease(_ handler: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        release = handler
    }

    var isBusy: Bool {
        lock.lock()
        defer { lock.unlock() }
        return leases > 0
    }

    func begin() {
        lock.lock()
        defer { lock.unlock() }
        leases += 1
        generation += 1
        timer?.cancel()
        timer = nil
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        leases -= 1
        guard leases == 0 else { return }
        generation += 1
        let expected = generation
        timer?.cancel()
        timer = Task { [self] in
            try? await sleep(delay)
            guard !Task.isCancelled, let handler = releaseIfCurrent(expected) else { return }
            await handler()
        }
    }

    /// The release handler, if nothing has started or ended since `expected`.
    private func releaseIfCurrent(_ expected: UInt64) -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected, leases == 0 else { return nil }
        return release
    }

    /// Waits for the pending release timer, for tests.
    func waitForPendingRelease() async {
        let pending = lock.withLock { timer }
        await pending?.value
    }
}

/// One claim on the loaded models. The models stay loaded until every lease is
/// released; dropping the last reference releases it too, so a live session
/// that is abandoned does not pin them.
public final class ModelLease: Sendable {
    private let state: LeaseState

    init(tracker: ModelUseTracker) {
        tracker.begin()
        state = LeaseState(tracker: tracker)
    }

    public func release() { state.release() }

    deinit { state.release() }
}

private final class LeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var tracker: ModelUseTracker?

    init(tracker: ModelUseTracker) { self.tracker = tracker }

    func release() {
        lock.lock()
        let held = tracker
        tracker = nil
        lock.unlock()
        held?.end()
    }
}
