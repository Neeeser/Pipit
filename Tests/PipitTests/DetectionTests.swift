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
        let dm = try #require(SlackWindowTitle.parse("Rowan Ashby (DM) - Larkfield - Slack"))
        #expect(dm.conversation == "Rowan Ashby")
        #expect(dm.kind == .directMessage)
        #expect(dm.workspace == "Larkfield")

        let channel = try #require(
            SlackWindowTitle.parse("larkfield-booking (Channel) - Northwind - Slack")
        )
        #expect(channel.conversation == "larkfield-booking")
        #expect(channel.kind == .channel)

        let decorated = try #require(
            SlackWindowTitle.parse("marlow.fenn595 (DM) - Northwind - Slack [Main] 🏠🔊")
        )
        #expect(decorated.conversation == "marlow.fenn595")
        #expect(decorated.workspace == "Northwind")

        let preview = try #require(SlackWindowTitle.parse("Slack - Huddle Preview"))
        #expect(preview.isHuddlePreview)
    }

    @Test("a title with no conversation in it names nothing")
    func aTitleWithNoConversationInItNamesNothing() async throws {
        // Slack publishes "- Northwind - Slack" while a conversation is
        // loading. Read as a name it became the meeting's title, and a
        // huddle was filed and announced as "- Northwind".
        #expect(
            SlackWindowTitle.parse("- Northwind - Slack") == nil,
            "a leading separator is not a conversation name"
        )
        #expect(SlackWindowTitle.parse(" (DM) - Northwind - Slack") == nil)
        #expect(SlackWindowTitle.parse("Northwind - Slack")?.conversation == "Northwind")

        // And the last real name survives the moment the title is empty.
        var detector = SlackHuddleDetector()
        _ = detector.update(
            observation: Self.idle(title: "marlow.fenn595 (DM) - Northwind - Slack"),
            helperHoldsMicrophone: false, helperProducingOutput: false, at: 100
        )
        _ = detector.update(
            observation: Self.idle(title: "- Northwind - Slack"),
            helperHoldsMicrophone: false, helperProducingOutput: false, at: 101
        )
        #expect(detector.conversationTitle == "marlow.fenn595")
    }

    @Test("browsing to another conversation mid-huddle keeps the huddle's name")
    func browsingToAnotherConversationMidHuddleKeepsTheHuddlesName() async throws {
        // Slack's window title follows whichever conversation is open, so
        // opening another DM during a call renamed the meeting after it.
        var detector = SlackHuddleDetector()
        _ = detector.update(
            observation: DetectionFixtures.joined(title: "Rowan Ashby (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: 100
        )
        #expect(detector.state == .joined)
        _ = detector.update(
            observation: DetectionFixtures.joined(title: "Ines Calloway (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: 101
        )
        #expect(detector.conversationTitle == "Rowan Ashby")
    }

    @Test("the name is taken when Slack opens the microphone, not when the join is seen")
    func theNameIsTakenWhenSlackOpensTheMicrophone() async throws {
        var detector = SlackHuddleDetector()
        _ = detector.update(
            observation: Self.idle(title: "Rowan Ashby (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: false, at: 100
        )
        #expect(detector.state == .candidate)
        _ = detector.update(
            observation: Self.idle(title: "Ines Calloway (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: 105
        )
        _ = detector.update(
            observation: DetectionFixtures.joined(title: "Ines Calloway (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: 110
        )
        #expect(detector.state == .joined)
        #expect(detector.conversationTitle == "Rowan Ashby")
    }

    @Test("a huddle preview gives way to the conversation's name")
    func aHuddlePreviewGivesWayToTheConversationsName() async throws {
        var detector = SlackHuddleDetector()
        _ = detector.update(
            observation: Self.idle(title: "Slack - Huddle Preview"),
            helperHoldsMicrophone: true, helperProducingOutput: false, at: 100
        )
        _ = detector.update(
            observation: DetectionFixtures.joined(title: "Rowan Ashby (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: 105
        )
        #expect(detector.conversationTitle == "Rowan Ashby")
    }

    @Test("after the huddle ends the name follows Slack again")
    func afterTheHuddleEndsTheNameFollowsSlackAgain() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        _ = detector.update(
            observation: DetectionFixtures.joined(title: "Rowan Ashby (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: now
        )
        while detector.state != .idle, now < 130 {
            now += 0.5
            _ = detector.update(
                observation: Self.idle(title: "Rowan Ashby (DM) - Larkfield - Slack"),
                helperHoldsMicrophone: false, helperProducingOutput: false, at: now
            )
        }
        #expect(detector.state == .idle)
        _ = detector.update(
            observation: Self.idle(title: "Ines Calloway (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: false, helperProducingOutput: false, at: now + 1
        )
        #expect(detector.conversationTitle == "Ines Calloway")
    }

    @Test("a finished huddle's name does not carry into the next one")
    func aFinishedHuddlesNameDoesNotCarryIntoTheNextOne() async throws {
        var detector = SlackHuddleDetector()
        var now = 100.0
        _ = detector.update(
            observation: DetectionFixtures.joined(title: "Rowan Ashby (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: true, at: now
        )
        // Slack publishes a title with no conversation in it while one loads.
        let loading = Self.idle(title: "- Larkfield - Slack")
        while detector.state != .idle, now < 130 {
            now += 0.5
            _ = detector.update(
                observation: loading, helperHoldsMicrophone: false,
                helperProducingOutput: false, at: now
            )
        }
        #expect(detector.state == .idle)
        // The next huddle opens the microphone before a real title arrives.
        _ = detector.update(
            observation: loading, helperHoldsMicrophone: true,
            helperProducingOutput: false, at: now + 0.5
        )
        #expect(detector.state == .candidate)
        _ = detector.update(
            observation: Self.idle(title: "Ines Calloway (DM) - Larkfield - Slack"),
            helperHoldsMicrophone: true, helperProducingOutput: false, at: now + 1
        )
        #expect(detector.conversationTitle == "Ines Calloway")
    }

    private static func idle(title: String) -> SlackAccessibilityObservation {
        SlackAccessibilityObservation(
            hasLeaveHuddleControl: false, subtreeWasEmpty: false, windowTitle: title
        )
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

    @Test("a provider page without a meeting in its address is not a candidate")
    func aProviderPageWithoutAMeetingInItsAddressIsNotACandidate() async throws {
        // The extension runs on every page of a provider's site. Zoom's
        // Workplace home shows a join control, so it reported a prejoin for
        // as long as the tab stayed open, and capture stayed armed for
        // hours after the call the tab was opened for had ended. A prejoin
        // or a waiting room carries the meeting in its address.
        var detector = BrowserMeetingDetector()
        let now = 100.0
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: true, windowTitles: ["Zoom"]
        )
        detector.sensorConnected(at: now)
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .zoom, state: .prejoin,
                timestamp: now, url: "https://app.zoom.us/wc", meetingID: nil, tabID: 1
            ),
            at: now
        )
        #expect(detector.update(native: native, at: now).confidence == .none)

        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .zoom, state: .prejoin,
                timestamp: now + 0.5, url: "https://app.zoom.us/wc/81771591841/join",
                meetingID: "81771591841", tabID: 2
            ),
            at: now + 0.5
        )
        #expect(detector.update(native: native, at: now + 0.5).confidence == .candidate)
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
            windowTitles: ["Marlow Fenn's Zoom Meeting"]
        )
        let first = detector.update(native: titleOnly, at: now)
        #expect(first.provider == .zoom)
        #expect(first.confidence == .none, "a title alone is not a meeting")

        now += 5.3
        let withMic = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Marlow Fenn's Zoom Meeting"]
        )
        #expect(detector.update(native: withMic, at: now).confidence == .candidate)
        now += 21
        let confirmed = detector.update(native: withMic, at: now)
        #expect(confirmed.confidence == .confirmed)
        #expect(confirmed.title == "Marlow Fenn's Zoom Meeting")
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

    @Test("a call in a background tab stays a meeting while the browser keeps the microphone")
    func aCallInABackgroundTabStaysAMeeting() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let onCall = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: onCall, at: now)
        now += 25
        #expect(detector.update(native: onCall, at: now).confidence == .confirmed)

        // The person switches to another tab in the same window. The window
        // title is now that tab's, and the call keeps the microphone open.
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        for _ in 0..<300 {
            now += 1
            let evidence = detector.update(native: otherTab, at: now)
            #expect(evidence.confidence == .confirmed)
            #expect(evidence.provider == .googleMeet)
        }
    }

    @Test("a refresh in a background tab does not end the call")
    func aRefreshInABackgroundTabDoesNotEndTheCall() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 200
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)

        let dropped = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 0.5
        #expect(detector.update(native: dropped, at: now).confidence == .candidate)
        now += 1.5
        #expect(detector.update(native: otherTab, at: now).provider == .googleMeet)
        now += 25
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)
    }

    @Test("a background call ends when the browser lets go of the microphone")
    func aBackgroundCallEndsWhenTheMicrophoneIsReleased() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: now
        )
        now += 25
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 200
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)

        // Leaving the call releases the microphone. Past the refresh grace the
        // title remembered from minutes ago no longer stands for anything.
        let left = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: false,
            windowTitles: ["Quarterly plan - Docs"]
        )
        _ = detector.update(native: left, at: now + 1)
        #expect(detector.update(native: left, at: now + 15).confidence == .none)

        // The microphone opens again for something else. The call it was held
        // for is over, so the remembered title must not claim the new use.
        _ = detector.update(native: otherTab, at: now + 20)
        #expect(detector.update(native: otherTab, at: now + 45).confidence == .none)
    }

    @Test("without the extension, a ready-to-join page with the microphone open records like a call")
    func aReadyToJoinPageWithTheMicrophoneOpenRecordsLikeACall() async throws {
        // Window titles and microphone use cannot tell a Meet page waiting to
        // be joined from a joined call, and the output flag is not a signal the
        // detector reads. Pinned as the chosen trade-off: a missed meeting costs
        // more than a recording of a waiting page.
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let waiting = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: false,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: waiting, at: now)
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: false,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 300
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)
    }

    @Test("with the extension loaded, a closed meeting tab ends the meeting after the usual memory")
    func aClosedTabEndsTheMeetingWhileTheExtensionIsLoaded() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let call = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        // The extension reports the call every few seconds until the tab closes.
        for _ in 0...5 {
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .googleMeet, state: .inCall, timestamp: now,
                    meetingID: "hzc-josd-epv", tabID: 1
                ),
                at: now
            )
            _ = detector.update(native: call, at: now)
            now += 5
        }
        #expect(detector.update(native: call, at: now).confidence == .confirmed)

        // The tab closes while another page keeps the browser's microphone open
        // for an unrelated reason. The extension reported this call, so its
        // silence now means the call is over.
        detector.closeTab(1, at: now)
        let elsewhere = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Voice memo - Recorder"]
        )
        now += 1
        let justClosed = detector.update(native: elsewhere, at: now)
        #expect(justClosed.source == .native, "the closed tab's report is gone, not merely stale")
        now += 150
        #expect(detector.update(native: elsewhere, at: now).confidence == .none)
    }

    @Test("with the extension loaded but blind to the call, a background call keeps recording")
    func aCallTheExtensionNeverReportedStaysAMeeting() async throws {
        // A call in another Chromium browser, a private window, or a profile
        // the add-on does not run in: the add-on says hello but never mentions
        // this call, so its silence says nothing about it.
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let call = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: call, at: now)
        now += 25
        #expect(detector.update(native: call, at: now).confidence == .confirmed)

        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        for _ in 0..<60 {
            now += 5
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .unknown, state: .browsing, timestamp: now, tabID: 7
                ),
                at: now
            )
            #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)
        }
    }

    @Test("with the extension loaded, a call it reports ended is not kept alive by the microphone")
    func anEndedReportWinsOverTheMicrophoneWhileTheExtensionIsLoaded() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let call = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        for _ in 0...5 {
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .googleMeet, state: .inCall, timestamp: now,
                    meetingID: "hzc-josd-epv", tabID: 1
                ),
                at: now
            )
            _ = detector.update(native: call, at: now)
            now += 5
        }
        #expect(detector.update(native: call, at: now).confidence == .confirmed)

        // Another web app starts a call in the same browser.
        let elsewhere = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Standup - Other App"]
        )
        now += 150
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .ended, timestamp: now, tabID: 1
            ),
            at: now
        )
        #expect(detector.update(native: elsewhere, at: now).confidence == .none)
    }

    @Test("a microphone that opens after the title has left the screen still ties the call to the browser")
    func aMicrophoneOpeningAfterTheTitleStillHoldsTheCall() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        // Zoom's page shows its title before the microphone opens.
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: false, browserProducesOutput: false,
                windowTitles: ["Standup - Zoom"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 5
        _ = detector.update(native: otherTab, at: now)
        now += 300
        let evidence = detector.update(native: otherTab, at: now)
        #expect(evidence.confidence == .confirmed)
        #expect(evidence.provider == .zoom)
    }

    @Test("a short microphone drop on the tick the title is visible does not forget the call")
    func aShortMicrophoneDropWhileSwitchingTabsKeepsTheCall() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let call = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: call, at: now)
        now += 30
        _ = detector.update(native: call, at: now)
        // The microphone drops for a moment as the person switches tabs, and the
        // title is still the last thing on screen.
        now += 1
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: false, browserProducesOutput: true,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 1
        _ = detector.update(native: otherTab, at: now)
        now += 300
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)
    }

    @Test("with the extension loaded, a background call it reports stays a meeting")
    func aBackgroundCallStaysWhileTheExtensionReportsIt() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        for _ in 0..<60 {
            now += 5
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .googleMeet, state: .inCall, timestamp: now,
                    meetingID: "hzc-josd-epv", tabID: 1
                ),
                at: now
            )
            let evidence = detector.update(native: otherTab, at: now)
            #expect(evidence.confidence == .confirmed)
            #expect(evidence.meetingID == "hzc-josd-epv")
        }
    }

    @Test("a meeting window among several keeps the call, and a bare landing title does not confirm one")
    func severalWindowsAndALandingTitle() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let windows = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs", "Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: windows, at: now)
        now += 25
        let call = detector.update(native: windows, at: now)
        #expect(call.confidence == .confirmed)
        #expect(call.meetingID == "hzc-josd-epv")

        // The only titles left are a Meet home page and another app's page.
        let landing = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet", "Quarterly plan - Docs"]
        )
        now += 200
        let afterwards = detector.update(native: landing, at: now)
        #expect(afterwards.confidence == .candidate)
        #expect(afterwards.meetingID == nil)
    }

    @Test("a meeting title seen without the microphone is forgotten")
    func aTitleSeenWithoutTheMicrophoneIsForgotten() async throws {
        var detector = BrowserMeetingDetector()
        // A Meet tab that was looked at but never joined.
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: false, browserProducesOutput: false,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: 100
        )
        // The microphone opens minutes later for something else entirely.
        let elsewhere = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Voice memo - Recorder"]
        )
        _ = detector.update(native: elsewhere, at: 300)
        #expect(detector.update(native: elsewhere, at: 330).confidence == .none)
    }

    @Test("a provider's own tab title decoration comes off the meeting name")
    func aProviderSOwnTabTitleDecorationComesOffTheMeetingName() async throws {
        #expect(BrowserWindowTitle.meetingName("Meet - Northwind Daily") == "Northwind Daily")
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
                title: "Meet - Northwind Daily"
            ),
            at: now
        )
        let native = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true, windowTitles: []
        )
        #expect(detector.update(native: native, at: now).title == "Northwind Daily")
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
            )
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
            )
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
        _ = detector.update(
            states: [
                ApplicationAudioState(
                    bundleIdentifier: "com.apple.CoreSpeech", processID: 808,
                    holdsMicrophone: true, producesOutput: false,
                    isFrontmost: false, windowTitle: nil
                )
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
            )
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
                )
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
                )
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
                        )
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
            )
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
            MicrophoneIgnoreList.applicationIdentifier(for: "com.tinyspeck.slackmacgap.helper")
                == "com.tinyspeck.slackmacgap"
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
                            )
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
                        )
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
                        )
                    ],
                    at: now
                ) == []
            )
        }
        #expect(detector.currentEvidence().count == 0)
    }
}
