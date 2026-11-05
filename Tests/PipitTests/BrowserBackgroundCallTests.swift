import Foundation
import PipitCore
import Testing

@Suite("BrowserMeetingDetector background calls")
struct BrowserBackgroundCallTests {
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

    @Test("another app opening the microphone after a call ended is not that call once the title memory runs out")
    func aMicrophoneReopenedAfterTheCallEndedIsNotTheOldCallOnceTheMemoryRunsOut() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let call = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        _ = detector.update(native: call, at: now)
        now += 30
        #expect(detector.update(native: call, at: now).confidence == .confirmed)

        let left = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: false,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 1
        _ = detector.update(native: left, at: now)
        now += 14
        #expect(detector.update(native: left, at: now).confidence == .none)

        // Another web app opens the microphone well inside the title memory.
        let elsewhere = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Standup - Other App"]
        )
        now += 15
        _ = detector.update(native: elsewhere, at: now)
        // The old title ages out after the usual memory, as it always did.
        now += 110
        #expect(detector.update(native: elsewhere, at: now).confidence == .none)
        now += 200
        #expect(detector.update(native: elsewhere, at: now).confidence == .none)
    }

    @Test("a meeting title only glanced at is not a call once the title memory runs out")
    func aGlancedTitleIsNotACallOnceTheMemoryRunsOut() async throws {
        var detector = BrowserMeetingDetector()
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: false, browserProducesOutput: false,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: 100
        )
        let elsewhere = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Voice memo - Recorder"]
        )
        _ = detector.update(native: elsewhere, at: 200)
        #expect(detector.update(native: elsewhere, at: 230).confidence == .none)
        #expect(detector.update(native: elsewhere, at: 600).confidence == .none)
    }

    @Test("an add-on that only reported a waiting page has not reported the call")
    func aPrejoinReportDoesNotCountAsReportingTheCall() async throws {
        // If in-call detection breaks, the add-on says prejoin and then browsing.
        // That must cost extra recording, never the meeting.
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let call = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - hzc-josd-epv"]
        )
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .googleMeet, state: .prejoin, timestamp: now,
                meetingID: "hzc-josd-epv", tabID: 1
            ),
            at: now
        )
        _ = detector.update(native: call, at: now)
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        for _ in 0..<80 {
            now += 5
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .googleMeet, state: .browsing, timestamp: now, tabID: 1
                ),
                at: now
            )
            _ = detector.update(native: otherTab, at: now)
        }
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)
    }

    @Test("a second Zoom call the extension cannot see is not dropped because the first one was reported")
    func aSecondZoomCallDoesNotInheritTheFirstOnesReport() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let first = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Standup - Zoom"]
        )
        for _ in 0...5 {
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .zoom, state: .inCall, timestamp: now, tabID: 1
                ),
                at: now
            )
            _ = detector.update(native: first, at: now)
            now += 5
        }
        // The first call ends and the microphone is released.
        let idle = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: false, browserProducesOutput: false,
            windowTitles: ["Quarterly plan - Docs"]
        )
        detector.closeTab(1, at: now)
        _ = detector.update(native: idle, at: now)
        now += 15
        _ = detector.update(native: idle, at: now)

        // A second call, in a place the extension does not run, within the memory.
        now += 15
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Design review - Zoom"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        for _ in 0..<30 {
            now += 10
            let evidence = detector.update(native: otherTab, at: now)
            #expect(evidence.provider == .zoom)
            if now > 190 { #expect(evidence.confidence == .confirmed) }
        }
    }

    @Test("a different meeting's title clears the first meeting's report")
    func aDifferentMeetingsTitleClearsTheFirstMeetingsReport() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let first = BrowserMeetingDetector.NativeSignals(
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
            _ = detector.update(native: first, at: now)
            now += 5
        }
        // The microphone stays open while the browser moves to another call
        // the extension never reports.
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Meet - abc-defg-hij"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        for _ in 0..<30 {
            now += 10
            let evidence = detector.update(native: otherTab, at: now)
            if now > 190 {
                #expect(evidence.confidence == .confirmed)
                #expect(evidence.meetingID == "abc-defg-hij")
            }
        }
    }

    @Test("a browser's own suffix after the Zoom title does not hide the meeting page")
    func aBrowserSuffixAfterTheZoomTitleStillArmsTheMemory() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Design review - Zoom \u{2014} Private Browsing"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 300
        #expect(detector.update(native: otherTab, at: now).confidence == .confirmed)
    }

    @Test("an unrelated page that mentions Zoom does not keep a call alive in the background")
    func aPageMentioningZoomDoesNotKeepACallAlive() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        let mail = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Invoice for Zoom subscription - Mail"]
        )
        _ = detector.update(native: mail, at: now)
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 300
        #expect(detector.update(native: otherTab, at: now).confidence == .none)
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
}
