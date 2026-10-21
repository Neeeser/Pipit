import Foundation
import PipitCore

/// A crash of the previous launch, offered to the person once.
public struct CrashReportOffer: Sendable, Equatable {
    /// The crash report's incident, lowercase.
    public let incident: String
    /// When the crashed launch started. A `crash` report carries its events
    /// and crash summaries from here on.
    public let crashedLaunchStartedAt: Date

    public init(incident: String, crashedLaunchStartedAt: Date) {
        self.incident = incident
        self.crashedLaunchStartedAt = crashedLaunchStartedAt
    }
}

extension PipitRuntime {
    /// Whether the menu highlights Report a Problem: the previous launch
    /// crashed, automatic sharing is off, and the person has not opened the
    /// report or dismissed the offer.
    public var highlightsReportAProblem: Bool { crashReportOffer != nil }

    /// The person opened the report about the crash, or closed the offer.
    /// Nothing is sent by either.
    public func dismissCrashReportOffer() {
        crashReportOffer = nil
    }

    /// Connects the report builder that automatic sharing builds with. Until
    /// it is called, automatic sharing has nothing to send.
    public func setDiagnosticReportBuilder(_ build: @escaping DiagnosticSharingScheduler.BuildReport) {
        guard let sharing else { return }
        Task.detached(priority: .utility) { await sharing.setReportBuilder(build) }
    }

    /// Recording, about to record, or processing: automatic sharing waits.
    var isBusyForDiagnostics: Bool {
        status.isCapturing || !processing.isEmpty
    }

    /// Acts on how the previous launch ended, each time it is classified.
    ///
    /// A confirmed crash goes to automatic sharing when that is on, and is
    /// otherwise offered once: one notification, and the menu highlight.
    /// Every other class, `unclean_unknown` and `system_restart` among them,
    /// is neither offered nor sent.
    func handlePreviousExit(_ classification: ExitClassification, previous: LaunchRecord) async {
        guard let layout = diagnostics.layout else { return }
        let route = DiagnosticCrashRoute.route(
            classification, sharesAutomatically: settings.sharesDiagnosticsAutomatically
        )
        switch route {
        case .none:
            return
        case .share(let incident):
            guard let sharing else { return }
            await sharing.noteCrash(incident: incident, since: previous.startedAt)
            sharing.tickSoon()
        case .offer(let incident):
            let offers = DiagnosticCrashOffers(layout: layout)
            let isNew = await Task.detached(priority: .utility) { offers.claim(incident, now: Date()) }.value
            guard isNew else { return }
            crashReportOffer = CrashReportOffer(incident: incident, crashedLaunchStartedAt: previous.startedAt)
            if settings.showNotifications { notifications.crashReportOffer(incident: incident) }
        }
    }
}
