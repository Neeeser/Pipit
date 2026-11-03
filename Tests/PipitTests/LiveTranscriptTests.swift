import AVFoundation
import Foundation
import Testing

@testable import PipitAudio
@testable import PipitCore

/// The live transcript's plain parts: how engine updates become lines, how
/// speaker labels survive repeated passes, and how the microphone is lined up
/// with the far end before echo removal.
@Suite("Live transcript")
struct LiveTranscriptTests {
    // MARK: lines

    @Test("a provisional update is replaced, and a final one settles the line")
    func provisionalThenFinal() {
        var transcript = LiveTranscript()
        transcript.apply(.init(text: "can you", isFinal: false, start: 1, end: 2), track: .remote)
        transcript.apply(.init(text: "can you take the", isFinal: false, start: 1, end: 3), track: .remote)
        #expect(transcript.lines.count == 1)
        #expect(transcript.lines[0].text == "can you take the")
        #expect(!transcript.lines[0].isFinal)
        transcript.apply(.init(text: "Can you take the next one?", isFinal: true, start: 1, end: 4), track: .remote)
        #expect(transcript.lines.count == 1)
        #expect(transcript.lines[0].isFinal)
        transcript.apply(.init(text: "Sure", isFinal: false, start: 5, end: 6), track: .remote)
        #expect(transcript.lines.map(\.text) == ["Can you take the next one?", "Sure"])
    }

    @Test("each track fills its own line, and lines stay in spoken order")
    func tracksInterleaveInOrder() {
        var transcript = LiveTranscript()
        transcript.apply(.init(text: "second", isFinal: true, start: 4, end: 5), track: .remote)
        transcript.apply(.init(text: "first", isFinal: false, start: 2, end: 3), track: .mic)
        transcript.apply(.init(text: "still talking", isFinal: false, start: 6, end: 7), track: .remote)
        #expect(transcript.lines.map(\.text) == ["first", "second", "still talking"])
        transcript.apply(.init(text: "first words", isFinal: true, start: 2, end: 3.5), track: .mic)
        #expect(transcript.lines.map(\.text) == ["first words", "second", "still talking"])
    }

    @Test("an empty provisional update removes the open line")
    func emptyGuessRemovesLine() {
        var transcript = LiveTranscript()
        transcript.apply(.init(text: "uh", isFinal: false, start: 1, end: 2), track: .mic)
        transcript.apply(.init(text: "", isFinal: false, start: 1, end: 2), track: .mic)
        #expect(transcript.lines.isEmpty)
    }

    @Test("a note lands at the time it was typed")
    func noteAtTime() {
        var transcript = LiveTranscript()
        transcript.apply(.init(text: "before", isFinal: true, start: 1, end: 2), track: .remote)
        transcript.apply(.init(text: "after", isFinal: true, start: 9, end: 10), track: .remote)
        transcript.addNote("follow up on pricing", at: 5)
        #expect(transcript.lines.map(\.text) == ["before", "follow up on pricing", "after"])
        #expect(transcript.lines[1].kind == .note)
    }

    // MARK: speakers

    @Test("a far-end line takes the speaker who talked most over it")
    func speakerByOverlap() {
        var transcript = LiveTranscript()
        transcript.apply(.init(text: "hello there", isFinal: true, start: 10, end: 14), track: .remote)
        transcript.label(
            turns: [
                .init(start: 9, end: 11, speaker: "live-1"),
                .init(start: 11, end: 14, speaker: "live-2"),
            ],
            names: ["live-2": "Ada Park"]
        )
        let line = transcript.lines[0]
        #expect(transcript.speaker(of: line) == "live-2")
        #expect(transcript.displayName(ofSpeaker: "live-2") == "Ada Park")
        #expect(transcript.displayName(ofSpeaker: "live-1") == "Speaker 2")
    }

    @Test("labels carry over to the next pass by overlap, and new voices get new labels")
    func labelsStayStable() {
        let first = LiveSpeakerLabels.stabilize(
            previous: [],
            intervals: [.init(start: 0, end: 10, cluster: "S0"), .init(start: 10, end: 20, cluster: "S1")],
            used: []
        )
        #expect(first.labels == ["S0": "live-1", "S1": "live-2"])
        // The next pass names the same voices the other way round and finds
        // a third.
        let second = LiveSpeakerLabels.stabilize(
            previous: first.turns,
            intervals: [
                .init(start: 0, end: 10, cluster: "S1"), .init(start: 10, end: 20, cluster: "S0"),
                .init(start: 20, end: 30, cluster: "S2"),
            ],
            used: Set(first.labels.values)
        )
        #expect(second.labels == ["S1": "live-1", "S0": "live-2", "S2": "live-3"])
    }

    @Test("two clusters touching one earlier speaker do not share its label")
    func splitSpeakerGetsOneLabel() {
        let previous = [LiveSpeakerTurn(start: 0, end: 20, speaker: "live-1")]
        let result = LiveSpeakerLabels.stabilize(
            previous: previous,
            intervals: [.init(start: 0, end: 15, cluster: "A"), .init(start: 15, end: 20, cluster: "B")],
            used: ["live-1"]
        )
        #expect(result.labels["A"] == "live-1")
        #expect(result.labels["B"] == "live-2")
    }

