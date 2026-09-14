import Foundation
import PipitCore
import Testing

private func line(
    _ text: String, track: CaptureTrack, from start: Double, wordSeconds: Double = 0.4
) -> Utterance {
    let texts = text.split(separator: " ").map(String.init)
    let words = texts.enumerated().map {
        RawTranscriptWord(
            start: start + Double($0.offset) * wordSeconds,
            end: start + Double($0.offset + 1) * wordSeconds, text: " \($0.element)"
        )
    }
    let end = start + Double(texts.count) * wordSeconds
    return Utterance(
        id: "\(track.rawValue)-\(start)", start: start, end: end, track: track,
        rawSpeakerLabel: track == .mic ? nil : "A",
        speakerKey: track == .mic ? SpeakerLabel.localUser : "remote-A",
        text: text, chunkID: "\(track.rawValue)_full", model: "test", words: words
    )
}

/// The far end played out of the speakers and back into the microphone, and
/// what the canceller left of it was transcribed under the user's name. On a
/// call of 11 September 2026, 249 of 268 lines on the microphone repeated the
/// far end's words within three seconds. A line that is mostly the far end's
/// own words, said at the same moment, is the far end.
@Suite("FarEndOverlap")
struct FarEndOverlapTests {
    @Test("a microphone line that repeats the far end's words at the same moment is dropped")
    func aMicrophoneLineThatRepeatsTheFarEndIsDropped() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let echo = line("we should look at the deployment plan before friday", track: .mic, from: 10.1)
        let kept = FarEndOverlap.drop([remote, echo])
        #expect(kept.map(\.id) == [remote.id])
    }

    @Test("a garbled copy of the far end still counts as the far end")
    func aGarbledCopyStillCounts() {
        let remote = line("maybe just a quick intro of myself and then the team", track: .remote, from: 10)
        let echo = line("maybe just uh quick intro myself and then the team", track: .mic, from: 10.2)
        #expect(FarEndOverlap.drop([remote, echo]).map(\.id) == [remote.id])
    }

    @Test("the user's own sentence stays even when a few words match")
    func theUsersOwnSentenceStays() {
        let remote = line("the deployment plan needs another review", track: .remote, from: 10)
        let user = line("I think the plan is fine but the budget needs work first", track: .mic, from: 10.5)
        #expect(FarEndOverlap.drop([remote, user]).count == 2)
    }

    @Test("a short reply stays even when every word was also said by the far end")
    func aShortReplyStays() {
        let remote = line("that sounds right to me", track: .remote, from: 10)
        let reply = line("sounds right", track: .mic, from: 11)
        #expect(FarEndOverlap.drop([remote, reply]).count == 2)
    }

    @Test("the same words said ten seconds apart are two people")
    func theSameWordsTenSecondsApartStay() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let later = line("we should look at the deployment plan before friday", track: .mic, from: 22)
        #expect(FarEndOverlap.drop([remote, later]).count == 2)
    }

    @Test("with no far end on record nothing is dropped")
    func withNoFarEndNothingIsDropped() {
        let user = line("we should look at the deployment plan before friday", track: .mic, from: 10)
        #expect(FarEndOverlap.drop([user]).count == 1)
    }

    @Test("the assembler drops the echo before it interleaves turns")
    func theAssemblerDropsTheEcho() {
        let remoteSegment = RawTranscriptSegment(
            start: 10, end: 13.6, text: "we should look at the deployment plan before friday",
            speaker: "A", words: nil
        )
        let echoSegment = RawTranscriptSegment(
            start: 10.1, end: 13.7, text: "we should look at the deployment plan before friday",
            speaker: nil, words: nil
        )
        let ownSegment = RawTranscriptSegment(
            start: 20, end: 22, text: "and the budget needs work first", speaker: nil, words: nil
        )
        let raw = RawTranscript(chunks: [
            RawTranscriptChunk(
                id: "mic_full", track: .mic, timelineOffset: 0, durationSeconds: 60, model: "test",
                responseFormat: "json", segments: [echoSegment, ownSegment]
            ),
            RawTranscriptChunk(
                id: "remote_full", track: .remote, timelineOffset: 0, durationSeconds: 60,
                model: "test", responseFormat: "json", segments: [remoteSegment]
            ),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: raw, diarization: RawDiarization(runs: []), micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let mic = transcript.utterances.filter { $0.track == .mic }
        #expect(mic.map(\.text) == ["and the budget needs work first"])
    }
}
