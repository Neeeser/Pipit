import AppKit
import Foundation
import PipitCore
import PipitServices
import SwiftUI
import Testing

@testable import PipitUI

/// The whole meetings window drawn over an invented archive, at a quarter of
/// the screen and at full screen, in both appearances, with one meeting open
/// and with several selected.
///
/// Set `PIPIT_RENDER_DIR` to a folder to keep the drawings as PNG files.
@Suite("Meetings window render")
@MainActor
struct MeetingsWindowRenderTests {
    private static let summary = GeneratedSummary(
        overview: "The team checked whether the beta can open to the waitlist on Thursday. Sign-up and "
            + "payments are ready; the offline sync bug is the one blocker, with a fix expected Wednesday.",
        topics: [
            GeneratedSummary.Topic(
                title: "Offline sync bug", at: 20,
                points: [
                    "Edits made offline on two devices are lost when both reconnect",
                    "The merge step replaces the record instead of merging fields",
                ],
                actionItems: [
                    GeneratedSummary.ActionItem(
                        task: "Ship the fix for lost offline edits", owner: "Marcus Lee", due: "Wed, Nov 4", at: 37)
                ]
            ),
            GeneratedSummary.Topic(
                title: "Waitlist invites", at: 60,
                points: ["2,140 people are on the waitlist", "Two waves keep support load manageable"],
                actionItems: [
                    GeneratedSummary.ActionItem(
                        task: "Send the first 500 invites", owner: "Priya Shah", due: "Thu, Nov 5", at: 80)
                ]
            ),
        ]
    )

    private static let turns: [(key: String, track: CaptureTrack, text: String)] = [
        (SpeakerLabel.localUser, .mic, "Hey"),
        ("remote-001_speaker_00", .remote, "Hi, can you hear me all right? I just switched headsets."),
        (SpeakerLabel.localUser, .mic, "Loud and clear. Shall we start with the sync bug?"),
        (
            "remote-001_speaker_01", .remote,
            "Sure. The short version is that edits made offline on two devices get lost when both of them "
                + "reconnect, because the merge step replaces the whole record instead of merging fields."
        ),
        ("remote-001_speaker_00", .remote, "Do we have a fix in review yet, or is that still being written?"),
        (
            "remote-001_speaker_01", .remote,
            "It is in review now. I expect to ship it on Wednesday if the tests on the web app pass."
        ),
        ("remote-001_speaker_02", .remote, "Then the waitlist invites can go out Thursday as planned."),
        (SpeakerLabel.localUser, .mic, "Good. Let's send the first five hundred and watch support email."),
    ]

