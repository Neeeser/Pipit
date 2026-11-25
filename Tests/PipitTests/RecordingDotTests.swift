import AppKit
import SwiftUI
import Testing

@testable import PipitServices
@testable import PipitUI

/// Counts the layout passes SwiftUI asks of its host. A running animation asks
/// for one on every frame; a still view asks for none.
@MainActor
private final class CountingHost<Content: View>: NSHostingView<Content> {
    var layouts = 0

    override func layout() {
        layouts += 1
        super.layout()
    }
}

@MainActor
@Suite("RecordingDot")
struct RecordingDotTests {
    @Test("the dot stops animating once recording stops, so a hidden live window costs no CPU")
    func stopsPulsingWhenNotLive() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let host = CountingHost(rootView: RecordingDot(isLive: true))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.contentView = host
        WindowRender.orderInOutOfSight(panel)
        defer { panel.orderOut(nil) }

        try await Task.sleep(for: .milliseconds(500))
        let whileLive = host.layouts

        host.rootView = RecordingDot(isLive: false)
        panel.orderOut(nil)
        try await Task.sleep(for: .milliseconds(300))
        let settled = host.layouts
        try await Task.sleep(for: .seconds(1))

        // The pulse has to have been running for the check below to mean anything.
        #expect(whileLive > 5)
        #expect(host.layouts - settled < 3)
    }

    @Test("closing the live window during a call tells its view that nobody can see it")
    func panelReportsWhenHidden() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let model = LiveTranscriptModel()
        model.setState(.live)
        let panel = LiveTranscriptPanel(model: model) { _ in }
        #expect(!panel.presence.isShown)

        WindowRender.orderInOutOfSight(panel)
        #expect(panel.presence.isShown)

        panel.orderOut(nil)
        #expect(!panel.presence.isShown)
    }
}
