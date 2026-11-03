import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// The floating window that shows the live transcript during a call.
///
/// A non-activating panel: clicking it does not take focus from the call, and
/// it floats over full-screen meeting windows. It opens only when asked, from
/// the menu or by the setting that opens it with each recording.
@MainActor
final class LiveTranscriptPanel: NSPanel {
    static let expandedSize = NSSize(width: 360, height: 460)
    static let tuckedHeight: CGFloat = 64

    init(model: LiveTranscriptModel, openMeeting: @escaping (String) -> Void) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        title = "Live Transcript"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 280, height: Self.tuckedHeight)
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        let view = LiveTranscriptView(
            model: model,
            onTuck: { [weak self] tucked in self?.tuck(tucked) },
            openMeeting: openMeeting
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
        setFrameAutosaveName("LiveTranscriptPanel")
        if !setFrameUsingName("LiveTranscriptPanel") { placeTopRight() }
    }

    override var canBecomeKey: Bool { true }

    /// Out of the way by default: the top right of the screen, under the
    /// menu bar, where meeting apps rarely put controls.
    private func placeTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: screen.maxX - Self.expandedSize.width - 16,
            y: screen.maxY - Self.expandedSize.height - 12
        )
        setFrame(NSRect(origin: origin, size: Self.expandedSize), display: false)
    }

    private var expandedHeight: CGFloat = expandedSize.height

    /// Shrinks to the caption strip or grows back, keeping the top edge where
    /// it is so the strip stays where the window was.
    func tuck(_ tucked: Bool) {
        var frame = self.frame
        let top = frame.maxY
        if tucked {
            if frame.height > Self.tuckedHeight + 1 { expandedHeight = frame.height }
            frame.size.height = Self.tuckedHeight
        } else {
            frame.size.height = max(expandedHeight, 240)
        }
        frame.origin.y = top - frame.height
        setFrame(frame, display: true, animate: true)
    }

    /// Keeps the window out of screen shares and screenshots, or lets it in.
    func applySharing(hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }
}

/// What the live window draws.
struct LiveTranscriptView: View {
    @Bindable var model: LiveTranscriptModel
    let onTuck: (Bool) -> Void
    let openMeeting: (String) -> Void

