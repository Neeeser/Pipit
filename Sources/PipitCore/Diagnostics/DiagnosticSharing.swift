import Foundation

/// What automatic sharing remembers between launches, in
/// `state/automatic-sharing.json` (`docs/DIAGNOSTICS.md`, Automatic sharing).
///
/// Written when sharing is first seen on, and deleted when it is turned off,
/// so turning it on again starts from that moment rather than from whatever
/// was collected while it was off.
public struct DiagnosticSharingState: Codable, Sendable, Equatable {
    /// A crash of the previous launch, confirmed at this one, not yet built
    /// into a report.
    public struct PendingCrash: Codable, Sendable, Equatable {
        public var incident: String
        /// When the crashed launch started: the report carries its events
        /// from here on.
        public var since: Date
        public var notedAt: Date

        public init(incident: String, since: Date, notedAt: Date) {
            self.incident = incident.lowercased()
            self.since = since
            self.notedAt = notedAt
        }
    }

    /// The next daily report carries the events from here on: the later of
    /// when sharing was turned on and the creation of the last daily report
    /// the service confirmed.
    public var eventsSince: Date
    public var nextDailyAt: Date
    public var pendingCrashes: [PendingCrash]
    /// Incidents already built into a crash report, newest last, so one crash
    /// is sent once.
    public var sentCrashes: [String]

    public init(
        eventsSince: Date, nextDailyAt: Date, pendingCrashes: [PendingCrash] = [], sentCrashes: [String] = []
    ) {
        self.eventsSince = eventsSince
        self.nextDailyAt = nextDailyAt
        self.pendingCrashes = pendingCrashes
        self.sentCrashes = sentCrashes
    }
}

/// Reads and writes `state/automatic-sharing.json`.
public struct DiagnosticSharingStateStore: Sendable {
    public static let fileName = "automatic-sharing.json"

    public let file: URL

    public init(file: URL) { self.file = file }

    public init(layout: DiagnosticLayout) {
        self.init(file: layout.state.appendingPathComponent(Self.fileName))
    }

    public func load() -> DiagnosticSharingState? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? DiagnosticCoding.makeDecoder().decode(DiagnosticSharingState.self, from: data)
    }

    public func save(_ state: DiagnosticSharingState) throws {
        try AtomicFile.write(try DiagnosticCoding.makeFileEncoder().encode(state), to: file)
    }

    public func remove() {
        try? FileManager.default.removeItem(at: file)
    }
}

/// What the network is like, as `NWPathMonitor` reports it.
public struct DiagnosticNetworkCondition: Sendable, Equatable {
    public var isSatisfied: Bool
    /// Low Data Mode.
    public var isConstrained: Bool
    /// Cellular, or a personal hotspot.
    public var isExpensive: Bool

    public init(isSatisfied: Bool, isConstrained: Bool = false, isExpensive: Bool = false) {
        self.isSatisfied = isSatisfied
        self.isConstrained = isConstrained
        self.isExpensive = isExpensive
    }

    /// Before the first path update.
    public static let unknown = DiagnosticNetworkCondition(isSatisfied: false)
    public static let unmetered = DiagnosticNetworkCondition(isSatisfied: true)
}

/// Why automatic sharing waits.
public enum DiagnosticSharingBlocker: String, Sendable, Equatable {
    /// Recording or processing.
    case busy
    case offline
    /// Low Data Mode.
    case constrained
    case expensive
}

/// The rules of automatic sharing, apart from the clock and the disk.
public enum DiagnosticSharingPolicy {
    public static let dailyInterval: TimeInterval = 24 * 60 * 60
    /// Up to this much is added to each daily wait.
    public static let dailyJitter: TimeInterval = 60 * 60
    /// A crash report goes this long after the crash is confirmed, jittered
    /// within the range, so it does not compete with launching.
    public static let crashDelay: ClosedRange<TimeInterval> = 60...300
    /// How often the scheduler looks, once launched.
    public static let checkInterval: TimeInterval = 15 * 60
    /// The first look after launch waits this long, jittered.
    public static let launchDelay: ClosedRange<TimeInterval> = 120...600
    /// Incidents remembered as sent.
    public static let rememberedCrashes = 50

    /// The state of sharing first seen on at `now`: no events from before,
    /// and the first daily report a day later.
    public static func started(now: Date, random: Double) -> DiagnosticSharingState {
        DiagnosticSharingState(eventsSince: now, nextDailyAt: nextDaily(after: now, random: random))
    }

    public static func nextDaily(after now: Date, random: Double) -> Date {
        now.addingTimeInterval(dailyInterval + dailyJitter * min(max(random, 0), 1))
    }