    @Test("a mention is the first name said as a word")
    func mentionMatchesWord() {
        #expect(LiveTranscript.mentions("Sam Rivera", in: "Sam, can you take the next one?"))
        #expect(!LiveTranscript.mentions("Sam Rivera", in: "the same as last week"))
        #expect(!LiveTranscript.mentions("", in: "anything"))
    }

    // MARK: settings

    @Test("a settings file without the live block keeps the defaults")
    func liveSettingsDefault() throws {
        let decoded = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(decoded.live == LiveTranscriptSettings())
        #expect(decoded.live.isEnabled)
        #expect(!decoded.live.opensWithRecording)
        #expect(decoded.live.hiddenFromScreenSharing)
    }

    @Test("a stored engine with no live path falls back to the preferred one")
    func liveEngineWithoutLivePath() throws {
        let data = Data(#"{"live":{"engine":"cohere","isEnabled":false}}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.live.engine == LiveTranscriptSettings.preferredEngine)
        #expect(!decoded.live.isEnabled)
    }

    // MARK: audio

    @Test("the microphone is cleaned against the far end at the same timeline position")
    func echoUsesAlignedReference() {
        let canceller = RecordingCanceller(block: 4)
        let remover = LiveEchoRemover(canceller: canceller)
        remover.addReference([1, 2, 3, 4, 5, 6, 7, 8], start: 100)
        let cleaned = remover.addMicrophone([0, 0, 0, 0], start: 104)
        #expect(cleaned?.start == 104)
        #expect(canceller.references == [[5, 6, 7, 8]])
    }

    @Test("the microphone waits for the far end, then goes ahead with silence")
    func echoWaitsThenGivesUp() {
        let canceller = RecordingCanceller(block: 160)
        let remover = LiveEchoRemover(canceller: canceller)
        #expect(remover.addMicrophone([Float](repeating: 0.1, count: 160), start: 0) == nil)
        let wait = Int(LiveEchoRemover.maximumWaitSeconds * LiveTrackResampler.sampleRate)
        let later = remover.addMicrophone([Float](repeating: 0.1, count: wait), start: 160)
        #expect(later?.start == 0)
        #expect(canceller.references.first == [Float](repeating: 0, count: 160))
    }

    @Test("after a paused recording the microphone starts again at the new position")
    func echoRestartsAfterPause() {
        let canceller = RecordingCanceller(block: 4)
        let remover = LiveEchoRemover(canceller: canceller)
        remover.addReference([0, 0, 0, 0], start: 0)
        _ = remover.addMicrophone([1, 1, 1, 1], start: 0)
        let resumeAt = 10 * Int(LiveTrackResampler.sampleRate)
        remover.addReference([9, 9, 9, 9], start: resumeAt)
        let cleaned = remover.addMicrophone([2, 2, 2, 2], start: resumeAt)
        #expect(cleaned?.start == resumeAt)
        #expect(cleaned?.samples.count == 4)
        #expect(canceller.references.last == [9, 9, 9, 9])
    }

    @Test("the scratch file reads back everything appended before it was sealed")
    func growingWaveReadsBack() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("far-end.wav")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = try GrowingWaveFile(url: url)
        try file.append([Float](repeating: 0.25, count: 16_000))
        try file.seal()
        try file.append([Float](repeating: 0.5, count: 8_000))
        let first = try AVAudioFile(forReading: url)
        #expect(first.length == 16_000)
        try file.seal()
        let second = try AVAudioFile(forReading: url)
        #expect(second.length == 24_000)
        #expect(abs(file.seconds - 1.5) < 0.001)
    }

    @Test("buffers become 16 kHz mono placed by host time, and a gap moves the output")
    func resamplerPlacesByHostTime() throws {
        let resampler = LiveTrackResampler(origin: 10)
        let first = try #require(resampler.convert(Self.packet(seconds: 0.5, hostTime: 10)))
        #expect(first.start == 0)
        let second = try #require(resampler.convert(Self.packet(seconds: 0.5, hostTime: 10.5)))
        #expect(abs(second.start - (first.start + first.samples.count)) <= 1)
        let afterGap = try #require(resampler.convert(Self.packet(seconds: 0.5, hostTime: 13)))
        #expect(abs(afterGap.start - 48_000) < 400)
    }

    private static func packet(seconds: Double, hostTime: Double) -> AudioBufferPacket {
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(seconds * 48_000)
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                buffer.floatChannelData?[channel][frame] = sin(Float(frame) * 0.05) * 0.3
            }
        }
        return AudioBufferPacket(buffer: buffer, hostTime: hostTime)
    }
}

/// Passes the microphone through and remembers each reference block.
private final class RecordingCanceller: EchoCancelling {
    let blockFrames: Int
    var latencyFrames: Int { 0 }
    var reportedRemovalDB: Double? { nil }
    private(set) var references: [[Float]] = []

    init(block: Int) { blockFrames = block }

    func process(microphone: inout [Float], reference: [Float]) -> Bool {
        references.append(reference)
        return true
    }
}
