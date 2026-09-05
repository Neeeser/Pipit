import AppKit
import SwiftUI

/// Builds a view's tree and forces a layout pass.
public enum ViewFixtures {
    /// Hosts `view` at `size` and lays it out, which is what makes a view that
    /// traps on a nil or a missing meeting fail here rather than on screen.
    @MainActor
    public static func render(
        _ view: some View, size: NSSize = NSSize(width: 720, height: 560)
    ) {
        let controller = NSHostingController(rootView: AnyView(view))
        controller.view.frame = NSRect(origin: .zero, size: size)
        controller.view.layoutSubtreeIfNeeded()
        controller.view.displayIfNeeded()
    }
}
