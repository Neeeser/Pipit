import Foundation
import PipitCore
import Testing

@Suite("SlackHuddleDetector")
struct SlackHuddleDetectorTests {
    private static func previewing() -> SlackAccessibilityObservation {
        SlackAccessibilityObservation(hasLeaveHuddleControl: false, subtreeWasEmpty: false)
    }

    @Test("holding the microphone is a candidate, not a meeting")
    func holdingTheMicrophoneIsACandidateNotAMeeting() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0

        // Slack opened the microphone 12.2 s before the user joined.
        let event = detector.update(
            observation: Self.previewing(), helperHoldsMicrophone: true,
            helperProducingOutput: false, at: now
        )
        #expect(event == .candidateAppeared)
        #expect(detector.state == .candidate)

        for _ in 0..<30 {
            now += 0.4
            let tick = detector.update(
                observation: Self.previewing(), helperHoldsMicrophone: true,
                helperProducingOutput: false, at: now
            )
            #expect(tick == .none, "a preview must not become a meeting")
        }

        now += 0.4
        let joinedEvent = detector.update(
            observation: DetectionFixtures.joined(), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )
        #expect(joinedEvent == .joined)
    }

    @Test("a flapping accessibility subtree never ends a live huddle")
    func aFlappingAccessibilitySubtreeNeverEndsALiveHuddle() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        _ = detector.update(
            observation: DetectionFixtures.joined(), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )
        #expect(detector.state == .joined)

        // The subtree read empty repeatedly during a confirmed active huddle.
        for cycle in 0..<20 {
            now += 0.4
            let empty = detector.update(
                observation: .empty, helperHoldsMicrophone: true,
                helperProducingOutput: true, at: now
            )
            #expect(empty != .left(reason: "control_gone"), "ended on empty read \(cycle)")
            #expect(empty != .left(reason: "audio_stopped"))
            now += 0.4
            _ = detector.update(
                observation: DetectionFixtures.joined(), helperHoldsMicrophone: true,
                helperProducingOutput: true, at: now
            )
            #expect(detector.state == .joined)
        }
    }

    @Test("a real leave ends the huddle once the audio agrees")
    func aRealLeaveEndsTheHuddleOnceTheAudioAgrees() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        _ = detector.update(
            observation: DetectionFixtures.joined(), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )

        var ended: SlackHuddleDetector.Event = .none
        for _ in 0..<12 {
            now += 0.4
            ended = detector.update(
                observation: Self.previewing(), helperHoldsMicrophone: false,
                helperProducingOutput: false, at: now
            )
            if case .left = ended { break }
        }
        guard case .left = ended else {
            Issue.record("a genuine leave must end the huddle, got \(ended)")
            return
        }
        #expect(detector.state == .idle)
        #expect(now - 100.0 >= 1.2, "must not end on the first miss")
    }

    @Test("mute toggles are reported without touching the lifecycle")
    func muteTogglesAreReportedWithoutTouchingTheLifecycle() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        _ = detector.update(
            observation: DetectionFixtures.joined(mute: false), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )
        now += 0.4
        let muted = detector.update(
            observation: DetectionFixtures.joined(mute: true), helperHoldsMicrophone: true,
            helperProducingOutput: true, at: now
        )
        #expect(muted == .muteChanged(true))
        #expect(detector.state == .joined)
    }

    @Test("window titles yield conversation, kind and workspace")
    func windowTitlesYieldConversationKindAndWorkspace() async throws {
        let dm = try #require(SlackWindowTitle.parse("Brian McNamara (DM) - Vectorize - Slack"))
        #expect(dm.conversation == "Brian McNamara")
        #expect(dm.kind == .directMessage)
        #expect(dm.workspace == "Vectorize")

        let channel = try #require(
            SlackWindowTitle.parse("vectorize-booking (Channel) - Hindsight - Slack")
        )
        #expect(channel.conversation == "vectorize-booking")
        #expect(channel.kind == .channel)

        let decorated = try #require(
            SlackWindowTitle.parse("andrew.neeser595 (DM) - Hindsight - Slack [Main] 🏠🔊")
        )
        #expect(decorated.conversation == "andrew.neeser595")
        #expect(decorated.workspace == "Hindsight")

        let preview = try #require(SlackWindowTitle.parse("Slack - Huddle Preview"))
        #expect(preview.isHuddlePreview)
    }

    @Test("a title with no conversation in it names nothing")
    func aTitleWithNoConversationInItNamesNothing() async throws {
        // Slack publishes "- Hindsight - Slack" while a conversation is
        // loading. Read as a name it became the meeting's title, and a
        // huddle was filed and announced as "- Hindsight".
        #expect(
            SlackWindowTitle.parse("- Hindsight - Slack") == nil,
            "a leading separator is not a conversation name"
        )
        #expect(SlackWindowTitle.parse(" (DM) - Hindsight - Slack") == nil)
        #expect(SlackWindowTitle.parse("Hindsight - Slack")?.conversation == "Hindsight")

        // And the last real name survives the moment the title is empty.
        var detector = SlackHuddleDetector()
        _ = detector.update(
            observation: SlackAccessibilityObservation(
                hasLeaveHuddleControl: true, subtreeWasEmpty: false, isMuted: false,
                windowTitle: "andrew.neeser595 (DM) - Hindsight - Slack"
            ),
            helperHoldsMicrophone: true, helperProducingOutput: false, at: 100
        )
        _ = detector.update(
            observation: SlackAccessibilityObservation(
                hasLeaveHuddleControl: true, subtreeWasEmpty: false, isMuted: false,
                windowTitle: "- Hindsight - Slack"
            ),
            helperHoldsMicrophone: true, helperProducingOutput: false, at: 101
        )
        #expect(detector.conversationTitle == "andrew.neeser595")
    }
}

