import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// What Pipit keeps about its own running, where it is, a way to save it as
/// a report, and a way to delete it; whether reports are shared
/// automatically; and the reports sent.
struct DiagnosticsSettingsPane: View {
    let model: SettingsModel
    @State private var usedBytes: Int64?
    @State private var isConfirmingClear = false
    @State private var isClearing = false
    @State private var isExporting = false
    @State private var exportStatus: String?
    @State private var isConfirmingSharing = false
    @State private var receipts: [DiagnosticReceipt] = []
    @State private var pendingDeletion: DiagnosticReceipt?
    @State private var busyReportID: String?
    @State private var notice: Notice?

    /// A line under one sent report, after an action on it.
    struct Notice: Equatable {
        var reportID: String
        var text: String
    }

    private var diagnostics: DiagnosticLog { model.runtime.diagnostics }
    private var reports: DiagnosticReportSender? { model.runtime.reports }

    var body: some View {
        Form {
            Section("Diagnostics") {
                LabeledContent("Contains") { Text("App events and errors") }
                LabeledContent("Kept for") { Text("Up to 14 days") }
                LabeledContent("Size") { Text(usedBytes.map(Self.size) ?? "Calculating…") }
                if let root = diagnostics.layout?.root {
                    Text(root.path)
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Show in Finder") { showInFinder() }
                    Button("Export Diagnostics…") { export() }
                        .disabled(isExporting)
                }
                .disabled(diagnostics.layout == nil)
                if let exportStatus {
                    Text(exportStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("Share diagnostics automatically", isOn: sharingBinding)
                    .disabled(reports == nil)
            }
            Section("Sent reports") {
                if receipts.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(receipts) { receipt in
                    SentReportRow(
                        receipt: receipt,
                        now: Date(),
                        isBusy: busyReportID == receipt.reportID,
                        notice: notice?.reportID == receipt.reportID ? notice?.text : nil,
                        copy: { copyDeletionCode(receipt) },
                        delete: { pendingDeletion = receipt }
                    )
                }
            }
            // Last, beside the sent reports it can also forget.
            Section {
                Button("Clear Diagnostics…") { isConfirmingClear = true }
                    .disabled(isClearing || diagnostics.layout == nil)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear diagnostics?", isPresented: $isConfirmingClear) {
            Button("Clear Diagnostics", role: .destructive) { clear(forgettingSentReports: false) }
            if !receipts.isEmpty {
                Button("Clear and Forget Sent Reports", role: .destructive) { clear(forgettingSentReports: true) }
            }
        } message: {
            Text(
                receipts.isEmpty
                    ? "Deletes the event log and crash summaries."
                    : "Deletes the event log and crash summaries. Forgetting sent reports also deletes "
                        + "their deletion codes from this Mac."
            )
        }
        .confirmationDialog(
            "Delete this report from the server?", isPresented: isConfirmingDeletion, presenting: pendingDeletion
        ) { receipt in
            Button("Delete from Server", role: .destructive) { delete(receipt) }
        }
        .sheet(isPresented: $isConfirmingSharing) {
            AutomaticSharingSheet(
                turnOn: {
                    isConfirmingSharing = false
                    setSharing(true)
                },
                cancel: { isConfirmingSharing = false }
            )
        }
        .task {
            await refreshSize()
            await refreshReceipts()
        }
    }

    // MARK: - automatic sharing

    /// Turning it on asks first; turning it off does not.
    private var sharingBinding: Binding<Bool> {
        Binding(
            get: { model.runtime.settings.sharesDiagnosticsAutomatically },
            set: { isOn in
                if isOn {
                    isConfirmingSharing = true
                } else {
                    setSharing(false)
                }
            }
        )
    }

    private func setSharing(_ isOn: Bool) {
        var settings = model.runtime.settings
        settings.sharesDiagnosticsAutomatically = isOn
        model.runtime.update(settings: settings)
    }

    // MARK: - sent reports

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
    }

    /// The secret is read from the Keychain off the main thread, which can
    /// raise a prompt on a build the item does not trust.
    private func copyDeletionCode(_ receipt: DiagnosticReceipt) {
        guard let reports else { return }
        Task {
            guard let code = await reports.deletionCode(reportID: receipt.reportID) else {
                notice = Notice(reportID: receipt.reportID, text: "This Mac no longer has the deletion code.")
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
            notice = Notice(reportID: receipt.reportID, text: "Deletion code copied")
        }
    }

    private func delete(_ receipt: DiagnosticReceipt) {
        guard let reports else { return }
        pendingDeletion = nil
        busyReportID = receipt.reportID
        Task {
            let outcome = await reports.deleteFromServer(reportID: receipt.reportID)
            busyReportID = nil
            switch outcome {
            case .deleted, .alreadyGone:
                notice = nil
                await refreshReceipts()
            case .noSecret:
                notice = Notice(reportID: receipt.reportID, text: "This Mac no longer has the deletion code.")
            case .failed:
                notice = Notice(reportID: receipt.reportID, text: "The server could not be reached. Try again later.")
            }
        }
    }

    private func refreshReceipts() async {
        receipts = await reports?.receipts() ?? []
    }

    // MARK: - files

    /// The folder exists from the first event on, which can be after the page
    /// opens, so it is made here rather than letting the Finder find nothing.
    private func showInFinder() {
        guard let root = diagnostics.layout?.root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// The same report Report a Problem previews, without a note, saved as a
    /// `.zip` where the person chooses. It is never sent, so it carries a
    /// provisional identity and no deletion secret is made for it.
    private func export() {
        isExporting = true
        exportStatus = nil
        Task {
            defer { isExporting = false }
            let contents = await DiagnosticReportCollector(runtime: model.runtime).contents()
            do {
                let bundle = try await DiagnosticReportCollector.bundle(
                    contents, kind: .user, identity: .provisional(), createdAt: Date()
                )
                if let url = try await DiagnosticExportPanel.save(bundle) {
                    exportStatus = "Saved \(url.lastPathComponent)"
                }
            } catch {
                Log.ui.error("diagnostics not exported: \(String(describing: error), privacy: .public)")
                exportStatus = "Could not save the report."
            }
        }
    }

    /// Queued reports go with the rest, and their deletion secrets with them.
    /// Sent reports and their codes stay unless the person chose to forget
    /// them.
    private func clear(forgettingSentReports: Bool) {
        isClearing = true
        Task {
            await reports?.discardOutbox()
            if forgettingSentReports { await reports?.forgetSentReports() }
            await diagnostics.clear()
            await refreshSize()
            await refreshReceipts()
            isClearing = false
        }
    }

    private func refreshSize() async {
        guard let layout = diagnostics.layout else {
            usedBytes = 0
            return
        }
        usedBytes = await Task.detached(priority: .utility) { layout.usedBytes() }.value
    }

    static func size(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file))
    }
}

/// One sent report: when, what kind, its ID, how long the server keeps it,
/// and the two things to do with it.
struct SentReportRow: View {
    let receipt: DiagnosticReceipt
    let now: Date
    let isBusy: Bool
    let notice: String?
    let copy: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Self.kindName(receipt.kind))
                Spacer()
                Text(receipt.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            Text(receipt.reportID)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text(Self.retention(receipt, now: now))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Copy Deletion Code", action: copy)
                Button("Delete from Server…", action: delete)
                if isBusy { ProgressView().controlSize(.small) }
            }
            .disabled(isBusy)
            if let notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    static func kindName(_ kind: DiagnosticReport.Kind) -> String {
        switch kind {
        case .user: "Problem report"
        case .crash: "Crash report"
        case .automatic: "Daily report"
        }
    }

    static func retention(_ receipt: DiagnosticReceipt, now: Date) -> String {
        let date = receipt.expiresAt.formatted(date: .abbreviated, time: .omitted)
        return receipt.expiresAt > now ? "On the server until \(date)" : "Expired on \(date)"
    }
}

/// What turning on automatic sharing sends, asked before it is turned on.
struct AutomaticSharingSheet: View {
    let turnOn: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Share diagnostics automatically?").font(.headline)
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "After Pipit quits unexpectedly: the crash summary and recent app events.",
                    systemImage: "exclamationmark.triangle"
                )
                Label("Once a day: the app events since the last report.", systemImage: "calendar")
                Label(
                    "With each report: the app and macOS versions, the Mac model, and Pipit's settings "
                        + "and permissions.",
                    systemImage: "info.circle"
                )
                Label(
                    "Reports are kept on Pipit's server for 90 days. Delete any of them from Sent reports.",
                    systemImage: "trash"
                )
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button("Turn On", action: turnOn).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
