import AppKit
import Foundation
import PipitIntegrations
import Testing

@testable import PipitCore
@testable import PipitServices
@testable import PipitUI

/// A report built from a real runtime, archive and log, checked against what
/// must never reach one, and the Report a Problem window around it.
@Suite("DiagnosticReportCollector", .serialized)
@MainActor
struct DiagnosticReportCollectorTests {
    /// A runtime whose settings, archive and log hold canaries wherever a
    /// person or a meeting can put text.
    static func makeRuntime(base: URL) throws -> PipitRuntime {
        let archive = base.appendingPathComponent("CanaryPathLd1 Meetings", isDirectory: true)
        let logs = DiagnosticLayout(root: base.appendingPathComponent("Logs", isDirectory: true))

        var settings = AppSettings()
        settings.storageRootPath = archive.path
        settings.localUserName = "CanaryUserJw4"
        settings.models.vocabularyHints = "CanaryHintMm8, CanaryPersonZv3"
        settings.models.customEndpoint = "https://canary-endpoint-rt5.example.invalid/v1"
        settings.models.metadataProvider = .custom
        settings.models.metadata = "CanaryWordsKp9-model"
        settings.alwaysRecordApplications = ["com.example.CanaryTitleQx7"]
        try SettingsStore(directory: base).save(settings)

        let meeting = try PipelineFixtures.makeRecordedMeeting(root: archive)
        _ = try meeting.store.updateMetadata { metadata in
            metadata.titles.human = "CanaryTitleQx7 planning"
            metadata.processing.recordFailure(
                ProcessingFailure(
                    stage: .enriching, message: "CanaryWordsKp9 at canary-endpoint-rt5 refused", isRetryable: true,
                    occurredAt: Date(timeIntervalSince1970: 1_792_500_000),
                    code: DiagnosticCode("language_model", "unreachable")
                ),
                at: Date(timeIntervalSince1970: 1_792_500_000)
            )
        }

        let log = DiagnosticLog(layout: logs, freeSpace: { _ in .max })
        log.record(
            .appLaunched(
                .init(
                    version: "0.1.8", build: "812", commit: nil, os: "15.6.1", osBuild: "24G90", hardware: "Mac15,3",
                    arch: .appleSilicon
                )))
        log.record(.sessionStarted(source: .googleMeet, trigger: .auto, segmentSeconds: 30))
        #expect(log.flush())

        let crash = try #require(CrashReportReducer.reduce(try DiagnosticsFixtures.data("pipit-crash")))
        CrashReportScanner(reportsDirectory: base, crashesDirectory: logs.crashes)
            .store([crash], now: crash.summary.occurredAt)

        // Stand-ins for the report service and the Keychain: a runtime whose
        // log writes to disk otherwise makes the real ones.
        return PipitRuntime(
            settingsDirectory: base, diagnostics: log, reportTransport: FakeReportTransport(),
            deletionSecrets: InMemoryDeletionSecrets()
        )
    }

