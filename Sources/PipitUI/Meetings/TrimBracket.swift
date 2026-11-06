import AppKit
import PipitCore
import SwiftUI

/// The kept stretch of a meeting, drawn over the strip in the player bar.
///
/// A yellow frame with a handle at each end, the way trimming looks elsewhere
/// on the Mac. What falls outside the frame is dimmed, because that is what
/// Trim deletes.
///
/// A handle dragged near the playhead lands on it, so the person can play to
/// where the voice starts, stop, and drag the handle there without hunting for
/// the exact point. The time shows above a handle while it moves.
struct TrimBracket: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let startLimits: ClosedRange<Double>
    let endLimits: ClosedRange<Double>
    /// Where playback is, on the same timeline as `start` and `end`.
    var playhead: Double = 0
    /// Called with the position of a handle as it is dragged, so the playhead
    /// can follow it and the person hears where they are cutting.
    var scrub: (Double) -> Void = { _ in }
    /// Formats a position for the label above a dragged handle.
    var timecode: (Double) -> String = { TranscriptRenderer().timecode($0) }

    static let handleWidth: CGFloat = 9
    /// How close to the playhead, in points, a dragged handle lands on it.
    static let snapDistance: CGFloat = 6
    private static let frameColor = Color.yellow
    /// The least that may be kept, matching what Trim accepts.
    private let shortest = MeetingTrim.shortestKept

    /// The handle being dragged, and whether it sits on the playhead now.
    @State private var dragging: MeetingReviewModel.TrimEdge?
    @State private var onPlayhead = false

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let left = x(start, width)
            let right = x(end, width)
            ZStack(alignment: .topLeading) {
                // Outside the frame: what will be deleted, dimmed over the
                // speaker turns and greyed where there are none. Clicks pass
                // through to the strip beneath, so the person can still seek
                // there; only the handles take drags.
                removed.frame(width: max(0, left)).allowsHitTesting(false)
                removed.frame(width: max(0, width - right)).offset(x: right).allowsHitTesting(false)

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(Self.frameColor, lineWidth: 2.5)
                    .frame(width: max(Self.handleWidth * 2, right - left))
                    .offset(x: left)
                    .allowsHitTesting(false)

                handle(edge: .leading)
                    .offset(x: left)
                    .gesture(drag(.start, width: width))
                    .contextMenu { playheadCommands }
                    .accessibilityLabel("Start of the kept part")
                    .accessibilityValue(timecode(start))
                    .accessibilityAdjustableAction { direction in
                        start = clampStart(start + (direction == .increment ? 1 : -1))
                    }

                handle(edge: .trailing)
                    .offset(x: right - Self.handleWidth)
                    .gesture(drag(.end, width: width))
                    .contextMenu { playheadCommands }
                    .accessibilityLabel("End of the kept part")
                    .accessibilityValue(timecode(end))
                    .accessibilityAdjustableAction { direction in
                        end = clampEnd(end + (direction == .increment ? 1 : -1))
                    }

                if let dragging {
                    let at = dragging == .start ? start : end
                    Text(timecode(at))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: .textBackgroundColor))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary))
                        .fixedSize()
                        .alignmentGuide(.leading) { $0.width / 2 }
                        .offset(x: x(at, width), y: -22)
                        .allowsHitTesting(false)
                }
            }
            .coordinateSpace(.named(Self.space))
        }
    }

    /// The same two commands I and O run, offered on either handle with the
    /// keys shown, for a person who reaches for the pointer first.
    @ViewBuilder private var playheadCommands: some View {
        Button("Move Start to Playhead") { start = clampStart(playhead) }
            .keyboardShortcut("i", modifiers: [])
        Button("Move End to Playhead") { end = clampEnd(playhead) }
            .keyboardShortcut("o", modifiers: [])
    }

    private var removed: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).opacity(0.6)
            Color.primary.opacity(0.07)
        }
    }

    private func handle(edge: HorizontalEdge) -> some View {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .leading ? 4 : 0, bottomLeadingRadius: edge == .leading ? 4 : 0,
            bottomTrailingRadius: edge == .trailing ? 4 : 0, topTrailingRadius: edge == .trailing ? 4 : 0,
            style: .continuous
        )
        .fill(Self.frameColor)
        .overlay {
            Capsule()
                .fill(Color.black.opacity(0.45))
                .frame(width: 1.5)
                .padding(.vertical, 5)
        }
        .frame(width: Self.handleWidth)
        .contentShape(Rectangle().inset(by: -6))
        .pointerStyle(.columnResize)
        .accessibilityElement()
    }

    /// Moves a handle to where the pointer is, or onto the playhead when the
    /// pointer is within a few points of it, and the playhead with it unless
    /// it is the playhead the handle landed on.
    private func drag(_ edge: MeetingReviewModel.TrimEdge, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard width > 0, duration > 0 else { return }
                dragging = edge
                let pointer = Double(min(max(value.location.x / width, 0), 1)) * duration
                let snap = Self.snapped(pointer, toPlayhead: playhead, duration: duration, width: width)
                if (snap != nil) != onPlayhead {
                    onPlayhead = snap != nil
                    // The tick a trackpad gives when something lines up.
                    if onPlayhead {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                }
                let target = snap ?? pointer
                switch edge {
                case .start: start = clampStart(target)
                case .end: end = clampEnd(target)
                }
                if snap == nil { scrub(edge == .start ? start : end) }
            }
            .onEnded { _ in
                dragging = nil
                onPlayhead = false
            }
    }

    /// The playhead's position when `seconds` falls within `snapDistance`
    /// points of it on a strip `width` points wide, and nil otherwise.
    static func snapped(_ seconds: Double, toPlayhead playhead: Double, duration: Double, width: CGFloat) -> Double? {
        guard duration > 0, width > 0 else { return nil }
        let points = abs(seconds - playhead) / duration * Double(width)
        return points <= Double(snapDistance) ? playhead : nil
    }

    static let space = "TrimBracket"

    private func x(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        duration > 0 ? CGFloat(min(max(seconds / duration, 0), 1)) * width : 0
    }

    private func clampStart(_ value: Double) -> Double {
        min(max(value, startLimits.lowerBound), min(startLimits.upperBound, end - shortest))
    }

    private func clampEnd(_ value: Double) -> Double {
        max(min(value, endLimits.upperBound), max(endLimits.lowerBound, start + shortest))
    }
}
