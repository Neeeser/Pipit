import Foundation
import PipitCore
import PipitServices
import PipitUI
import Testing

@Suite("ReleaseNotes")
struct ReleaseNotesTests {
    @Test("the GitHub release body becomes headed lists without the attribution trailers")
    func theGitHubReleaseBodyBecomesHeadedListsWithoutTheAttributionTrailers() async throws {
        let body = """
            Meeting detection gets a lot more careful.

            ## What's Changed
            ### Features
            * Add an AI Features setup page by @someone in https://github.com/example/app/pull/89
            ### Fixes
            - Stop the microphone cutting out every second by @someone in https://github.com/example/app/pull/85
            - Improve automatic meeting detection in https://github.com/example/app/pull/90

            **Full Changelog**: https://github.com/example/app/compare/v0.1.0...v0.1.1
            """
        let notes = ReleaseNotes.parse(markdown: body)
        #expect(
            notes.sections == [
                .init(title: nil, items: ["Meeting detection gets a lot more careful."]),
                .init(title: "Features", items: ["Add an AI Features setup page"]),
                .init(
                    title: "Fixes",
                    items: [
                        "Stop the microphone cutting out every second",
                        "Improve automatic meeting detection",
                    ]),
            ])
    }

    @Test("a body with nothing in it is empty, and one without headings is one list")
    func aBodyWithNothingInItIsEmptyAndOneWithoutHeadingsIsOneList() async throws {
        #expect(ReleaseNotes.parse(markdown: "").isEmpty)
        #expect(ReleaseNotes.parse(markdown: "\n\n**Full Changelog**: x\n").isEmpty)
        let flat = ReleaseNotes.parse(markdown: "## What's Changed\n* One thing\n* Another\n")
        #expect(flat.sections == [.init(title: "What's Changed", items: ["One thing", "Another"])])
    }

    @Test("the loader reads the body field of the release")
    func theLoaderReadsTheBodyFieldOfTheRelease() async throws {
        let json = Data(###"{"tag_name":"v0.2.0","body":"## Fixes\n* A fix by @x in https://e/pull/1"}"###.utf8)
        #expect(
            try ReleaseNotesLoader.notes(from: json).sections == [.init(title: "Fixes", items: ["A fix"])]
        )
        #expect(
            ReleaseNotesLoader.url(version: "0.2.0")?.absoluteString
                == "https://api.github.com/repos/\(ReleaseNotesLoader.repository)/releases/tags/v0.2.0"
        )
        let loader = ReleaseNotesLoader { url in
            #expect(url == ReleaseNotesLoader.url(version: "0.2.0"))
            return json
        }
        #expect(try await loader.load(version: "0.2.0").sections.count == 1)
    }
}

@Suite("UpdateFlow")
@MainActor
struct UpdateFlowTests {
    @Test("an update found waits for a choice and reports it")
    func anUpdateFoundWaitsForAChoiceAndReportsIt() async throws {
        let model = UpdateFlowModel()
        var replies: [UpdateFlowModel.Choice] = []
        model.updateFound(.init(version: "0.2.0", contentLength: 41_000_000), userInitiated: false) {
            replies.append($0)
        }
        #expect(model.phase == .found)
        #expect(model.needsWindow, "an update on offer is shown whoever asked for the check")
        model.install()
        #expect(replies == [.install])
        #expect(model.phase == .downloading, "the button has been pressed; the download is what comes next")
        model.install()
        #expect(replies == [.install], "one answer per question")
    }

    @Test("the close box answers whatever is pending")
    func theCloseBoxAnswersWhateverIsPending() async throws {
        let model = UpdateFlowModel()
        var replies: [UpdateFlowModel.Choice] = []
        model.updateFound(.init(version: "0.2.0", contentLength: 1), userInitiated: true) { replies.append($0) }
        model.windowClosed()
        #expect(replies == [.later])

        var cancelled = false
        model.checkStarted(userInitiated: true) { cancelled = true }
        model.windowClosed()
        #expect(cancelled)
        #expect(model.phase == .idle)
    }

