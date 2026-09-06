import PipitAudio
import PipitCore
import PipitServices
import Sparkle

/// Owns the Sparkle updater.
///
/// The controller is created once and held for the life of the process, because
/// Sparkle schedules its own background checks from it and the delegate must
/// stay alive to answer them. Nothing here draws anything: Sparkle brings its
/// own windows.
@MainActor
public final class UpdateController: NSObject, SPUUpdaterDelegate {
    private let runtime: PipitRuntime
    private var controller: SPUStandardUpdaterController?
    /// The beta setting as of the last settings change. Sparkle asks for the
    /// channels from its own scheduler, off the main actor, so the value is
    /// mirrored into a lock rather than read from the runtime at that point.
    private let receivesBeta = LockedBox(false)

    public init(runtime: PipitRuntime) {
        self.runtime = runtime
        super.init()
        receivesBeta.withLock { $0 = runtime.settings.receivesBetaUpdates }
        runtime.observeStatus { [box = receivesBeta] in
            box.withLock { $0 = runtime.settings.receivesBetaUpdates }
        }
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

    public nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UpdateChannels.allowed(receivesBeta: receivesBeta.withLock { $0 })
    }
}
