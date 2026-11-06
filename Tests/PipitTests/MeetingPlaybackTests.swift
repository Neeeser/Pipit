import AVFoundation
import Foundation
import PipitUI
import Testing

@MainActor
@Suite("MeetingPlayback")
struct MeetingPlaybackTests {
    @Test("seeking to the end stops instead of restarting the final recording")
    func seekingToEndStops() throws {
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
        defer { playback.stop() }
        playback.update(recordings: [.init(id: "recording", audio: audio, timelineOffset: 0)], lines: [])
        playback.play()
        #expect(playback.isPlaying)

        playback.skip(by: 15)

        #expect(!playback.isPlaying)
        #expect(playback.position == playback.timeline.duration)
    }

    @Test("a recording replaced by a shorter one at the same path is read again")
    func aReplacedRecordingIsReadAgain() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("recording.wav")
        func write(seconds: Double) throws {
            try? FileManager.default.removeItem(at: audio)
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
            let frames = AVAudioFrameCount(seconds * 24_000)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            try file.write(from: buffer)
        }
        let playback = MeetingPlaybackModel()
        defer { playback.stop() }
        let recordings = [MeetingPlaybackModel.Recording(id: "recording", audio: audio, timelineOffset: 0)]

        try write(seconds: 2)
        playback.update(recordings: recordings, lines: [])
        #expect(abs(playback.timeline.duration - 2) < 0.01)

        try write(seconds: 0.5)
        playback.update(recordings: recordings, lines: [])
        #expect(abs(playback.timeline.duration - 0.5) < 0.01, "got \(playback.timeline.duration)")
    }
}
