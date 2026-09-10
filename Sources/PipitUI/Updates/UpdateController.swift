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

    /// The version this process runs, injectable so a test can stand in for
    /// a launch under a new version.
    private let running: String

    public init(
        runtime: PipitRuntime, windows: WindowManager, runningVersion: String = UpdateController.runningVersion
    ) {
        self.runtime = runtime
        self.windows = windows
        self.running = runningVersion
        super.init()
        model.runningVersion = runningVersion
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
        noticeLaunchAfterUpdate()
    }

    /// The first launch under a new version is the second step of the update.
    ///
    /// Sparkle's installer reports "installed and relaunched" to the process
    /// it terminated and stops its status service before relaunching, so the
    /// relaunched app never hears it. The version that last ran is kept in
    /// settings instead, and a change to it is the moment to ask for the
    /// add-on, if the add-on is behind.
    private func noticeLaunchAfterUpdate() {
        guard let runtime else { return }
        let previous = runtime.settings.lastLaunchedVersion
        // An install from before the record existed has no previous version
        // and is still an install that was just updated. Finished setup or an
        // add-on that has connected is what says it is not a first launch.
        let existingInstall =
            runtime.settings.hasCompletedOnboarding || runtime.settings.firefoxSensorHasConnected
        if previous != running {
            var settings = runtime.settings
            settings.lastLaunchedVersion = running
            runtime.update(settings: settings)
        }
        guard Self.isFirstLaunchAfterUpdate(previous: previous, running: running, existingInstall: existingInstall)
        else { return }
        model.syncAddOn(from: runtime.status)
        let installAddOn: () -> Void = { [weak self] in self?.installAddOn() }
        if model.installedAndRelaunched(acknowledge: { [weak self] in self?.windows.closeUpdate() }) {
            windows.showUpdate(model, installAddOn: installAddOn, activating: false)
        }
    }

    /// Whether this launch follows an update.
    ///
    /// No previous version means either a first launch ever or an install
    /// from before the version was recorded, and `existingInstall` tells
    /// them apart. Reading it as a first launch kept the window shut on the
    /// one launch the record was added for.
    public nonisolated static func isFirstLaunchAfterUpdate(
        previous: String?, running: String, existingInstall: Bool
    ) -> Bool {
        guard !running.isEmpty else { return false }
        guard let previous else { return existingInstall }
        return previous != running
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
    func installAddOn() {
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
    public static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle calls its delegate on the main thread, so the current setting is
    /// read from the runtime at check time rather than mirrored.
    public nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            UpdateChannels.allowed(
                receivesBeta: runtime?.settings.receivesBetaUpdates ?? false,
                appVersion: running
            )
        }
    }
}
