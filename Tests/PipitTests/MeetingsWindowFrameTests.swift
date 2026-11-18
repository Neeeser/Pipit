import AppKit
import SwiftUI
import Testing

@testable import PipitUI

@MainActor
@Suite("MeetingsWindowFrame")
struct MeetingsWindowFrameTests {
    @Test("the meetings window reopens where it was left")
    func reopensAtSavedFrame() throws {
        let name = "MeetingsWindowFrameTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        // Inside a screen this Mac has, the way a person leaves a window. AppKit
        // moves a restored frame that hangs off its screen, so a fixed frame
        // passed on one display arrangement and failed on another.
        let screen = try #require(NSScreen.screens.first).visibleFrame
        let left = NSRect(
            x: screen.minX + 15, y: screen.minY + 20,
            width: min(900, screen.width - 30), height: min(588, screen.height - 40)
        )

        let first = WindowManager.makeMeetingsWindow(content: Text("First"), autosaveName: name)
        first.setFrame(left, display: false)
        first.saveFrame(usingName: name)
        first.close()
        // A name belongs to one window at a time, as it does across launches.
        first.setFrameAutosaveName("")

        let second = WindowManager.makeMeetingsWindow(content: Text("Second"), autosaveName: name)
        defer { second.close() }
        #expect(second.frame == left, "reopened at \(second.frame)")
    }
}
