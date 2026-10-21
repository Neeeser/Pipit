import AppKit
import Foundation
import PipitAudio
import PipitCore

public struct DetectionSnapshot: Sendable, Equatable {
    public var evidence: [ProviderEvidence]
    public var slackState: SlackHuddleDetector.State
    public var browserSensor: BrowserSensorTracker.Connection
    public var hasAccessibility: Bool
    public var hasWindowTitles: Bool
    /// Who the meeting client says is in the call, and who is holding the floor.
    /// Empty where nothing readable is in a meeting.
    public var roster: SensorReading?
    /// What the Firefox add-on said about itself when it last connected.
    public var sensorHello: SensorMessage.Hello?
    /// Every browser's add-on, as Pipit last heard from it. `browserSensor` is
    /// the Firefox entry, kept on its own for the menu bar and the update flow,
    /// which only know about Firefox.
    public var browserSensors: [BrowserKind: BrowserSensorTracker.Connection]
    /// What each browser's add-on said about itself when it last connected.
    public var sensorHellos: [BrowserKind: SensorMessage.Hello]

    public init(
        evidence: [ProviderEvidence] = [],
        slackState: SlackHuddleDetector.State = .idle,
        browserSensor: BrowserSensorTracker.Connection = .absent,
        hasAccessibility: Bool = false,
        hasWindowTitles: Bool = false,
        roster: SensorReading? = nil,
        sensorHello: SensorMessage.Hello? = nil,
        browserSensors: [BrowserKind: BrowserSensorTracker.Connection] = [:],
        sensorHellos: [BrowserKind: SensorMessage.Hello] = [:]
    ) {
        self.evidence = evidence
        self.slackState = slackState
        self.browserSensor = browserSensor
        self.hasAccessibility = hasAccessibility
        self.hasWindowTitles = hasWindowTitles
        self.roster = roster
        self.sensorHello = sensorHello
        self.browserSensors = browserSensors
        self.sensorHellos = sensorHellos
    }
}

public protocol DetectionEngineDelegate: AnyObject, Sendable {
    func detectionEngineDidUpdate(_ snapshot: DetectionSnapshot)
}

