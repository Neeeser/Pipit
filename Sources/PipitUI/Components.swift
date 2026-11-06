import PipitCore
import SwiftUI

public enum Format {
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    public static func shortDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 3_600 { return "\(total / 3_600)h \((total % 3_600) / 60)m" }
        if total >= 60 { return "\(total / 60)m" }
        return "\(total)s"
    }

    /// Just the clock time, for a row already under a heading that says which
    /// day it was.
    public static func timeOfDay(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// What a row says under a heading that may or may not name a day.
    ///
    /// Today and Yesterday name one, so a clock time is enough there. Every
    /// other heading is a month, and a clock time alone left no way to tell
    /// which day a meeting was without opening it.
    public static func listDate(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        if calendar.isDate(date, inSameDayAs: now) || date > now
            || (yesterday.map { calendar.isDate(date, inSameDayAs: $0) } ?? false)
        {
            return timeOfDay(date)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    public static func day(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return "Today \(date.formatted(date: .omitted, time: .shortened))"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Yesterday \(date.formatted(date: .omitted, time: .shortened))"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// The status of one processing stage, for the meetings window.
public struct StageBadge: View {
    public let state: ProcessingState

    public init(state: ProcessingState) {
        self.state = state
    }

    public var body: some View {
        Text(state.displayName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(background, in: Capsule())
            .foregroundStyle(foreground)
    }

    private var background: Color {
        switch state {
        case .complete: .green.opacity(0.15)
        case .failed: .red.opacity(0.15)
        default: .secondary.opacity(0.15)
        }
    }

    private var foreground: Color {
        switch state {
        case .complete: .green
        case .failed: .red
        default: .secondary
        }
    }
}

struct SectionCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One permission's state and the control that changes it.
///
/// Shared by the Permissions tab in Settings and by the setup wizard's own
/// summary, so both report a permission the same way.
struct PermissionRow: View {
    let status: PermissionStatus
    let onRequest: () async -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(status.kind.title).font(.body.weight(.medium))
                    if status.kind.isRequired {
                        Text("Required").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(status.kind.rationale).font(.caption).foregroundStyle(.secondary)
                if let advice = status.advice {
                    Text(advice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            actions
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status.kind.title), \(status.state.rawValue)")
    }

    @ViewBuilder
    private var actions: some View {
        switch status.state {
        case .granted:
            EmptyView()
        case .notDetermined:
            Button("Enable") { Task { await onRequest() } }
        case .denied, .grantedButNotEffective:
            if !status.kind.isGrantedByPrompt {
                // Requesting first is what adds Pipit to the list in System
                // Settings. Without it the pane opens on a list the app is not in
                // and there is nothing to switch on.
                Button("Enable in System Settings…") { Task { await onRequest() } }
            } else {
                Button("Open System Settings…") { onOpenSettings() }
            }
        }
    }

    private var symbol: String {
        switch status.state {
        case .granted: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .notDetermined: "circle"
        case .grantedButNotEffective: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status.state {
        case .granted: .green
        case .denied: .red
        case .notDetermined: .secondary
        case .grantedButNotEffective: .orange
        }
    }
}

/// A pill-shaped button: filled with the accent colour when `prominent`, and
/// with a quiet fill otherwise.
///
/// Drawn here rather than asked of the system, because the bordered styles
/// ignore a capsule border shape at these sizes and draw a rounded rectangle.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    /// A colour for the label and a light fill of it behind, the way a folder
    /// tag is drawn. Ignored when `prominent`.
    var tint: Color?
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize

    func makeBody(configuration: Configuration) -> some View {
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            // The size of the segmented control's labels, so a pill beside the
            // tabs reads as the same kind of control rather than a louder one.
            .font(.system(size: small ? 11 : 12))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, small ? 9 : 11)
            // One height per size whatever the label holds, so a pill with an
            // icon and one with text alone line up side by side.
            .frame(height: small ? 20 : 24)
            .foregroundStyle(prominent ? Color.white : tint ?? Color.primary)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : isEnabled ? 1 : 0.45)
    }

    private var fill: Color {
        if prominent { return .accentColor }
        return tint?.opacity(0.18) ?? Color.primary.opacity(0.1)
    }
}

extension View {
    /// The search field at the top of a sidebar, as the Meetings and People
    /// windows draw it: a magnifying glass and the field on a faint rounded
    /// fill, with no border.
    func sidebarSearchField() -> some View {
        padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

extension View {
    /// The window's name in bold at the leading end of the toolbar, where
    /// System Settings shows the name of its pane.
    ///
    /// Also what gives a split-view window its look: with no item in the
    /// detail's toolbar, the window buttons sit on a strip above the sidebar
    /// and a line runs under the toolbar.
    func toolbarTitle(_ title: String) -> some View {
        toolbar {
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) { ToolbarTitleText(title: title) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) { ToolbarTitleText(title: title) }
            }
        }
    }

    /// The plain page colour behind a split-view window's detail pane, white
    /// or near black, up under the toolbar. The window's own colour takes a
    /// tint from the desktop picture, and grouped forms fill themselves with
    /// it, so without this the pane beside a meeting's transcript and the
    /// panes of the other windows each came out a different grey.
    func detailBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
    }

    /// A solid grey behind a split-view window's sidebar. The system sidebar
    /// is see-through glass while its window is in front and turns opaque
    /// only once the window falls behind, so the same window changed colour
    /// whenever it was focused.
    func sidebarBackground() -> some View {
        scrollContentBackground(.hidden)
            .background(Color.panel)
    }
}

extension Color {
    /// The fill of the panels that float over the page: the sidebar and the
    /// summary beside the transcript.
    static let panel = Color(
        nsColor: NSColor(name: "PipitPanel") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 46 / 255, alpha: 1)
                : NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 245 / 255, alpha: 1)
        }
    )
}

private struct ToolbarTitleText: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .bold))
            .fixedSize()
            .padding(.leading, 4)
    }
}
