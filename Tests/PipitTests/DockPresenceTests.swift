import AppKit
import Foundation
import PipitCore
import PipitServices
import Testing

@testable import PipitUI

/// Whether Pipit takes a Dock slot, and what it costs when it does not.
///
/// macOS skips accessory applications when it hands activation back. The setup
/// wizard sitting behind a permission prompt therefore stayed behind whatever
/// the prompt was covering once the prompt closed, with no Dock icon and no app
/// switcher entry to reach it. A window on screen now makes Pipit a regular
/// application for as long as it is open.
@Suite("DockPresence")
struct DockPresenceTests {
    @Test("an open window puts Pipit in the Dock whatever the setting says")
    func anOpenWindowPutsPipitInTheDockWhateverTheSettingSays() async throws {
        #expect(
            DockPresence.policy(showsDockIcon: false, hasOpenWindow: true) == .regular,
            "a window open with the setting off"
        )
        #expect(
            DockPresence.policy(showsDockIcon: true, hasOpenWindow: false) == .regular,
            "the setting on with nothing open"
        )
        #expect(DockPresence.policy(showsDockIcon: true, hasOpenWindow: true) == .regular, "both")
        #expect(
            DockPresence.policy(showsDockIcon: false, hasOpenWindow: false) == .accessory,
            "menu bar only when there is nothing to keep reachable"
        )
    }

    @Test("opening the wizard asks for the Dock, and closing it gives it back")
    func openingTheWizardAsksForTheDockAndClosingItGivesItBack() async throws {
        try await Self.theWindowDrivesThePolicy()
    }

    @Test("the keep-or-discard prompt does not ask for the Dock")
    func theKeepOrDiscardPromptDoesNotAskForTheDock() async throws {
        try await Self.theProvisionalPromptLeavesThePolicyAlone()
    }

    @Test("a closed Meetings window is kept hidden, shown again as it was, and let go under memory pressure")
    func aClosedMeetingsWindowIsKeptUntilMemoryIsShort() async throws {
        try await Self.aClosedMeetingsWindowIsKept()
    }

    /// Built again on every open, the window took a third of a second to come
    /// back and drew the meeting after the list. Kept, it comes back as it
    /// was, and it still gives its memory up when the system asks.
    @MainActor
    private static func aClosedMeetingsWindowIsKept() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let recorder = Recorder()
        let windows = makeWindows(root: root, into: recorder)
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))

        windows.showMeetings(activating: false)
        weak let opened = NSApp.windows.first { !before.contains(ObjectIdentifier($0)) }
        #expect(opened != nil, "the window opened")

        autoreleasepool { opened?.close() }
        try await Task.sleep(for: .milliseconds(100))
        #expect(opened != nil, "the closed window is kept")
        #expect(opened?.isVisible == false, "and hidden")
        #expect(!windows.hasOpenWindow, "so it does not hold the Dock icon")

        windows.showMeetings(activating: false)
        // Identifiers rather than the windows, which would keep the window
        // alive for the rest of the test.
        let shown = NSApp.windows.filter { !before.contains(ObjectIdentifier($0)) && $0.isVisible }
            .map(ObjectIdentifier.init)
        #expect(shown == [opened.map(ObjectIdentifier.init)].compactMap { $0 }, "the same window comes back")

        autoreleasepool { opened?.close() }
        try await Task.sleep(for: .milliseconds(100))
        autoreleasepool { windows.releaseHiddenMeetingsWindow() }
        for _ in 0..<20 where opened != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(opened == nil, "memory pressure lets it go")
        withExtendedLifetime(windows) {}
    }

    @Test("a note typed just before the People window closes is still saved")
    func aNoteTypedJustBeforeClosingIsSaved() async throws {
        try await Self.aNoteSurvivesClosingThePeopleWindow()
    }

    /// The note saves a beat after typing stops through a timer that holds the
    /// model weakly, and closing the window now lets the model go.
    @MainActor
    private static func aNoteSurvivesClosingThePeopleWindow() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let store = try #require(runtime.speakerStore)
        await runtime.ensureLocalUserIdentity()
        let me = try #require(try await store.localUser())
        NSApplication.shared.setActivationPolicy(.prohibited)
        let windows = WindowManager(runtime: runtime) { _ in }
        let before = Set(NSApp.windows.map(ObjectIdentifier.init))

        windows.showPeople()
        // Held weakly, as the save timer holds it, so only the window manager
        // keeps it alive.
        weak let model = windows.peopleModel
        await model?.reload()
        model?.select(me.id, extending: false)
        // Selecting flushes the previous person's note in a task of its own.
        try await Task.sleep(for: .milliseconds(50))
        model?.notesDraft = "Prefers written agendas"
        model?.notesChanged()
        NSApp.windows.first { !before.contains(ObjectIdentifier($0)) }?.close()

        for _ in 0..<100 {
            if try await store.localUser()?.notes != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await store.localUser()?.notes == "Prefers written agendas")
        withExtendedLifetime(windows) {}
    }

    /// Holds what the window manager asked for.
    @MainActor
    private final class Recorder {
        var policies: [NSApplication.ActivationPolicy] = []
    }

    /// A window manager whose policy changes are recorded rather than applied.
    /// Applying them would turn the test process into a Dock application.
    @MainActor
    private static func makeWindows(root: URL, into recorder: Recorder) -> WindowManager {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        // Menu bar only, so the window is the only thing asking for the Dock.
        settings.showsDockIcon = false
        runtime.update(settings: settings)
        return WindowManager(runtime: runtime) { recorder.policies.append($0) }
    }

    @MainActor
    private static func theWindowDrivesThePolicy() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let recorder = Recorder()
        let windows = makeWindows(root: root, into: recorder)

        windows.showSetup()
        #expect(windows.hasOpenWindow, "the wizard counts as open")
        #expect(recorder.policies.last == .regular, "and asks for a Dock icon")

        windows.closeSetup()
        // `willClose` is delivered on the main queue rather than inside `close()`.
        await Task.yield()
        #expect(!windows.hasOpenWindow, "closing it is noticed")
        #expect(recorder.policies.last == .accessory, "and the Dock slot goes back")
    }

    @MainActor
    private static func theProvisionalPromptLeavesThePolicyAlone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        let recorder = Recorder()
        let windows = makeWindows(root: root, into: recorder)

        windows.showProvisionalPrompt(
            ProvisionalPrompt(
                meetingID: "m1", applicationBundleID: "com.example.caller",
                applicationName: "Caller", title: nil
            )
        )
        #expect(
            !windows.hasOpenWindow,
            "it floats above everything and is answered where it stands"
        )
        #expect(recorder.policies.isEmpty, "so it never asks for a Dock icon")
        windows.closeProvisionalPrompt()
    }
}
