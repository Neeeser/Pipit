import Foundation

/// Applications that hold the microphone without a meeting happening.
///
/// `com.apple.CoreSpeech` held microphone input for an hour and thirty-five
/// minutes of an observed session with no user speech at any point, interrupted
/// only by sub-second audio-object recreations. Any detector that treats "a
/// process holds the microphone" as a candidate fires permanently without this.
public enum MicrophoneIgnoreList {
    /// Applications that hold the microphone and play audio for as long as they
    /// run, without anyone being in a meeting: remote desktop, screen sharing and
    /// game streaming. They match every signal the generic detector has, so they
    /// are excluded by name.
    public static let notMeetings: Set<String> = [
        "com.p5sys.jump.connect",
        "com.p5sys.jump.mac.viewer",
        "com.p5sys.jump.mac.viewer.web",
        "com.apple.ScreenSharing",
        "com.apple.screensharing.agent",
        "com.apple.screensharing.MessagesAgent",
        "com.teamviewer.TeamViewer",
        "com.teamviewer.TeamViewerHost",
        "com.philandro.anydesk",
        "com.google.chromeremotedesktop",
        "com.edovia.screens5.mac",
        "com.realvnc.vncviewer",
        "com.realvnc.vncserver",
        "com.parsecgaming.parsec",
        "com.splashtop.streamer-mac",
        "com.moonlight-stream.Moonlight",
        "com.valvesoftware.steamlink",
        "com.nvidia.gfnpc.mac",
        "com.apple.QuickTimePlayerX",
        "com.apple.PhotoBooth",
        "com.apple.VoiceMemos",
        "com.obsproject.obs-studio",
    ]

    public static let systemServices: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.accessibility.heard",
        "com.apple.cmio.ContinuityCaptureAgent",
        "com.apple.audio.AudioComponentRegistrar",
        "com.apple.controlcenter",
        "com.apple.Spotlight",
        "com.apple.VoiceMemos.RecordingWidget",
        "com.apple.speech.speechsynthesisd",
        "com.apple.SiriTTSService",
        "com.apple.dictationd",
        "com.apple.voicebankingd",
    ]

    /// Pipit's own capture must never look like a meeting to itself.
    public static let ownBundleIdentifiers: Set<String> = ["com.pipit.app"]

    /// The application a helper process belongs to.
    ///
    /// Electron and Chromium applications open the microphone from a helper, and
    /// which one varies over the life of the process: `.helper`,
    /// `.helper.Renderer`, `.helper.GPU`. CoreAudio reports whichever it was, so
    /// a choice the user made about "this application" is recorded against the
    /// application rather than against the helper that happened to be asked
    /// about.
    ///
    /// Nothing is collapsed below two components. A bundle identifier is
    /// reverse-DNS, and shortening `com.helper.app` to `com` would ban most of
    /// the machine through the prefix match. Two is the floor rather than three
    /// because vendor identifiers that short exist: Notion ships as `notion.id`
    /// with helpers under `notion.id.helper`.
    public static func applicationIdentifier(for bundleIdentifier: String) -> String {
        let components = bundleIdentifier.split(separator: ".")
        guard let helper = components.firstIndex(where: { $0.lowercased() == "helper" }),
            helper >= 2
        else { return bundleIdentifier }
        return components[..<helper].joined(separator: ".")
    }

    public static func isIgnored(_ bundleIdentifier: String, additional: Set<String> = []) -> Bool {
        if bundleIdentifier.isEmpty { return true }
        if systemServices.contains(bundleIdentifier) { return true }
        if notMeetings.contains(bundleIdentifier) { return true }
        if ownBundleIdentifiers.contains(bundleIdentifier) { return true }
        if additional.contains(bundleIdentifier) { return true }
        // Helper processes of an ignored application, Pipit's own included:
        // its capture must never look like a meeting to itself, and it is the
        // helper that would hold the microphone.
        let excluded =
            systemServices
            .union(notMeetings)
            .union(ownBundleIdentifiers)
            .union(additional)
        return excluded.contains { bundleIdentifier.hasPrefix($0 + ".") }
    }
}

