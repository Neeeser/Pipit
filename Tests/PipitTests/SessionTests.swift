import Foundation
import PipitCore
import Testing

@Suite("SessionController")
struct SessionControllerTests {
    private static func slackEvidence(confidence: MeetingConfidence) -> ProviderEvidence {
        ProviderEvidence(
            provider: .slack, confidence: confidence, source: .accessibility,
            title: "Engineering", applicationBundleID: "com.tinyspeck.slackmacgap",
            audioBundlePrefixes: ["com.tinyspeck.slackmacgap"]
        )
    }

    private static func genericEvidence(
        confidence: MeetingConfidence, bundleIdentifier: String = "com.example.videochat"
    ) -> ProviderEvidence {
        ProviderEvidence(
            provider: .unknown, confidence: confidence, source: .native,
            meetingID: nil, url: nil, title: "Team call", browser: nil,
            applicationBundleID: bundleIdentifier,
            audioBundlePrefixes: [bundleIdentifier]
        )
    }

    /// Runs a confirmed meeting and then withholds all evidence, returning how
    /// many seconds passed before the meeting was finished.
    private static func secondsUntilFinish(
        _ controller: inout SessionController, step: Double = 0.5, limit: Double = 400
    ) -> Double? {
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let start = 100.0
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: start, wallClock: wall
        )
        var now = start
        while now - start < limit {
            now += step
            let actions = controller.update(evidence: [], now: now, wallClock: wall)
            if actions.contains(where: { if case .finishRecording = $0 { true } else { false } }) {
                return now - start
            }
        }
        return nil
    }

    @Test("a candidate arms capture before anything reaches disk")
    func aCandidateArmsCaptureBeforeAnythingReachesDisk() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let actions = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .candidate)], now: 100, wallClock: wall
        )
        #expect(controller.snapshot.state == .candidate)
        guard case .armCapture(let prefixes, let capturesRemote) = actions.first else {
            Issue.record("expected capture to be armed, got \(actions)")
            return
        }
        #expect(prefixes == ["org.mozilla.firefox"])
        #expect(capturesRemote)
        #expect(
            !(actions.contains { if case .commitRecording = $0 { true } else { false } }),
            "a candidate must not create a meeting directory"
        )
    }

    @Test("a provider change between candidate and confirm retargets the tap")
    func aProviderChangeBetweenCandidateAndConfirmRetargetsTheTap() async throws {
        // A generic call arms the tap on the unknown application. When the
        // call turns out to be Meet in Firefox, the tap has to follow, or
        // the meeting records the wrong process for its whole length.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let generic = ProviderEvidence(
            provider: .unknown, confidence: .candidate, source: .native,
            meetingID: nil, url: nil, title: nil, browser: nil,
            applicationBundleID: "com.example.videochat",
            audioBundlePrefixes: ["com.example.videochat"]
        )
        _ = controller.update(evidence: [generic], now: 100, wallClock: wall)
        #expect(controller.snapshot.state == .candidate)

        let actions = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 104, wallClock: wall
        )
        let retargetIndex = actions.firstIndex { action in
            if case .retargetCapture(let prefixes) = action {
                return prefixes == ["org.mozilla.firefox"]
            }
            return false
        }
        let commitIndex = actions.firstIndex {
            if case .commitRecording = $0 { true } else { false }
        }
        guard let retargetIndex, let commitIndex else {
            Issue.record("expected a retarget and a commit, got \(actions)")
            return
        }
        #expect(
            retargetIndex < commitIndex,
            "the tap must follow the provider before the meeting is committed"
        )
    }

    @Test("starting a recording by hand during a candidate keeps the pre-roll")
    func startingARecordingByHandDuringACandidateKeepsThePreRoll() async throws {
        // Slack opens the microphone about twelve seconds before the user
        // joins, so the menu item is often pressed while a candidate is
        // armed. Arming again would throw away the ring.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .candidate)], now: 100, wallClock: wall
        )
        #expect(controller.snapshot.state == .candidate)

        let actions = controller.startManual(
            source: .manual, bundlePrefixes: ["org.mozilla.firefox"],
            titles: TitleCandidates(timestampFallback: "manual"),
            now: 104, wallClock: wall
        )
        #expect(controller.snapshot.state == .recording)
        #expect(controller.snapshot.isManual)
        #expect(
            !(actions.contains { if case .armCapture = $0 { true } else { false } }),
            "arming again discards the pre-roll: \(actions)"
        )
        #expect(
            actions.contains { if case .commitRecording = $0 { true } else { false } },
            "the recording still starts: \(actions)"
        )
    }

    @Test("confirmation commits the recording and flushes the pre-roll")
    func confirmationCommitsTheRecordingAndFlushesThePreRoll() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .candidate)], now: 100, wallClock: wall
        )
        let actions = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 101.5,
            wallClock: wall.addingTimeInterval(1.5)
        )
        #expect(controller.snapshot.state == .recording)
        guard let commit = actions.compactMap({ action -> CommitRequest? in
            if case .commitRecording(let request) = action { return request }
            return nil
        }).first else {
            Issue.record("expected a commit, got \(actions)")
            return
        }
        #expect(commit.source == .googleMeet)
        #expect(commit.providerMeetingID == "abc-defg-hij")
        #expect(!commit.isProvisional)
    }

    @Test("an abandoned prejoin discards its buffered audio")
    func anAbandonedPrejoinDiscardsItsBufferedAudio() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .candidate)], now: 100, wallClock: wall
        )
        var actions: [SessionAction] = []
        var now = 100.0
        for _ in 0..<40 {
            now += 30
            actions = controller.update(evidence: [], now: now, wallClock: wall)
            if !actions.isEmpty { break }
        }
        #expect(controller.snapshot.state == .idle)
        guard case .discardCapture = actions.first else {
            Issue.record("expected the candidate to be discarded, got \(actions)")
            return
        }
    }

    @Test("losing the extension mid-meeting does not end the recording")
    func losingTheExtensionMidMeetingDoesNotEndTheRecording() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 100, wallClock: wall
        )
        #expect(controller.snapshot.state == .recording)

        // The extension disconnects, and the native path keeps reporting a
        // confirmed meeting from the window title plus microphone state.
        var now = 100.0
        for _ in 0..<60 {
            now += 0.5
            let actions = controller.update(
                evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed, source: .native)],
                now: now, wallClock: wall
            )
            #expect(
                !(actions.contains { if case .finishRecording = $0 { true } else { false } }),
                "native fallback must keep the recording alive"
            )
        }
        #expect(controller.snapshot.state == .recording)
    }

    @Test("a disconnect and rejoin stays one meeting with two runs")
    func aDisconnectAndRejoinStaysOneMeetingWithTwoRuns() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 100, wallClock: wall
        )

        // Firefox quits. Evidence disappears entirely.
        var now = 100.0
        var sawReconnecting = false
        var sawPause = false
        for _ in 0..<30 {
            now += 0.5
            let actions = controller.update(evidence: [], now: now, wallClock: wall)
            if actions.contains(where: { $0 == .notify(.reconnecting(provider: .googleMeet)) }) {
                sawReconnecting = true
            }
            if actions.contains(where: { if case .pauseCapture = $0 { true } else { false } }) {
                sawPause = true
            }
            #expect(
                !(actions.contains { if case .finishRecording = $0 { true } else { false } }),
                "must not finish inside the reconnect window"
            )
        }
        #expect(sawReconnecting)
        #expect(sawPause, "the reconnect window is waiting, not meeting, so writing must pause")
        #expect(controller.snapshot.state == .reconnecting)

        // Firefox comes back and rejoins the same meeting.
        now += 1
        let resumed = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: now, wallClock: wall
        )
        #expect(controller.snapshot.state == .recording)
        #expect(controller.snapshot.runCount == 2)
        #expect(
            resumed.contains { if case .beginRun = $0 { true } else { false } },
            "the rejoin should append a run, not start a meeting"
        )
        #expect(
            !(resumed.contains { if case .commitRecording = $0 { true } else { false } }),
            "a rejoin must not create a second meeting"
        )
    }

    @Test("another provider's candidate evidence cannot hold a meeting open")
    func anotherProviderSCandidateEvidenceCannotHoldAMeetingOpen() async throws {
        // After leaving a Meet, Slack idling with the microphone (or any
        // other app producing candidate-level evidence) used to reset the
        // end clock forever, so the recording never finished.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 100, wallClock: wall
        )
        #expect(controller.snapshot.state == .recording)

        let slackCandidate = ProviderEvidence(
            provider: .slack, confidence: .candidate, source: .native,
            applicationBundleID: "com.tinyspeck.slackmacgap",
            audioBundlePrefixes: ["com.tinyspeck.slackmacgap"]
        )
        var now = 100.0
        var finished = false
        for _ in 0..<400 {
            now += 0.5
            let actions = controller.update(evidence: [slackCandidate], now: now, wallClock: wall)
            if actions.contains(where: { if case .finishRecording = $0 { true } else { false } }) {
                finished = true
                break
            }
        }
        #expect(finished, "the Meet recording must end despite Slack's idle microphone")
    }

    @Test("a meeting that does not come back is finished after the window")
    func aMeetingThatDoesNotComeBackIsFinishedAfterTheWindow() async throws {
        let configuration = SessionController.Configuration()
        var controller = SessionController(configuration: configuration)
        let elapsed = try #require(
            Self.secondsUntilFinish(&controller),
            "the meeting should end once the reconnect window expires"
        )
        #expect(controller.snapshot.state == .idle)
        let waited = configuration.endGraceSeconds + configuration.reconnectWindowSeconds
        #expect(elapsed >= waited, "ended too early: \(elapsed)s, expected \(waited)s")
        #expect(elapsed < waited + 1, "ended too late: \(elapsed)s, expected \(waited)s")
    }

    @Test("a shorter configured wait ends the meeting sooner")
    func aShorterConfiguredWaitEndsTheMeetingSooner() async throws {
        // The two waits are settings, so the lifecycle has to read them
        // rather than the numbers it was written against.
        var controller = SessionController(
            configuration: SessionController.Configuration(
                reconnectWindowSeconds: 10, endGraceSeconds: 2
            )
        )
        let elapsed = try #require(
            Self.secondsUntilFinish(&controller),
            "the meeting should end once the configured wait expires"
        )
        #expect(elapsed >= 12, "ended before the configured wait: \(elapsed)s")
        #expect(elapsed < 13, "ignored the configured wait: \(elapsed)s")
    }

    @Test("provider state never stops a manually started recording")
    func providerStateNeverStopsAManuallyStartedRecording() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.startManual(
            source: .manual, bundlePrefixes: ["org.mozilla.firefox"],
            titles: TitleCandidates(human: "Ad-hoc call", timestampFallback: "f"),
            now: 100, wallClock: wall
        )
        #expect(controller.snapshot.state == .recording)
        #expect(controller.snapshot.isManual)

        var now = 100.0
        for _ in 0..<600 {
            now += 0.5
            let actions = controller.update(evidence: [], now: now, wallClock: wall)
            #expect(
                !(actions.contains { if case .finishRecording = $0 { true } else { false } }),
                "a manual recording only ends when the user says so"
            )
        }
        #expect(controller.snapshot.state == .recording)

        let stopped = controller.stop(reason: "user_stopped", now: 400)
        #expect(stopped.contains { if case .finishRecording = $0 { true } else { false } })
        #expect(controller.snapshot.state == .idle)
    }

    @Test("an in-person recording captures the microphone only")
    func anInPersonRecordingCapturesTheMicrophoneOnly() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let actions = controller.startManual(
            source: .inPerson, bundlePrefixes: [],
            titles: TitleCandidates(timestampFallback: "f"), now: 100, wallClock: wall
        )
        guard case .armCapture(_, let capturesRemote) = actions.first else {
            Issue.record("expected capture to be armed, got \(actions)")
            return
        }
        #expect(!capturesRemote)
        #expect(controller.snapshot.source == .inPerson)
    }

    @Test("a provisional unknown call records first and asks after")
    func aProvisionalUnknownCallRecordsFirstAndAsksAfter() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let actions = controller.startManual(
            source: .genericCall, bundlePrefixes: ["com.example.videochat"],
            titles: TitleCandidates(window: "Team call", timestampFallback: "f"),
            now: 100, wallClock: wall, isProvisional: true,
            applicationBundleID: "com.example.videochat"
        )
        let commitIndex = try #require(
            actions.firstIndex {
            if case .commitRecording = $0 { return true } else { return false }
        }
        )
        let askIndex = try #require(
            actions.firstIndex {
            if case .askToKeepProvisional = $0 { return true } else { return false }
        }
        )
        #expect(commitIndex < askIndex, "capture must already be running when we ask")

        let discarded = controller.resolveProvisional(
            keep: false, reason: "user_discarded", now: 101
        )
        guard case .discardCapture = discarded.first else {
            Issue.record("declining should discard, got \(discarded)")
            return
        }
    }

    @Test("keeping a provisional recording leaves it running")
    func keepingAProvisionalRecordingLeavesItRunning() async throws {
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.startManual(
            source: .genericCall, bundlePrefixes: ["com.example.videochat"],
            titles: TitleCandidates(timestampFallback: "f"), now: 100, wallClock: wall,
            isProvisional: true, applicationBundleID: "com.example.videochat"
        )
        #expect(controller.resolveProvisional(keep: true, reason: "kept", now: 101) == [])
        #expect(controller.snapshot.state == .recording)
        #expect(!controller.snapshot.isProvisional)
    }

    @Test("paused detection ignores providers but keeps manual recording")
    func pausedDetectionIgnoresProvidersButKeepsManualRecording() async throws {
        var controller = SessionController(policies: ProviderPolicies(detectionPaused: true))
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        #expect(
            controller.update(
                evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 100, wallClock: wall
            ) == []
        )
        #expect(controller.snapshot.state == .idle)

        let manual = controller.startManual(
            source: .manual, bundlePrefixes: [],
            titles: TitleCandidates(timestampFallback: "f"), now: 100, wallClock: wall
        )
        #expect(!manual.isEmpty)
    }

    @Test("a discarded provisional is not asked about again during the call")
    func aDiscardedProvisionalIsNotAskedAboutAgainDuringTheCall() async throws {
        // The prompt is raised from evidence, and evidence is reasserted
        // on every poll. With the answer forgotten the session went idle,
        // read the same evidence half a second later and asked again, so
        // the user had to answer once per poll for the length of the call.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let call = Self.genericEvidence(confidence: .confirmed)
        let first = controller.update(evidence: [call], now: 100, wallClock: wall)
        #expect(
            first.contains { if case .askToKeepProvisional = $0 { true } else { false } },
            "an unrecognised call asks"
        )

        let discarded = controller.resolveProvisional(
            keep: false, reason: "user_discarded", now: 101
        )
        guard case .discardCapture = discarded.first else {
            Issue.record("declining should discard, got \(discarded)")
            return
        }

        var now = 101.0
        for _ in 0..<120 {
            now += 0.5
            #expect(
                controller.update(evidence: [call], now: now, wallClock: wall) == [],
                "the answer holds while the application keeps the microphone"
            )
        }
        #expect(controller.snapshot.state == .idle)
    }

    @Test("a later call in the same application asks again")
    func aLaterCallInTheSameApplicationAsksAgain() async throws {
        // The answer is scoped to the call it was asked about, not to the
        // application forever. That is what Never Record This App is for.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let call = Self.genericEvidence(confidence: .confirmed)
        _ = controller.update(evidence: [call], now: 100, wallClock: wall)
        _ = controller.resolveProvisional(keep: false, reason: "user_discarded", now: 101)

        // The call ends: no evidence at all for longer than the grace.
        _ = controller.update(evidence: [], now: 102, wallClock: wall)
        _ = controller.update(evidence: [], now: 110, wallClock: wall)

        let second = controller.update(evidence: [call], now: 400, wallClock: wall)
        #expect(
            second.contains { if case .askToKeepProvisional = $0 { true } else { false } },
            "a new call in the same application is a new question"
        )
    }

    @Test("the answer is about the call the prompt named")
    func theAnswerIsAboutTheCallThePromptNamed() async throws {
        // While the prompt is open, another unrecognised microphone
        // holder can become the strongest evidence. Reading the answer
        // from whatever the evidence had drifted to asked again about the
        // call the user had just answered, and suppressed a call they
        // were never offered for as long as it ran.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let asked = Self.genericEvidence(
            confidence: .confirmed, bundleIdentifier: "com.hnc.Discord.helper"
        )
        let other = Self.genericEvidence(
            confidence: .confirmed, bundleIdentifier: "com.example.videochat"
        )
        _ = controller.update(evidence: [asked], now: 100, wallClock: wall)
        _ = controller.update(evidence: [other, asked], now: 100.5, wallClock: wall)
        _ = controller.resolveProvisional(keep: false, reason: "user_discarded", now: 101)

        #expect(
            controller.update(evidence: [asked], now: 101.5, wallClock: wall) == [],
            "the call the prompt named stays answered"
        )
        let untouched = controller.update(evidence: [other], now: 102, wallClock: wall)
        #expect(
            untouched.contains { if case .commitRecording = $0 { true } else { false } },
            "a call nobody was asked about is still recorded"
        )
    }

    @Test("a helper rotating under the call does not undo the answer")
    func aHelperRotatingUnderTheCallDoesNotUndoTheAnswer() async throws {
        // The same application opens the microphone from .helper on one
        // poll and .helper.Renderer on the next. Compared as raw process
        // identifiers, the answer stopped applying the moment it rotated.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let asked = Self.genericEvidence(
            confidence: .confirmed, bundleIdentifier: "com.hnc.Discord.helper"
        )
        let rotated = Self.genericEvidence(
            confidence: .confirmed, bundleIdentifier: "com.hnc.Discord.helper.Renderer"
        )
        _ = controller.update(evidence: [asked], now: 100, wallClock: wall)
        _ = controller.resolveProvisional(keep: false, reason: "user_discarded", now: 101)
        #expect(
            controller.update(evidence: [rotated], now: 101.5, wallClock: wall) == [],
            "the same application under a different helper is the same answer"
        )
    }

    @Test("declining one call does not suppress another in the same application")
    func decliningOneCallDoesNotSuppressAnotherInTheSameApplication() async throws {
        // Anything running in a tab reports the browser as its
        // application, so an answer scoped to the application alone would
        // stop every meeting in that browser from recording.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let call = Self.genericEvidence(confidence: .confirmed, bundleIdentifier: "org.mozilla.firefox")
        _ = controller.update(evidence: [call], now: 100, wallClock: wall)
        _ = controller.resolveProvisional(keep: false, reason: "user_discarded", now: 101)

        let meet = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 102, wallClock: wall
        )
        #expect(
            meet.contains { if case .commitRecording = $0 { true } else { false } },
            "a Meet call in the same browser still records"
        )
    }

    @Test("stopping by hand does not start the same call again")
    func stoppingByHandDoesNotStartTheSameCallAgain() async throws {
        // Slack holds the microphone either side of a huddle, and
        // evidence is reasserted on every poll. Stopping left the session
        // idle in front of that evidence, so half a second later it
        // recorded the same call again and the user threw away a
        // one-second meeting after every huddle.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let huddle = Self.slackEvidence(confidence: .confirmed)
        let started = controller.update(evidence: [huddle], now: 100, wallClock: wall)
        #expect(
            started.contains { if case .commitRecording = $0 { true } else { false } },
            "the huddle records"
        )

        let stopped = controller.stop(reason: "user_stopped", now: 200)
        #expect(stopped.contains { if case .finishRecording = $0 { true } else { false } })

        var now = 200.0
        for _ in 0..<120 {
            now += 0.5
            #expect(
                controller.update(evidence: [huddle], now: now, wallClock: wall) == [],
                "the call the user stopped stays stopped while it is still there"
            )
        }
        #expect(controller.snapshot.state == .idle)
    }

    @Test("a later call records after a hand stop")
    func aLaterCallRecordsAfterAHandStop() async throws {
        // The stop is about the call the user stopped, not about the
        // application for the rest of the day.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        let huddle = Self.slackEvidence(confidence: .confirmed)
        _ = controller.update(evidence: [huddle], now: 100, wallClock: wall)
        _ = controller.stop(reason: "user_stopped", now: 200)

        // The huddle ends: no evidence at all for longer than the grace.
        _ = controller.update(evidence: [], now: 201, wallClock: wall)
        _ = controller.update(evidence: [], now: 210, wallClock: wall)

        let second = controller.update(evidence: [huddle], now: 400, wallClock: wall)
        #expect(
            second.contains { if case .commitRecording = $0 { true } else { false } },
            "a later huddle is a new meeting"
        )
    }

    @Test("the huddle after the one the user stopped records")
    func theHuddleAfterTheOneTheUserStoppedRecords() async throws {
        // Slack idles on the microphone between huddles, so waiting for
        // the application to go quiet would hold the stop over the next
        // huddle as well: the user leaves one call, joins another, and
        // nothing records. The huddle dropping out of confirmed is what
        // says it is over.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [Self.slackEvidence(confidence: .confirmed)], now: 100, wallClock: wall
        )
        _ = controller.stop(reason: "user_stopped", now: 200)

        let idling = Self.slackEvidence(confidence: .candidate)
        var now = 200.0
        for _ in 0..<20 {
            now += 0.5
            _ = controller.update(evidence: [idling], now: now, wallClock: wall)
        }
        #expect(controller.snapshot.state == .candidate, "the idle microphone only arms")

        let next = controller.update(
            evidence: [Self.slackEvidence(confidence: .confirmed)], now: now + 0.5,
            wallClock: wall
        )
        #expect(
            next.contains { if case .commitRecording = $0 { true } else { false } },
            "the next huddle is a new meeting"
        )
    }

    @Test("stopping one meeting does not stop the next one recording")
    func stoppingOneMeetingDoesNotStopTheNextOneRecording() async throws {
        // Both meetings run in the same browser, so an identity built
        // from the application alone would swallow the second one.
        var controller = SessionController()
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        _ = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 100, wallClock: wall
        )
        _ = controller.stop(reason: "user_stopped", now: 200)

        let next = controller.update(
            evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed, meetingID: "zzz-yyyy-xxx")],
            now: 201, wallClock: wall
        )
        #expect(
            next.contains { if case .commitRecording = $0 { true } else { false } },
            "a different meeting in the same browser records"
        )
    }

    @Test("a provider set to never record is left alone")
    func aProviderSetToNeverRecordIsLeftAlone() async throws {
        var policies = ProviderPolicies()
        policies.googleMeet = ProviderPolicy(autoStart: .never, autoStop: true)
        var controller = SessionController(policies: policies)
        let wall = Date(timeIntervalSince1970: 1_787_070_000)
        #expect(
            controller.update(
                evidence: [DetectionFixtures.meetEvidence(confidence: .confirmed)], now: 100, wallClock: wall
            ) == []
        )
        #expect(controller.snapshot.state == .idle)
    }
}

