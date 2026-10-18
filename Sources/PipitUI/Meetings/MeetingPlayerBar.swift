import PipitCore
import SwiftUI

/// The meeting's recording, under the speakers and over the tabs.
///
/// Over the tabs rather than inside the transcript, so it stays put while the
/// summary or the notes are read against what is playing.
struct MeetingPlayerBar: View {
    let detail: MeetingReviewModel

    private var playback: MeetingPlaybackModel { detail.playback }

    var body: some View {
        HStack(spacing: 14) {
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

            PlaybackClock(playback: playback)

            SpeakerLanesView(playback: playback, tint: tint(for:))

            Button(rateLabel) { playback.cycleRate() }
                .monospacedDigit()
                .help("Playback speed")

            Toggle(isOn: Binding(get: { playback.follows }, set: { playback.follows = $0 })) {
                Label("Follow", systemImage: "text.line.first.and.arrowtriangle.forward")
            }
            .toggleStyle(.button)
            .help("Keep the transcript on what is playing")
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(0.025))
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

/// One thin lane per speaker, lit where they talk, with the playhead across
/// them. Click or drag to move the playhead.
///
/// Lanes rather than a waveform: a waveform says how loud the room was, and the
/// question the bar answers is who was talking when.
struct SpeakerLanesView: View {
    let playback: MeetingPlaybackModel
    let tint: (String) -> Color
    /// Where the pointer is over the lanes, as a fraction of their width.
    @State private var hover: CGFloat?

    private let rowHeight: CGFloat = 10
    private let rowSpacing: CGFloat = 2

    var body: some View {
        let lanes = playback.lanes
        let height = max(rowHeight, CGFloat(lanes.count) * (rowHeight + rowSpacing) - rowSpacing)
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: rowSpacing) {
                ForEach(lanes) { lane in
                    Text(lane.name)
                        .font(.system(size: 9.5, weight: isSpeaking(lane.name) ? .semibold : .regular))
                        .foregroundStyle(tint(lane.name))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(height: rowHeight)
                }
            }
            .frame(width: 64, alignment: .trailing)

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    lanesCanvas(lanes)
                    if let hover {
                        Rectangle()
                            .fill(Color.primary.opacity(0.35))
                            .frame(width: 1, height: height + 6)
                            .offset(x: hover * width, y: -3)
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
                    switch phase {
                    case .active(let point):
                        hover = width > 0 ? min(max(point.x / width, 0), 1) : nil
                    case .ended:
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
                switch direction {
                case .increment: playback.skip(by: 5)
                case .decrement: playback.skip(by: -5)
                @unknown default: break
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// Played stretches at full strength and the rest faded, so the strip
    /// also reads as how far through the meeting this is.
    private func lanesCanvas(_ lanes: [SpeakerLane]) -> some View {
        let duration = playback.timeline.duration
        let position = playback.position
        let boundaries = playback.timeline.boundaries
        let colours = lanes.map { tint($0.name) }
        return Canvas { context, size in
            guard duration > 0 else { return }
            for (row, lane) in lanes.enumerated() {
                let y = CGFloat(row) * (rowHeight + rowSpacing) + 2
                let track = CGRect(x: 0, y: y, width: size.width, height: rowHeight - 4)
                context.fill(Path(roundedRect: track, cornerRadius: 3), with: .color(.primary.opacity(0.08)))
                for span in lane.spans {
                    let x = CGFloat(span.start / duration) * size.width
                    let length = max(2, CGFloat((span.end - span.start) / duration) * size.width)
                    let rect = CGRect(x: x, y: y, width: length, height: rowHeight - 4)
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

    private func isSpeaking(_ name: String) -> Bool {
        guard let cursor = playback.cursor, cursor.isSpeaking else { return false }
        return cursor.speakerName == name
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
