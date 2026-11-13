import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// The floating window that shows the live transcript during a call.
///
/// A borderless, non-activating panel: clicking it does not take focus from
/// the call, it floats over full-screen meeting windows, and it draws its own
/// rounded glass instead of a title bar. It opens only when asked, from the
/// menu or by the setting that opens it with each recording.
@MainActor
final class LiveTranscriptPanel: NSPanel {
    static let expandedSize = NSSize(width: 352, height: 540)
    static let tuckedSize = NSSize(width: 300, height: 58)
    static let tuckedMentionHeight: CGFloat = 86

    private var expandedFrame: NSRect?

    init(model: LiveTranscriptModel, openMeeting: @escaping (String) -> Void) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = LiveTranscriptView(
            model: model,
            onTuck: { [weak self] tucked, mention in self?.tuck(tucked, mention: mention) },
            onClose: { [weak self] in self?.dismiss() },
            openMeeting: openMeeting
        )
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        contentView = host
        setFrameAutosaveName("LiveTranscriptWindow")
        if !setFrameUsingName("LiveTranscriptWindow") || frame.width < 200 { placeTopRight() }
    }

    override var canBecomeKey: Bool { true }

    /// Out of the way by default: the top right of the screen, under the
    /// menu bar, where meeting apps rarely put controls.
    private func placeTopRight() {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        let origin = NSPoint(
            x: screen.maxX - Self.expandedSize.width - 16,
            y: screen.maxY - Self.expandedSize.height - 10
        )
        setFrame(NSRect(origin: origin, size: Self.expandedSize), display: false)
    }

    /// Fades in from just above where it sits, the way a popover arrives.
    func present() {
        guard !isVisible else {
            orderFrontRegardless()
            return
        }
        hideIfNobodyCanSeeIt()
        guard NSApp.activationPolicy() != .prohibited else {
            orderFrontRegardless()
            return
        }
        alphaValue = 0
        let target = frame
        setFrame(target.offsetBy(dx: 0, dy: 8), display: false)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().alphaValue = 1
            animator().setFrame(target, display: true)
        }
    }

    private func dismiss() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor in
                self?.orderOut(nil)
                self?.alphaValue = 1
            }
        }
    }

    /// Shrinks to the caption strip or grows back, keeping the top right
    /// corner where it is, so the strip stays where the window was.
    func tuck(_ tucked: Bool, mention: Bool) {
        var target = frame
        let top = target.maxY
        let right = target.maxX
        if tucked {
            if frame.width > Self.tuckedSize.width + 1 { expandedFrame = frame }
            target.size = NSSize(
                width: Self.tuckedSize.width,
                height: mention ? Self.tuckedMentionHeight : Self.tuckedSize.height
            )
        } else {
            target.size = expandedFrame?.size ?? Self.expandedSize
        }
        target.origin = NSPoint(x: right - target.width, y: top - target.height)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.32
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
            animator().setFrame(target, display: true)
        }
    }

    /// Keeps the window out of screen shares and screenshots, or lets it in.
    func applySharing(hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }
}

/// Frosted glass behind the window's content, blended with what is behind
/// the window rather than with the window itself, which is clear.
private struct Glass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = LiveStyle.corner
        view.layer?.masksToBounds = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The look the mockup set: one type scale, three greys, and a warm accent
/// for the person recording and their notes.
enum LiveStyle {
    static let corner: CGFloat = 14
    static let accent = Color(red: 0.69, green: 0.48, blue: 0.23)
    static let record = Color(red: 0.90, green: 0.28, blue: 0.30)
    static let hairline = Color.primary.opacity(0.12)
    static let ink3 = Color(nsColor: .tertiaryLabelColor)
}

/// What the live window draws.
struct LiveTranscriptView: View {
    @Bindable var model: LiveTranscriptModel
    let onTuck: (Bool, Bool) -> Void
    let onClose: () -> Void
    let openMeeting: (String) -> Void

