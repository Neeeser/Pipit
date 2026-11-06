import PipitCore
import SwiftUI

/// The meeting's recording, in a card at the bottom of the pane.
///
/// Outside the tabs, so it stays put while the summary or the notes are read
/// against what is playing. One strip between the controls holds every
/// speaker's turns in their own colour. The Lanes button opens a lane per
/// speaker above the controls, across the whole bar, with a time ruler over
/// them and each speaker's talk time at the end. The open lanes are then the
/// thing to click or drag, so the single strip goes, and the lanes get the
/// width it and the controls beside it held.
struct MeetingPlayerBar: View {
    let detail: MeetingReviewModel

    /// The person's choice, kept across meetings and launches. The lanes stay
    /// closed until they open them.
    @AppStorage("MeetingPlayerLanes") private var lanesChoice = ""

    /// The height of the closed card. The sidebar's footer matches it, so the
    /// two meet in one line across the window.
    static let cardHeight: CGFloat = 48
    @State private var hover: CGFloat?
    @State private var lanesHover: CGFloat?
    @State private var confirmingTrim = false

    /// The kept stretch while the bar is in trim mode; nil otherwise.
    private var trim: ClosedRange<Double>? { detail.trimDraft }

    private var playback: MeetingPlaybackModel { detail.playback }

    private var lanesShown: Bool { lanesChoice == "open" }

    var body: some View {
        VStack(spacing: 0) {
            if lanesShown, trim == nil {
                OpenSpeakerLanes(
                    playback: playback, tint: tint(for:), talkSeconds: talkSeconds(_:), hover: $lanesHover
                )
                .padding(.top, 10)
            }
            HStack(spacing: Self.spacing) {
                HStack(spacing: Self.spacing) {
                    transport
                    PlaybackClock(playback: playback)
                }
                .fixedSize()

                if let trim, let limits = detail.trimLimits {
                    SpeakerLanesPlot(
                        playback: playback, tint: tint(for:), hover: $hover,
                        height: Self.trimStripHeight, combined: true
                    )
                    .overlay {
                        TrimBracket(
                            start: Binding(
                                get: { trim.lowerBound }, set: { detail.moveTrimEdge(.start, to: $0) }),
                            end: Binding(get: { trim.upperBound }, set: { detail.moveTrimEdge(.end, to: $0) }),
                            duration: playback.timeline.duration,
                            startLimits: limits.start, endLimits: limits.end,
                            playhead: playback.position,
                            scrub: { playback.seek(to: $0) },
                            timecode: timecode
                        )
                    }
                } else if lanesShown {
                    Spacer(minLength: 0)
                } else {
                    SpeakerLanesPlot(
                        playback: playback, tint: tint(for:), hover: $hover,
                        height: SpeakerLanesPlot.combinedHeight, combined: true
                    )
                }

                if let trim {
                    trimControls(trim)
                } else {
                    playerControls
                }
            }
            .frame(height: Self.cardHeight)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .playerCard()
        .alert(trimQuestion, isPresented: $confirmingTrim) {
            Button("Trim", role: .destructive) {
                if let trim { detail.trim(keepFrom: trim.lowerBound, to: trim.upperBound) }
                detail.cancelTrimming()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Deletes the audio and transcript outside this range. You can't undo this.")
        }
        .onChange(of: detail.canTrim) { _, canTrim in
            if !canTrim { detail.cancelTrimming() }
        }
    }

    private static let trimStripHeight: CGFloat = 24

    private var playerControls: some View {
        HStack(spacing: Self.spacing) {
            Button(rateLabel) { playback.cycleRate() }
                .monospacedDigit()
                .help("Playback speed")

            Button {
                playback.follows.toggle()
            } label: {
                icon("text.alignleft")
            }
            // Blue while on, the way a toolbar toggle shows its state.
            .buttonStyle(PillButtonStyle(tint: playback.follows ? .accentColor : nil))
            .accessibilityLabel("Follow")
            .accessibilityAddTraits(playback.follows ? .isSelected : [])
            .help("Keep the transcript on what is playing")

            Button {
                lanesChoice = lanesShown ? "closed" : "open"
            } label: {
                icon("person.2.wave.2")
            }
            .buttonStyle(PillButtonStyle(tint: lanesShown ? .accentColor : nil))
            .accessibilityLabel("Lanes")
            .accessibilityAddTraits(lanesShown ? .isSelected : [])
            .help(lanesShown ? "Hide the lane for each speaker" : "Show a lane for each speaker")

            if detail.isTrimming {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text("Trimming")
                }
                .foregroundStyle(.secondary)
            } else if detail.canTrim {
                Button {
                    detail.beginTrimming()
                } label: {
                    icon("scissors")
                }
                .accessibilityLabel("Trim")
                .help("Remove the start or end of this meeting")
            }
        }
        .buttonStyle(PillButtonStyle())
        .fixedSize()
        .overlay(alignment: .bottomTrailing) {
            if let message = detail.trimMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize()
                    .offset(y: 14)
            }
        }
    }