    @Test("download progress follows the bytes")
    func downloadProgressFollowsTheBytes() async throws {
        let model = UpdateFlowModel()
        model.updateFound(.init(version: "0.2.0", contentLength: 100), userInitiated: true) { _ in }
        model.install()
        model.downloadStarted {}
        #expect(model.progress == nil, "unknown until the size arrives")
        model.expect(bytes: 100)
        model.received(bytes: 25)
        #expect(model.progress == 0.25)
        model.received(bytes: 100)
        #expect(model.progress == 1, "never past the end")
        model.extracting(progress: 0.5)
        #expect(model.phase == .extracting)
        var readyReplies: [UpdateFlowModel.Choice] = []
        model.readyToInstall { readyReplies.append($0) }
        #expect(model.phase == .readyToInstall)
        model.install()
        #expect(readyReplies == [.install])
    }

    @Test("a scheduled check that finds nothing says nothing")
    func aScheduledCheckThatFindsNothingSaysNothing() async throws {
        let model = UpdateFlowModel()
        var acknowledged = 0
        model.upToDate { acknowledged += 1 }
        #expect(acknowledged == 1, "nobody asked, so nothing waits on a click")
        #expect(model.phase == .idle)

        model.checkStarted(userInitiated: true) {}
        model.upToDate { acknowledged += 1 }
        #expect(model.phase == .upToDate)
        #expect(model.needsWindow, "the person asked, and is told")
        model.acknowledge()
        #expect(acknowledged == 2)
    }

    @Test("the launch after an update asks for the add-on only when it is behind")
    func theLaunchAfterAnUpdateAsksForTheAddOnOnlyWhenItIsBehind() async throws {
        let model = UpdateFlowModel()
        var acknowledged = 0
        model.addOn = .init(installedVersion: "0.1.1.87", needsUpdate: false)
        #expect(!model.installedAndRelaunched { acknowledged += 1 })
        #expect(acknowledged == 1, "nothing to do, nothing shown")

        model.addOn = .init(installedVersion: "0.1.1.87", needsUpdate: true)
        #expect(model.installedAndRelaunched { acknowledged += 1 })
        #expect(model.phase == .installed)
        #expect(model.needsWindow)
        #expect(acknowledged == 1)

        // The add-on reconnects at the new version: the window's work is done.
        var status = RuntimeStatus()
        status.firefoxSensorHasConnected = true
        status.firefoxAddOnProtocol = SensorProtocol.required
        status.firefoxAddOnVersion = "0.2.0.90"
        model.syncAddOn(from: status)
        #expect(acknowledged == 2)
        #expect(model.phase == .idle)
    }

    @Test("an up-to-date app still asks for an add-on that is behind")
    func anUpToDateAppStillAsksForAnAddOnThatIsBehind() async throws {
        // Check for Updates is the one place a person goes to update
        // anything, so the add-on step appears there too.
        let model = UpdateFlowModel()
        model.addOn = .init(installedVersion: "0.1.1.87", needsUpdate: true)
        model.upToDate {}
        #expect(model.phase == .upToDate)
        #expect(model.needsWindow)
        #expect(model.addOnStepPending)
    }
}

@Suite("LaunchAfterUpdate")
struct LaunchAfterUpdateTests {
    @Test("a launch under a new version is the one after an update")
    func aLaunchUnderANewVersionIsTheOneAfterAnUpdate() async throws {
        #expect(UpdateController.isFirstLaunchAfterUpdate(previous: "0.1.2", running: "0.1.3"))
        #expect(!UpdateController.isFirstLaunchAfterUpdate(previous: "0.1.3", running: "0.1.3"))
        #expect(
            !UpdateController.isFirstLaunchAfterUpdate(previous: nil, running: "0.1.3"),
            "a first launch ever follows no update"
        )
        #expect(!UpdateController.isFirstLaunchAfterUpdate(previous: "0.1.2", running: ""))
    }

    @Test("the settings file keeps the version that last ran")
    func theSettingsFileKeepsTheVersionThatLastRan() async throws {
        var settings = AppSettings()
        #expect(settings.lastLaunchedVersion == nil)
        settings.lastLaunchedVersion = "0.1.3"
        let decoded = try JSONDecoder().decode(AppSettings.self, from: try JSONEncoder().encode(settings))
        #expect(decoded.lastLaunchedVersion == "0.1.3")
    }
}
