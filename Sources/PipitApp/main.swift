import AppKit
import PipitCore
import PipitServices
import PipitUI

/// Pipit runs as a menu-bar utility with no main window. Whether it also
/// takes a Dock slot is a setting; the menu bar item is there either way.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // These five are built in `applicationDidFinishLaunching`, which runs
    // before any other method this delegate implements.
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var runtime: PipitRuntime!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var windows: WindowManager!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var menuBar: MenuBarController!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var notificationRouter: NotificationRouter!
    // swiftlint:disable:next implicitly_unwrapped_optional
    private var updates: UpdateController!
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The real event log only here. Every other runtime, the tests' among
        // them, gets the disabled one and writes nothing to the Logs folder.
        runtime = PipitRuntime(diagnostics: DiagnosticLog(layout: .standard))
        LoginItem.apply(launchAtLogin: runtime.settings.launchAtLogin)
        windows = WindowManager(runtime: runtime)
        // Applied from the loaded settings rather than hardcoded, and again on
        // every settings change through the menu bar controller's observer and
        // whenever a window opens or closes.
        windows.refreshDockPresence()
        updates = UpdateController(runtime: runtime, windows: windows)
        windows.checkForUpdates = { [weak self] in self?.updates.checkForUpdates() }
        menuBar = MenuBarController(runtime: runtime, windows: windows, updates: updates)
        notificationRouter = NotificationRouter(runtime: runtime, windows: windows)
        connectDiagnosticReports()
        runtime.start()
        // After the runtime, so a check on launch never delays capture.
        updates.start()

        // Asynchronous, because reading notification permission is a call into
        // another process. Recording and detection are already running by then;
        // setup opening is not a precondition for either.
        Task { @MainActor in await windows.showSetupIfNeeded() }
        Log.app.info("Pipit started")
    }

    /// Report a Problem sends through the runtime's sender, automatic sharing
    /// builds with the same collector and bundle builder, and the crash
    /// prompt's Review… opens Report a Problem on the crash. Before
    /// `runtime.start()`, so the first look of automatic sharing has a builder.
    private func connectDiagnosticReports() {
        notificationRouter.onReviewCrashReport = { [weak self] in self?.windows.showCrashReport() }
        guard let reports = runtime.reports else { return }
        windows.reportSender = reports
        runtime.setDiagnosticReportBuilder(DiagnosticReportCollector.reportBuilder(runtime: runtime, sender: reports))
    }

    /// Finalising a recording is asynchronous, and a terminating run loop does
    /// not run the work that `stop()` enqueues. Termination is deferred until the
    /// recording is closed, so the meeting is not left for crash recovery.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Task { @MainActor in
            await runtime.stopAndWait()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
        runtime.finishDiagnostics()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing a panel must never stop recording.
        false
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// The stored preference is read once the runtime has loaded settings, in
// applicationDidFinishLaunching. Until then the app stays out of the Dock, so a
// menu bar install never flashes an icon on launch.
application.setActivationPolicy(.accessory)
application.run()