    /// Only Cancel and Trim. The handles set the range: dragged, snapped to
    /// the playhead, or moved there with I and O, and the time of a handle
    /// shows above it while it moves.
    private func trimControls(_ range: ClosedRange<Double>) -> some View {
        HStack(spacing: Self.spacing) {
            Button("Cancel") { detail.cancelTrimming() }
                .keyboardShortcut(.cancelAction)
            Button("Trim…") { confirmingTrim = true }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(!removesSomething(range))
        }
        .buttonStyle(PillButtonStyle())
        .fixedSize()
    }

    /// An icon-only pill. The name goes to the tooltip and VoiceOver.
    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12))
            .frame(minWidth: 14)
    }

    private var trimQuestion: String {
        guard let trim else { return "Trim this meeting?" }
        return "Trim this meeting to \(timecode(trim.lowerBound))–\(timecode(trim.upperBound))?"
    }

    private func removesSomething(_ range: ClosedRange<Double>) -> Bool {
        range.lowerBound > MeetingTrim.tolerance
            || playback.timeline.duration - range.upperBound > MeetingTrim.tolerance
    }

    private func timecode(_ position: Double) -> String {
        TranscriptRenderer().timecode(playback.timeline.timelineSeconds(at: position))
    }

    private static let spacing: CGFloat = 12

    private var transport: some View {
        HStack(spacing: 4) {
            Button {
                playback.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Back 15 seconds")

            Button {
                playback.toggle()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .textBackgroundColor))
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(Color.primary))
            }
            .buttonStyle(.plain)
            .help(playback.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

            Button {
                playback.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Forward 15 seconds")
        }
    }

    private var rateLabel: String {
        let rate = playback.rate
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return "\(text)×"
    }

    /// The same time the speaker's chip gives, summed over both halves of a
    /// rejoined call. A lane with no chip, the words nobody was matched to,
    /// adds up its own stretches.
    private func talkSeconds(_ lane: SpeakerLane) -> Double {
        let rows = detail.speakerRows.filter { $0.displayName == lane.name }
        if !rows.isEmpty { return rows.reduce(0) { $0 + $1.speechSeconds } }
        return lane.spans.reduce(0) { $0 + ($1.end - $1.start) }
    }

    /// The colour this speaker has on the chips and over their turns.
    private func tint(for name: String) -> Color {
        let identity = detail.speakerRows.first { $0.displayName == name }?.identity?.id
        return PersonTint.color(identity: identity, name: name)
    }
}

/// What the bar shows before the recording exists.
struct MeetingPlayerPlaceholder: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.secondary.opacity(0.4)))
                .padding(.leading, 34)
            Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
            Text("Preparing audio…").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: MeetingPlayerBar.cardHeight)
        .playerCard()
    }
}

/// The time played and the length, on the clock the transcript headers read.
///
/// Its own view because it reads the position, which ticks, and nothing else
/// on the bar needs to be rebuilt that often.
private struct PlaybackClock: View {
    let playback: MeetingPlaybackModel

    var body: some View {
        let renderer = TranscriptRenderer()
        HStack(spacing: 3) {
            Text(renderer.timecode(playback.timeline.timelineSeconds(at: playback.position)))
            Text("/ \(renderer.timecode(playback.timeline.timelineDuration))")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .monospacedDigit()
        .fixedSize()
    }
}

/// The open lanes: the names, the lanes under the ruler, and the talk time
/// under its heading. One stack per column keeps each name, lane and time on
/// the same line without measuring anything, and the lanes take every point
/// the two outer columns leave.
struct OpenSpeakerLanes: View {
    let playback: MeetingPlaybackModel
    let tint: (String) -> Color
    let talkSeconds: (SpeakerLane) -> Double
    @Binding var hover: CGFloat?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Only as wide as the names. A spacer that could stretch sideways
            // made this column split the row with the lanes, which then
            // stopped halfway across a wide window.
            VStack(alignment: .trailing, spacing: 0) {
                Color.clear.frame(width: 1, height: LaneRuler.height)
                SpeakerLaneLabels(playback: playback, tint: tint)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 0) {
                LaneRuler(timeline: playback.timeline)
                SpeakerLanesPlot(
                    playback: playback, tint: tint, hover: $hover,
                    height: SpeakerLaneLabels.height(lanes: playback.lanes.count),
                    rowHeight: SpeakerLaneLabels.rowHeight, rowSpacing: SpeakerLaneLabels.rowSpacing
                )
            }
            VStack(alignment: .trailing, spacing: SpeakerLaneLabels.rowSpacing) {
                Text("Talk time")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(height: LaneRuler.height, alignment: .bottom)
                ForEach(playback.lanes) { lane in
                    Text(Format.shortDuration(talkSeconds(lane)))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(height: SpeakerLaneLabels.rowHeight)
                }
            }
            .fixedSize()
        }
    }
}

