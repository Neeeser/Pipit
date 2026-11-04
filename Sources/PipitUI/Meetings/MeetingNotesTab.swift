import PipitCore
import SwiftUI

/// The Notes tab: the person's own notes, then the topics the meeting covered
/// in order, each with what someone who missed it would need.
///
/// Expected participants sit folded at the bottom: they set up speaker
/// matching rather than record what was said.
struct MeetingNotesTab: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel
    @State private var copied = false
    @State private var showsParticipants = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let suggestion = detail.continuationSuggestion { continuationCard(suggestion) }
                yourNotes
                if let structure = detail.generatedSummary, !structure.topics.isEmpty {
                    topics(structure)
                } else if let generated = detail.generatedNotes, !generated.isEmpty {
                    SectionCard(title: "Meeting notes", subtitle: "Written from the transcript.") {
                        SummaryMarkdownText(markdown: generated)
                    }
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
                participants
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .summaryWidth()
        }
    }

    private var yourNotes: some View {
        SectionCard(title: "Your notes", subtitle: "Saved as you type.") {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: detail.notesBinding())
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                Text(
                    "Context such as “Northwind call with me, my boss Chris and Tim” is "
                        + "used as input when speaker names are suggested."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func topics(_ structure: GeneratedSummary) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SummarySectionHeading(title: "Topics discussed", count: structure.topics.count) {
                Button(copied ? "Copied" : "Copy") {
                    SummaryClipboard.copy(structure.notesMarkdown)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
            }
            .padding(.bottom, 6)
            ForEach(Array(structure.topics.enumerated()), id: \.offset) { _, topic in
                TopicRow(topic: topic, detail: detail)
            }
        }
    }

    private var participants: some View {
        DisclosureGroup(isExpanded: $showsParticipants) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Relaxes the margin a saved voice needs. It never forces a name onto a speaker who did not match.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(detail.expectedParticipants, id: \.self) { name in
                    HStack {
                        Text(name).font(.callout)
                        Spacer()
                        Button("Remove") { detail.removeParticipant(name) }
                            .buttonStyle(.link).font(.caption)
                    }
                }
                HStack {
                    TextField("Add a name", text: detail.text(\.participantDraft))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { detail.addParticipant() }
                    Button("Add") { detail.addParticipant() }
                        .disabled(detail.participantDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Changing this re-runs speaker matching.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text("Expected participants")
                if !detail.expectedParticipants.isEmpty {
                    Text("\(detail.expectedParticipants.count)").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .font(.headline)
        }
        .padding(.top, 4)
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
}

/// One topic: its title, when it started, and its points. The time sits in a
/// column of its own when the tab is wide, so the topics read as a timeline.
private struct TopicRow: View {
    let topic: GeneratedSummary.Topic
    let detail: MeetingReviewModel
    @Environment(\.summaryIsWide) private var wide

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if wide {
                Group {
                    if let at = topic.at { SummaryTimeChip(seconds: at, detail: detail) } else { Color.clear }
                }
                .frame(width: 64, alignment: .trailing)
                .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(topic.title).font(.system(size: 14, weight: .semibold))
                    if !wide, let at = topic.at { SummaryTimeChip(seconds: at, detail: detail) }
                }
                ForEach(Array(topic.points.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(point).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