@Suite("ReconnectMatcher")
struct ReconnectMatcherTests {
    @Test("the same meeting ID resumed quickly merges automatically")
    func theSameMeetingIDResumedQuicklyMergesAutomatically() async throws {
        let matcher = ReconnectMatcher()
        let start = Date(timeIntervalSince1970: 1_787_070_000)
        let earlier = ReconnectMatcher.Candidate(
            meetingID: "a", provider: .googleMeet, providerMeetingID: "abc-defg-hij",
            url: "https://meet.google.com/abc-defg-hij",
            startedAt: start, endedAt: start.addingTimeInterval(600)
        )
        let later = ReconnectMatcher.Candidate(
            meetingID: "b", provider: .googleMeet, providerMeetingID: "abc-defg-hij",
            url: "https://meet.google.com/abc-defg-hij?authuser=0",
            startedAt: start.addingTimeInterval(690)
        )
        guard case .sameMeeting = matcher.compare(earlier, later) else {
            Issue.record("expected an automatic merge, got \(matcher.compare(earlier, later))")
            return
        }
    }

    @Test("a weak match is offered to the user instead of guessed")
    func aWeakMatchIsOfferedToTheUserInsteadOfGuessed() async throws {
        let matcher = ReconnectMatcher()
        let start = Date(timeIntervalSince1970: 1_787_070_000)
        let earlier = ReconnectMatcher.Candidate(
            meetingID: "a", provider: .slack, title: "Engineering",
            startedAt: start, endedAt: start.addingTimeInterval(300)
        )
        let later = ReconnectMatcher.Candidate(
            meetingID: "b", provider: .slack, title: "Engineering",
            startedAt: start.addingTimeInterval(420)
        )
        guard case .possible = matcher.compare(earlier, later) else {
            Issue.record("expected a suggestion, got \(matcher.compare(earlier, later))")
            return
        }
    }

