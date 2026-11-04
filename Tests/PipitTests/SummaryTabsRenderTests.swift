import AppKit
import Foundation
import PipitCore
import PipitServices
import SwiftUI
import Testing

@testable import PipitUI

/// The Summary and Notes tabs drawn for an invented meeting, at the width of a
/// quarter of the screen and at full width, in both appearances.
///
/// Set `PIPIT_RENDER_DIR` to a folder to keep the drawings as PNG files.
@Suite("Summary tabs")
@MainActor
struct SummaryTabsRenderTests {
    private static let structure = GeneratedSummary(
        overview: "The team checked whether the beta can open to the waitlist on Thursday. Sign-up and "
            + "payments are ready; the offline sync bug is the one blocker, with a fix expected Wednesday.",
        topics: [
            GeneratedSummary.Topic(
                title: "Offline sync bug", at: 200,
                points: [
                    "Edits made offline on two devices are lost when both reconnect",
                    "The merge step replaces the record instead of merging fields",
                ],
                decisions: [GeneratedSummary.Item(text: "Hold the invites until the sync fix is verified", at: 310)],
                actionItems: [
                    GeneratedSummary.ActionItem(
                        task: "Ship the fix for lost offline edits", owner: "Marcus", due: "Wed, Nov 4", at: 372)
                ],
                openQuestions: [GeneratedSummary.Item(text: "Who answers support email during launch week?", at: 1_754)]
            ),
            GeneratedSummary.Topic(
                title: "Waitlist invites", at: 930,
                points: ["2,140 people are on the waitlist", "Two waves keep support load manageable"],
                decisions: [GeneratedSummary.Item(text: "Invite the waitlist in two waves", at: 1_075)],
                actionItems: [
                    GeneratedSummary.ActionItem(
                        task: "Send the first 500 invites", owner: "Priya", due: "Thu, Nov 5", at: 1_120),
                    GeneratedSummary.ActionItem(task: "Set up a feedback category in the forum", at: 1_862),
                ]
            ),
        ]
    )

    private func reviewModel(root: URL) throws -> MeetingReviewModel {
        let archive = root.appendingPathComponent("Meetings")
        let repository = MeetingRepository(root: archive)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "Beta check-in", timestampFallback: "f"), now: started
        )
        let document = SummaryDocument(
            summary: Self.structure.summaryMarkdown, generatedNotes: Self.structure.notesMarkdown
        )
        try created.store.writeSummary(document.markdown, structure: Self.structure)
        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = archive.path
        runtime.update(settings: settings)
        return MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
    }

    @Test("both tabs lay out at a quarter of the screen and at full width, dark and light")
    func bothTabsLayOut() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try reviewModel(root: root)
        #expect(detail.generatedSummary == Self.structure)
        let windowModel = MeetingsWindowModel(runtime: detail.runtime)

        let output = ProcessInfo.processInfo.environment["PIPIT_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        for (tab, view) in [
            ("summary", AnyView(MeetingSummaryTab(detail: detail))),
            ("notes", AnyView(MeetingNotesTab(model: windowModel, detail: detail))),
        ] {
            for width in [470.0, 1_000.0] {
                for (look, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                    let host = NSHostingView(
                        rootView: view.padding(.top, 14).frame(width: width, height: 774)
                            .background(Color(nsColor: .windowBackgroundColor)))
                    host.appearance = NSAppearance(named: appearance)
                    host.frame = NSRect(x: 0, y: 0, width: width, height: 774)
                    host.layoutSubtreeIfNeeded()
                    #expect(host.fittingSize.width > 0, "\(tab) at \(width) did not lay out")
                    guard let output, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                        continue
                    }
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try bitmap.representation(using: .png, properties: [:])?
                        .write(to: output.appendingPathComponent("\(tab)-\(Int(width))-\(look).png"))
                }
            }
        }
    }
}
