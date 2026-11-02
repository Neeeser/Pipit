import AppKit
import SwiftUI
import Testing

@testable import PipitUI

@MainActor
@Suite("SpeakerChipBadge")
struct SpeakerChipBadgeTests {
    private func size(_ shows: SpeakerChipBadge.Shows) -> CGSize {
        NSHostingView(rootView: SpeakerChipBadge(name: "Synthetic Speaker", shows: shows)).fittingSize
    }

    @Test("hovering or speaking leaves a chip the same width, so the row does not reflow under the pointer")
    func badgeKeepsItsSize() {
        let face = size(.face)
        #expect(face.width == SpeakerChipBadge.side)
        #expect(size(.jump(walking: false)) == face)
        #expect(size(.jump(walking: true)) == face)
        #expect(size(.speaking(.blue)) == face)
    }
}