    @Test("different meeting IDs are never merged")
    func differentMeetingIDsAreNeverMerged() async throws {
        let matcher = ReconnectMatcher()
        let start = Date(timeIntervalSince1970: 1_787_070_000)
        let earlier = ReconnectMatcher.Candidate(
            meetingID: "a", provider: .googleMeet, providerMeetingID: "abc-defg-hij",
            startedAt: start, endedAt: start.addingTimeInterval(60)
        )
        let later = ReconnectMatcher.Candidate(
            meetingID: "b", provider: .googleMeet, providerMeetingID: "zzz-zzzz-zzz",
            startedAt: start.addingTimeInterval(90)
        )
        #expect(matcher.compare(earlier, later) == .unrelated)
    }

    @Test("a long gap is a new meeting whatever the evidence says")
    func aLongGapIsANewMeetingWhateverTheEvidenceSays() async throws {
        let matcher = ReconnectMatcher()
        let start = Date(timeIntervalSince1970: 1_787_070_000)
        let earlier = ReconnectMatcher.Candidate(
            meetingID: "a", provider: .zoom, providerMeetingID: "81771591841",
            startedAt: start, endedAt: start.addingTimeInterval(600)
        )
        let later = ReconnectMatcher.Candidate(
            meetingID: "b", provider: .zoom, providerMeetingID: "81771591841",
            startedAt: start.addingTimeInterval(600 + 3_600)
        )
        #expect(matcher.compare(earlier, later) == .unrelated)
    }
}

