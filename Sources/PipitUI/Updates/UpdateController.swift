import AppKit
import Foundation
import PipitCore
import PipitDetection
import PipitServices
import Sparkle

/// Owns the Sparkle updater and the window that shows an update.
///
/// The controller is created once and held for the life of the process, because
/// Sparkle schedules its own background checks from it and the delegate must
/// stay alive to answer them. Sparkle's own windows are not used: the update
/// is drawn by `UpdateWindowView` from `UpdateFlowModel`, so the app and the
/// Firefox add-on appear as the two steps of one update and the release notes
/// are lists rather than a web page.
@MainActor
public final class UpdateController: NSObject, SPUUpdaterDelegate {
    private weak var runtime: PipitRuntime?
    private let windows: WindowManager
    private var updater: SPUUpdater?
    private var driver: UpdateUserDriver?
    private let notesLoader = ReleaseNotesLoader()
    public let model = UpdateFlowModel()

    /// Whether the updater started. A menu item that calls `checkForUpdates()`
    /// is disabled while this is false.
    public var isAvailable: Bool { updater != nil }

    public init(runtime: PipitRuntime, windows: WindowManager) {
        self.runtime = runtime
        self.windows = windows
        super.init()
        model.runningVersion = Self.runningVersion
        model.syncAddOn(from: runtime.status)
    }

    /// Starts the updater and its daily schedule. Called after the runtime is
    /// running, so the updater cannot delay recording.
    ///
    /// Started by hand rather than from the initialiser. Sparkle refuses to
    /// start on a bundle whose feed or public key is unusable, and its own
    /// handling of that is a modal alert in front of a menu-bar app that has
    /// just launched. A refusal is logged and the rest of the app runs.
    public func start() {
        guard updater == nil else { return }
        let driver = UpdateUserDriver(
            model: model,
            present: { [weak self] activating in
                guard let self else { return }
                windows.showUpdate(model, installAddOn: { self.installAddOn() }, activating: activating)
            },
            dismiss: { [weak self] in self?.windows.closeUpdate() },
            loadNotes: { [weak self] version in self?.loadNotes(version: version) },
            refreshAddOn: { [weak self] in
                guard let self, let runtime else { return }
                model.syncAddOn(from: runtime.status)
            }
        )
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self
        )
        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
            Log.ui.info("updater started")
        } catch {
            Log.ui.error("updater not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Checks now and shows the result, including "you are up to date".
    public func checkForUpdates() {
        guard let updater else {
            Log.ui.info("update check skipped: the updater did not start")
            return
        }
        updater.checkForUpdates()
    }

    /// The add-on state moved. Called from the status observer, so the window
    /// waiting on the add-on step closes when the add-on reconnects updated.
    public func statusDidChange() {
        guard let runtime else { return }
        model.syncAddOn(from: runtime.status)
        if !model.needsWindow, model.phase == .idle { windows.closeUpdate() }
    }

    /// Hands the bundled add-on to Firefox, with the relay in place first.
    private func installAddOn() {
        if let binary = NativeMessagingInstaller.bundledHostURL() {
            _ = try? NativeMessagingInstaller().install(hostBinary: binary)
        }
        FirefoxAddOn.install()
    }

    private func loadNotes(version: String) {
        let loader = notesLoader
        Task { @MainActor [weak self] in
            do {
                let notes = try await loader.load(version: version)
                self?.model.notesLoaded(notes)
            } catch {
                Log.ui.info("release notes not loaded: \(error.localizedDescription, privacy: .public)")
                self?.model.notesFailed()
            }
        }
    }

    /// The version this copy of the app was built as. Sparkle compares the
    /// same string when it decides whether a feed item is newer.
    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle calls its delegate on the main thread, so the current setting is
    /// read from the runtime at check time rather than mirrored.
    public nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            UpdateChannels.allowed(
                receivesBeta: runtime?.settings.receivesBetaUpdates ?? false,
                appVersion: Self.runningVersion
            )
        }
    }
}
