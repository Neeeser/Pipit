import Foundation
import PipitCore
import Testing

@Suite("BrowserMeetingDetector reported calls")
struct BrowserReportedCallTests {
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

    @Test("a window with a page that only mentions Zoom does not outrank the call's window")
    func aMailWindowDoesNotOutrankTheCallWindow() async throws {
        for titles in [
            ["Invoice for Zoom subscription - Mail", "Meet - hzc-josd-epv"],
            ["Meet - hzc-josd-epv", "Invoice for Zoom subscription - Mail"],
        ] {
            var detector = BrowserMeetingDetector()
            var now = 100.0
            let windows = BrowserMeetingDetector.NativeSignals(
                browserHoldsMicrophone: true, browserProducesOutput: true, windowTitles: titles
            )
            _ = detector.update(native: windows, at: now)
            let otherTab = BrowserMeetingDetector.NativeSignals(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Quarterly plan - Docs"]
            )
            now += 300
            let evidence = detector.update(native: otherTab, at: now)
            #expect(evidence.confidence == .confirmed)
            #expect(evidence.provider == .googleMeet)
        }
    }

    @Test("a back-to-back call the extension cannot see does not inherit the first call's report")
    func aBackToBackCallDoesNotInheritTheFirstCallsReport() async throws {
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
                    browser: .firefox, provider: .zoom, state: .inCall, timestamp: now,
                    meetingID: "123456789", title: "Standup - Zoom", tabID: 1
                ),
                at: now
            )
            _ = detector.update(native: first, at: now)
            now += 5
        }
        // The second call starts five seconds later, in a place the extension
        // does not run, and the microphone never lets go in between.
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
            if now > 190 { #expect(evidence.confidence == .confirmed) }
        }
    }

    @Test("a glance at a page that mentions Zoom does not relabel a Meet call")
    func aMentionOfZoomDoesNotRelabelAMeetCall() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: now
        )
        now += 30
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Invoice for Zoom subscription - Mail"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 300
        let evidence = detector.update(native: otherTab, at: now)
        #expect(evidence.provider == .googleMeet)
        #expect(evidence.meetingID == "hzc-josd-epv")
        #expect(evidence.confidence == .confirmed)
    }

    @Test("a browser's suffix is not part of the stored meeting name or code")
    func aBrowserSuffixIsNotPartOfTheMeetingNameOrCode() async throws {
        let zoom = BrowserWindowTitle.parse("Design review - Zoom \u{2014} Private Browsing")
        #expect(zoom?.title == "Design review")
        let named = BrowserWindowTitle.parse("Marlow's Zoom Meeting \u{2014} Private Browsing")
        #expect(named?.title == "Marlow's Zoom Meeting")
        let meet = BrowserWindowTitle.parse("Meet - hzc-josd-epv \u{2014} Private Browsing")
        #expect(meet?.meetingID == "hzc-josd-epv")
        let chrome = BrowserWindowTitle.parse("Meet - hzc-josd-epv - Google Chrome - Person 1")
        #expect(chrome?.meetingID == "hzc-josd-epv")
    }

    @Test("a coded Meet call the extension cannot see does not inherit a named call's report")
    func aCodedMeetCallDoesNotInheritANamedCallsReport() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        detector.sensorConnected(at: now)
        let named = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet - Northwind Daily"]
        )
        for _ in 0...5 {
            detector.receive(
                BrowserMeetingEvent(
                    browser: .firefox, provider: .googleMeet, state: .inCall, timestamp: now,
                    meetingID: "aaa-bbbb-ccc", title: "Meet - Northwind Daily", tabID: 1
                ),
                at: now
            )
            _ = detector.update(native: named, at: now)
            now += 5
        }
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
        for _ in 0..<30 {
            now += 10
            let evidence = detector.update(native: otherTab, at: now)
            if now > 190 {
                #expect(evidence.confidence == .confirmed)
                #expect(evidence.meetingID == "hzc-josd-epv")
            }
        }
    }

    @Test("a mail or document title that mentions Zoom does not relabel a background Meet call")
    func aMailTitleWithAZoomLabelDoesNotRelabelAMeetCall() async throws {
        var detector = BrowserMeetingDetector()
        var now = 100.0
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Meet - hzc-josd-epv"]
            ),
            at: now
        )
        now += 30
        _ = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Agenda - Zoom - me@example.com - Gmail"]
            ),
            at: now
        )
        let otherTab = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Quarterly plan - Docs"]
        )
        now += 300
        let evidence = detector.update(native: otherTab, at: now)
        #expect(evidence.provider == .googleMeet)
        #expect(evidence.meetingID == "hzc-josd-epv")
    }

    @Test("the extension's evidence does not borrow another provider's window title")
    func theExtensionsEvidenceDoesNotBorrowAnotherProvidersTitle() async throws {
        var detector = BrowserMeetingDetector()
        let now = 100.0
        detector.sensorConnected(at: now)
        detector.receive(
            BrowserMeetingEvent(
                browser: .firefox, provider: .zoom, state: .inCall, timestamp: now, tabID: 1
            ),
            at: now
        )
        let evidence = detector.update(
            native: .init(
                browserHoldsMicrophone: true, browserProducesOutput: true,
                windowTitles: ["Meet - Northwind Daily"]
            ),
            at: now
        )
        #expect(evidence.provider == .zoom)
        #expect(evidence.title == nil)
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

    @Test("a meeting window among several keeps the call, and a bare landing title does not replace it")
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

        // The only titles left are a Meet home page and another app's page. The
        // microphone has not let go, so the home page does not replace the call.
        let landing = BrowserMeetingDetector.NativeSignals(
            browserHoldsMicrophone: true, browserProducesOutput: true,
            windowTitles: ["Meet", "Quarterly plan - Docs"]
        )
        now += 200
        let afterwards = detector.update(native: landing, at: now)
        #expect(afterwards.confidence == .confirmed)
        #expect(afterwards.meetingID == "hzc-josd-epv")
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
