import AppKit
import SwiftUI
import Testing

@testable import PipitUI

@MainActor
@Suite("MeetingsWindowFrame")
struct MeetingsWindowFrameTests {
    @Test("the meetings window reopens where it was left")
    func reopensAtSavedFrame() {
        let name = "MeetingsWindowFrameTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: "NSWindow Frame \(name)") }
        let left = NSRect(x: 15, y: 300, width: 900, height: 588)

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
