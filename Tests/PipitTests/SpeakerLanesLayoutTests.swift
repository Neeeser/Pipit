import AVFoundation
import AppKit
import PipitCore
import SwiftUI
import Testing

@testable import PipitUI

/// A one second silent recording, enough for the timeline to have a length.
private func silentRecording(in root: URL) throws -> URL {
    let audio = root.appendingPathComponent("recording.wav")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
    buffer.frameLength = buffer.frameCapacity
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { samples[index] = 0 }
    do {
        let file = try AVAudioFile(forWriting: audio, settings: format.settings)
        try file.write(from: buffer)
    }
    return audio
}

@MainActor
@Suite("SpeakerLanesLayout")
struct SpeakerLanesLayoutTests {
    private struct Snapshot {
        var firstLanePixel: Int
        var lastLanePixel: Int
        var darkPixels: Int
        var playheadPixel: Int
    }

    private func snapshot(_ playback: MeetingPlaybackModel, width: CGFloat, hover: CGFloat?) throws -> Snapshot {
        let view = NSHostingView(
            rootView: SpeakerLanesPlot(playback: playback, tint: { _ in .red }, hover: .constant(hover), height: 10)
                .padding(.vertical, 32)
                .frame(width: width, height: 74)
                .background(.white)
                .environment(\.colorScheme, .light)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: 74)
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        var first = image.pixelsWide
        var last = -1
        var dark = 0
        var playhead: Int?
        let playheadRow = image.pixelsHigh * 43 / 74
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent > color.greenComponent + 0.15,
                    color.redComponent > color.blueComponent + 0.15
                {
                    first = min(first, x)
                    last = max(last, x)
                }
                if color.redComponent < 0.3, color.greenComponent < 0.3, color.blueComponent < 0.3 {
                    dark += 1
                    if y == playheadRow, playhead == nil { playhead = x }
                }
            }
        }
        #expect(last >= first, "the rendered plot must contain the speaker lane")
        return Snapshot(
            firstLanePixel: first, lastLanePixel: last, darkPixels: dark, playheadPixel: try #require(playhead)
        )
    }

    @Test("hover feedback leaves the speaker lane in the same place", arguments: [96.0, 160.0, 400.0])
    func hoverDoesNotMoveLanes(width: Double) throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try silentRecording(in: root)
        let playback = MeetingPlaybackModel()
        playback.update(
            recordings: [.init(id: "rec-a", audio: audio, timelineOffset: 0)],
            lines: [PlaybackTimelineTests.line(speaker: "Synthetic speaker label", start: 0, end: 0.4, text: "Test")]
        )
        playback.seek(to: 0.5)
        let baseline = try snapshot(playback, width: width, hover: nil)
        for hover in [0.1, 0.5, 0.9] {
            let hovered = try snapshot(playback, width: width, hover: hover)
            #expect(hovered.darkPixels > baseline.darkPixels + 30, "the hover label must actually be rendered")
            #expect(hovered.firstLanePixel == baseline.firstLanePixel)
            #expect(hovered.lastLanePixel == baseline.lastLanePixel)
            #expect(hovered.playheadPixel == baseline.playheadPixel)
        }
    }
}

@MainActor
@Suite("SpeakerLanesCombined")
struct SpeakerLanesCombinedTests {
    /// Rows of the rendered plot that hold a pixel of the given colour.
    private func rows(
        _ playback: MeetingPlaybackModel, combined: Bool, height: CGFloat,
        matching test: (NSColor) -> Bool
    ) throws -> Set<Int> {
        let tint: (String) -> Color = { $0 == "Synthetic speaker one" ? .red : .blue }
        let view = NSHostingView(
            rootView: SpeakerLanesPlot(
                playback: playback, tint: tint, hover: .constant(nil), height: height, combined: combined
            )
            .frame(width: 200, height: height)
            .background(.white)
            .environment(\.colorScheme, .light)
        )
        view.frame = NSRect(x: 0, y: 0, width: 200, height: height)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        var found: Set<Int> = []
        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if test(color) { found.insert(y) }
            }
        }
        return found
    }

    @Test("the closed strip draws every speaker on the same row")
    func combinedDrawsEverySpeakerOnOneRow() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try silentRecording(in: root)
        let playback = MeetingPlaybackModel()
        playback.update(
            recordings: [.init(id: "rec-a", audio: audio, timelineOffset: 0)],
            lines: [
                PlaybackTimelineTests.line(speaker: "Synthetic speaker one", start: 0, end: 0.4, text: "One"),
                PlaybackTimelineTests.line(speaker: "Synthetic speaker two", start: 0.5, end: 0.9, text: "Two"),
            ]
        )
        // Past both turns, so both are drawn at full strength.
        playback.seek(to: 1)
        let red: (NSColor) -> Bool = {
            $0.redComponent > $0.greenComponent + 0.3 && $0.redComponent > $0.blueComponent + 0.3
        }
        let blue: (NSColor) -> Bool = {
            $0.blueComponent > $0.redComponent + 0.3 && $0.blueComponent > $0.greenComponent + 0.3
        }

        let combinedRed = try rows(playback, combined: true, height: SpeakerLanesPlot.combinedHeight, matching: red)
        let combinedBlue = try rows(playback, combined: true, height: SpeakerLanesPlot.combinedHeight, matching: blue)
        #expect(!combinedRed.isEmpty && !combinedBlue.isEmpty, "both speakers must be drawn")
        #expect(combinedRed == combinedBlue, "both speakers must share one row")

        // The lane per speaker, for contrast: the same two speakers on two rows.
        let laneRed = try rows(playback, combined: false, height: 22, matching: red)
        let laneBlue = try rows(playback, combined: false, height: 22, matching: blue)
        #expect(laneRed.isDisjoint(with: laneBlue))
    }
}

@MainActor
@Suite("OpenSpeakerLanes")
struct OpenSpeakerLanesTests {
    @Test("open lanes reach across a wide bar instead of stopping halfway")
    func lanesFillTheWidth() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try silentRecording(in: root)
        let playback = MeetingPlaybackModel()
        playback.update(
            recordings: [.init(id: "rec-a", audio: audio, timelineOffset: 0)],
            lines: [PlaybackTimelineTests.line(speaker: "Synthetic speaker", start: 0, end: 0.99, text: "Test")]
        )
        playback.seek(to: 1)
        let width: CGFloat = 1_200
        let view = NSHostingView(
            rootView: OpenSpeakerLanes(
                playback: playback, tint: { _ in .red }, talkSeconds: { _ in 1 }, hover: .constant(nil)
            )
            .frame(width: width)
            .background(.white)
            .environment(\.colorScheme, .light)
        )
        view.frame = NSRect(x: 0, y: 0, width: width, height: view.fittingSize.height)
        view.layoutSubtreeIfNeeded()
        let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        // The lane is one unbroken red bar, the longest red run on any row of
        // pixels; the red name beside it breaks up into letters.
        var longestRun = 0
        for y in 0..<image.pixelsHigh {
            var run = 0
            for x in 0..<image.pixelsWide {
                let red =
                    image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB).map {
                        $0.redComponent > 0.8 && $0.greenComponent < 0.5 && $0.blueComponent < 0.5
                    } ?? false
                run = red ? run + 1 : 0
                longestRun = max(longestRun, run)
            }
        }
        let laneWidth = CGFloat(longestRun) / (CGFloat(image.pixelsWide) / width)
        // The names and the talk time take a little over 150 points of the 1200;
        // the lane gets the rest.
        #expect(laneWidth > width * 0.75, "the lane is \(laneWidth) of \(width) points wide")
    }
}
