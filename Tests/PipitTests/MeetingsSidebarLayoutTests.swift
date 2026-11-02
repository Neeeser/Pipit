import AppKit
import PipitCore
import SwiftUI
import Testing

@testable import PipitUI

@MainActor
@Suite("MeetingsSidebarLayout")
struct MeetingsSidebarLayoutTests {
    @Test("the filter control fits the narrowest sidebar without cutting off a label")
    func filterFitsNarrowestSidebar() {
        let room = MeetingsWindowView.sidebarMinWidth - 2 * MeetingsWindowView.sidebarMargin
        let controller = NSHostingController(rootView: MeetingsFilterPicker(selection: .constant(.all)))
        // Proposing almost no width asks for the narrowest the control can be
        // drawn. Anything wider than the room is drawn past the sidebar's edge.
        let narrowest = controller.sizeThatFits(in: NSSize(width: 1, height: 100)).width
        #expect(narrowest > 0)
        #expect(narrowest <= room, "the four labels need \(narrowest) points and the sidebar has \(room)")
    }
}