    @State private var tucked = false
    @State private var atBottom = true
    @State private var note = ""
    @State private var hovering = false
    @State private var idleTask: Task<Void, Never>?
    @FocusState private var noteFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if tucked {
                strip
            } else {
                header
                Divider().opacity(0.4)
                content
                if model.state == .live || model.state == .starting {
                    noteField
                }
            }
        }
        .background(.regularMaterial)
        .onHover { inside in
            hovering = inside
            if inside, tucked { setTucked(false) }
            scheduleTuck()
        }
        .onAppear { scheduleTuck() }
        .onChange(of: model.mention?.id) { _, mention in
            if mention != nil, tucked { setTucked(false) }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.state == .live ? Color.red : Color.secondary)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.meetingTitle.isEmpty ? "Live Transcript" : model.meetingTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 4)
            Button {
                setTucked(true)
            } label: {
                Image(systemName: "rectangle.compress.vertical")
            }
            .buttonStyle(.borderless)
            .help("Shrink to one line")
        }
        .padding(.horizontal, 14)
        .padding(.top, 30)
        .padding(.bottom, 10)
    }

    private var statusLine: String {
        switch model.state {
        case .idle: "No recording"
        case .starting: "Starting"
        case .live: Format.duration(model.elapsed)
        case .ended: "Ended at \(Format.duration(model.elapsed))"
        case .off: "Live transcript is off"
        case .unavailable: "Live transcript unavailable"
        }
    }

    // MARK: transcript

    @ViewBuilder private var content: some View {
        switch model.state {
        case .off:
            message("Live transcript is off. Turn it on in Settings, under Recording.")
        case .unavailable(let reason):
            message(reason)
        case .idle:
            message("The transcript appears here while a meeting records.")
        default:
            if model.transcript.lines.isEmpty {
                message(model.state == .ended ? "Nothing was heard." : "Listening")
            } else {
                transcript
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(20)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.[0].id) { group in
                            LiveLineGroup(model: model, lines: group)
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 30
                } action: { _, isAtBottom in
                    atBottom = isAtBottom
                }
                .onChange(of: model.transcript.lines) { _, _ in
                    if atBottom { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }

                if !atBottom {
                    Button {
                        withAnimation { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Label("Back to live", systemImage: "arrow.down")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.bottom, 8)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if model.state == .ended, let meetingID = model.meetingID {
                    Button("Open Meeting") { openMeeting(meetingID) }
                        .controlSize(.small)
                        .padding(10)
                }
            }
        }
    }

    private static let bottom = "live-bottom"

    /// Consecutive lines from one speaker, shown under one name.
    private var groups: [[LiveTranscriptLine]] {
        var out: [[LiveTranscriptLine]] = []
        for line in model.transcript.lines {
            if let last = out.last?.last, last.kind != .note, line.kind != .note,
                model.speakerKey(of: last) == model.speakerKey(of: line), line.start - last.end < 8
            {
                out[out.count - 1].append(line)
            } else {
                out.append([line])
            }
        }
        return out
    }

    // MARK: notes

    private var noteField: some View {
        HStack(spacing: 6) {
            TextField("Type a note", text: $note)
                .textFieldStyle(.roundedBorder)
                .focused($noteFocused)
                .onSubmit {
                    model.addNote(note)
                    note = ""
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: strip

    /// One line that follows the words: the newest at the right edge, older
    /// ones sliding off the left, each run led by a short speaker name.
    private var strip: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let mention = model.mention {
                Text("\(firstName(model.speakerName(of: mention))) mentioned you")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            HStack(spacing: 8) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                caption
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .frame(maxHeight: .infinity, alignment: .center)
        .contentShape(Rectangle())
        .onTapGesture { setTucked(false) }
    }

    private var caption: Text {
        let recent = model.transcript.lines.filter { $0.kind != .note }.suffix(3)
        guard !recent.isEmpty else { return Text(model.state == .live ? "Listening" : statusLine) }
        var text = Text("")
        for (index, line) in recent.enumerated() {
            let name = Text(firstName(model.speakerName(of: line)) + " ")
                .font(.caption.weight(.medium))
                .foregroundColor(LiveSpeakerColor.color(for: model.speakerKey(of: line)))
            let said = Text(line.text).foregroundColor(line.isFinal ? .primary : .secondary)
            text = text + (index > 0 ? Text("   ") : Text("")) + name + said
        }
        return text.font(.callout)
    }

    private func firstName(_ name: String) -> String {
        name.hasPrefix("Speaker ") ? name : (name.split(separator: " ").first.map(String.init) ?? name)
    }

    // MARK: tucking

    private func setTucked(_ value: Bool) {
        guard tucked != value else { return }
        withAnimation(.easeInOut(duration: 0.2)) { tucked = value }
        onTuck(value)
    }

    /// Shrinks to the strip after half a minute without the pointer over the
    /// window, unless a note is being typed or the person is reading back.
    private func scheduleTuck() {
        idleTask?.cancel()
        guard !hovering, !tucked else { return }
        idleTask = Task {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled, !hovering, note.isEmpty, !noteFocused, atBottom,
                model.state == .live
            else { return }
            setTucked(true)
        }
    }
}

/// The lines of one speaker turn.
private struct LiveLineGroup: View {
    let model: LiveTranscriptModel
    let lines: [LiveTranscriptLine]

    var body: some View {
        let first = lines[0]
        let mentioned = lines.contains { $0.id == model.mention?.id }
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.speakerName(of: first))
                    .font(.caption.weight(.semibold))
                    .foregroundColor(LiveSpeakerColor.color(for: model.speakerKey(of: first)))
                Text(Format.duration(first.start))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            lines.reduce(Text("")) { text, line in
                text
                    + Text((line.id == first.id ? "" : " ") + line.text)
                    .foregroundColor(line.isFinal ? .primary : .secondary)
            }
            .font(first.kind == .note ? .callout.italic() : .callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(mentioned ? 6 : 0)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(mentioned ? Color.accentColor.opacity(0.12) : .clear)
        )
    }
}

/// One colour per speaker, the same in the list and the strip.
enum LiveSpeakerColor {
    private static let palette: [Color] = [.blue, .purple, .green, .orange, .pink, .teal, .indigo, .brown]

    static func color(for key: String) -> Color {
        switch key {
        case "you": return .accentColor
        case "note": return .secondary
        case "others": return .secondary
        default:
            let number =
                Int(key.split(separator: "-").last ?? "") ?? key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[abs(number) % palette.count]
        }
    }
}
