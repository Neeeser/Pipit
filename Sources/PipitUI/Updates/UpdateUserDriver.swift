import AppKit
import Foundation
import PipitCore
import Sparkle

/// Sparkle's view of the update window.
///
/// Sparkle calls these on the main thread and hands each a reply to send once
/// the person has decided. Everything goes to the model, which the window
/// draws from; this only translates Sparkle's types and decides when the window
/// has to be on screen. Replacing Sparkle's own driver is what lets the app
/// and the add-on update as one sequence, on one window, with the release
/// notes drawn as lists.
final class UpdateUserDriver: NSObject, SPUUserDriver {
    private let model: UpdateFlowModel
    private let present: @MainActor (_ activating: Bool) -> Void
    private let dismiss: @MainActor () -> Void
    private let loadNotes: @MainActor (_ version: String) -> Void

    @MainActor
    init(
        model: UpdateFlowModel,
        present: @escaping @MainActor (_ activating: Bool) -> Void,
        dismiss: @escaping @MainActor () -> Void,
        loadNotes: @escaping @MainActor (_ version: String) -> Void
    ) {
        self.model = model
        self.present = present
        self.dismiss = dismiss
        self.loadNotes = loadNotes
    }

    /// Puts the window up or takes it down for the state the model is in.
    @MainActor
    private func sync(activating: Bool = true) {
        if model.needsWindow { present(activating) } else { dismiss() }
    }

    // MARK: - SPUUserDriver

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist enables scheduled checks, so Sparkle does not ask. Should
        // it, the answer is the one the plist gives: check, never send a
        // profile, and download nothing until the person says so.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            model.checkStarted(userInitiated: true, cancel: cancellation)
            sync()
        }
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        MainActor.assumeIsolated {
            let offer = UpdateFlowModel.Offer(
                version: appcastItem.displayVersionString, contentLength: appcastItem.contentLength
            )
            model.updateFound(offer, userInitiated: state.userInitiated) { choice in
                switch choice {
                case .install: reply(.install)
                case .skip: reply(.skip)
                case .later: reply(.dismiss)
                }
            }
            // A scheduled check that finds something shows the window without
            // taking the keyboard from whatever the person is doing.
            sync(activating: state.userInitiated)
            loadNotes(appcastItem.displayVersionString)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // The appcast points at the release page. The window draws the
        // release body from the API instead, so the page is not used.
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            model.upToDate(acknowledge: acknowledgement)
            sync()
        }
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            model.failed(error.localizedDescription, acknowledge: acknowledgement)
            sync()
        }
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        MainActor.assumeIsolated {
            model.downloadStarted(cancel: cancellation)
            sync()
        }
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        MainActor.assumeIsolated { model.expect(bytes: expectedContentLength) }
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        MainActor.assumeIsolated { model.received(bytes: length) }
    }

    func showDownloadDidStartExtractingUpdate() {
        MainActor.assumeIsolated { model.extracting(progress: 0) }
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        MainActor.assumeIsolated { model.extracting(progress: progress) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        MainActor.assumeIsolated {
            model.readyToInstall { choice in
                switch choice {
                case .install: reply(.install)
                case .skip: reply(.skip)
                case .later: reply(.dismiss)
                }
            }
            sync()
        }
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        MainActor.assumeIsolated {
            model.installing()
            sync()
        }
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        MainActor.assumeIsolated {
            // The second step of the update: the add-on, if it is behind. When
            // it is not, the model acknowledges and nothing appears.
            if model.installedAndRelaunched(acknowledge: acknowledgement) { sync() }
        }
    }

    func showUpdateInFocus() {
        MainActor.assumeIsolated { sync() }
    }

    func dismissUpdateInstallation() {
        MainActor.assumeIsolated {
            model.dismissed()
            dismiss()
        }
    }
}