    public static func crashDelay(random: Double) -> TimeInterval {
        crashDelay.lowerBound + (crashDelay.upperBound - crashDelay.lowerBound) * min(max(random, 0), 1)
    }

    /// Why nothing automatic may go now, or nil when it may. Busy first: it
    /// is the one that clears on its own soonest.
    public static func blocker(isBusy: Bool, network: DiagnosticNetworkCondition) -> DiagnosticSharingBlocker? {
        if isBusy { return .busy }
        if !network.isSatisfied { return .offline }
        if network.isConstrained { return .constrained }
        if network.isExpensive { return .expensive }
        return nil
    }

    /// The state with a crash added to send, unless it was sent or is
    /// already waiting.
    public static func noting(
        crash incident: String, since: Date, now: Date, in state: DiagnosticSharingState
    ) -> DiagnosticSharingState {
        let incident = incident.lowercased()
        guard !state.sentCrashes.contains(incident), !state.pendingCrashes.contains(where: { $0.incident == incident })
        else { return state }
        var updated = state
        updated.pendingCrashes.append(.init(incident: incident, since: since, notedAt: now))
        return updated
    }

    /// The state once a crash has been built into a report, or found to have
    /// nothing to build.
    public static func handled(crash incident: String, in state: DiagnosticSharingState) -> DiagnosticSharingState {
        var updated = state
        updated.pendingCrashes.removeAll { $0.incident == incident }
        updated.sentCrashes.removeAll { $0 == incident }
        updated.sentCrashes.append(incident)
        if updated.sentCrashes.count > rememberedCrashes {
            updated.sentCrashes.removeFirst(updated.sentCrashes.count - rememberedCrashes)
        }
        return updated
    }

    /// The state once the service confirmed a daily report created at
    /// `createdAt`. The cut-off only moves forward.
    public static func confirmedDaily(createdAt: Date, in state: DiagnosticSharingState) -> DiagnosticSharingState {
        var updated = state
        updated.eventsSince = max(state.eventsSince, createdAt)
        return updated
    }
}

/// What happens about a crash found at launch.
public enum DiagnosticCrashRoute: Sendable, Equatable {
    case none
    /// Ask the person: one notification and the highlighted menu item.
    case offer(incident: String)
    /// Automatic sharing is on: send it without asking.
    case share(incident: String)

    /// Only a confirmed `crash` with its incident. `unclean_unknown`,
    /// `system_restart`, `hang`, and a clean exit are never offered or sent.
    public static func route(_ classification: ExitClassification, sharesAutomatically: Bool) -> DiagnosticCrashRoute {
        guard classification.exitClass == .crash, let incident = classification.incident?.lowercased(),
            !incident.isEmpty
        else { return .none }
        return sharesAutomatically ? .share(incident: incident) : .offer(incident: incident)
    }
}

/// The crash incidents already offered to the person, in
/// `state/crash-offers.json`, so each is offered once.
public struct DiagnosticCrashOffers: Sendable {
    public static let fileName = "crash-offers.json"
    public static let remembered = 50

    public struct Offer: Codable, Sendable, Equatable {
        public var incident: String
        public var offeredAt: Date
    }

    private struct Document: Codable {
        var offers: [Offer]
    }

    public let file: URL

    public init(file: URL) { self.file = file }

    public init(layout: DiagnosticLayout) {
        self.init(file: layout.state.appendingPathComponent(Self.fileName))
    }

    public func offers() -> [Offer] {
        guard let data = try? Data(contentsOf: file),
            let document = try? DiagnosticCoding.makeDecoder().decode(Document.self, from: data)
        else { return [] }
        return document.offers
    }

    public func hasOffered(_ incident: String) -> Bool {
        offers().contains { $0.incident == incident.lowercased() }
    }

    /// Records the incident as offered. True when it had not been offered
    /// before, which is when the caller offers it. A write that fails still
    /// answers true: the incident is only ever classified at the launch after
    /// the crash, so the worst case is the one offer this exists to allow.
    public func claim(_ incident: String, now: Date) -> Bool {
        let incident = incident.lowercased()
        var offers = offers()
        guard !offers.contains(where: { $0.incident == incident }) else { return false }
        offers.append(Offer(incident: incident, offeredAt: now))
        if offers.count > Self.remembered { offers.removeFirst(offers.count - Self.remembered) }
        if let data = try? DiagnosticCoding.makeFileEncoder().encode(Document(offers: offers)) {
            try? AtomicFile.write(data, to: file)
        }
        return true
    }
}
