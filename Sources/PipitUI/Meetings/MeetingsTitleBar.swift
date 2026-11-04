import AppKit
import SwiftUI

/// The strip the meetings window draws in its own title bar.
///
/// The window's content runs under a transparent title bar, so the detail
/// pane's tabs and Copy transcript sit on the line the window buttons already
/// use instead of on a row of their own. Whatever this strip does not cover
/// with a control still moves the window and zooms it on a double-click, the
/// two things a title bar is expected to do.
struct MeetingsTitleBar<Content: View>: View {
    /// The height of the title bar the window's empty compact toolbar makes,
    /// measured on macOS 26. The window buttons are centred in it, and so are
    /// the controls, with the same room above them as below.
    static var barHeight: CGFloat { 40 }

    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 12)
            .frame(height: Self.barHeight)
            .frame(maxWidth: .infinity)
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { Self.performDoubleClickAction() }
                    .gesture(WindowDragGesture())
            }
    }

    /// Does what the person chose in Desktop & Dock for a double-click on a
    /// title bar: zoom unless they picked minimize or nothing.
    private static func performDoubleClickAction() {
        guard let window = NSApp.keyWindow else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.zoom(nil)
        }
    }
}

extension MeetingsTitleBar where Content == EmptyView {
    /// A bare strip, for a pane with nothing to put on the title bar line.
    init() { self.init { EmptyView() } }
}