    @Test("a report from a real runtime carries no meeting content, setting text or path")
    func aReportFromARealRuntimeCarriesNoMeetingContentSettingTextOrPath() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)

        let contents = await DiagnosticReportCollector(runtime: runtime, hasKey: { $0 == .openAI }).contents()
        let bundle = try await DiagnosticReportCollector.bundle(
            contents, kind: .user, identity: .provisional(), createdAt: Date()
        )
        let report = bundle.report
        #expect(DiagnosticReportValidator.violations(in: report).isEmpty)
        let text = String(decoding: bundle.json, as: UTF8.self).lowercased()
        for canary in DiagnosticsInstrumentationTests.canaries {
            #expect(!text.contains(canary.lowercased()), "\(canary) reached the report")
        }
        #expect(!text.contains(base.path.lowercased()))

        #expect(report.summary.storage.meetings == 1)
        #expect(report.summary.recentFailures.map(\.code) == ["language_model.unreachable"])
        #expect(report.summary.settings["storageRoot"] == .string("custom"))
        #expect(report.summary.settings["metadataModel"] == .string("custom"))
        #expect(report.summary.settings["hasOpenAIKey"] == .bool(true))
        #expect(report.summary.settings["hasCustomEndpointKey"] == .bool(false))
        #expect(report.summary.settings["alwaysRecordAppCount"] == .integer(1))
        #expect(Set(report.summary.permissions.keys) == Set(DiagnosticEvent.Permission.allCases.map(\.rawValue)))
        #expect(report.summary.browserAddOns.map(\.browser) == ["firefox", "chrome", "safari"])
        #expect(report.events.count == report.summary.diagnostics.eventsIncluded)
        #expect(report.summary.diagnostics.eventsIncluded >= 2)
        #expect(report.crashes.count == 1)
        #expect(report.reportID.count == 36)
        #expect(report.deletionSecretHash.count == 43)
        #expect(DiagnosticTokenRule.accepts(report.deletionSecretHash))

        let entries = try DiagnosticArchive.read(try DiagnosticExport.archive(bundle))
        #expect(entries.count == 3)
    }

    @Test("Report a Problem builds, previews, and says when sending is not available")
    func reportAProblemBuildsPreviewsAndSaysWhenSendingIsNotAvailable() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runtime = try Self.makeRuntime(base: base)
        let model = ReportProblemModel(
            runtime: runtime, sender: UnavailableDiagnosticReportSender(),
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.preview?.report.note == nil)
        ViewFixtures.render(ReportProblemView(model: model))

        model.note = String(repeating: "a", count: DiagnosticReportLimits.noteLength + 10)
        model.holdToLimits()
        #expect(model.note.utf16.count == DiagnosticReportLimits.noteLength)

        await model.send()
        #expect(model.status == "Sending is not available in this version. Export the report instead.")
    }

    @Test("a sender is handed the report with the note and address as typed")
    func aSenderIsHandedTheReportWithTheNoteAndAddressAsTyped() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender()
        let model = ReportProblemModel(
            runtime: runtime, sender: sender,
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        await model.load()
        model.note = "It stopped after the call ended."
        model.contact = "someone@example.com"
        await model.send()
        let sent = try #require(sender.reports.first)
        #expect(sent.note == "It stopped after the call ended.")
        #expect(sent.contact == "someone@example.com")
        #expect(sent.reportID == model.preview?.report.reportID)
        #expect(model.status == "Sent.")
    }

    @Test("the preview carries the sender's identity, and closing without sending gives it back")
    func thePreviewCarriesTheSendersIdentity() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender(handsOutIdentities: true)
        let model = ReportProblemModel(
            runtime: runtime, sender: sender,
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        await model.load()
        let identity = try #require(sender.identities.first)
        #expect(model.preview?.report.reportID == identity.reportID)
        #expect(model.preview?.report.deletionSecretHash == identity.deletionSecretHash)

        model.windowClosed()
        try await Self.wait { !sender.discarded.isEmpty }
        #expect(sender.discarded == [identity])
    }

    @Test("a sent report keeps its identity when the window closes, and cannot be sent twice")
    func aSentReportKeepsItsIdentity() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender(handsOutIdentities: true)
        let model = ReportProblemModel(
            runtime: runtime, sender: sender,
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        await model.load()
        await model.send()
        await model.send()
        #expect(model.isSent)
        #expect(sender.reports.count == 1)
        #expect(sender.reports.first?.reportID == sender.identities.first?.reportID)
        model.windowClosed()
        try await Task.sleep(for: .milliseconds(100))
        #expect(sender.discarded.isEmpty)
    }

    @Test("a successful send closes once and retains the sent report identity")
    func aSuccessfulSendClosesOnce() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender(handsOutIdentities: true)
        let model = ReportProblemModel(
            runtime: runtime, sender: sender,
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        var closes = 0
        model.onSent = { [weak model] in
            #expect(model?.isSent == true)
            closes += 1
            model?.windowClosed()
        }
        await model.load()
        await model.send()
        await model.send()
        #expect(closes == 1)
        #expect(sender.reports.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(sender.discarded.isEmpty)
    }

    @Test(
        "an unconfirmed send keeps the window open",
        arguments: [
            DiagnosticSendOutcome.willRetry(at: Date(timeIntervalSince1970: 1)),
            .rejected(.tooLarge), .failed, .unavailable,
        ]
    )
    func anUnconfirmedSendKeepsTheWindowOpen(outcome: DiagnosticSendOutcome) async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender(outcome: outcome)
        let model = ReportProblemModel(
            runtime: runtime, sender: sender,
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        var closes = 0
        model.onSent = { closes += 1 }
        await model.load()
        model.note = "Synthetic problem description"
        await model.send()
        #expect(closes == 0)
        #expect(model.note == "Synthetic problem description")
        #expect(model.status != nil)
        model.windowClosed()
    }

    @Test("a crash report from the prompt has no note or address and starts at the crashed launch")
    func aCrashReportFromThePromptHasNoNote() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender()
        let since = Date().addingTimeInterval(86_400)
        let model = ReportProblemModel(
            runtime: runtime, sender: sender, kind: .crash, since: since,
            collector: DiagnosticReportCollector(runtime: runtime, hasKey: { _ in false })
        )
        await model.load()
        #expect(!model.takesNote)
        ViewFixtures.render(ReportProblemView(model: model))
        model.note = "Typed before the field was hidden."
        await model.send()
        let sent = try #require(sender.reports.first)
        #expect(sent.kind == .crash)
        #expect(sent.note == nil)
        #expect(sent.contact == nil)
        // Everything in the fixture log is older than `since`.
        #expect(sent.events.isEmpty)
        #expect(sent.crashes.isEmpty)
        #expect(sent.summary.diagnostics.eventsOmitted == 0)
    }

    @Test("automatic sharing's builder stamps a new identity and starts at the given time")
    func automaticSharingsBuilderStampsANewIdentity() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let runtime = try Self.makeRuntime(base: base)
        let sender = RecordingSender(handsOutIdentities: true)
        let build = DiagnosticReportCollector.reportBuilder(runtime: runtime, sender: sender, hasKey: { _ in false })

        let everything = try #require(await build(.automatic, nil))
        #expect(everything.kind == .automatic)
        #expect(everything.reportID == sender.identities.first?.reportID)
        #expect(everything.deletionSecretHash == sender.identities.first?.deletionSecretHash)
        #expect(everything.events.count >= 2)
        #expect(everything.crashes.count == 1)
        #expect(everything.note == nil)

        let crash = try #require(everything.crashes.first)
        let later = try #require(await build(.crash, crash.occurredAt.addingTimeInterval(1)))
        #expect(later.kind == .crash)
        #expect(later.reportID == sender.identities.last?.reportID)
        #expect(sender.identities.count == 2)
        #expect(later.crashes.isEmpty)
        #expect(DiagnosticReportValidator.violations(in: later).isEmpty)
    }

    /// Waits up to two seconds for work handed to a detached task.
    static func wait(until condition: () -> Bool) async throws {
        var waits = 0
        while !condition(), waits < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waits += 1
        }
    }
}

