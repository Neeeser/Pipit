import AppKit
import Foundation
import PipitCore
import PipitServices
import SwiftUI
import Testing

@testable import PipitUI

// Draws the real windows offscreen over the archive named in
// `PIPIT_TIMING_ARCHIVE` and times what a person clicking around would wait
// for: the first frame, each meeting opened, each tab and each Settings page.
// The directory holds a `Meetings` folder. Skipped when the variable is unset.
// With `PIPIT_RENDER_DIR` set, the first frame is saved as a PNG.

private let windowTimingRoot = ProcessInfo.processInfo.environment["PIPIT_TIMING_ARCHIVE"]
    .map { URL(fileURLWithPath: $0) }

@Suite("WindowTiming", .enabled(if: windowTimingRoot != nil))
@MainActor
struct WindowTimingTests {
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    /// Runs `change`, then lays out and draws the window, and reports both
    /// together: what the person waits for between the click and the frame.
    @discardableResult
    private static func frame(
        _ label: String, in window: NSWindow, _ change: () -> Void
    ) -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        change()
        RunLoop.current.run(until: Date())
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.displayIfNeeded()
        let ms = milliseconds(clock.now - start)
        print(String(format: "TIMING %-52@ %9.1f ms", label as NSString, ms))
        return ms
    }

    /// Lets the work a click started in the background land, and reports how
    /// long the main thread spent on it beyond the sleeps: that time is frames
    /// the window could not draw.
    private static func settle(_ window: NSWindow) async {
        let clock = ContinuousClock()
        let start = clock.now
        let rounds = 5
        for _ in 0..<rounds {
            try? await Task.sleep(for: .milliseconds(60))
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
        }
        let busy = milliseconds(clock.now - start) - Double(rounds * 60)
        if busy > 5 { print(String(format: "TIMING %-52@ %9.1f ms", "   then main thread busy" as NSString, busy)) }
    }

    private static func capture(_ window: NSWindow, name: String) {
        guard let folder = ProcessInfo.processInfo.environment["PIPIT_RENDER_DIR"] else { return }
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: folder), withIntermediateDirectories: true)
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", "\(folder)/\(name).png"]
        try? capture.run()
        capture.waitUntilExit()
    }

    @Test("time the meetings window")
    func timeTheMeetingsWindow() async throws {
        guard let root = windowTimingRoot else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        // What launch does in the background before anyone opens the window.
        let rows = await runtime.meetingRows()
        print("TIMING   \(rows.count) meetings")

        for pass in 1...2 {
            var window: NSWindow?
            var model: MeetingsWindowModel?
            Self.frame("open meetings window, first frame (pass \(pass))", in: NSWindow()) {
                let made = MeetingsWindowModel(runtime: runtime)
                let created = WindowManager.makeMeetingsWindow(
                    content: MeetingsWindowView(model: made), autosaveName: "PipitTimingTest")
                WindowRender.orderInOutOfSight(created)
                created.contentView?.layoutSubtreeIfNeeded()
                created.contentView?.displayIfNeeded()
                made.showLastList()
                window = created
                model = made
            }
            guard let window, let model else { return }
            print("TIMING   first frame: \(model.rows.count) rows, meeting open: \(model.detail != nil)")
            Self.capture(window, name: "meetings-first-frame-pass\(pass)")
            await Self.settle(window)
            let clock = ContinuousClock()
            let start = clock.now
            await model.reload()
            print(
                String(
                    format: "TIMING %-52@ %9.1f ms", "reload after open (background)" as NSString,
                    Self.milliseconds(clock.now - start)))
            await Self.settle(window)

            if pass == 1 {
                // Newest first, as the list shows them, then the longest ones.
                let byLength = rows.sorted { $0.summary.durationSeconds > $1.summary.durationSeconds }
                let picks = Array(model.sections.flatMap(\.rows).prefix(8)) + Array(byLength.prefix(4))
                var times: [Double] = []
                for row in picks {
                    let minutes = Int(row.summary.durationSeconds / 60)
                    times.append(
                        Self.frame("click meeting (\(minutes) min)", in: window) {
                            model.select(row.id, extending: false, openingLater: true)
                        })
                    await Self.settle(window)
                }
                print(
                    String(
                        format: "TIMING   click meeting: median %.1f ms, worst %.1f ms",
                        times.sorted()[times.count / 2], times.max() ?? 0))
                // With `PIPIT_TIMING_PROFILE` set, keeps clicking for that many
                // seconds so a sampler attached to this process sees the clicks.
                if let seconds = ProcessInfo.processInfo.environment["PIPIT_TIMING_PROFILE"]
                    .flatMap(Double.init)
                {
                    print("TIMING PROFILE START pid \(ProcessInfo.processInfo.processIdentifier)")
                    let until = Date().addingTimeInterval(seconds)
                    var index = 0
                    let action = ProcessInfo.processInfo.environment["PIPIT_TIMING_PROFILE_ACTION"] ?? "click"
                    let folder = model.folderRows.first?.name
                    while Date() < until {
                        let row = picks[index % picks.count]
                        index += 1
                        Self.frame("profile \(action)", in: window) {
                            switch action {
                            case "folder":
                                if index % 2 == 0, let folder {
                                    model.open(folder: folder)
                                } else {
                                    model.closeFolder()
                                }
                            case "search": model.query = index % 2 == 0 ? "budget" : ""
                            default: model.select(row.id, extending: false)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                    print("TIMING PROFILE END after \(index) clicks")
                }
                Self.frame("summary tab", in: window) { model.tab = .summary }
                await Self.settle(window)
                Self.frame("transcript tab", in: window) { model.tab = .transcript }
                await Self.settle(window)
                Self.frame("folders view", in: window) { model.show(.folders) }
                await Self.settle(window)
                if let folder = model.folderRows.first {
                    Self.frame("open folder (\(folder.name.count) chars)", in: window) {
                        model.open(folder: folder.name)
                    }
                    await Self.settle(window)
                }
                Self.frame("timeline view", in: window) { model.show(.timeline) }
                await Self.settle(window)
                for query in ["t", "th", "the", "budget"] {
                    Self.frame("type search '\(query)'", in: window) { model.query = query }
                }
                Self.frame("clear search", in: window) { model.query = "" }
            }
            model.end()
            window.close()
        }
    }

    @Test("time the settings window")
    func timeTheSettingsWindow() async throws {
        guard let root = windowTimingRoot else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        var window: NSWindow?
        var model: SettingsModel?
        Self.frame("open settings window, first frame", in: NSWindow()) {
            let made = SettingsModel(runtime: runtime)
            let created = WindowManager.makeSplitWindow(
                title: "Pipit Settings", size: NSSize(width: 720, height: 560),
                content: SettingsView(model: made), autosaveName: "PipitTimingSettings")
            WindowRender.orderInOutOfSight(created)
            created.contentView?.layoutSubtreeIfNeeded()
            created.contentView?.displayIfNeeded()
            window = created
            model = made
        }
        guard let window, let model else { return }
        await Self.settle(window)
        for pane in SettingsPane.allCases {
            Self.frame("settings page \(pane.rawValue)", in: window) { model.pane = pane }
            await Self.settle(window)
        }
        window.close()
    }
}