@Suite("BrowserMeetingDetector")
struct BrowserMeetingDetectorTests {
    @Test("Meet prejoin and joined are only distinguishable with the sensor")
    func meetPrejoinAndJoinedAreOnlyDistinguishableWithTheSensor() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        // Native view of the whole controlled test: the title carries the
        // meeting code and the microphone is held, through prejoin, join
        // and leave, with no transition at the moment of joining.
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: false,
            windowTitles: ["Meet - jfp-btbt-owm"]
        )
        let early = detector.update(native: native, at: now)
        #expect(early.provider == .googleMeet)
        #expect(early.confidence == .candidate)
        #expect(early.meetingID == "jfp-btbt-owm")

        // Native alone eventually records anyway: recall beats precision.
        now += 25
        #expect(detector.update(native: native, at: now).confidence == .confirmed)

        // With the sensor connected, prejoin is explicit.
        var sensored = BrowserMeetingDetector()
        sensored.sensorConnected(at: now)
        sensored.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .prejoin,
                timestamp: now, url: "https://meet.google.com/jfp-btbt-owm",
                meetingID: "jfp-btbt-owm"
            ),
            at: now
        )
        #expect(sensored.update(native: native, at: now).confidence == .candidate)

        now += 1.6
        sensored.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .inCall,
                timestamp: now, url: "https://meet.google.com/jfp-btbt-owm",
                meetingID: "jfp-btbt-owm", muted: false
            ),
            at: now
        )
        let joined = sensored.update(native: native, at: now)
        #expect(joined.confidence == .confirmed)
        #expect(joined.source == .browserSensor)
        #expect(joined.muted == false)
    }

    @Test("a prejoin screen is not recorded while the extension is reporting")
    func aPrejoinScreenIsNotRecordedWhileTheExtensionIsReporting() async throws {
        // Meet holds the microphone on its prejoin screen, so the native
        // dwell confirms a meeting that has not been joined. The sensor
        // knows better, and an abandoned prejoin must leave no directory.
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: false,
            windowTitles: ["Meet - jfp-btbt-owm"]
        )
        detector.sensorConnected(at: now)
        _ = detector.update(native: native, at: now)
        now += 30
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .prejoin,
                timestamp: now, url: "https://meet.google.com/jfp-btbt-owm",
                meetingID: "jfp-btbt-owm"
            ),
            at: now
        )
        let waiting = detector.update(native: native, at: now)
        #expect(
            waiting.confidence == .candidate,
            "the native dwell must not commit a prejoin the sensor can see"
        )

        // When the sensor goes quiet the native path takes over again.
        now += 30
        let silent = detector.update(native: native, at: now)
        #expect(
            silent.confidence == .confirmed,
            "losing the extension costs precision, and the meeting is still recorded"
        )
    }

    @Test("Zoom's title arrives before the microphone, and that is fine")
    func zoomSTitleArrivesBeforeTheMicrophoneAndThatIsFine() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        // Measured ordering: title at 16:41:26, microphone at 16:41:31.
        let titleOnly = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: false,
            windowTitles: ["Andrew Neeser's Zoom Meeting"]
        )
        let first = detector.update(native: titleOnly, at: now)
        #expect(first.provider == .zoom)
        #expect(first.confidence == .none, "a title alone is not a meeting")

        now += 5.3
        let withMic = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Andrew Neeser's Zoom Meeting"]
        )
        #expect(detector.update(native: withMic, at: now).confidence == .candidate)
        now += 21
        let confirmed = detector.update(native: withMic, at: now)
        #expect(confirmed.confidence == .confirmed)
        #expect(confirmed.title == "Andrew Neeser's Zoom Meeting")
    }

    @Test("a stale sensor falls back to native without losing the meeting")
    func aStaleSensorFallsBackToNativeWithoutLosingTheMeeting() async throws {
        var detector = BrowserMeetingDetector(freshnessWindow: 5)
        var now = 100.0
        detector.sensorConnected(at: now)
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .inCall,
                timestamp: now, meetingID: "abc-defg-hij"
            ),
            at: now
        )
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - abc-defg-hij"]
        )
        #expect(detector.update(native: native, at: now).source == .browserSensor)

        // The extension stops reporting. Native evidence carries the meeting.
        now += 30
        let fallback = detector.update(native: native, at: now)
        #expect(fallback.source == .native)
        #expect(fallback.confidence == .confirmed, "the meeting must not vanish")
        #expect(fallback.meetingID == "abc-defg-hij")
        #expect(detector.sensor.connection == .stale)
    }

    @Test("a refresh does not look like a leave")
    func aRefreshDoesNotLookLikeALeave() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let live = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: live, at: now)
        now += 25
        #expect(detector.update(native: live, at: now).confidence == .confirmed)

        // Measured refresh: microphone drops for 1.486 s and comes back with
        // the same meeting ID.
        now += 0.5
        let dropped = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: false,
            windowTitles: ["Meet"]
        )
        #expect(detector.update(native: dropped, at: now).confidence == .candidate)
        now += 1.5
        let back = detector.update(native: live, at: now)
        #expect(back.meetingID == "hzc-josd-epv")
    }

    @Test("a provider's own tab title decoration comes off the meeting name")
    func aProviderSOwnTabTitleDecorationComesOffTheMeetingName() async throws {
        #expect(BrowserWindowTitle.meetingName("Meet - Hindsight Daily") == "Hindsight Daily")
        #expect(
            BrowserWindowTitle.meetingName("Meet - abc-defg-hij") == nil,
            "a meeting code is not a name"
        )
        #expect(BrowserWindowTitle.meetingName("Google Meet") == nil)
        #expect(BrowserWindowTitle.meetingName("Standup - Zoom") == "Standup")
        #expect(BrowserWindowTitle.meetingName("Zoom") == nil)
        #expect(
            BrowserWindowTitle.meetingName("Design review") == "Design review",
            "a title from a provider with no rules is left alone"
        )
    }

    @Test("the extension's raw tab title is cleaned before it names the meeting")
    func theExtensionSRawTabTitleIsCleanedBeforeItNamesTheMeeting() async throws {
        // The extension sends document.title untouched, and it won
        // over the parsed title, so every Meet call was filed as
        // "Meet - something".
        var detector = BrowserMeetingDetector(freshnessWindow: 5)
        let now = 100.0
        detector.sensorConnected(at: now)
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .inCall,
                timestamp: now, meetingID: "abc-defg-hij",
                title: "Meet - Hindsight Daily"
            ),
            at: now
        )
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true, windowTitles: []
        )
        #expect(detector.update(native: native, at: now).title == "Hindsight Daily")
    }

    @Test("meeting identifiers come out of provider URLs")
    func meetingIdentifiersComeOutOfProviderURLs() async throws {
        #expect(
            MeetingURLParser.meetingID(forURL: "https://meet.google.com/jfp-btbt-owm") == "jfp-btbt-owm"
        )
        #expect(
            MeetingURLParser.meetingID(forURL: "https://app.zoom.us/wc/81771591841/join") == "81771591841"
        )
        #expect(MeetingURLParser.provider(forURL: "https://app.zoom.us/wc/1/join") == .zoom)
        #expect(MeetingURLParser.provider(forURL: "https://example.com") == nil)
    }
}

