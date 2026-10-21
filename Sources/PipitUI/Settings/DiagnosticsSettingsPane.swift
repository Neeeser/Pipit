import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// What Pipit keeps about its own running, where it is, a way to save it as
/// a report, and a way to delete it.
///
/// The sending and automatic sharing controls join this page later.
struct DiagnosticsSettingsPane: View {
    let model: SettingsModel
    @State private var usedBytes: Int64?
    @State private var isConfirmingClear = false
    @State private var isClearing = false
    @State private var isExporting = false
    @State private var exportStatus: String?

    private var diagnostics: DiagnosticLog { model.runtime.diagnostics }

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
                    Button("Clear Diagnostics…") { isConfirmingClear = true }
                        .disabled(isClearing)
                }
                .disabled(diagnostics.layout == nil)
                if let exportStatus {
                    Text(exportStatus).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear diagnostics?", isPresented: $isConfirmingClear) {
            Button("Clear Diagnostics", role: .destructive) { clear() }
        } message: {
            Text("Deletes the event log and crash summaries.")
        }
        .task { await refreshSize() }
    }

    /// The folder exists from the first event on, which can be after the page
    /// opens, so it is made here rather than letting the Finder find nothing.
    private func showInFinder() {
        guard let root = diagnostics.layout?.root else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// The same report Report a Problem previews, without a note, saved as a
    /// `.zip` where the person chooses.
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

    private func clear() {
        isClearing = true
        Task {
            await diagnostics.clear()
            await refreshSize()
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
