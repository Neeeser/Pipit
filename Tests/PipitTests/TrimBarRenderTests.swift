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
    private func detail(root: URL) throws -> MeetingReviewModel {
        let archive = root.appendingPathComponent("Meetings")
        let made = try PipelineFixtures.makeRecordedMeeting(root: archive, seconds: 60)
        _ = try made.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: $0.startedAt)
        }
        _ = try AudioCompactor().compact(store: made.store)
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
                let host = NSHostingView(
                    rootView: MeetingPlayerBar(detail: detail, roomy: false, trim: trim)
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
}
