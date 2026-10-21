import AppKit
import Foundation
import PipitCore
import Testing

@testable import PipitServices
@testable import PipitUI

/// The crash prompt, the automatic sharing switch, and the Diagnostics page,
/// through a runtime whose report service and Keychain are stand-ins
/// (`docs/DIAGNOSTICS.md`, Exit classes and Automatic sharing).
@Suite("Diagnostic reporting in the runtime", .serialized)
struct DiagnosticReportingRuntimeTests {
    @MainActor
    private struct Rig {
        let base: URL
        let layout: DiagnosticLayout
        let transport = FakeReportTransport()
        let secrets = InMemoryDeletionSecrets()
        let runtime: PipitRuntime

        init(sharing: Bool = false) throws {
            base = try TestPaths.makeTemporaryDirectory()
            layout = DiagnosticLayout(root: base.appendingPathComponent("Logs", isDirectory: true))
            if sharing {
                var settings = AppSettings()
                settings.sharesDiagnosticsAutomatically = true
                try SettingsStore(directory: base).save(settings)
            }
            runtime = PipitRuntime(
                settingsDirectory: base,
                diagnostics: DiagnosticLog(layout: layout, freeSpace: { _ in .max }),
                reportTransport: transport, deletionSecrets: secrets
            )
        }

        func remove() { try? FileManager.default.removeItem(at: base) }
    }

    static let previous = DiagnosticsFixtures.crashedLaunch()

    @Test("a crash is offered once, with the menu highlight, and dismissing it sends nothing")
    @MainActor
    func aCrashIsOfferedOnce() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let crash = ExitClassification(.crash, incident: "8F3C2B1A-0D4E-4F5A-9B6C-7D8E9F0A1B2C")
        await rig.runtime.handlePreviousExit(crash, previous: Self.previous)
        #expect(
            rig.runtime.crashReportOffer
                == CrashReportOffer(
                    incident: "8f3c2b1a-0d4e-4f5a-9b6c-7d8e9f0a1b2c", crashedLaunchStartedAt: Self.previous.startedAt
                ))
        #expect(rig.runtime.highlightsReportAProblem)

        rig.runtime.dismissCrashReportOffer()
        #expect(!rig.runtime.highlightsReportAProblem)
        // The same incident again, as a later classification would bring it.
        await rig.runtime.handlePreviousExit(crash, previous: Self.previous)
        #expect(rig.runtime.crashReportOffer == nil)

        let sharing = try #require(rig.runtime.sharing)
        #expect(await sharing.tick() == .off)
        #expect(rig.transport.requestCount == 0)
        #expect(DiagnosticSharingStateStore(layout: rig.layout).load() == nil)
    }

    @Test("an unclean exit, a restart, a hang and a clean exit are never offered")
    @MainActor
    func otherExitsAreNeverOffered() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        for exitClass in [ExitClass.uncleanUnknown, .systemRestart, .hang, .clean] {
            await rig.runtime.handlePreviousExit(
                ExitClassification(exitClass, incident: exitClass == .hang ? "a1" : nil), previous: Self.previous
            )
            #expect(rig.runtime.crashReportOffer == nil)
        }
        #expect(DiagnosticCrashOffers(layout: rig.layout).offers().isEmpty)
        #expect(rig.transport.requestCount == 0)
    }

    @Test("with automatic sharing on, a crash is queued to send and not offered")
    @MainActor
    func withSharingOnACrashIsQueued() async throws {
        let rig = try Rig(sharing: true)
        defer { rig.remove() }
        await rig.runtime.handlePreviousExit(ExitClassification(.crash, incident: "c1"), previous: Self.previous)
        #expect(rig.runtime.crashReportOffer == nil)
        let state = try #require(DiagnosticSharingStateStore(layout: rig.layout).load())
        #expect(state.pendingCrashes.map(\.incident) == ["c1"])
        #expect(state.pendingCrashes.first?.since == Self.previous.startedAt)
    }

    @Test("turning automatic sharing off in Settings empties its queued reports")
    @MainActor
    func turningSharingOffEmptiesItsQueue() async throws {
        let rig = try Rig(sharing: true)
        defer { rig.remove() }
        let reports = try #require(rig.runtime.reports)
        rig.transport.fallback = .unavailable(status: 503, retryAfter: nil)
        let identity = reports.prepareIdentity()
        let report = try DiagnosticDeliveryFixtures.report(
            kind: .automatic, reportID: identity.reportID, hash: identity.deletionSecretHash
        )
        _ = await reports.send(report, automatic: true)
        #expect(await reports.pending().count == 1)

        var settings = rig.runtime.settings
        settings.sharesDiagnosticsAutomatically = false
        rig.runtime.update(settings: settings)
        var waits = 0
        while await !reports.pending().isEmpty, waits < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waits += 1
        }
        #expect(await reports.pending().isEmpty)
        #expect(rig.secrets.stored.isEmpty)
    }

    @Test("the Diagnostics page builds with sent reports, and the sharing sheet builds")
    @MainActor
    func theDiagnosticsPageBuildsWithSentReports() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let reports = try #require(rig.runtime.reports)
        let identity = reports.prepareIdentity()
        _ = await reports.send(
            try DiagnosticDeliveryFixtures.report(reportID: identity.reportID, hash: identity.deletionSecretHash)
        )
        let receipt = try #require(await reports.receipts().first)
        let model = SettingsModel(runtime: rig.runtime, storedKeyLookup: { _ in false })
        ViewFixtures.render(DiagnosticsSettingsPane(model: model))
        ViewFixtures.render(
            SentReportRow(
                receipt: receipt, now: receipt.sentAt, isBusy: true, notice: "Deletion code copied", copy: {},
                delete: {}
            )
        )
        ViewFixtures.render(AutomaticSharingSheet(turnOn: {}, cancel: {}))

        #expect(SentReportRow.kindName(.automatic) == "Daily report")
        #expect(SentReportRow.retention(receipt, now: receipt.sentAt).hasPrefix("On the server until "))
        #expect(SentReportRow.retention(receipt, now: receipt.expiresAt).hasPrefix("Expired on "))
    }
}
