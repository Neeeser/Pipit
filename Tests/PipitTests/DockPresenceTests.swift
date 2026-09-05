import AppKit
import Foundation
import PipitCore
import PipitServices
import PipitUI
import Testing

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