@Suite("MeetingContinuation")
struct MeetingContinuationTests {
    @Test("a rejoined meeting links to the earlier one without moving audio")
    func aRejoinedMeetingLinksToTheEarlierOneWithoutMovingAudio() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root)
        let start = Date(timeIntervalSince1970: 1_787_070_000)

        let first = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet, startedAt: start,
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"), now: start
        )
        _ = try first.store.updateMetadata { metadata in
            metadata.providerMeetingID = "abc-defg-hij"
            metadata.endedAt = start.addingTimeInterval(600)
            metadata.durationSeconds = 600
        }
        let second = try repository.createMeeting(
            source: .googleMeet, provider: .googleMeet,
            startedAt: start.addingTimeInterval(690),
            titles: TitleCandidates(provider: "Weekly sync", timestampFallback: "f"),
            now: start.addingTimeInterval(690)
        )
        _ = try second.store.updateMetadata { $0.providerMeetingID = "abc-defg-hij" }

        let matcher = ReconnectMatcher()
        let earlier = ReconnectMatcher.Candidate(
            meetingID: first.metadata.id, provider: .googleMeet,
            providerMeetingID: "abc-defg-hij",
            startedAt: start, endedAt: start.addingTimeInterval(600)
        )
        let later = ReconnectMatcher.Candidate(
            meetingID: second.metadata.id, provider: .googleMeet,
            providerMeetingID: "abc-defg-hij",
            startedAt: start.addingTimeInterval(690)
        )
        guard case .sameMeeting = matcher.compare(earlier, later) else {
            Issue.record("a rejoin with the same meeting ID should merge")
            return
        }

        // Both directories survive a merge: combining is a link, not a copy.
        #expect(FileManager.default.fileExists(atPath: first.store.layout.root.path))
        #expect(FileManager.default.fileExists(atPath: second.store.layout.root.path))
    }
}