@Suite("GenericCallDetector")
struct GenericCallDetectorTests {
    @Test("system speech services never become a meeting")
    func systemSpeechServicesNeverBecomeAMeeting() async throws {
        var detector = GenericCallDetector()
        var now = 100.0
        // corespeechd held the microphone for the whole observed session.
        let states = [
            ApplicationAudioState(
                bundleIdentifier: "com.apple.CoreSpeech", processID: 808,
                holdsMicrophone: true, producesOutput: false,
                isFrontmost: false, windowTitle: nil
            ),
        ]
        for _ in 0..<400 {
            now += 0.5
            #expect(detector.update(states: states, at: now) == [])
        }
    }

    @Test("a remote desktop session is never a meeting")
    func aRemoteDesktopSessionIsNeverAMeeting() async throws {
        // Jump Desktop Connect holds the microphone and plays audio for as
        // long as the session lasts, which is every signal the detector
        // has. It recorded a remote-desktop session as a call.
        var detector = GenericCallDetector()
        let states = [
            ApplicationAudioState(
                bundleIdentifier: "com.p5sys.jump.connect", processID: 500,
                holdsMicrophone: true, producesOutput: true,
                isFrontmost: false, windowTitle: nil
            ),
            ApplicationAudioState(
                bundleIdentifier: "com.apple.ScreenSharing", processID: 501,
                holdsMicrophone: true, producesOutput: true,
                isFrontmost: false, windowTitle: nil
            ),
        ]
        var now = 100.0
        for _ in 0..<200 {
            now += 0.5
            #expect(detector.update(states: states, at: now) == [])
        }
        #expect(detector.currentEvidence().count == 0, "nothing to record here")
    }