/// One application's audio state, as the detector sees it.
public struct ApplicationAudioState: Sendable, Equatable {
    public let bundleIdentifier: String
    public let processID: Int32
    public let holdsMicrophone: Bool
    public let producesOutput: Bool
    public let isFrontmost: Bool
    public let windowTitle: String?

    public init(
        bundleIdentifier: String, processID: Int32, holdsMicrophone: Bool,
        producesOutput: Bool, isFrontmost: Bool, windowTitle: String?
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processID = processID
        self.holdsMicrophone = holdsMicrophone
        self.producesOutput = producesOutput
        self.isFrontmost = isFrontmost
        self.windowTitle = windowTitle
    }
}

/// Finds probable calls in applications Pipit has no adapter for.
///
/// Recall is worth more than precision here: capture starts provisionally and the
/// user is asked afterwards, so a false positive costs a prompt while a miss
/// costs the meeting. Microphone ownership alone is never enough, and simple
/// heuristics are used deliberately in place of a classifier.
public struct GenericCallDetector: Sendable {
    public struct Configuration: Sendable, Equatable {
        /// How long an application must hold the microphone before it counts.
        public var dwellSeconds: Double
        /// Two-way audio is much stronger evidence than the microphone alone, so it
        /// promotes faster.
        public var dwellSecondsWithOutput: Double
        /// Applications the user chose to always or never record.
        public var alwaysRecord: Set<String>
        public var neverRecord: Set<String>
        /// How long an application can vanish from the audio process list before
        /// the call is considered over.
        public var endGraceSeconds: Double

        public init(
            dwellSeconds: Double = 25,
            dwellSecondsWithOutput: Double = 8,
            alwaysRecord: Set<String> = [],
            neverRecord: Set<String> = [],
            endGraceSeconds: Double = 6
        ) {
            self.dwellSeconds = dwellSeconds
            self.dwellSecondsWithOutput = dwellSecondsWithOutput
            self.alwaysRecord = alwaysRecord
            self.neverRecord = neverRecord
            self.endGraceSeconds = endGraceSeconds
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let bundleIdentifier: String
        public let processID: Int32
        public let heldForSeconds: Double
        public let hasTwoWayAudio: Bool
        public let windowTitle: String?
        /// The user already said always-record this application.
        public let isPreapproved: Bool
    }

    public enum Event: Sendable, Equatable {
        case none
        case callLikely(Candidate)
        case callEnded(bundleIdentifier: String)
    }

    public var configuration: Configuration

    private struct Tracked {
        var since: Double
        var promoted = false
        var sawOutput = false
        var lastSeen: Double
        var windowTitle: String?
        var processID: Int32 = -1
    }

    private var tracked: [String: Tracked] = [:]

    /// Meeting apps whose desktop calls this detector finds. Their calls are
    /// filed under the app rather than as an unknown "Call", so the app's own
    /// policy decides whether to record.
    public let apps: [MeetingApp]

    public init(
        configuration: Configuration = Configuration(),
        apps: [MeetingApp] = MeetingApp.all.filter { !$0.hasOwnDesktopDetector }
    ) {
        self.configuration = configuration
        self.apps = apps
    }

    public mutating func update(states: [ApplicationAudioState], at now: Double) -> [Event] {
        var events: [Event] = []
        var seen: Set<String> = []

        for state in states {
            guard state.holdsMicrophone else { continue }
            guard !isNeverRecorded(state.bundleIdentifier) else { continue }
            seen.insert(state.bundleIdentifier)

            var entry = tracked[state.bundleIdentifier] ?? Tracked(since: now, lastSeen: now)
            entry.lastSeen = now
            entry.processID = state.processID
            if let title = state.windowTitle { entry.windowTitle = title }
            if state.producesOutput { entry.sawOutput = true }
            let held = now - entry.since
            let threshold =
                entry.sawOutput
                ? configuration.dwellSecondsWithOutput
                : configuration.dwellSeconds
            // Both lists name applications, and the microphone is held by a
            // helper, so the process is resolved to its application either way.
            let preapproved = !configuration.alwaysRecord.isDisjoint(
                with: listedIdentifiers(for: state.bundleIdentifier)
            )

            if !entry.promoted, preapproved || held >= threshold {
                entry.promoted = true
                events.append(
                    .callLikely(
                        Candidate(
                            bundleIdentifier: state.bundleIdentifier,
                            processID: state.processID,
                            heldForSeconds: held,
                            hasTwoWayAudio: entry.sawOutput,
                            windowTitle: state.windowTitle,
                            isPreapproved: preapproved
                        )))
            }
            tracked[state.bundleIdentifier] = entry
        }

        // A single missed poll is not the end of a call: CoreAudio recreates
        // audio objects for sub-second stretches during normal operation.
        // A ban is not a flap, though. An entry whose application is now on the
        // never-record list kept publishing confirmed evidence through the end
        // grace, and the session re-prompted the user it had just answered.
        for (bundleIdentifier, entry) in tracked where !seen.contains(bundleIdentifier) {
            let banned = isNeverRecorded(bundleIdentifier)
            guard banned || now - entry.lastSeen >= configuration.endGraceSeconds else { continue }
            if entry.promoted { events.append(.callEnded(bundleIdentifier: bundleIdentifier)) }
            tracked.removeValue(forKey: bundleIdentifier)
        }
        return events
    }