/// Keeps what it is handed and answers that it was sent. With
/// `handsOutIdentities`, it gives out identities as the real sender does and
/// remembers the ones given back.
private final class RecordingSender: DiagnosticReportSending, @unchecked Sendable {
    private let lock = NSLock()
    private var held: [DiagnosticReport] = []
    private var given: [DiagnosticReportIdentity] = []
    private var returned: [DiagnosticReportIdentity] = []
    private let handsOutIdentities: Bool
    private let outcome: DiagnosticSendOutcome?

    init(handsOutIdentities: Bool = false, outcome: DiagnosticSendOutcome? = nil) {
        self.handsOutIdentities = handsOutIdentities
        self.outcome = outcome
    }

    var reports: [DiagnosticReport] { lock.withLock { held } }
    var identities: [DiagnosticReportIdentity] { lock.withLock { given } }
    var discarded: [DiagnosticReportIdentity] { lock.withLock { returned } }

    func prepareReportIdentity() -> DiagnosticReportIdentity? {
        guard handsOutIdentities else { return nil }
        let identity = DiagnosticReportIdentity.provisional()
        lock.withLock { given.append(identity) }
        return identity
    }

    func discardReportIdentity(_ identity: DiagnosticReportIdentity) {
        lock.withLock { returned.append(identity) }
    }

    func send(_ report: DiagnosticReport) async -> DiagnosticSendOutcome {
        lock.withLock { held.append(report) }
        if let outcome { return outcome }
        return .sent(
            DiagnosticReceipt(
                reportID: report.reportID, kind: report.kind, sentAt: report.createdAt,
                receivedAt: report.createdAt, expiresAt: report.createdAt.addingTimeInterval(90 * 86_400),
                bytes: 0
            )
        )
    }
}
