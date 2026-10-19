import AVFoundation
import AppKit
import PipitCore
import SwiftUI
import Testing

@testable import PipitUI

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