    /// The identifiers the always- and never-record lists may name this
    /// process by.
    ///
    /// Its application, and for a process of a known meeting app every one of
    /// that app's bundle identifiers: the evidence offers the app's main
    /// identifier, which is what the person's answer is saved under, while the
    /// microphone is usually held by a helper with a different identifier.
    private func listedIdentifiers(for bundleIdentifier: String) -> Set<String> {
        var identifiers: Set<String> = [MicrophoneIgnoreList.applicationIdentifier(for: bundleIdentifier)]
        if let app = MeetingApp.owning(bundleIdentifier: bundleIdentifier, in: apps) {
            identifiers.formUnion(app.desktopBundleIdentifiers)
        }
        return identifiers
    }

    private func isNeverRecorded(_ bundleIdentifier: String) -> Bool {
        MicrophoneIgnoreList.isIgnored(bundleIdentifier, additional: configuration.neverRecord)
            || !configuration.neverRecord.isDisjoint(with: listedIdentifiers(for: bundleIdentifier))
    }

    /// Evidence for every call being watched.
    ///
    /// An application that has just taken the microphone is a candidate, which
    /// arms capture into the memory ring without writing anything to disk. It
    /// becomes confirmed once it has held the microphone past the dwell. Without
    /// the candidate step the ring is empty at promotion and the first eight to
    /// twenty-five seconds of an unsupported call are lost.
    ///
    /// Evidence is reasserted on every poll because the session lifecycle ends a
    /// recording whose evidence disappears.
    public func currentEvidence() -> [ProviderEvidence] {
        var evidence: [ProviderEvidence] = []
        var indexByApp: [MeetingProvider: Int] = [:]
        // Sorted so the merge below, and the order of the result, does not
        // depend on dictionary order.
        for (bundleIdentifier, entry) in tracked.sorted(by: { $0.key < $1.key }) {
            let confidence: MeetingConfidence = entry.promoted ? .confirmed : .candidate
            guard let app = MeetingApp.owning(bundleIdentifier: bundleIdentifier, in: apps) else {
                evidence.append(
                    ProviderEvidence(
                        provider: .unknown,
                        confidence: confidence,
                        source: .native,
                        title: entry.windowTitle,
                        applicationBundleID: bundleIdentifier,
                        audioBundlePrefixes: [bundleIdentifier]
                    ))
                continue
            }
            // An app's call is one meeting however many of its processes hold
            // the microphone, so its helpers fold into one piece of evidence.
            if let index = indexByApp[app.provider] {
                evidence[index].confidence = max(evidence[index].confidence, confidence)
                if evidence[index].title == nil { evidence[index].title = entry.windowTitle }
                continue
            }
            indexByApp[app.provider] = evidence.count
            evidence.append(
                ProviderEvidence(
                    provider: app.provider,
                    confidence: confidence,
                    source: .native,
                    title: entry.windowTitle,
                    applicationBundleID: app.desktopBundleIdentifiers.first ?? bundleIdentifier,
                    audioBundlePrefixes: app.desktopAudioBundlePrefixes
                ))
        }
        return evidence
    }
}
