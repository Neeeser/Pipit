import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// What Pipit keeps about its own running, where it is, and a way to delete it.
///
/// The report, export and automatic sharing controls join this page later.
struct DiagnosticsSettingsPane: View {
    let model: SettingsModel
    @State private var usedBytes: Int64?
    @State private var isConfirmingClear = false
    @State private var isClearing = false

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
                    Button("Clear Diagnostics…") { isConfirmingClear = true }
                        .disabled(isClearing)
                }
                .disabled(diagnostics.layout == nil)
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