/// The speakers' names, one per lane, beside the lanes they label.
///
/// Lanes rather than a waveform: a waveform says how loud the room was, and the
/// question the bar answers is who was talking when.
struct SpeakerLaneLabels: View {
    let playback: MeetingPlaybackModel
    let tint: (String) -> Color

    static let rowHeight: CGFloat = 14
    static let rowSpacing: CGFloat = 3

    static func height(lanes: Int) -> CGFloat {
        max(rowHeight, CGFloat(lanes) * (rowHeight + rowSpacing) - rowSpacing)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.rowSpacing) {
            ForEach(playback.lanes) { lane in
                Text(lane.name)
                    .font(.system(size: 11, weight: isSpeaking(lane.name) ? .semibold : .regular))
                    .foregroundStyle(tint(lane.name))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: Self.rowHeight)
            }
        }
        // A long name is cut rather than taking the lanes' room.
        .frame(maxWidth: 140, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func isSpeaking(_ name: String) -> Bool {
        guard let cursor = playback.cursor, cursor.isSpeaking else { return false }
        return cursor.speakerName == name
    }
}

/// The plot's drawing and pointer feedback, separate from the speaker labels.
struct SpeakerLanesPlot: View {
    let playback: MeetingPlaybackModel
    let tint: (String) -> Color
    @Binding var hover: CGFloat?
    let height: CGFloat
    /// Every speaker on one row, each in their own colour: the strip the bar
    /// shows while the lane per speaker is closed.
    var combined = false
    var rowHeight: CGFloat = SpeakerLanesPlot.rowHeight
    var rowSpacing: CGFloat = SpeakerLanesPlot.rowSpacing

    static let rowHeight: CGFloat = 10
    static let rowSpacing: CGFloat = 2
    static let combinedHeight: CGFloat = 14

    var body: some View {
        let lanes = playback.lanes
        GeometryReader { geometry in
            let width = geometry.size.width
            lanesCanvas(lanes)
                // Pointer feedback must not participate in the canvas layout.
                // A centered label in a ZStack shifts its siblings as its width changes.
                .overlay(alignment: .topLeading) {
                    if let hover {
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1, height: height + 6)
                            .offset(x: hover * width, y: -3)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let hover {
                        Text(hoverLabel(at: hover))
                            .font(.caption2)
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: .textBackgroundColor))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary))
                            .fixedSize()
                            .alignmentGuide(.leading) { $0.width / 2 }
                            .offset(x: hover * width, y: -24)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    playhead(height: height)
                        .offset(x: fraction(of: playback.position) * width - 1, y: -3)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard width > 0 else { return }
                            let at = min(max(value.location.x / width, 0), 1)
                            playback.seek(to: Double(at) * playback.timeline.duration)
                        }
                )
                .onContinuousHover { phase in
                    if case .active(let point) = phase, width > 0 {
                        hover = min(max(point.x / width, 0), 1)
                    } else {
                        hover = nil
                    }
                }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(
            TranscriptRenderer().timecode(playback.timeline.timelineSeconds(at: playback.position))
        )
        .accessibilityAdjustableAction { direction in
            if direction == .increment {
                playback.skip(by: 5)
            } else if direction == .decrement {
                playback.skip(by: -5)
            }
        }
    }

    /// Played stretches at full strength and the rest faded, so the strip
    /// also reads as how far through the meeting this is.
    private func lanesCanvas(_ lanes: [SpeakerLane]) -> some View {
        let laneHeight = combined ? height : rowHeight
        let laneSpacing = rowSpacing
        let combined = combined
        let duration = playback.timeline.duration
        let position = playback.position
        let boundaries = playback.timeline.boundaries
        let colours = lanes.map { tint($0.name) }
        return Canvas { context, size in
            guard duration > 0 else { return }
            let tracks = combined ? min(lanes.count, 1) : lanes.count
            for row in 0..<tracks {
                let y = CGFloat(row) * (laneHeight + laneSpacing) + 2
                let track = CGRect(x: 0, y: y, width: size.width, height: laneHeight - 4)
                context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.primary.opacity(0.08)))
            }
            for (row, lane) in lanes.enumerated() {
                let y = combined ? 2 : CGFloat(row) * (laneHeight + laneSpacing) + 2
                for span in lane.spans {
                    let x = CGFloat(span.start / duration) * size.width
                    let length = max(2, CGFloat((span.end - span.start) / duration) * size.width)
                    let rect = CGRect(x: x, y: y, width: length, height: laneHeight - 4)
                    let colour = colours[row].opacity(span.start < position ? 1 : 0.45)
                    context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(colour))
                }
            }
            // Where the call dropped and the next recording picks up.
            for boundary in boundaries {
                let x = CGFloat(boundary / duration) * size.width
                var line = Path()
                line.move(to: CGPoint(x: x, y: -3))
                line.addLine(to: CGPoint(x: x, y: size.height + 3))
                context.stroke(
                    line, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                )
            }
        }
    }

    private func playhead(height: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary)
            .frame(width: 2, height: height + 6)
            .overlay(alignment: .top) {
                Circle().fill(Color.primary).frame(width: 9, height: 9).offset(y: -4)
            }
            .allowsHitTesting(false)
    }

    private func fraction(of position: Double) -> CGFloat {
        let duration = playback.timeline.duration
        return duration > 0 ? CGFloat(min(max(position / duration, 0), 1)) : 0
    }

    /// The time under the pointer, and who is talking there.
    private func hoverLabel(at fraction: CGFloat) -> String {
        let at = Double(fraction) * playback.timeline.duration
        let time = TranscriptRenderer().timecode(playback.timeline.timelineSeconds(at: at))
        let speaker = playback.lanes.first { lane in
            lane.spans.contains { $0.start <= at && at <= $0.end }
        }
        return speaker.map { "\($0.name) · \(time)" } ?? time
    }
}

