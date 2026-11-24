import AppKit
import PipitServices
import SwiftUI
import Testing

@testable import PipitUI

/// Dragging a split-view window's sidebar narrower than its minimum hides it.
/// The windows are AppKit windows around SwiftUI, and the system's own sidebar
/// button never reaches their toolbar, so a sidebar dragged shut stayed gone
/// until the window was opened again.
@Suite("Sidebar toggle")
@MainActor
struct SidebarToggleTests {
    @Test("a hidden sidebar leaves a button in the toolbar that brings it back")
    func hiddenSidebarCanComeBack() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        for hidden in [true, false] {
            let sidebar: NavigationSplitViewVisibility = hidden ? .detailOnly : .all
            let windows: [(String, AnyView)] = [
                (
                    "Meetings",
                    AnyView(MeetingsWindowView(model: MeetingsWindowModel(runtime: runtime), sidebar: sidebar))
                ),
                (
                    "People",
                    AnyView(PeopleDirectoryView(model: PeopleDirectoryModel(runtime: runtime), sidebar: sidebar))
                ),
                (
                    "Settings",
                    AnyView(
                        SettingsView(
                            model: SettingsModel(runtime: runtime, storedKeyLookup: { _ in false }), sidebar: sidebar))
                ),
            ]
            for (name, content) in windows {
                let labels = try await toolbarLabels(content)
                #expect(
                    labels.contains("Show Sidebar") == hidden,
                    "\(name) with the sidebar \(hidden ? "hidden" : "shown") has toolbar items \(labels)")
            }
        }
    }

    /// The same, reached the way a person reaches it: the divider dragged to
    /// the window's leading edge.
    @Test("dragging the Meetings sidebar shut leaves a button that brings it back")
    func draggedShutSidebarCanComeBack() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = MeetingsWindowModel(runtime: RuntimeFixtures.makeRuntime(root: root))
        let window = WindowManager.makeMeetingsWindow(
            content: MeetingsWindowView(model: model), autosaveName: "PipitRenderTest")
        WindowRender.orderInOutOfSight(window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let split = try #require(window.contentView.flatMap(Self.splitView(in:)))
        let before = window.toolbar?.items.map(\.label) ?? []
        #expect(!before.contains("Show Sidebar"), "before the drag, toolbar items \(before)")
        split.setPosition(0, ofDividerAt: 0)
        try await Task.sleep(for: .milliseconds(400))
        let after = window.toolbar?.items.map(\.label) ?? []
        #expect(after.contains("Show Sidebar"), "after the drag, toolbar items \(after)")
    }

    private static func splitView(in view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for child in view.subviews {
            if let found = splitView(in: child) { return found }
        }
        return nil
    }

    private func toolbarLabels(_ content: AnyView) async throws -> [String] {
        let window = WindowManager.makeSplitWindow(
            title: "Sidebar", size: NSSize(width: 1_000, height: 640), content: content)
        WindowRender.orderInOutOfSight(window)
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        return window.toolbar?.items.map(\.label) ?? []
    }
}
