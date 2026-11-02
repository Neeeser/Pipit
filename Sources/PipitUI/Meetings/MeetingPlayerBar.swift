import PipitCore
import SwiftUI

/// The meeting's recording, docked at the bottom of the pane.
///
/// Outside the tabs, so it stays put while the summary or the notes are read
/// against what is playing. One lane holds every speaker in their own colour;
/// the Lanes button opens a lane per speaker above it, lined up with that lane
/// so the playheads match.
struct MeetingPlayerBar: View {
    let detail: MeetingReviewModel
    /// Whether the pane is tall enough for the lanes to start open.
    let roomy: Bool

    /// The person's own choice, kept across meetings and launches. Empty
    /// until they press Lanes, and then the pane's height decides.
    @AppStorage("MeetingPlayerLanes") private var lanesChoice = ""
    @State private var hover: CGFloat?
    /// The widths either side of the combined lane, so the open lanes start
    /// and end where it does.
    @State private var leadingWidth: CGFloat = 0
    @State private var trailingWidth: CGFloat = 0

    private var playback: MeetingPlaybackModel { detail.playback }

    private var lanesShown: Bool {
        switch lanesChoice {
        case "open": true
        case "closed": false
        default: roomy
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if lanesShown {
                SpeakerLanesView(playback: playback, tint: tint(for:), labelWidth: leadingWidth)
                    .padding(.trailing, trailingWidth + Self.spacing)
                    .padding(.top, 12)
                    .padding(.bottom, 2)
            }
            HStack(spacing: Self.spacing) {
                HStack(spacing: Self.spacing) {
                    transport
                    PlaybackClock(playback: playback)
                }
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    leadingWidth = $0
                }

                SpeakerLanesPlot(
                    playback: playback, tint: tint(for:), hover: $hover,
                    height: SpeakerLanesPlot.combinedHeight, combined: true
                )

                HStack(spacing: Self.spacing) {
                    Button(rateLabel) { playback.cycleRate() }
                        .monospacedDigit()
                        .help("Playback speed")

                    Toggle(isOn: Binding(get: { playback.follows }, set: { playback.follows = $0 })) {
                        Label("Follow", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .toggleStyle(.button)
                    .help("Keep the transcript on what is playing")

                    Toggle(
                        isOn: Binding(
                            get: { lanesShown },
                            set: { lanesChoice = $0 ? "open" : "closed" }
                        )
                    ) {
                        Label("Lanes", systemImage: "chart.bar.xaxis")
                    }
                    .toggleStyle(.button)
                    .help(lanesShown ? "Hide the lane for each speaker" : "Show a lane for each speaker")
                }
                .fixedSize()
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    trailingWidth = $0
                }
            }
            .frame(height: 46)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .background(Color.primary.opacity(0.025))
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
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
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

/// One lane per speaker, lit where they talk, with the playhead across them.
/// Click or drag to move the playhead.
///
/// Lanes rather than a waveform: a waveform says how loud the room was, and the
/// question the bar answers is who was talking when.
struct SpeakerLanesView: View {
    let playback: MeetingPlaybackModel
    let tint: (String) -> Color
    /// The width of the name column, matched to the controls under it so the
    /// lanes line up with the combined lane.
    let labelWidth: CGFloat
    /// Where the pointer is over the lanes, as a fraction of their width.
    @State private var hover: CGFloat?

    private static let rowHeight: CGFloat = 14
    private static let rowSpacing: CGFloat = 3

    var body: some View {
        let rowHeight = Self.rowHeight
        let rowSpacing = Self.rowSpacing
        let lanes = playback.lanes
        let height = max(rowHeight, CGFloat(lanes.count) * (rowHeight + rowSpacing) - rowSpacing)
        HStack(spacing: 12) {
            VStack(alignment: .trailing, spacing: rowSpacing) {
                ForEach(lanes) { lane in
                    Text(lane.name)
                        .font(.system(size: 11, weight: isSpeaking(lane.name) ? .semibold : .regular))
                        .foregroundStyle(tint(lane.name))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: rowHeight)
                }
            }
            .frame(width: max(64, labelWidth - 12), alignment: .trailing)

            SpeakerLanesPlot(
                playback: playback, tint: tint, hover: $hover, height: height,
                rowHeight: rowHeight, rowSpacing: rowSpacing
            )
        }
        .frame(maxWidth: .infinity)
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
