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

/// One microphone line made of several, the way the transcript joins segments
/// that are less than a second and a quarter apart.
private func joined(_ parts: Utterance...) -> Utterance {
    var result = parts[0]
    result.words = parts.flatMap { $0.words ?? [] }
    result.text = parts.map(\.text).joined(separator: " ")
    result.end = parts[parts.count - 1].end
    return result
}

private func untimed(_ utterance: Utterance) -> Utterance {
    var result = utterance
    result.words = nil
    return result
}

private func micText(_ utterances: [Utterance]) -> [String] {
    utterances.filter { $0.track == .mic }.map(\.text)
}

/// The far end played out of the speakers and back into the microphone, and
/// what the canceller left of it was transcribed under the user's name. On a
/// call of 11 September 2026, 249 of 268 lines on the microphone repeated the
/// far end's words at the same moment. A line that is mostly the far end's
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

    @Test("a user who repeats the far end's words a few seconds later keeps the line")
    func aUserRepeatingTheFarEndAFewSecondsLaterKeepsTheLine() {
        // Two people in one conversation, one saying back what the other said.
        // The two lines overlap in time, so the lines are near each other, but
        // every shared word is spoken seconds apart. Echo is the same sound at
        // the same moment.
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let repeated = line(
            "so look at the deployment plan before friday", track: .mic, from: 12.4)
        #expect(FarEndOverlap.drop([remote, repeated]).count == 2)
    }

    @Test("a line is the far end only when its words fall at the far end's own moments")
    func aLineIsTheFarEndOnlyWhenItsWordsFallAtTheFarEndsMoments() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        // The echo is slower than the far end by a fraction of a second per word,
        // so its words drift but each stays within a second of the original.
        let drifting = line(
            "we should look at the deployment plan before friday", track: .mic, from: 10.3,
            wordSeconds: 0.45)
        #expect(FarEndOverlap.drop([remote, drifting]).map(\.id) == [remote.id])
    }

    @Test("a line that joins the user's own words to the far end's echo loses only the echo")
    func aLineJoiningTheUsersWordsToEchoLosesOnlyTheEcho() {
        // The transcript joins segments less than a second and a quarter apart,
        // so the user's sentence and the echo that follows it arrive as one line.
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 30)
        let own = line("I checked the budget numbers yesterday morning", track: .mic, from: 26)
        let echo = line("we should look at the deployment plan before friday", track: .mic, from: 30.1)
        var joined = own
        joined.words = (own.words ?? []) + (echo.words ?? [])
        joined.text = own.text + " " + echo.text
        joined.end = echo.end

        let kept = FarEndOverlap.drop([remote, joined]).filter { $0.track == .mic }
        #expect(kept.map(\.text) == ["I checked the budget numbers yesterday morning"])
        #expect(kept.first?.start == own.start)
        #expect(kept.first?.end == own.end)
    }

    @Test("echo in the middle of a line leaves the words on both sides")
    func echoInTheMiddleLeavesBothSides() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 30)
        let before = line("I checked the budget numbers yesterday", track: .mic, from: 25)
        let echo = line("we should look at the deployment plan before friday", track: .mic, from: 30.1)
        let after = line("and the hiring plan next", track: .mic, from: 33.9)
        var joined = before
        joined.words = (before.words ?? []) + (echo.words ?? []) + (after.words ?? [])
        joined.text = [before.text, echo.text, after.text].joined(separator: " ")
        joined.end = after.end

        let kept = FarEndOverlap.drop([remote, joined]).filter { $0.track == .mic }
        #expect(
            kept.map(\.text) == [
                "I checked the budget numbers yesterday", "and the hiring plan next",
            ])
        #expect(Set(kept.map(\.id)).count == 2)
    }

    @Test("with no far end on record nothing is dropped")
    func withNoFarEndNothingIsDropped() {
        let user = line("we should look at the deployment plan before friday", track: .mic, from: 10)
        #expect(FarEndOverlap.drop([user]).count == 1)
    }

    @Test("echo, then the user's own sentence, then more echo keeps the sentence")
    func echoAroundTheUsersSentenceKeepsTheSentence() {
        let first = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let second = line(
            "please send the updated budget numbers after lunch today", track: .remote, from: 18)
        let echo1 = line("we should look at the deployment plan before friday", track: .mic, from: 10.1)
        let own = line("I checked the budget numbers yesterday morning", track: .mic, from: 14)
        let echo2 = line(
            "please send the updated budget numbers after lunch today", track: .mic, from: 18.1)
        let kept = FarEndOverlap.drop([first, second, joined(echo1, own, echo2)])
        #expect(micText(kept) == ["I checked the budget numbers yesterday morning"])
    }

    @Test("echo the microphone mis-hears at the end of a run goes with the run")
    func misheardEchoAtTheEndGoesWithTheRun() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let echo = line("we should look at the deployment plan before fry day", track: .mic, from: 10.2)
        #expect(micText(FarEndOverlap.drop([remote, echo])).isEmpty)
    }

    @Test("echo the microphone mis-hears at the start of a run goes with the run")
    func misheardEchoAtTheStartGoesWithTheRun() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let echo = line(
            "wee shoulder look at the deployment plan before friday", track: .mic, from: 10.2)
        #expect(micText(FarEndOverlap.drop([remote, echo])).isEmpty)
    }

    @Test("the user's words after an echo stay, even where the far end goes on talking")
    func theUsersWordsAfterEchoStay() {
        let remote = line(
            "we should look at the deployment plan before friday and then check the budget",
            track: .remote, from: 10)
        let echo = line("we should look at the deployment plan before friday", track: .mic, from: 10.1)
        let own = line("lunch tomorrow", track: .mic, from: 10.1 + 9 * 0.4)
        let kept = FarEndOverlap.drop([remote, joined(echo, own)])
        #expect(micText(kept) == ["lunch tomorrow"])
    }

    @Test("a short word the far end repeats once counts once")
    func aRepeatedWordPairsWithOneFarEndWord() {
        let remote = line("the budget is fine", track: .remote, from: 10)
        let user = line("budget budget budget budget", track: .mic, from: 10.2)
        #expect(micText(FarEndOverlap.drop([remote, user])) == ["budget budget budget budget"])
    }

    @Test("backchannels the far end also said never make a line the far end's")
    func backchannelsStay() {
        let remote = line("yes okay yes okay right", track: .remote, from: 20)
        let user = line("yeah okay yes okay right", track: .mic, from: 20.3)
        #expect(micText(FarEndOverlap.drop([remote, user])) == ["yeah okay yes okay right"])
    }

    @Test("echo split across two microphone lines goes")
    func echoSplitAcrossTwoLinesGoes() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let first = line("we should look at the", track: .mic, from: 10.1)
        let second = line("deployment plan before friday", track: .mic, from: 12.1)
        #expect(micText(FarEndOverlap.drop([remote, first, second])).isEmpty)
    }

    @Test("a line after a short echo line stays")
    func aLineAfterAShortEchoLineStays() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let first = line("we should look at the", track: .mic, from: 10.1)
        let own = line("I will send the budget numbers", track: .mic, from: 12.1)
        #expect(micText(FarEndOverlap.drop([remote, first, own])).contains(own.text))
    }

    @Test("a microphone line without word timings is judged whole by its span")
    func aLineWithoutTimingsIsJudgedWhole() {
        let remote = line("we should look at the deployment plan before friday", track: .remote, from: 10)
        let echo = untimed(line("we should look at the deployment plan before friday", track: .mic, from: 10.1))
        let later = untimed(line("we should look at the deployment plan before friday", track: .mic, from: 22))
        #expect(FarEndOverlap.drop([remote, echo]).map(\.id) == [remote.id])
        #expect(FarEndOverlap.drop([remote, later]).count == 2)
    }

    @Test("a far-end line without word timings gives its span to every word")
    func aFarEndLineWithoutTimingsGivesItsSpan() {
        let remote = untimed(
            line(
                "we should look at the deployment plan before friday and then check the budget",
                track: .remote, from: 10))
        let echo = line("we should look at the deployment plan before friday", track: .mic, from: 10.1)
        let late = line("so look at the deployment plan before friday then", track: .mic, from: 18)
        #expect(micText(FarEndOverlap.drop([remote, echo])).isEmpty)
        #expect(micText(FarEndOverlap.drop([remote, late])) == [late.text])
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
