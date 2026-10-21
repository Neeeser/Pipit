import PipitCore
import PipitServices
import SwiftUI

/// Report a Problem: what the report holds, section by section, an optional
/// note and address, and the two ways to hand it over.
struct ReportProblemView: View {
    @Bindable var model: ReportProblemModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Optional") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("What happened")
                        TextEditor(text: $model.note)
                            .font(.body)
                            .frame(minHeight: 80)
                            .scrollContentBackground(.hidden)
                    }
                    TextField("Email", text: $model.contact, prompt: Text("For a reply"))
                }
                Section("Report") {
                    switch model.phase {
                    case .loading:
                        ProgressView().controlSize(.small)
                    case .failed:
                        Text("Could not build the report.").foregroundStyle(.secondary)
                    case .ready:
                        if let preview = model.preview {
                            ReportSections(bundle: preview)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.note) { model.holdToLimits() }
            .onChange(of: model.contact) { model.holdToLimits() }

            Divider()
            HStack(spacing: 12) {
                if let status = model.status {
                    Text(status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Export…") { Task { await model.export() } }
                Button("Send") { Task { await model.send() } }
                    .keyboardShortcut(.defaultAction)
            }
            .disabled(model.phase != .ready || model.isWorking)
            .padding(16)
        }
        .frame(minWidth: 520, minHeight: 480)
        .task { await model.load() }
    }
}

/// The report, one collapsible section per part, each as the JSON it is
/// sent as.
private struct ReportSections: View {
    let bundle: DiagnosticBundle

    private var report: DiagnosticReport { bundle.report }

    var body: some View {
        let diagnostics = report.summary.diagnostics
        LabeledContent("Size") {
            Text(Int64(bundle.size.compressed).formatted(.byteCount(style: .file)))
        }
        JSONSection(title: "App", value: report.app)
        JSONSection(title: "Mac", value: report.system)
        JSONSection(title: "Settings", value: report.summary.settings)
        JSONSection(title: "Permissions", value: report.summary.permissions)
        JSONSection(title: "Models", value: report.summary.models)
        JSONSection(title: "Browser add-ons", value: report.summary.browserAddOns)
        JSONSection(title: "Storage", value: report.summary.storage)
        JSONSection(
            title: "Recent failures", value: report.summary.recentFailures, count: report.summary.recentFailures.count)
        JSONSection(title: "Diagnostics", value: diagnostics)
        EventsSection(
            events: report.events, total: diagnostics.eventsIncluded + diagnostics.eventsOmitted
        )
        JSONSection(title: "Crashes", value: report.crashes, count: report.crashes.count)
        JSONSection(title: "Report", value: ReportHeader(report: report))
    }
}

/// The fields that name the report itself.
private struct ReportHeader: Encodable {
    let schemaVersion: Int
    let reportID: String
    let kind: DiagnosticReport.Kind
    let createdAt: Date

    init(report: DiagnosticReport) {
        schemaVersion = report.schemaVersion
        reportID = report.reportID
        kind = report.kind
        createdAt = report.createdAt
    }
}

private struct JSONSection<Value: Encodable>: View {
    let title: String
    let value: Value
    var count: Int?

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                Text(Self.pretty(value))
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } label: {
            LabeledContent(title) {
                if let count { Text(count.formatted()) }
            }
        }
    }

    /// Pretty-printed with the report's own encoder, so the preview reads
    /// as the report does.
    static func pretty(_ value: Value) -> String {
        let encoder = DiagnosticCoding.makeReportEncoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Up to twenty thousand lines, one row each, laid out as they scroll in.
private struct EventsSection: View {
    let events: [JSONValue]
    /// Every event on this Mac the report could have carried.
    let total: Int

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if isExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(events.indices, id: \.self) { index in
                            Text(Self.line(events[index]))
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 240)
            }
        } label: {
            LabeledContent("Events") {
                Text(
                    events.count == total
                        ? events.count.formatted() : "\(events.count.formatted()) of \(total.formatted())"
                )
            }
        }
    }

    /// One event as its line.
    static func line(_ event: JSONValue) -> String {
        let encoder = DiagnosticCoding.makeReportEncoder()
        guard let data = try? encoder.encode(event) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