    private func makeArchive(root: URL) throws -> (runtime: PipitRuntime, open: String, others: [String]) {
        let archive = root.appendingPathComponent("Meetings")
        let made = try PipelineFixtures.makeRecordedMeeting(root: archive, source: .slackHuddle, seconds: 100)
        let started = made.metadata.startedAt
        let utterances = Self.turns.enumerated().map { index, turn in
            Utterance(
                id: "u\(index)", start: Double(index) * 12, end: Double(index) * 12 + 10,
                track: turn.track, rawSpeakerLabel: turn.key, speakerKey: turn.key,
                text: turn.text, chunkID: "c1", model: "m"
            )
        }
        try made.store.writeCanonicalTranscript(CanonicalTranscript(generatedAt: started, utterances: utterances))
        var map = SpeakerMap()
        map.assign("Priya Shah", to: "remote-001_speaker_00")
        map.assign("Marcus Lee", to: "remote-001_speaker_01")
        try made.store.writeSpeakerMap(map)
        _ = try made.store.updateMetadata {
            $0.titles = TitleCandidates(provider: "Beta check-in", timestampFallback: "f")
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        let document = SummaryDocument(
            summary: Self.summary.summaryMarkdown, generatedNotes: Self.summary.notesMarkdown
        )
        try made.store.writeSummary(document.markdown, structure: Self.summary)
        _ = try AudioCompactor().compact(store: made.store)

        var others: [String] = []
        let extra: [(String, MeetingSource, Double)] = [
            ("Design review", .googleMeet, -3_600),
            ("Hiring sync", .zoom, -86_400),
            ("Roadmap planning", .googleMeet, -90_000),
            ("Customer call", .slackHuddle, -200_000),
        ]
        for (title, source, offset) in extra {
            let meeting = try RuntimeFixtures.makeMeeting(
                root: root, clusters: ["remote-001_speaker_00", "remote-001_speaker_01"], source: source,
                title: title, startedAt: started.addingTimeInterval(offset)
            )
            others.append(meeting.id)
        }

        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = archive.path
        settings.localUserName = "Sam Rivera"
        runtime.update(settings: settings)
        return (runtime, made.metadata.id, others)
    }

    private static let looks: [(String, NSAppearance.Name)] = [("dark", .darkAqua), ("light", .aqua)]

    /// Lays a view out in a window built the way the app builds the meetings
    /// window, and writes it to `PIPIT_RENDER_DIR` when that is set.
    ///
    /// A window rather than a bare hosting view: a split view's panes draw
    /// nothing offscreen without one. The fill behind the content stands in for
    /// the window background, which `cacheDisplay` does not capture.
    private func render(_ content: some View, size: CGSize, appearance: NSAppearance.Name, name: String) async throws {
        let window = WindowManager.makeMeetingsWindow(
            content: content.background(Color(nsColor: .windowBackgroundColor)), autosaveName: "PipitRenderTest"
        )
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        // On screen but out of sight: a split view built by SwiftUI lays out
        // and draws its columns only once its window is ordered in.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.hasShadow = false
        window.orderFrontRegardless()
        defer { window.close() }
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        #expect(view.fittingSize.width > 0, "\(name) did not lay out")
        guard let output = ProcessInfo.processInfo.environment["PIPIT_RENDER_DIR"].map({ URL(fileURLWithPath: $0) })
        else { return }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        // From the window server rather than `cacheDisplay`, which draws the
        // columns of a SwiftUI split view and its sidebar material as blank.
        // `-o` leaves out the shadow, so the file is the window alone.
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", output.appendingPathComponent("\(name).png").path]
        try capture.run()
        capture.waitUntilExit()
    }

    @Test("the window lays out with one meeting open and with several selected")
    func theWindowLaysOut() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let built = try makeArchive(root: root)
        let model = MeetingsWindowModel(runtime: built.runtime)
        await model.reload()

        let sizes: [(String, CGSize)] = [
            ("quarter", CGSize(width: 900, height: 640)), ("full", CGSize(width: 1_728, height: 1_080)),
        ]
        let states: [(String, () -> Void)] = [
            (
                "transcript",
                {
                    model.select(built.open, extending: false)
                    model.tab = .transcript
                }
            ),
            (
                "summary",
                {
                    model.select(built.open, extending: false)
                    model.tab = .summary
                }
            ),
            (
                "trim",
                {
                    model.select(built.open, extending: false)
                    model.tab = .transcript
                    model.detail?.beginTrimming()
                    model.detail?.moveTrimEdge(.start, to: 9)
                    model.detail?.moveTrimEdge(.end, to: 88)
                }
            ),
            (
                "multiselect",
                {
                    model.detail?.cancelTrimming()
                    model.select(built.open, extending: false)
                    for id in built.others.prefix(3) { model.select(id, extending: true) }
                }
            ),
        ]
        for (state, apply) in states {
            apply()
            for _ in 0..<40 where model.detail?.combinedLines.isEmpty ?? false {
                try await Task.sleep(for: .milliseconds(50))
            }
            for (sizeName, size) in sizes {
                for (look, appearance) in Self.looks {
                    try await render(
                        MeetingsWindowView(model: model), size: size, appearance: appearance,
                        name: "window-\(state)-\(sizeName)-\(look)")
                }
            }
        }
    }

    @Test("every Settings pane lays out, dark and light")
    func everySettingsPaneLaysOut() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let runtime = PipitRuntime(settingsDirectory: root)
        let model = SettingsModel(runtime: runtime, storedKeyLookup: { _ in false })
        for pane in SettingsPane.allCases {
            model.pane = pane
            for (look, appearance) in Self.looks {
                try await render(
                    SettingsView(model: model), size: CGSize(width: 760, height: 600), appearance: appearance,
                    name: "settings-\(pane.rawValue)-\(look)")
            }
        }
    }

    /// Typing in a freshly opened window renamed the meeting: the split view
    /// handed the first key view to the title field rather than the search
    /// field, and Space stopped playing because a field with text held it.
    @Test("opening the window gives the keys to the search field, not the meeting's title")
    func theSearchFieldHasTheKeys() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let built = try makeArchive(root: root)
        let model = MeetingsWindowModel(runtime: built.runtime)
        await model.reload()
        model.select(built.open, extending: false)
        let window = WindowManager.makeMeetingsWindow(
            content: MeetingsWindowView(model: model), autosaveName: "PipitRenderTest")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.close() }
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        let editor = window.firstResponder as? NSTextView
        #expect(editor?.string != "Beta check-in", "the title field holds the keys")
    }
}