/// Times along the top of the open lanes, so a stretch can be read off as
/// "about twenty minutes in" without hovering.
struct LaneRuler: View {
    let timeline: PlaybackTimeline

    /// Tall enough for a label's full line above its mark; the canvas clips
    /// anything drawn outside it.
    nonisolated static let height: CGFloat = 20
    nonisolated static let labelSize: CGFloat = 10
    /// How far a label's bottom edge sits above the rule.
    nonisolated static let labelGap: CGFloat = 6
    /// Room a label needs beside the next one.
    nonisolated static let minimumSpacing: CGFloat = 64

    var body: some View {
        // Drawn rather than laid out: a label centred on its mark widened a
        // stack's bounds and moved the whole ruler off the lanes under it.
        let duration = timeline.duration
        let renderer = TranscriptRenderer()
        Canvas { context, size in
            let baseline = size.height - 0.5
            var rule = Path()
            rule.move(to: CGPoint(x: 0, y: baseline))
            rule.addLine(to: CGPoint(x: size.width, y: baseline))
            context.stroke(rule, with: .color(.primary.opacity(0.12)), lineWidth: 1)
            let step = Self.interval(duration: duration, width: size.width)
            guard duration > 0, step > 0 else { return }
            for seconds in stride(from: 0.0, to: duration, by: step) {
                let x = CGFloat(seconds / duration) * size.width
                var tick = Path()
                tick.move(to: CGPoint(x: x + 0.5, y: baseline))
                tick.addLine(to: CGPoint(x: x + 0.5, y: baseline - 5))
                context.stroke(tick, with: .color(.primary.opacity(0.25)), lineWidth: 1)
                let label = Text(renderer.timecode(timeline.timelineSeconds(at: seconds)))
                    .font(.system(size: Self.labelSize).monospacedDigit())
                    .foregroundStyle(Color.secondary)
                // The first label starts at its mark, so it does not hang
                // off the left end; the rest are centred on theirs.
                context.draw(
                    label, at: CGPoint(x: x, y: baseline - Self.labelGap),
                    anchor: seconds == 0 ? .bottomLeading : .bottom
                )
            }
        }
        .frame(height: Self.height)
        .accessibilityHidden(true)
    }

    /// The gap between marks: the shortest of a few round lengths that keeps
    /// the labels apart at this width.
    nonisolated static func interval(duration: Double, width: CGFloat) -> Double {
        guard duration > 0, width > 0 else { return 0 }
        let steps: [Double] = [30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200]
        let fits = steps.first { CGFloat($0 / duration) * width >= minimumSpacing }
        return fits ?? steps[steps.count - 1]
    }
}

extension View {
    /// A rounded card floating over the page like the sidebar and the summary
    /// panel, with the same gap to the window's edges. A bar docked edge to
    /// edge met the side of the floating sidebar in a straight cut, with its
    /// top line at a different height from the sidebar's footer line.
    fileprivate func playerCard() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return background(Color.primary.opacity(0.025), in: shape)
            .overlay(shape.stroke(.separator))
            .padding([.horizontal, .bottom], 8)
    }
}