    @State private var tucked = false
    @State private var atBottom = true
    @State private var note = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        ZStack {
            if tucked {
                strip.transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    header
                    LiveStyle.hairline.frame(height: 0.5)
                    content
                    if model.state == .live || model.state == .starting {
                        LiveStyle.hairline.frame(height: 0.5)
                        noteField
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Glass())
        .overlay(
            RoundedRectangle(cornerRadius: LiveStyle.corner)
                .strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: LiveStyle.corner))
        // The window shrinks only when the person asks, with the button in
        // the header. Shrinking on its own after a quiet spell hid the
        // transcript while they were reading it.
        .onHover { inside in
            if inside, tucked { setTucked(false) }
        }
        .onChange(of: model.mention?.id) { _, mention in
            if tucked { onTuck(true, mention != nil) }
        }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 9) {
            RecordingDot(isLive: model.state == .live)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.meetingTitle.isEmpty ? "Live Transcript" : model.meetingTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 6)
            if model.hiddenFromSharing {
                Image(systemName: "eye.slash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                    .help("Hidden when sharing screen")
            }
            IconButton(symbol: "arrow.down.right.and.arrow.up.left", help: "Shrink to one line") {
                setTucked(true)
            }
            IconButton(symbol: "xmark", help: "Close", action: onClose)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
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
            message("Live transcript is off. Turn it on in Recording settings.")
        case .unavailable(let reason):
            message(reason)
        case .idle:
            message("Transcript appears during a meeting")
        default:
            if model.transcript.lines.isEmpty {
                message(model.state == .ended ? "No speech" : "Listening")
            } else {
                transcript
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.[0].id) { group in
                            LiveLineGroup(model: model, lines: group)
                                .transition(.opacity.combined(with: .offset(y: 6)))
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .padding(.bottom, 14)
                    .animation(.easeOut(duration: 0.25), value: model.transcript.lines.count)
                }
                .scrollIndicators(.never)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 30
                } action: { _, isAtBottom in
                    withAnimation(.easeOut(duration: 0.2)) { atBottom = isAtBottom }
                }
                .onChange(of: model.transcript.lines) { _, _ in
                    guard atBottom else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }

                if !atBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down")
                            Text("Back to live")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary, in: Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 7, y: 4)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }

                if model.state == .ended, let meetingID = model.meetingID {
                    HStack {
                        Spacer()
                        Button("Open Meeting") { openMeeting(meetingID) }
                            .controlSize(.small)
                    }
                    .padding(10)
                }
            }
        }
    }

    private static let bottom = "live-bottom"

    /// Consecutive lines from one speaker, shown under one name. Far-end lines
    /// no speaker pass has labelled yet stay apart: they may be different
    /// people, and merging them turned the whole far end into one paragraph.
    private var groups: [[LiveTranscriptLine]] {
        var out: [[LiveTranscriptLine]] = []
        for line in model.transcript.lines {
            let key = model.speakerKey(of: line)
            if let last = out.last?.last, last.kind != .note, line.kind != .note, key != "others",
                model.speakerKey(of: last) == key, line.start - last.end < 8
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
        TextField("Type a note", text: $note, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .lineLimit(2...4)
            .focused($noteFocused)
            .onSubmit {
                model.addNote(note)
                note = ""
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(minHeight: 46, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        noteFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.15),
                        lineWidth: noteFocused ? 2 : 0.5
                    )
            )
            .animation(.easeOut(duration: 0.15), value: noteFocused)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 12)
    }

    // MARK: strip

    /// One line that follows the words: the newest at the right edge, older
    /// ones fading off the left, each run led by a short speaker name.
    private var strip: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let mention = model.mention {
                Text("\(firstName(model.speakerName(of: mention))) mentioned you")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(LiveStyle.accent, in: Capsule())
                    .transition(.opacity)
            }
            HStack(spacing: 10) {
                RecordingDot(isLive: model.state == .live)
                caption
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .mask(
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12)],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { setTucked(false) }
        .animation(.easeOut(duration: 0.2), value: model.mention?.id)
    }

    private var caption: Text {
        let recent = model.transcript.lines.filter { $0.kind != .note }.suffix(3)
        guard !recent.isEmpty else {
            return Text(model.state == .live ? "Listening" : statusLine).foregroundColor(.secondary)
        }
        var text = Text("")
        for (index, line) in recent.enumerated() {
            let name = Text(firstName(model.speakerName(of: line)) + "  ")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(LiveSpeakerColor.color(for: model.speakerKey(of: line)))
            let said = Text(line.text).foregroundColor(line.isFinal ? .primary : LiveStyle.ink3)
            text = text + (index > 0 ? Text("    ") : Text("")) + name + said
        }
        return text.font(.system(size: 13))
    }

    private func firstName(_ name: String) -> String {
        name.hasPrefix("Speaker") ? name : (name.split(separator: " ").first.map(String.init) ?? name)
    }

    // MARK: tucking

    private func setTucked(_ value: Bool) {
        guard tucked != value else { return }
        withAnimation(.easeInOut(duration: 0.25)) { tucked = value }
        onTuck(value, model.mention != nil)
    }
}

