import PipitCore
import SwiftUI

/// The kept stretch of a meeting, drawn over the strip in the player bar.
///
/// A yellow frame with a handle at each end, the way trimming looks elsewhere
/// on the Mac. What falls outside the frame is dimmed, because that is what
/// Trim deletes.
struct TrimBracket: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let startLimits: ClosedRange<Double>
    let endLimits: ClosedRange<Double>
    /// Called with the position of a handle as it is dragged, so the playhead
    /// can follow it and the person hears where they are cutting.
    var scrub: (Double) -> Void = { _ in }

    static let handleWidth: CGFloat = 9
    private static let frameColor = Color.yellow
    /// The least that may be kept, matching what Trim accepts.
    private let shortest = MeetingTrim.shortestKept

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
                    .gesture(
                        drag(width: width) {
                            start = clampStart($0)
                            return start
                        }
                    )
                    .accessibilityLabel("Start of the kept part")
                    .accessibilityValue(TranscriptRenderer().timecode(start))
                    .accessibilityAdjustableAction { direction in
                        start = clampStart(start + (direction == .increment ? 1 : -1))
                    }

                handle(edge: .trailing)
                    .offset(x: right - Self.handleWidth)
                    .gesture(
                        drag(width: width) {
                            end = clampEnd($0)
                            return end
                        }
                    )
                    .accessibilityLabel("End of the kept part")
                    .accessibilityValue(TranscriptRenderer().timecode(end))
                    .accessibilityAdjustableAction { direction in
                        end = clampEnd(end + (direction == .increment ? 1 : -1))
                    }
            }
            .coordinateSpace(.named(Self.space))
        }
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

    /// Moves a handle to where the pointer is and the playhead with it.
    /// `update` sets the handle and the value it settled on, which the limits
    /// may have moved from where the pointer is.
    private func drag(width: CGFloat, _ update: @escaping (Double) -> Double) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                guard width > 0, duration > 0 else { return }
                scrub(update(Double(min(max(value.location.x / width, 0), 1)) * duration))
            }
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
