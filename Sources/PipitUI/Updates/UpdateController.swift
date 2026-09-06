import PipitCore
import PipitServices
import Sparkle

/// Owns the Sparkle updater.
///
/// The controller is created once and held for the life of the process, because
/// Sparkle schedules its own background checks from it and the delegate must
/// stay alive to answer them. The controller draws nothing. Sparkle brings its
/// own windows.
@MainActor
public final class UpdateController: NSObject, SPUUpdaterDelegate {
    private weak var runtime: PipitRuntime?
    private var controller: SPUStandardUpdaterController?

    /// Whether the updater started. A menu item that calls `checkForUpdates()`
    /// is disabled while this is false.
    public var isAvailable: Bool { controller != nil }

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
        super.init()
    }

    /// Starts the updater and its daily schedule. Called after the runtime is
    /// running, so the updater cannot delay recording.
    ///
    /// Started by hand rather than from the initialiser. Sparkle refuses to
    /// start on a bundle whose feed or public key is unusable, and its own
    /// handling of that is a modal alert in front of a menu-bar app that has
    /// just launched. A refusal is logged and the rest of the app runs.
    public func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        do {
            try controller.updater.start()
            self.controller = controller
            Log.ui.info("updater started")
        } catch {
            Log.ui.error("updater not started: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Checks now and shows the result, including "you are up to date".
    public func checkForUpdates() {
        guard let controller else {
            Log.ui.info("update check skipped: the updater did not start")
            return
        }
        controller.updater.checkForUpdates()
    }

    // MARK: - SPUUpdaterDelegate

    /// Sparkle calls its delegate on the main thread, so the current setting is
    /// read from the runtime at check time rather than mirrored.
    public nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        MainActor.assumeIsolated {
            UpdateChannels.allowed(receivesBeta: runtime?.settings.receivesBetaUpdates ?? false)
        }
    }
}