/// The red dot that pulses while recording.
private struct RecordingDot: View {
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(isLive ? LiveStyle.record : Color.secondary)
            .frame(width: 8, height: 8)
            .opacity(isLive && pulse ? 0.45 : 1)
            .animation(
                isLive ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulse
            )
            .onAppear { pulse = true }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// The lines of one speaker turn: the name and time, then the words, grey
/// while the engine may still change them and dark once they settle.
private struct LiveLineGroup: View {
    let model: LiveTranscriptModel
    let lines: [LiveTranscriptLine]

    var body: some View {
        let first = lines[0]
        let isNote = first.kind == .note
        let mentioned = lines.contains { $0.id == model.mention?.id }
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(model.speakerName(of: first))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(
                        isNote ? LiveStyle.accent : LiveSpeakerColor.color(for: model.speakerKey(of: first))
                    )
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.35), value: model.speakerName(of: first))
                Spacer(minLength: 4)
                Text(Format.duration(first.start))
                    .font(.system(size: 11))
                    .foregroundStyle(LiveStyle.ink3)
                    .monospacedDigit()
            }
            lines.reduce(Text("")) { text, line in
                text
                    + Text((line.id == first.id ? "" : " ") + line.text)
                    .foregroundColor(isNote ? .secondary : line.isFinal ? .primary : LiveStyle.ink3)
            }
            .font(.system(size: 13.5))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .animation(.easeInOut(duration: 0.35), value: lines.map(\.isFinal))
        }
        .padding(.vertical, 7)
        .padding(.leading, isNote ? 10 : 0)
        .overlay(alignment: .leading) {
            if isNote { LiveStyle.accent.frame(width: 2) }
        }
        .padding(.horizontal, mentioned ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(mentioned ? LiveStyle.accent.opacity(0.13) : .clear)
        )
        .padding(.horizontal, mentioned ? -8 : 0)
    }
}

/// One colour per speaker, the same in the list and the strip.
enum LiveSpeakerColor {
    private static let palette: [Color] = [
        Color(red: 0.18, green: 0.44, blue: 0.69),
        Color(red: 0.54, green: 0.35, blue: 0.62),
        Color(red: 0.18, green: 0.54, blue: 0.43),
        Color(red: 0.75, green: 0.36, blue: 0.29),
        Color(red: 0.25, green: 0.47, blue: 0.55),
        Color(red: 0.55, green: 0.45, blue: 0.20),
    ]

    static func color(for key: String) -> Color {
        switch key {
        case "you", "note": return LiveStyle.accent
        case "others": return LiveStyle.ink3
        default:
            let number =
                Int(key.split(separator: "-").last ?? "") ?? key.unicodeScalars.reduce(0) { $0 + Int($1.value) }
            return palette[abs(number) % palette.count]
        }
    }
}
