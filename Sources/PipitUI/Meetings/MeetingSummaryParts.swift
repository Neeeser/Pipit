import AppKit
import PipitCore
import SwiftUI

/// The moment an item was said, as a button that plays the recording from
/// there.
struct SummaryTimeChip: View {
    let seconds: Double
    let detail: MeetingReviewModel
    @State private var hovering = false

    var body: some View {
        Button {
            guard let recording = detail.metadata?.id else { return }
            detail.playback.play(recordingID: recording, seconds: seconds)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "play.fill").font(.system(size: 7))
                Text(TranscriptRenderer().timecode(seconds)).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor.opacity(hovering ? 0.16 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .disabled(detail.metadata.map { !detail.playback.canPlay(recordingID: $0.id) } ?? true)
        .help("Play from here")
        .fixedSize()
    }
}

/// Who took a task, in the colour they have on the player's lanes.
struct SummaryOwnerChip: View {
    let owner: String
    let detail: MeetingReviewModel

    var body: some View {
        if owner.isEmpty {
            Text("No owner").font(.caption).foregroundStyle(.tertiary)
        } else {
            let tint = PersonTint.color(
                identity: detail.speakerRows.first { $0.displayName == owner }?.identity?.id, name: owner
            )
            HStack(spacing: 5) {
                Text(owner.prefix(1).uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 17, height: 17)
                    .background(Circle().fill(tint.opacity(0.2)))
                    .overlay(Circle().strokeBorder(tint.opacity(0.45), lineWidth: 1))
                Text(owner).font(.caption).lineLimit(1)
            }
        }
    }
}

/// A section's name and how many items it holds.
struct SummarySectionHeading<Trailing: View>: View {
    let title: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.headline)
            if let count { Text("\(count)").foregroundStyle(.secondary).monospacedDigit() }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.bottom, 4)
    }
}

extension SummarySectionHeading where Trailing == EmptyView {
    init(title: String, count: Int? = nil) {
        self.init(title: title, count: count) { EmptyView() }
    }
}

/// Markdown a summary was written in before it came as structure, or after a
/// person edited `summary.md`: headings, bullets and paragraphs, drawn as such
/// rather than as the characters that mark them.
struct SummaryMarkdownText: View {
    let markdown: String

    private enum Block: Hashable {
        case heading(String)
        case bullet(String)
        case paragraph(String)
    }

    private var blocks: [Block] {
        markdown.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                return .heading(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { return .bullet(String(line.dropFirst(2))) }
            return .paragraph(line)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text):
                    Text(inline(text)).font(.headline).padding(.top, 6)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(.tertiary)
                        Text(inline(text))
                    }
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
        .textSelection(.enabled)
    }

    /// Bold, italics and code inside a line.
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}

enum SummaryClipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// How wide the tab is, so a list can lay its details out in columns when
/// there is room and under the text when there is not.
private struct SummaryWideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var summaryIsWide: Bool {
        get { self[SummaryWideKey.self] }
        set { self[SummaryWideKey.self] = newValue }
    }
}

extension View {
    /// Reads the width this view gets and tells the views inside it whether
    /// that is room for columns.
    func summaryWidth() -> some View {
        modifier(SummaryWidthReader())
    }
}

private struct SummaryWidthReader: ViewModifier {
    @State private var wide = false

    func body(content: Content) -> some View {
        content
            .environment(\.summaryIsWide, wide)
            .onGeometryChange(for: Bool.self) {
                $0.size.width >= 640
            } action: {
                wide = $0
            }
    }
}
