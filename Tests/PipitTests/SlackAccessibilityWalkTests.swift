import Testing

@testable import PipitDetection

@Suite("SlackAccessibilityWalk")
struct SlackAccessibilityWalkTests {
    @Test("Slack holding the microphone builds the web tree and walks deep")
    func slackHoldingTheMicrophoneBuildsTheWebTreeAndWalksDeep() async throws {
        // A freshly launched Slack exposes no web content until asked, and the
        // leave control lives in that content. Waiting to see the control
        // before asking meant a huddle was never confirmed.
        let walk = SlackAccessibilityWalk(
            huddleMayBeRunning: true, webTreeIsBuilt: false, webTreeIsWorthRetrying: true
        )
        #expect(walk.buildsWebTree)
        #expect(walk.maxDepth == SlackAccessibilityWalk.deepDepth)
    }

    @Test("the deep walk reaches past where Slack puts its huddle controls")
    func theDeepWalkReachesPastWhereSlackPutsItsHuddleControls() async throws {
        // Slack 4.52 put the conversation's huddle button 18 levels below its
        // window and its deepest node at 30. The shallow walk stops at 16.
        #expect(SlackAccessibilityWalk.deepDepth > 30)
        #expect(SlackAccessibilityWalk.shallowDepth < 18)
    }

    @Test("an idle Slack keeps the cheap walk")
    func anIdleSlackKeepsTheCheapWalk() async throws {
        let walk = SlackAccessibilityWalk(
            huddleMayBeRunning: false, webTreeIsBuilt: false, webTreeIsWorthRetrying: true
        )
        #expect(!walk.buildsWebTree)
        #expect(walk.maxDepth == SlackAccessibilityWalk.shallowDepth)
    }

    @Test("a built tree is not asked for again")
    func aBuiltTreeIsNotAskedForAgain() async throws {
        let walk = SlackAccessibilityWalk(
            huddleMayBeRunning: true, webTreeIsBuilt: true, webTreeIsWorthRetrying: true
        )
        #expect(!walk.buildsWebTree)
        #expect(walk.maxDepth == SlackAccessibilityWalk.deepDepth)
    }

    @Test("a tree that never builds stops being asked for, but the walk stays deep")
    func aTreeThatNeverBuildsStopsBeingAskedForButTheWalkStaysDeep() async throws {
        let walk = SlackAccessibilityWalk(
            huddleMayBeRunning: true, webTreeIsBuilt: false, webTreeIsWorthRetrying: false
        )
        #expect(!walk.buildsWebTree)
        #expect(walk.maxDepth == SlackAccessibilityWalk.deepDepth)
    }

    @Test("the tree is kept while a huddle may be running, even without the control")
    func theTreeIsKeptWhileAHuddleMayBeRunning() async throws {
        // A read can come back without the leave control mid-huddle, and a
        // muted huddle may not hold the microphone. Dropping the tree then
        // put the next walk back at the shallow depth, where the control
        // cannot be seen, so the huddle would read as over.
        let running = SlackAccessibilityWalk(
            huddleMayBeRunning: true, webTreeIsBuilt: true, webTreeIsWorthRetrying: true
        )
        #expect(!running.forgetsWebTree(foundLeaveControl: false))

        let idle = SlackAccessibilityWalk(
            huddleMayBeRunning: false, webTreeIsBuilt: true, webTreeIsWorthRetrying: true
        )
        #expect(idle.forgetsWebTree(foundLeaveControl: false))
        #expect(!idle.forgetsWebTree(foundLeaveControl: true))
    }

    @Test("a set that works restores the retries an earlier busy Slack used up")
    func aSetThatWorksRestoresTheRetries() async throws {
        // The leave control now needs the tree, so a limit that only ever
        // counted up would end huddle detection for the life of that Slack.
        var state = SlackWebTreeState()
        for _ in 0..<SlackWebTreeState.attemptLimit { state.record(setSucceeded: false) }
        #expect(!state.isWorthRetrying)

        state.record(setSucceeded: true)
        #expect(state.isBuilt)
        #expect(state.isWorthRetrying)
        state.forget()
        #expect(!state.isBuilt)
        #expect(state.isWorthRetrying)
    }
}
