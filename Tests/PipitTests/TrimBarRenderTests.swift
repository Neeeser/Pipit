import AppKit
import Foundation
import PipitCore
import PipitServices
import SwiftUI
import Testing

@testable import PipitUI

@Suite("Trim bar")
@MainActor
struct TrimBarRenderTests {
    /// A finished, archived two-track meeting open in the detail pane.
    private func detail(root: URL, source: MeetingSource? = nil) throws -> MeetingReviewModel {
        let archive = root.appendingPathComponent("Meetings")
        let made = try PipelineFixtures.makeRecordedMeeting(root: archive, seconds: 60)
        _ = try made.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
        }
        _ = try AudioCompactor().compact(store: made.store)
        if let source { _ = try made.store.updateMetadata { $0.source = source } }
        let runtime = PipitRuntime(settingsDirectory: root)
        var settings = runtime.settings
        settings.storageRootPath = archive.path
        runtime.update(settings: settings)
        return MeetingReviewModel(runtime: runtime, meetingID: made.metadata.id)
    }

    @Test("a finished meeting offers Trim, and the bar lays out in trim mode")
    func aFinishedMeetingOffersTrim() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try detail(root: root)
        #expect(detail.canTrim, "a finished, archived recording can be trimmed")
        let limits = try #require(detail.trimLimits)
        #expect(limits.start.lowerBound == 0)

        let output = ProcessInfo.processInfo.environment["PIPIT_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        let trims: [(String, ClosedRange<Double>?)] = [("idle", nil), ("trimming", 9...41)]
        for (name, trim) in trims {
            for (look, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
                detail.trimDraft = trim
                let host = NSHostingView(
                    rootView: MeetingPlayerBar(detail: detail, roomy: false)
                        .frame(width: 900)
                        .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: appearance)
                host.frame = NSRect(x: 0, y: 0, width: 900, height: 60)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width > 0, "\(name) did not lay out")
                guard let output, let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: output.appendingPathComponent("trim-\(name)-\(look).png"))
            }
        }
    }

    @Test("a meeting imported from a file is not offered Trim")
    func anImportedMeetingIsNotOfferedTrim() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try detail(root: root.appendingPathComponent("recorded")).canTrim)
        #expect(!(try detail(root: root.appendingPathComponent("imported"), source: .imported).canTrim))
    }

    private func parts(_ lengths: [(id: String, seconds: Double)]) -> [PlaybackTimeline.Part] {
        PlaybackTimeline(
            lengths.map {
                PlaybackTimeline.Source(
                    recordingID: $0.id, audio: URL(fileURLWithPath: "/\($0.id).m4a"), duration: $0.seconds,
                    timelineOffset: 0)
            }
        ).parts
    }

    @Test("a handle at the end of the timeline keeps each track to its end")
    func aHandleAtTheEndKeepsEachTrackToItsEnd() throws {
        // The mixdown is 65 s because the far end began 5 s late, and the
        // meeting's recorded length is 60 s.
        let one = parts([("a", 65)])
        let toEnd = MeetingReviewModel.cuts(parts: one, keepFrom: 5, to: 65)
        #expect(toEnd.count == 1)
        #expect(toEnd.first?.range.keepsEnd == true)
        #expect(toEnd.first?.range.start == 5)
        let before = MeetingReviewModel.cuts(parts: one, keepFrom: 5, to: 40)
        #expect(before.first?.range.keepsEnd == false)
        #expect(before.first?.range.end == 40)

        // A handle in the far end's late tail, between 60 s and 65 s, cuts the
        // tail off. With the start at 0 that is the whole trim.
        let tail = MeetingReviewModel.cuts(parts: one, keepFrom: 0, to: 62)
        #expect(tail.count == 1, "a handle at 62 s of 65 removes the last 3 s")
        #expect(tail.first?.range.keepsEnd == false)
        #expect(tail.first?.range.end == 62)
    }

    @Test("across recordings only the start of the first and the end of the last move")
    func acrossRecordingsOnlyTheOuterEndsMove() throws {
        let two = parts([("a", 60), ("b", 40)])

        let both = MeetingReviewModel.cuts(parts: two, keepFrom: 10, to: 90)
        #expect(both.map(\.id) == ["a", "b"])
        #expect(both[0].range.start == 10)
        #expect(both[0].range.keepsEnd, "the first recording is kept to its end")
        #expect(both[1].range.start == 0)
        #expect(both[1].range.end == 30, "90 on the playback bar is 30 s into the second recording")
        #expect(!both[1].range.keepsEnd)

        let startOnly = MeetingReviewModel.cuts(parts: two, keepFrom: 10, to: 100)
        #expect(startOnly.map(\.id) == ["a"], "the second is kept whole, so it is not touched")
        let endOnly = MeetingReviewModel.cuts(parts: two, keepFrom: 0, to: 90)
        #expect(endOnly.map(\.id) == ["b"])
        // A handle cannot take a whole recording with it.
        let clamped = MeetingReviewModel.cuts(parts: two, keepFrom: 75, to: 100)
        #expect(clamped.isEmpty, "the start cannot leave the first recording, and there is nothing else to cut")
    }

    @Test("a dragged handle snaps onto the playhead within a few points of it, and not further")
    func aHandleSnapsOntoThePlayhead() {
        // 600 points for 600 seconds: one point is one second.
        let near = TrimBracket.snapped(103, toPlayhead: 100, duration: 600, width: 600)
        #expect(near == 100, "3 points away snaps")
        let far = TrimBracket.snapped(110, toPlayhead: 100, duration: 600, width: 600)
        #expect(far == nil, "10 points away does not")
        let zoomedOut = TrimBracket.snapped(103, toPlayhead: 100, duration: 6_000, width: 600)
        #expect(zoomedOut == 100, "30 seconds is under a point on a long meeting")
    }

    @Test("I and O set the start and end at the playhead, within the limits")
    func anEdgeMovesToThePlayhead() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let detail = try detail(root: root)
        detail.beginTrimming()
        let draft = try #require(detail.trimDraft)
        #expect(draft.lowerBound == 0)

        detail.moveTrimEdge(.start, to: 12)
        #expect(detail.trimDraft?.lowerBound == 12)
        detail.moveTrimEdge(.end, to: 40)
        #expect(detail.trimDraft?.upperBound == 40)
        // The start cannot pass the end, less the shortest stretch Trim keeps.
        detail.moveTrimEdge(.start, to: 45)
        #expect(detail.trimDraft?.lowerBound == 40 - MeetingTrim.shortestKept)

        detail.cancelTrimming()
        #expect(detail.trimDraft == nil)
    }
}