/// Turns OS observations into provider evidence on a fixed poll.
///
/// Every provider adapter here only reports what it sees. Nothing in this file
/// decides whether to record; `SessionController` does, from the evidence.
public final class DetectionEngine: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var pollInterval: Double
        public var slackBundleIdentifier: String
        public var slackAudioPrefixes: [String]
        public var browsers: [BrowserKind]
        public var genericDetection: Bool

        public init(
            pollInterval: Double = 0.5,
            slackBundleIdentifier: String = "com.tinyspeck.slackmacgap",
            slackAudioPrefixes: [String] = ["com.tinyspeck.slackmacgap"],
            browsers: [BrowserKind] = [.firefox, .chrome, .safari],
            genericDetection: Bool = true
        ) {
            self.pollInterval = pollInterval
            self.slackBundleIdentifier = slackBundleIdentifier
            self.slackAudioPrefixes = slackAudioPrefixes
            self.browsers = browsers
            self.genericDetection = genericDetection
        }
    }

    private let configuration: Configuration
    private let clock: any Clock
    private let delegate: any DetectionEngineDelegate
    private let queue = DispatchQueue(label: "com.pipit.detection", qos: .userInitiated)
    private let lock = NSLock()

    private let slackReader: SlackAccessibilityReader
    private let windowReader = WindowTitleReader()
    private let audioObserver = AudioProcessObserver()

    private var slackDetector = SlackHuddleDetector()
    private var browserDetectors: [BrowserKind: BrowserMeetingDetector] = [:]
    private var genericDetector = GenericCallDetector()
    private var timer: DispatchSourceTimer?
    private var sensorServer: BrowserSensorServer?
    /// Safari's own socket, inside the app group. Nil on a build without the
    /// Safari extension.
    private var safariSensorServer: BrowserSensorServer?
    /// The last hello from each browser's add-on.
    private var hellos: [BrowserKind: SensorMessage.Hello] = [:]
    /// When Safari's add-on last said anything. Safari holds no connection, so
    /// silence is the only sign that the add-on was turned off or Safari quit.
    private var lastSafariContact: Double?
    /// The add-on says hello every minute while Safari runs, and a background
    /// page can miss one. Two and a half minutes of silence is it gone.
    static let safariSilenceLimit: Double = 150
    private var lastSnapshot = DetectionSnapshot()
    private var previousEvidence: [String] = []

    public init(
        configuration: Configuration = Configuration(),
        clock: any Clock = SystemClock(),
        delegate: any DetectionEngineDelegate
    ) {
        self.configuration = configuration
        self.clock = clock
        self.delegate = delegate
        self.slackReader = SlackAccessibilityReader(bundleIdentifier: configuration.slackBundleIdentifier)
        for browser in configuration.browsers {
            browserDetectors[browser] = BrowserMeetingDetector(browser: browser)
        }
    }

    /// Who the meeting client says is in the call.
    ///
    /// Slack wins over the browser when both are readable, because the huddle
    /// reader sees other people's tiles directly while the extension reports
    /// whatever the page chose to render. Nothing here decides that a meeting is
    /// happening; that stays with the evidence above.
    private func reading(
        slack: SlackAccessibilityObservation,
        browsers: [BrowserKind: BrowserMeetingDetector],
        at now: Double
    ) -> SensorReading? {
        if !slack.tiles.isEmpty {
            return SensorReading(
                source: "slack-huddle-ax",
                provider: .slack,
                at: now,
                participants: slack.tiles.map {
                    SensorParticipant(id: $0.userID, displayName: $0.displayName, isSelf: $0.isSelf)
                },
                // At most one tile carries the flag, and it moves atomically, so
                // the first one holding it is the floor.
                speakingID: slack.tiles.first(where: \.isSpeaking)?.userID,
                unmutedIDs: Set(slack.tiles.filter { $0.isMuted == false }.map(\.userID)),
                // Slack's tile identifier carries `self_`, which is structural
                // rather than inferred from anything the interface renders.
                selfIsAuthoritative: true
            )
        }
        for kind in [BrowserKind.firefox, .chrome, .safari] {
            // currentEvent, not lastEvent. The latter is whatever arrived most
            // recently from any tab, so a second Meet tab sitting on a landing
            // page reporting `browsing` would hide the roster of the call being
            // recorded, and a dead content script would leave a stale event
            // latched. currentEvent weighs tabs and drops the untrustworthy.
            guard let event = browsers[kind]?.sensor.currentEvent(at: now),
                event.state.isActiveCall,
                let people = event.people, !people.isEmpty
            else { continue }
            return SensorReading(
                source: "\(event.provider.rawValue)-dom",
                provider: event.provider,
                at: now,
                participants: people.map {
                    SensorParticipant(id: $0.id, displayName: $0.displayName, isSelf: $0.isSelf)
                },
                meetingID: event.meetingID,
                speakingID: event.activeSpeaker,
                unmutedIDs: Set(people.filter { $0.isMuted == false }.map(\.id))
            )
        }
        return nil
    }

    public var snapshot: DetectionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return lastSnapshot
    }

    public func updateGenericConfiguration(_ configuration: GenericCallDetector.Configuration) {
        lock.lock()
        genericDetector.configuration = configuration
        lock.unlock()
    }

    /// Idempotent: a second call replaces the timer rather than orphaning it.
    public func start() {
        stop()
        startSensorServer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: configuration.pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    public func stop() {
        lock.lock()
        let timer = self.timer
        self.timer = nil
        let server = sensorServer
        sensorServer = nil
        let safariServer = safariSensorServer
        safariSensorServer = nil
        lock.unlock()
        timer?.cancel()
        server?.stop()
        safariServer?.stop()
    }

    /// Bundle-identifier prefixes whose audio belongs to a Slack huddle.
    public var slackAudioPrefixes: [String] { configuration.slackAudioPrefixes }

    private func startSensorServer() {
        let server = BrowserSensorServer(
            onMessage: { [weak self] message in self?.handleSensor(message) },
            onConnectionChange: { [weak self] count in self?.handleSensorConnectionChange(count) }
        )
        do {
            try server.start()
            lock.lock()
            sensorServer = server
            lock.unlock()
        } catch {
            Log.detection.error("sensor server failed to start: \(logSafeDescription(error), privacy: .public)")
        }
        startSafariSensorServer()
    }

    /// Listens for the Safari extension. Its connections come and go with the
    /// extension's process, which the system stops between messages, so a
    /// closed connection says nothing about whether the add-on is loaded and
    /// is not reported. Silence is, in `poll`.
    private func startSafariSensorServer() {
        guard let socketURL = SafariSensorSocket.url(),
            let verifier = SensorPeerVerifier.safariExtension()
        else { return }
        let server = BrowserSensorServer(
            socketURL: socketURL,
            verifier: verifier,
            onMessage: { [weak self] message in
                // Only Safari speaks on this socket, whatever a message claims.
                guard message.browser == .safari else { return }
                self?.handleSensor(message)
            }
        )
        do {
            try server.start()
            lock.withLock { safariSensorServer = server }
        } catch {
            Log.detection.error(
                "safari sensor server failed to start: \(logSafeDescription(error), privacy: .public)"
            )
        }
    }

    public var sensorStatus: BrowserSensorServer.Status? {
        lock.lock()
        defer { lock.unlock() }
        return sensorServer?.currentStatus
    }

    private func handleSensor(_ message: SensorMessage) {
        let now = clock.monotonicSeconds
        lock.lock()
        defer { lock.unlock() }
        if message.browser == .safari { lastSafariContact = now }
        switch message {
        case .hello(let hello):
            hellos[hello.browser] = hello
            browserDetectors[hello.browser]?.sensorConnected(at: now)
        case .event(let event):
            browserDetectors[event.browser]?.receive(event, at: now)
        case .tabClosed(let browser, let tabID):
            // Tab identifiers are per browser, and another tab in the same browser
            // may still be in a call, so only this one entry is dropped.
            browserDetectors[browser]?.closeTab(tabID, at: now)
        case .goodbye(let browser):
            // One browser's host exiting says nothing about another's.
            browserDetectors[browser]?.sensorDisconnected(at: now)
        }
    }

    private func handleSensorConnectionChange(_ count: Int) {
        let now = clock.monotonicSeconds
        lock.lock()
        defer { lock.unlock() }
        guard count == 0 else { return }
        // No relay is connected at all, so no browser that reports through one
        // is reporting. Safari reports through its own socket.
        for (browser, var detector) in browserDetectors where browser != .safari {
            detector.sensorDisconnected(at: now)
            browserDetectors[browser] = detector
        }
    }

    private func poll() {
        let now = clock.monotonicSeconds
        let audioStates = audioObserver.snapshot()
        let titles = windowReader.allTitles()
        let windowTitlesByBundle = windowReader.titlesByBundleIdentifier(from: titles)

        var evidence: [ProviderEvidence] = []

        // Read accessibility before taking the lock: the walk crosses into
        // another process and can block for seconds when Slack is busy.
        let slackObservation = slackReader.read()
        // Stamped after the walk, because the tiles describe the call as of
        // when the read finished. Stamping with the poll's start put every turn
        // boundary early by however long the walk took, and inflated the
        // cadence estimate that decides when a silence ends a turn.
        let observedAt = clock.monotonicSeconds

        lock.lock()

        // Slack
        let slackHoldsMic = audioObserver.holdsMicrophone(
            bundlePrefixes: configuration.slackAudioPrefixes, in: audioStates
        )
        let slackProducesOutput = audioObserver.producesOutput(
            bundlePrefixes: configuration.slackAudioPrefixes, in: audioStates
        )
        _ = slackDetector.update(
            observation: slackObservation,
            helperHoldsMicrophone: slackHoldsMic,
            helperProducingOutput: slackProducesOutput,
            at: now
        )
        let slackConfidence: MeetingConfidence =
            switch slackDetector.state {
            case .joined, .leaving: .confirmed
            case .candidate: .candidate
            case .idle: .none
            }
        if slackConfidence > .none {
            evidence.append(
                ProviderEvidence(
                    provider: .slack,
                    confidence: slackConfidence,
                    source: .accessibility,
                    title: slackDetector.conversationTitle,
                    muted: slackDetector.isMuted,
                    applicationBundleID: configuration.slackBundleIdentifier,
                    audioBundlePrefixes: configuration.slackAudioPrefixes
                ))
        }

        // Browsers
        if let contact = lastSafariContact, now - contact > Self.safariSilenceLimit {
            browserDetectors[.safari]?.sensorDisconnected(at: now)
            lastSafariContact = nil
        }
        for (browser, var detector) in browserDetectors {
            let ownerTitles = browser.windowOwnerNames.flatMap { titles[$0] ?? [] }
            let native = BrowserMeetingDetector.NativeSignals(
                browserHoldsMicrophone: audioObserver.holdsMicrophone(
                    bundlePrefixes: browser.audioBundlePrefixes, in: audioStates
                ),
                browserProducesOutput: audioObserver.producesOutput(
                    bundlePrefixes: browser.audioBundlePrefixes, in: audioStates
                ),
                windowTitles: ownerTitles
            )
            let result = detector.update(native: native, at: now)
            browserDetectors[browser] = detector
            if result.confidence > .none { evidence.append(result) }
        }

        // Unsupported applications
        if configuration.genericDetection {
            // Safari's audio comes from WebKit's processes, which carry a call on
            // any site and which other applications share. They stay with the
            // generic detector unless Safari has a meeting of its own, so a call
            // on a site the add-on does not read is still found.
            let knownPrefixes =
                configuration.slackAudioPrefixes
                + configuration.browsers.flatMap(\.bundleIdentifiers)
                + evidence.compactMap(\.browser).flatMap(\.audioBundlePrefixes)
            let unknownStates =
                audioStates
                .filter { state in !knownPrefixes.contains { state.bundleIdentifier.hasPrefix($0) } }
                .map { state in
                    ApplicationAudioState(
                        bundleIdentifier: state.bundleIdentifier,
                        processID: state.processID,
                        holdsMicrophone: state.holdsMicrophone,
                        producesOutput: state.producesOutput,
                        isFrontmost: state.isFrontmost,
                        windowTitle: windowTitlesByBundle[state.bundleIdentifier]
                    )
                }
            // The events drive the detector's own state machine; the evidence is
            // what the session acts on.
            _ = genericDetector.update(states: unknownStates, at: now)
            evidence.append(contentsOf: genericDetector.currentEvidence())
        }

        let snapshot = DetectionSnapshot(
            evidence: evidence,
            slackState: slackDetector.state,
            browserSensor: browserDetectors[.firefox]?.sensor.connection ?? .absent,
            hasAccessibility: AccessibilityBridge.isTrusted,
            hasWindowTitles: !titles.isEmpty || windowReader.hasTitleAccess,
            roster: reading(slack: slackObservation, browsers: browserDetectors, at: observedAt),
            sensorHello: hellos[.firefox],
            browserSensors: browserDetectors.mapValues(\.sensor.connection),
            sensorHellos: hellos
        )
        let labels = evidence.map { item in
            "\(item.provider.rawValue):\(item.confidence.rawValue):\(item.source.rawValue)"
        }
        let evidenceChanged = previousEvidence != labels
        previousEvidence = labels
        lastSnapshot = snapshot
        lock.unlock()

        if evidenceChanged {
            // Notice rather than info so a `log show` after the fact still has
            // the trail; this fires only when the evidence set changes.
            Log.detection.notice(
                "evidence: \(labels.isEmpty ? "none" : labels.joined(separator: ", "), privacy: .public)"
            )
        }
        delegate.detectionEngineDidUpdate(snapshot)
    }
}

extension NSLock {
    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        lock()
        defer { unlock() }
        return try body()
    }
}

extension BrowserKind {
    /// The name CoreGraphics reports as the window owner.
    var windowOwnerNames: [String] {
        switch self {
        case .firefox: ["firefox", "Firefox", "Firefox Developer Edition", "Nightly"]
        case .chrome:
            [
                "Google Chrome", "Google Chrome Beta", "Google Chrome Canary", "Brave Browser",
                "Brave Browser Beta", "Microsoft Edge", "Microsoft Edge Beta", "Arc", "Vivaldi", "Chromium",
            ]
        case .safari: ["Safari", "Safari Technology Preview"]
        case .unknown: []
        }
    }
}
