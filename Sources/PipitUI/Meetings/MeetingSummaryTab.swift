import PipitCore
import SwiftUI

/// The Summary tab: what the meeting was about, a timeline of what was
/// discussed with the person's own notes in it, then the action items, each
/// with the moment it was said.
///
/// A meeting summarised before the summary came as structure, or whose
/// `summary.md` a person has edited, shows that text in the same order.
struct MeetingSummaryTab: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel
    @State private var copiedTimeline = false
    @State private var copiedActions = false

    private var notes: [MeetingNoteEntry] {
        guard let started = detail.metadata?.startedAt else { return [] }
        return MeetingNoteEntry.entries(in: detail.notes, startedAt: started) + detail.continuationNotes
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                if let suggestion = detail.continuationSuggestion { continuationCard(suggestion) }
                if detail.summaryIsOutOfDate { outOfDateNotice }
                if let structure = detail.generatedSummary, !structure.isEmpty {
                    structured(structure)
                } else {
                    legacy
                }
                if detail.metadata?.hadOtherAudibleTabs == true {
                    SectionCard(title: "Another tab was playing audio", subtitle: nil) {
                        Text(
                            "A browser tab other than the meeting was audible during this "
                                + "recording, so the meeting track may hold that audio as well."
                        )
                        .font(.callout)
                    }
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

    @ViewBuilder private func structured(_ structure: GeneratedSummary) -> some View {
        if !structure.overview.isEmpty {
            Text(structure.overview)
                .font(.system(size: 15))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: 640, alignment: .leading)
        }
        if !structure.topics.isEmpty || !notes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SummarySectionHeading(title: "Timeline", count: structure.topics.count) {
                    copyButton(copied: $copiedTimeline) { structure.notesMarkdown }
                }
                .padding(.bottom, 6)
                SummaryTimeline(topics: structure.topics, notes: notes, detail: detail)
            }
        }
        if !structure.actionItems.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SummarySectionHeading(title: "Action items", count: structure.actionItems.count) {
                    copyButton(copied: $copiedActions) {
                        structure.actionItems.map(Self.line).joined(separator: "\n")
                    }
                }
                Divider()
                ForEach(Array(structure.actionItems.enumerated()), id: \.offset) { _, item in
                    ActionRow(item: item, detail: detail)
                    Divider()
                }
            }
        }
    }

    /// What a meeting shows when its summary has no structure: the text it
    /// has, in the same order, with the person's notes after it.
    @ViewBuilder private var legacy: some View {
        if let summary = detail.summary, !summary.isEmpty {
            SummaryMarkdownText(markdown: summary)
        } else if detail.canGenerateEnrichment {
            writeSummary
        } else {
            Text("No summary yet.").foregroundStyle(.secondary)
        }
        if let generated = detail.generatedNotes, !generated.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SummarySectionHeading(title: "Notes")
                SummaryMarkdownText(markdown: generated)
            }
        }
        if !notes.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                SummarySectionHeading(title: "Your notes", count: notes.count)
                SummaryTimeline(topics: [], notes: notes, detail: detail)
            }
        }
    }

    /// Shown when the recordings changed after the summary was written and the
    /// rewrite has not happened, for want of a key or because the app quit.
    private var outOfDateNotice: some View {
        HStack(spacing: 10) {
            Text("This summary does not cover every recording.")
                .foregroundStyle(.secondary)
            Button {
                detail.generateEnrichment()
            } label: {
                if detail.isEnriching {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Write again", systemImage: "sparkles")
                }
            }
            .disabled(detail.isEnriching)
        }
    }

    /// Offered where a finished meeting has no summary, which is what a meeting
    /// processed before a key was stored looks like.
    ///
    /// Inside the tab rather than in a bar at the top of the pane: the tab the
    /// text belongs to is where a reader goes looking for it. Nothing is
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
                "One request writes the summary and a suggested title. "
                    + "Nothing already on this meeting is replaced."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func continuationCard(_ suggestion: (title: String, reason: String)) -> some View {
        SectionCard(
            title: "Same meeting?",
            subtitle: "Combining links the two recordings."
        ) {
            VStack(alignment: .leading, spacing: 10) {
                Text("This may be a continuation of “\(suggestion.title)”. \(suggestion.reason).")
                    .font(.callout)
                HStack {
                    Button("Combine") { model.combineWithEarlier() }
                    Button("Keep separate") { detail.keepSeparate() }
                }
            }
        }
    }

    private func copyButton(copied: Binding<Bool>, text: @escaping () -> String) -> some View {
        Button(copied.wrappedValue ? "Copied" : "Copy") {
            SummaryClipboard.copy(text())
            copied.wrappedValue = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied.wrappedValue = false
            }
        }
        .buttonStyle(.link)
        .font(.callout)
    }

    /// One task as a line of plain text, for pasting into a tracker or a chat.
    private static func line(_ item: GeneratedSummary.ActionItem) -> String {
        var details: [String] = []
        if !item.owner.isEmpty { details.append(item.owner) }
        if !item.due.isEmpty { details.append("due \(item.due)") }
        return "- \(item.task)" + (details.isEmpty ? "" : " (\(details.joined(separator: ", ")))")
    }
}

