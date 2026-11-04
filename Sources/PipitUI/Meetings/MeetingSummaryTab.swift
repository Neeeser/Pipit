import PipitCore
import SwiftUI

/// The Summary tab: what the meeting was about, then who does what, what was
/// decided and what is still open, each with the moment it was said.
///
/// A meeting summarised before the summary came as structure, or whose
/// `summary.md` a person has edited, shows that text instead.
struct MeetingSummaryTab: View {
    let detail: MeetingReviewModel
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let structure = detail.generatedSummary, !structure.isEmpty {
                    StructuredSummary(structure: structure, detail: detail, copied: $copied)
                } else if let summary = detail.summary, !summary.isEmpty {
                    SummaryMarkdownText(markdown: summary)
                } else if detail.canGenerateEnrichment {
                    writeSummary
                } else {
                    Text("No summary yet.").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .summaryWidth()
        }
    }

    /// Offered where a finished meeting has no summary, which is what a meeting
    /// processed before a key was stored looks like.
    ///
    /// Inside the section rather than in a bar at the top of the pane: the tab
    /// the text belongs to is where a reader goes looking for it. Nothing is
    /// replaced, so there is nothing to confirm and no bar to dismiss.
    private var writeSummary: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("No summary was written for this meeting.")
                .foregroundStyle(.secondary)
            Button {
                detail.generateEnrichment()
            } label: {
                if detail.isEnriching {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Reading the transcript…")
                    }
                } else {
                    Label("Write a summary", systemImage: "sparkles")
                }
            }
            .disabled(detail.isEnriching)
            Text(
                "One request writes the summary, the notes and a suggested title. "
                    + "Nothing already on this meeting is replaced."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StructuredSummary: View {
    let structure: GeneratedSummary
    let detail: MeetingReviewModel
    @Binding var copied: Bool
    @Environment(\.summaryIsWide) private var wide

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !structure.overview.isEmpty {
                Text(structure.overview)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: 640, alignment: .leading)
            }
            if !structure.actionItems.isEmpty { actions }
            let lists = HStackOrVStack(wide: wide) {
                if !structure.decisions.isEmpty {
                    ItemList(
                        title: "Decisions", items: structure.decisions, symbol: "checkmark", tint: .secondary,
                        detail: detail)
                }
                if !structure.openQuestions.isEmpty {
                    ItemList(
                        title: "Open questions", items: structure.openQuestions, symbol: "questionmark.circle",
                        tint: .orange, detail: detail)
                }
            }
            if !structure.decisions.isEmpty || !structure.openQuestions.isEmpty { lists }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummarySectionHeading(title: "Action items", count: structure.actionItems.count) {
                Button(copied ? "Copied" : "Copy") {
                    SummaryClipboard.copy(structure.actionItems.map(Self.line).joined(separator: "\n"))
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            Divider()
            ForEach(Array(structure.actionItems.enumerated()), id: \.offset) { _, item in
                ActionRow(item: item, detail: detail)
                Divider()
            }
        }
    }

    /// One task as a line of plain text, for pasting into a tracker or a chat.
    private static func line(_ item: GeneratedSummary.ActionItem) -> String {
        var details: [String] = []
        if !item.owner.isEmpty { details.append(item.owner) }
        if !item.due.isEmpty { details.append("due \(item.due)") }
        return "- \(item.task)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
    }
}

/// A task, who does it and by when. In columns when the tab is wide, with the
/// owner and date under the task when it is not.
private struct ActionRow: View {
    let item: GeneratedSummary.ActionItem
    let detail: MeetingReviewModel
    @Environment(\.summaryIsWide) private var wide

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(item.task).frame(maxWidth: .infinity, alignment: .leading)
                    SummaryOwnerChip(owner: item.owner, detail: detail).frame(width: 170, alignment: .leading)
                    due.frame(width: 110, alignment: .leading)
                    time.frame(width: 62, alignment: .trailing)
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.task).frame(maxWidth: .infinity, alignment: .leading)
                        time
                    }
                    HStack(spacing: 14) {
                        SummaryOwnerChip(owner: item.owner, detail: detail)
                        due
                    }
                }
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
    }

    private var due: some View {
        Label(item.due.isEmpty ? "No date" : item.due, systemImage: "calendar")
            .font(.caption)
            .foregroundStyle(item.due.isEmpty ? .tertiary : .secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var time: some View {
        if let at = item.at { SummaryTimeChip(seconds: at, detail: detail) }
    }
}

/// Decisions or open questions: one line each, with its moment.
private struct ItemList: View {
    let title: String
    let items: [GeneratedSummary.Item]
    let symbol: String
    let tint: Color
    let detail: MeetingReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummarySectionHeading(title: title, count: items.count)
            Divider()
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: symbol).font(.caption).foregroundStyle(tint)
                    Text(item.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    if let at = item.at { SummaryTimeChip(seconds: at, detail: detail) }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 2)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// Side by side when there is room for both, one above the other when not.
private struct HStackOrVStack<Content: View>: View {
    let wide: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if wide {
            HStack(alignment: .top, spacing: 28) { content }
        } else {
            VStack(alignment: .leading, spacing: 24) { content }
        }
    }
}
