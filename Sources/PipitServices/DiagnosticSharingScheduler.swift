import Foundation
import PipitCore

/// Automatic sharing, and the retries of every queued report
/// (`docs/DIAGNOSTICS.md`, Automatic sharing).
///
/// While **Share diagnostics automatically** is on, a crash confirmed at
/// launch is sent as a `crash` report a few minutes later, and once a day the
/// events since the last confirmed daily report are sent as an `automatic`
/// one. Nothing automatic goes while Pipit records or processes, offline, in
/// Low Data Mode, or on an expensive network: the look is deferred to the
/// next one. While it is off, nothing automatic is built or sent; only the
/// retries of reports the person sent continue.
///
/// Everything it depends on is injected: whether sharing is on, whether
/// Pipit is busy, the network, the clock, and the report builder. The
/// builder defaults to one that builds nothing, until the bundle builder is
/// connected with `setReportBuilder`.
public actor DiagnosticSharingScheduler {
    /// Builds a report of a kind with the events from `since`, stamped with an
    /// identity from `DiagnosticReportSender.prepareIdentity()`. For `crash`,
    /// `since` is when the crashed launch started, and the report carries the
    /// crash summaries from then on. Nil when there is nothing to build.
    public typealias BuildReport = @Sendable (DiagnosticReport.Kind, Date?) async -> DiagnosticReport?

    public enum TickResult: Sendable, Equatable {
        /// Sharing is off. Only person-sent retries ran.
        case off
        case deferred(DiagnosticSharingBlocker)
        case ran
        /// Another look was under way.
        case alreadyRunning
    }

    private let sender: DiagnosticReportSender
    private let store: DiagnosticSharingStateStore
    private let isEnabled: @Sendable () -> Bool
    private let isBusy: @Sendable () async -> Bool
    private let network: @Sendable () -> DiagnosticNetworkCondition
    private let now: @Sendable () -> Date
    private let random: @Sendable () -> Double
    private var buildReport: BuildReport
    private var isTicking = false
    private var sharingGeneration = 0

    public init(
        sender: DiagnosticReportSender,
        layout: DiagnosticLayout,
        isEnabled: @escaping @Sendable () -> Bool,
        isBusy: @escaping @Sendable () async -> Bool,
        network: @escaping @Sendable () -> DiagnosticNetworkCondition,
        now: @escaping @Sendable () -> Date = { Date() },
        random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) },
        buildReport: @escaping BuildReport = { _, _ in nil }
    ) {
        self.sender = sender
        self.store = DiagnosticSharingStateStore(layout: layout)
        self.isEnabled = isEnabled
        self.isBusy = isBusy
        self.network = network
        self.now = now
        self.random = random
        self.buildReport = buildReport
    }

    /// Connects the report builder.
    public func setReportBuilder(_ build: @escaping BuildReport) {
        buildReport = build
    }

    /// Sharing was turned on: events from now on, the first daily report a
    /// day later.
    public func enable() {
        guard isEnabled(), store.load() == nil else { return }
        save(DiagnosticSharingPolicy.started(now: now(), random: random()))
    }

    /// Sharing was turned off: nothing more is built, and the automatic
    /// reports still queued are removed at once.
    public func disable() async {
        sharingGeneration += 1
        store.remove()
        await sender.discardAutomatic()
    }

    /// A crash of the previous launch, confirmed at this one. Kept in the
    /// state file, so a quit before the next look does not lose it. Ignored
    /// while sharing is off: the crash prompt asks instead.
    public func noteCrash(incident: String, since: Date) {
        guard isEnabled() else { return }
        let state = currentState()
        save(DiagnosticSharingPolicy.noting(crash: incident, since: since, now: now(), in: state))
    }

    /// One look: retries what is due, then sends what automatic sharing owes.
    @discardableResult
    public func tick() async -> TickResult {
        guard !isTicking else { return .alreadyRunning }
        isTicking = true
        defer { isTicking = false }

        guard isEnabled() else {
            _ = await sender.retryDue(includeAutomatic: false)
            return .off
        }
        let generation = sharingGeneration
        var state = currentState()
        let blocker = DiagnosticSharingPolicy.blocker(isBusy: await isBusy(), network: network())
        guard isCurrent(generation) else { return .off }
        let confirmed = await sender.retryDue(includeAutomatic: blocker == nil)
        guard isCurrent(generation) else { return .off }
        for entry in confirmed where entry.automatic && entry.kind == .automatic {
            state = DiagnosticSharingPolicy.confirmedDaily(createdAt: entry.createdAt, in: state)
        }
        save(state)
        if let blocker { return .deferred(blocker) }

        for crash in state.pendingCrashes {
            switch await sendAutomaticReport(.crash, since: crash.since, generation: generation) {
            case .cancelled: return .off
            case .deferred(let blocker): return .deferred(blocker)
            case .sent, .notSent: break
            }
            state = DiagnosticSharingPolicy.handled(crash: crash.incident, in: state)
            save(state)
        }

        let dailyQueued = await sender.pending().contains { $0.automatic && $0.kind == .automatic }
        guard isCurrent(generation) else { return .off }
        if now() >= state.nextDailyAt, !dailyQueued {
            switch await sendAutomaticReport(.automatic, since: state.eventsSince, generation: generation) {
            case .sent(let createdAt):
                state = DiagnosticSharingPolicy.confirmedDaily(createdAt: createdAt, in: state)
            case .cancelled: return .off
            case .deferred(let blocker): return .deferred(blocker)
            case .notSent: break
            }
            state.nextDailyAt = DiagnosticSharingPolicy.nextDaily(after: now(), random: random())
            save(state)
        }
        return .ran
    }

    private enum AutomaticSendResult {
        case sent(createdAt: Date)
        case notSent
        case cancelled
        case deferred(DiagnosticSharingBlocker)
    }

    /// Building can outlast a setting or network change. Recheck immediately
    /// before handing the report to the sender and discard unused identities.
    private func sendAutomaticReport(
        _ kind: DiagnosticReport.Kind, since: Date, generation: Int
    ) async -> AutomaticSendResult {
        guard isCurrent(generation) else { return .cancelled }
        guard let report = await buildReport(kind, since) else {
            return isCurrent(generation) ? .notSent : .cancelled
        }
        let blocker = DiagnosticSharingPolicy.blocker(isBusy: await isBusy(), network: network())
        guard isCurrent(generation) else {
            discard(report)
            return .cancelled
        }
        if let blocker {
            discard(report)
            return .deferred(blocker)
        }
        let outcome = await sender.send(report, automatic: true)
        guard isCurrent(generation) else { return .cancelled }
        if case .sent = outcome { return .sent(createdAt: report.createdAt) }
        return .notSent
    }

    /// Looks after a jittered delay from launch, then every
    /// `DiagnosticSharingPolicy.checkInterval`, until cancelled.
    public nonisolated func run(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) -> Task<Void, Never> {
        let range = DiagnosticSharingPolicy.launchDelay
        let first = range.lowerBound + (range.upperBound - range.lowerBound) * random()
        return Task.detached(priority: .utility) { [self] in
            await sleep(first)
            while !Task.isCancelled {
                await tick()
                await sleep(DiagnosticSharingPolicy.checkInterval)
            }
        }
    }

    /// Looks once after the crash delay, so a crash noted at launch goes in
    /// minutes rather than at the next regular look.
    public nonisolated func tickSoon(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        let delay = DiagnosticSharingPolicy.crashDelay(random: random())
        Task.detached(priority: .utility) { [self] in
            await sleep(delay)
            await tick()
        }
    }

    /// A build started before an opt-out stays cancelled if sharing is
    /// enabled again while the builder is still reading the disk.
    private func isCurrent(_ generation: Int) -> Bool {
        isEnabled() && sharingGeneration == generation
    }

    private func discard(_ report: DiagnosticReport) {
        sender.discardReportIdentity(
            DiagnosticReportIdentity(reportID: report.reportID, deletionSecretHash: report.deletionSecretHash)
        )
    }

    // MARK: - state

    /// The state on disk, or a fresh one when sharing is on and none was
    /// written: the first look after turning it on, or after Clear
    /// Diagnostics deleted `state/`.
    private func currentState() -> DiagnosticSharingState {
        if let stored = store.load() { return stored }
        let started = DiagnosticSharingPolicy.started(now: now(), random: random())
        save(started)
        return started
    }

    /// Written only while sharing is on, so a look that was under way when it
    /// was turned off does not bring the file back.
    private func save(_ state: DiagnosticSharingState) {
        guard isEnabled() else { return }
        do {
            try store.save(state)
        } catch {
            Log.app.error("automatic sharing state not saved: \(logSafeDescription(error), privacy: .public)")
        }
    }
}
