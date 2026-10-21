import AppKit
import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import UserNotifications

/// Routes notification button taps to the runtime.
///
/// Without a delegate the actions registered on each category are inert: the
/// buttons appear and do nothing. Under an ad-hoc signature macOS refuses to
/// deliver actionable notifications at all, so this only comes alive on a build
/// signed with a Developer ID.
@MainActor
public final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private let runtime: PipitRuntime
    private let windows: WindowManager
    /// Opens the report about a crash: the application sets it to Report a
    /// Problem on a `crash` report. Settings › Diagnostics while it is nil.
    public var onReviewCrashReport: (@MainActor () -> Void)?

    public init(runtime: PipitRuntime, windows: WindowManager) {
        self.runtime = runtime
        self.windows = windows
        super.init()
        if NotificationSupport.isAvailable {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let content = response.notification.request.content
        let meetingID = content.userInfo["meetingID"] as? String
        let isCrashReport = content.categoryIdentifier == NotificationService.Category.crashReport.rawValue
        await MainActor.run {
            // The body and the Review button both open the report. A dismissal
            // arrives as its own action and sends nothing.
            if isCrashReport {
                if action == NotificationService.Action.reviewCrash.rawValue
                    || action == UNNotificationDefaultActionIdentifier
                {
                    reviewCrashReport()
                }
                return
            }
            switch NotificationService.Action(rawValue: action) {
            case .keep:
                runtime.resolveProvisional(keep: true)
            case .discard:
                runtime.resolveProvisional(keep: false)
            case .reveal:
                if let meetingID { runtime.revealInFinder(meetingID: meetingID) }
            case .retry:
                if let meetingID { runtime.retryProcessing(meetingID: meetingID) }
            case .reviewCrash:
                reviewCrashReport()
            case nil:
                // Tapping the body opens the meeting it refers to.
                if let meetingID { windows.showReview(meetingID: meetingID) }
            }
        }
    }

    /// Either way the offer is answered, so the menu stops highlighting
    /// Report a Problem.
    private func reviewCrashReport() {
        if let onReviewCrashReport {
            onReviewCrashReport()
        } else {
            runtime.dismissCrashReportOffer()
            windows.showSettings(pane: .diagnostics)
        }
    }

    /// Meeting notices are worth seeing even while Pipit is frontmost.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
