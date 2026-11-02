import Foundation
import PipitCore
import Testing

/// The live transcript cuts each track into phrases at pauses as it records.
@Suite("LiveSpeechSegmenter")
struct LiveSpeechSegmenterTests {
    private static let tuning = LiveSpeechSegmenter.Tuning(
        speechThreshold: 0.5, pauseWindows: 2, maximumWindows: 6,
        paddingWindows: 1, minimumSpeechWindows: 2
    )

    /// Feeds probabilities and collects every phrase, the closing one too.
    private static func phrases(_ probabilities: [Float]) -> [LiveSpeechSegmenter.Phrase] {
        var segmenter = LiveSpeechSegmenter(tuning: tuning)
        var out = probabilities.compactMap { segmenter.push($0) }
        if let last = segmenter.finish() { out.append(last) }
        return out
    }

    @Test("a pause closes the phrase with one window of padding each side")
    func pauseClosesPhrase() {
        let found = Self.phrases([0, 0, 0.9, 0.9, 0.9, 0, 0, 0, 0])
        #expect(found == [.init(start: 1, end: 6, lastSpeechEnd: 5)])
    }

    @Test("a phrase that reaches the maximum is cut and the next does not overlap it")
    func longSpeechIsCutWithoutOverlap() {
        let found = Self.phrases(Array(repeating: 0.9, count: 10))
        #expect(found.count == 2)
        #expect(found[0] == .init(start: 0, end: 6, lastSpeechEnd: 6))
        #expect(found[1].start == 6)
        #expect(found[1].end == 10)
    }

    @Test("a single loud window is dropped")
    func clickIsDropped() {
        #expect(Self.phrases([0, 0.9, 0, 0, 0, 0]).isEmpty)
    }

    @Test("speech still open when the track ends is returned")
    func finishReturnsOpenPhrase() {
        let found = Self.phrases([0, 0.9, 0.9, 0.9])
        #expect(found == [.init(start: 0, end: 4, lastSpeechEnd: 4)])
    }
}

@Suite("LiveTranscriptionSupport")
struct LiveTranscriptionSupportTests {
    @Test("only the engines with a measured live path offer live text")
    func engineCapabilities() {
        #expect(LocalTranscriptionModel.apple.liveTranscription == .streaming)
        #expect(LocalTranscriptionModel.parakeet.liveTranscription == .phrases)
        for model in [LocalTranscriptionModel.cohere, .whisper, .canary] {
            #expect(model.liveTranscription == LiveTranscriptionSupport.none)
        }
    }
}