/// The topics in the order they came up, each with when it started and its
/// points, and the person's notes under the topic being discussed when each
/// was typed. Notes with no time come last.
struct SummaryTimeline: View {
    let topics: [GeneratedSummary.Topic]
    let notes: [MeetingNoteEntry]
    let detail: MeetingReviewModel

    /// The notes typed while each topic was being discussed: from the moment
    /// it started until the next one did. A note before the first topic goes
    /// with the first.
    private func notes(for index: Int) -> [MeetingNoteEntry] {
        let start = index == 0 ? -Double.infinity : (topics[index].at ?? .infinity)
        let end = index + 1 < topics.count ? (topics[index + 1].at ?? .infinity) : .infinity
        return notes.filter { note in note.at.map { $0 >= start && $0 < end } ?? false }
    }

    /// Notes that no topic takes: those with no time, and every timed note
    /// when there are no topics to put them under.
    private var remaining: [MeetingNoteEntry] {
        topics.isEmpty ? notes : notes.filter { $0.at == nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(topics.enumerated()), id: \.offset) { index, topic in
                TimelineRow(time: topic.at, detail: detail) {
                    Text(topic.title).font(.system(size: 14, weight: .semibold))
                } content: {
                    ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Text("•").foregroundStyle(.tertiary)
                            Text(point).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    ForEach(Array(notes(for: index).enumerated()), id: \.offset) { _, note in
                        NoteRow(note: note, detail: detail)
                    }
                }
            }
            if !remaining.isEmpty {
                TimelineRow(time: nil, detail: detail) {
                    if !topics.isEmpty {
                        Text("Added after the meeting").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                } content: {
                    ForEach(Array(remaining.enumerated()), id: \.offset) { _, note in
                        NoteRow(note: note, detail: detail)
                    }
                }
            }
        }
    }
}

/// A timeline entry: its time in a column of its own when the tab is wide, so
/// the entries read as a timeline, and beside the title when it is not.
private struct TimelineRow<Title: View, Content: View>: View {
    let time: Double?
    let detail: MeetingReviewModel
    @ViewBuilder var title: Title
    @ViewBuilder var content: Content
    @Environment(\.summaryIsWide) private var wide

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if wide {
                Group {
                    if let time { SummaryTimeChip(seconds: time, detail: detail) } else { Color.clear }
                }
                .frame(width: 64, height: 16, alignment: .trailing)
                .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    if !wide, let time { SummaryTimeChip(seconds: time, detail: detail) }
                }
                content
            }
            .textSelection(.enabled)
            .padding(.leading, wide ? 14 : 0)
            .overlay(alignment: .leading) {
                if wide { Rectangle().fill(.quaternary).frame(width: 1) }
            }
        }
        .padding(.bottom, 18)
    }
}

/// One of the person's own notes, set apart from what the model wrote.
private struct NoteRow: View {
    let note: MeetingNoteEntry
    let detail: MeetingReviewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Your note").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            Text(note.text).frame(maxWidth: .infinity, alignment: .leading)
            if let at = note.at { SummaryTimeChip(seconds: at, detail: detail) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.top, 2)
    }
}

/// A task, who does it and by when. In columns when the tab is wide, with the
/// owner and date under the task when it is not. A question someone has to
/// answer carries a question mark where a task has a circle.
private struct ActionRow: View {
    let item: GeneratedSummary.ActionItem
    let detail: MeetingReviewModel
    @Environment(\.summaryIsWide) private var wide

    var body: some View {
        Group {
            if wide {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    mark
                    Text(item.task).frame(maxWidth: .infinity, alignment: .leading)
                    SummaryOwnerChip(owner: item.owner, detail: detail).frame(width: 170, alignment: .leading)
                    due.frame(width: 110, alignment: .leading)
                    time.frame(width: 62, alignment: .trailing)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    mark
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
        }
        .textSelection(.enabled)
        .padding(.vertical, 8)
        .padding(.horizontal, 2)
    }

    private var mark: some View {
        Image(systemName: item.isQuestion ? "questionmark.circle" : "circle")
            .font(.system(size: 12))
            .foregroundStyle(item.isQuestion ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
            .help(item.isQuestion ? "A question to find the answer to" : "")
    }

    private var due: some View {
        Text(item.due.isEmpty ? "No date" : item.due)
            .font(.caption)
            .foregroundStyle(item.due.isEmpty ? .tertiary : .secondary)
            .lineLimit(1)
    }

    @ViewBuilder private var time: some View {
        if let at = item.at { SummaryTimeChip(seconds: at, detail: detail) }
    }
}