    @Test("an unknown call is a candidate before it is confirmed")
    func anUnknownCallIsACandidateBeforeItIsConfirmed() async throws {
        // The ring has to be armed while the dwell is still running,
        // otherwise the first eight to twenty-five seconds of the call
        // exist nowhere by the time it is promoted.
        var detector = GenericCallDetector()
        let states = [
            ApplicationAudioState(
                bundleIdentifier: "com.example.videochat", processID: 4242,
                holdsMicrophone: true, producesOutput: true,
                isFrontmost: true, windowTitle: "Team call"
            ),
        ]
        _ = detector.update(states: states, at: 100)
        let early = detector.currentEvidence()
        #expect(early.count == 1)
        #expect(early.first?.confidence == .candidate, "armed but not committed")
        #expect(early.first?.audioBundlePrefixes == ["com.example.videochat"])

        _ = detector.update(states: states, at: 100 + 9)
        let promoted = detector.currentEvidence()
        #expect(promoted.first?.confidence == .confirmed, "the dwell has passed")

        // An ignored process never reaches the evidence at all.
        _ = detector.update(states: [
            ApplicationAudioState(
                bundleIdentifier: "com.apple.CoreSpeech", processID: 808,
                holdsMicrophone: true, producesOutput: false,
                isFrontmost: false, windowTitle: nil
            ),
        ], at: 110)
        #expect(
            !(detector.currentEvidence().contains { $0.applicationBundleID == "com.apple.CoreSpeech" }),
            "the ignore list keeps system services out entirely"
        )
    }

    @Test("a sustained two-way call in an unknown app is promoted")
    func aSustainedTwoWayCallInAnUnknownAppIsPromoted() async throws {
        var detector = GenericCallDetector()
        var now = 100.0
        let states = [
            ApplicationAudioState(
                bundleIdentifier: "com.example.videochat", processID: 4_242,
                holdsMicrophone: true, producesOutput: true,
                isFrontmost: true, windowTitle: "Team call"
            ),
        ]
        var promoted: GenericCallDetector.Candidate?
        for _ in 0..<40 {
            now += 0.5
            for event in detector.update(states: states, at: now) {
                if case .callLikely(let candidate) = event { promoted = candidate }
            }
            if promoted != nil { break }
        }
        let candidate = try #require(promoted)
        #expect(candidate.bundleIdentifier == "com.example.videochat")
        #expect(candidate.hasTwoWayAudio)
        #expect(candidate.heldForSeconds >= 8)
    }

    @Test("an application the user always records starts immediately")
    func anApplicationTheUserAlwaysRecordsStartsImmediately() async throws {
        var detector = GenericCallDetector(
            configuration: .init(alwaysRecord: ["com.example.videochat"])
        )
        let events = detector.update(
            states: [
                ApplicationAudioState(
                    bundleIdentifier: "com.example.videochat", processID: 1,
                    holdsMicrophone: true, producesOutput: false,
                    isFrontmost: true, windowTitle: nil
                ),
            ],
            at: 100
        )
        guard case .callLikely(let candidate) = events.first else {
            Issue.record("expected an immediate candidate, got \(events)")
            return
        }
        #expect(candidate.isPreapproved)
    }

    @Test("an application the user always records preapproves its helpers")
    func anApplicationTheUserAlwaysRecordsPreapprovesItsHelpers() async throws {
        // The two lists hold applications, and the microphone is held by
        // a helper. Matching one list on the application and the other on
        // the raw process left always-record working only for the
        // applications that have no helpers.
        var detector = GenericCallDetector(
            configuration: .init(alwaysRecord: ["com.openai.chat"])
        )
        let events = detector.update(
            states: [
                ApplicationAudioState(
                    bundleIdentifier: "com.openai.chat.helper.Renderer", processID: 1,
                    holdsMicrophone: true, producesOutput: false,
                    isFrontmost: true, windowTitle: nil
                ),
            ],
            at: 100
        )
        guard case .callLikely(let candidate) = events.first else {
            Issue.record("expected an immediate candidate, got \(events)")
            return
        }
        #expect(candidate.isPreapproved)
    }

    @Test("an application the user never records is ignored")
    func anApplicationTheUserNeverRecordsIsIgnored() async throws {
        var detector = GenericCallDetector(
            configuration: .init(neverRecord: ["com.example.videochat"])
        )
        var now = 100.0
        for _ in 0..<200 {
            now += 0.5
            #expect(
                detector.update(
                    states: [
                        ApplicationAudioState(
                            bundleIdentifier: "com.example.videochat", processID: 1,
                            holdsMicrophone: true, producesOutput: true,
                            isFrontmost: true, windowTitle: nil
                        ),
                    ],
                    at: now
                ) == []
            )
        }
    }

    @Test("never record takes effect while the app still holds the microphone")
    func neverRecordTakesEffectWhileTheAppStillHoldsTheMicrophone() async throws {
        // The user answers the provisional prompt with "never record this
        // app" while the call is still live. The tracked entry kept
        // publishing confirmed evidence for the six-second end grace,
        // which restarted the provisional recording and asked again.
        var detector = GenericCallDetector()
        let states = [
            ApplicationAudioState(
                bundleIdentifier: "com.example.videochat", processID: 4_242,
                holdsMicrophone: true, producesOutput: true,
                isFrontmost: true, windowTitle: "Team call"
            ),
        ]
        _ = detector.update(states: states, at: 100)
        _ = detector.update(states: states, at: 109)
        #expect(detector.currentEvidence().first?.confidence == .confirmed)

        detector.configuration.neverRecord = ["com.example.videochat"]
        let events = detector.update(states: states, at: 109.5)
        #expect(events == [.callEnded(bundleIdentifier: "com.example.videochat")])
        #expect(
            detector.currentEvidence().count == 0,
            "the ban is immediate, not after the end grace"
        )
    }

    @Test("a ban recorded against a helper covers the whole application")
    func aBanRecordedAgainstAHelperCoversTheWholeApplication() async throws {
        // CoreAudio names whichever helper opened the microphone, and an
        // Electron application rotates through .helper, .helper.Renderer
        // and .helper.GPU. Stored as reported, the ban missed both the
        // siblings and the application itself, so the next poll that
        // found a different helper asked again.
        #expect(
            MicrophoneIgnoreList.applicationIdentifier(for: "com.openai.chat.helper.Renderer") == "com.openai.chat"
        )
        #expect(
            MicrophoneIgnoreList.applicationIdentifier(for: "com.tinyspeck.slackmacgap.helper") == "com.tinyspeck.slackmacgap"
        )
        // A two-component vendor identifier still normalises: Notion ships
        // as notion.id, with its helpers under notion.id.helper.
        #expect(
            MicrophoneIgnoreList.applicationIdentifier(for: "notion.id.helper.Renderer") == "notion.id"
        )
        // An application that is not a helper is stored exactly as it is.
        #expect(
            MicrophoneIgnoreList.applicationIdentifier(for: "com.example.videochat") == "com.example.videochat"
        )
        // Nothing is ever collapsed to one component: a ban on "com"
        // would prefix-match most of the machine.
        #expect(
            MicrophoneIgnoreList.applicationIdentifier(for: "com.helper.app") == "com.helper.app"
        )
        #expect(
            MicrophoneIgnoreList.applicationIdentifier(for: "com.acme.helperapp") == "com.acme.helperapp"
        )

        // Each sibling is held past the dwell it would otherwise promote
        // at, so the ban is what keeps it out rather than the clock.
        let banned = MicrophoneIgnoreList.applicationIdentifier(
            for: "com.openai.chat.helper.Renderer"
        )
        var detector = GenericCallDetector(configuration: .init(neverRecord: [banned]))
        var when = 100.0
        for sibling in [
            "com.openai.chat", "com.openai.chat.helper", "com.openai.chat.helper.GPU",
        ] {
            for _ in 0..<60 {
                when += 0.5
                #expect(
                    detector.update(
                        states: [
                            ApplicationAudioState(
                                bundleIdentifier: sibling, processID: 1,
                                holdsMicrophone: true, producesOutput: true,
                                isFrontmost: true, windowTitle: nil
                            ),
                        ],
                        at: when
                    ) == [],
                    "\(sibling) belongs to an application the user banned"
                )
            }
            #expect(detector.currentEvidence().count == 0, "\(sibling) is not evidence")
        }
    }

    @Test("Pipit's own helpers are never a meeting")
    func pipitSOwnHelpersAreNeverAMeeting() async throws {
        // Its capture holds the microphone for the length of every
        // recording, and it is the helper that would hold it.
        var detector = GenericCallDetector()
        var when = 100.0
        for _ in 0..<60 {
            when += 0.5
            #expect(
                detector.update(
                    states: [
                        ApplicationAudioState(
                            bundleIdentifier: "com.pipit.app.helper", processID: 1,
                            holdsMicrophone: true, producesOutput: true,
                            isFrontmost: false, windowTitle: nil
                        ),
                    ],
                    at: when
                ) == []
            )
        }
        #expect(detector.currentEvidence().count == 0)
    }

    @Test("never record covers a descendant of a banned identifier")
    func neverRecordCoversADescendantOfABannedIdentifier() async throws {
        var detector = GenericCallDetector(
            configuration: .init(neverRecord: ["com.example.videochat"])
        )
        var now = 100.0
        for _ in 0..<200 {
            now += 0.5
            #expect(
                detector.update(
                    states: [
                        ApplicationAudioState(
                            bundleIdentifier: "com.example.videochat.helper.Renderer",
                            processID: 1,
                            holdsMicrophone: true, producesOutput: true,
                            isFrontmost: true, windowTitle: nil
                        ),
                    ],
                    at: now
                ) == []
            )
        }
        #expect(detector.currentEvidence().count == 0)
    }
}
