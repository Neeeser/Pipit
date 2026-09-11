import Foundation
import PipitCore
import Testing

/// Words one per second from `start`, each 0.8 s long, chunk-relative.
private func words(
    _ texts: [String], from start: Double, wordSeconds: Double = 0.8
) -> [RawTranscriptWord] {
    texts.enumerated().map {
        RawTranscriptWord(
            start: start + Double($0.offset), end: start + Double($0.offset) + wordSeconds,
            text: " \($0.element)"
        )
    }
}

private func segment(
    _ texts: [String], from start: Double, timed: Bool = true, wordSeconds: Double = 0.8
) -> RawTranscriptSegment {
    let timedWords = words(texts, from: start, wordSeconds: wordSeconds)
    return RawTranscriptSegment(
        start: start, end: start + Double(texts.count - 1) + wordSeconds,
        text: texts.joined(separator: " "),
        speaker: nil, words: timed ? timedWords : nil
    )
}

private func chunk(track: CaptureTrack, segments: [RawTranscriptSegment]) -> RawTranscriptChunk {
    RawTranscriptChunk(
        id: "\(track.rawValue)_full", track: track, timelineOffset: 0, durationSeconds: 600,
        model: "test", responseFormat: "json", segments: segments
    )
}

/// The far end's lines carry a diarizer label so they render as a speaker.
private func remoteChunk(_ segments: [RawTranscriptSegment]) -> RawTranscriptChunk {
    var labelled = chunk(track: .remote, segments: segments)
    labelled.segments = segments.map {
        var copy = $0
        copy.speaker = "A"
        return copy
    }
    return labelled
}

private func assemble(mic: [RawTranscriptSegment], remote: [RawTranscriptSegment]) -> [Utterance] {
    TranscriptAssembler().assemble(
        raw: RawTranscript(chunks: [chunk(track: .mic, segments: mic), remoteChunk(remote)]),
        micTrackIsLocalUser: true,
        generatedAt: Date(timeIntervalSince1970: 0)
    ).utterances
}

/// A decoder cuts a line at its own speaker's pauses and never at the other
/// track's, so one long stretch of talk swallowed every reply spoken inside
/// it. The transcript is read in the order people spoke, which means a line
/// divides where the other track starts.
@Suite("TurnInterleaving")
struct TurnInterleavingTests {
    @Test("a reply spoken inside a long line divides it so the transcript reads in order")
    func aReplySpokenInsideALongLineDividesIt() async throws {
        // Twelve seconds of the local user; the far end answers at 4 s.
        let mic = segment(
            ["shall", "we", "wait", "for", "them", "okay", "then", "let", "me", "start", "with", "context"],
            from: 0)
        let remote = segment(["no", "go", "ahead"], from: 4)
        let lines = assemble(mic: [mic], remote: [remote])
        let order = lines.map { "\($0.track.rawValue): \($0.text)" }
        #expect(
            order == [
                "mic: shall we wait for them",
                "remote: no go ahead",
                "mic: okay then let me start with context",
            ], "got \(order)")
    }

    @Test("the division moves forward to a sentence end within two seconds of the reply")
    func theDivisionMovesForwardToASentenceEnd() async throws {
        // The sentence ends at 4.8 s and the reply starts at 3.5 s, during
        // its last words. The sentence stays whole and the reply follows it.
        let mic = segment(
            ["shall", "we", "wait", "for", "them?", "okay", "then", "let", "me", "start"], from: 0)
        let remote = segment(["no", "go", "ahead"], from: 3.5)
        let lines = assemble(mic: [mic], remote: [remote])
        let order = lines.map { "\($0.track.rawValue): \($0.text)" }
        #expect(
            order == [
                "mic: shall we wait for them?",
                "remote: no go ahead",
                "mic: okay then let me start",
            ], "got \(order)")
    }

    @Test("a sentence end further than two seconds ahead does not pull the division")
    func aDistantSentenceEndDoesNotPullTheDivision() async throws {
        let mic = segment(
            ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine.", "ten"], from: 0)
        let remote = segment(["yes"], from: 6.1)
        let lines = assemble(mic: [mic], remote: [remote])
        let texts = lines.map(\.text)
        #expect(texts == ["one two three four five six seven", "yes", "eight nine. ten"], "got \(texts)")
    }

    @Test("a sentence end behind the reply never pulls the division back")
    func aSentenceEndBehindTheReplyNeverPullsTheDivisionBack() async throws {
        // Dividing at 3 s would open a piece that starts before the reply and
        // so prints before it, which is the fault this pass exists to remove.
        let mic = segment(["one", "two", "three.", "four", "five", "six", "seven", "eight"], from: 0)
        let remote = segment(["yes"], from: 3.5)
        let lines = assemble(mic: [mic], remote: [remote])
        let order = lines.map { "\($0.track.rawValue): \($0.text)" }
        #expect(
            order == ["mic: one two three. four", "remote: yes", "mic: five six seven eight"],
            "got \(order)")
    }

    @Test("a sentence end never pulls the division onto the next reply's start")
    func aSentenceEndNeverPullsTheDivisionOntoTheNextReply() async throws {
        // The first reply at 2 s would snap to "e" at 4 s, where the second
        // reply starts. A piece starting there ties with that reply and the
        // tie goes to the microphone, which hides the reply. The division for
        // the first reply stops short instead, and the second gets its own.
        // The first reply is short so the two stay separate lines.
        let mic = segment(["a", "b", "c", "d?", "e", "f", "g", "h"], from: 0)
        let lines = assemble(
            mic: [mic],
            remote: [segment(["yes"], from: 2, wordSeconds: 0.5), segment(["right"], from: 4)])
        let order = lines.map { "\($0.track.rawValue): \($0.text)" }
        #expect(
            order == ["mic: a b c", "remote: yes", "mic: d? e", "remote: right", "mic: f g h"],
            "got \(order)")
    }

    @Test("the local user's reply divides a long far-end line the same way")
    func theLocalUsersReplyDividesALongFarEndLine() async throws {
        let remote = segment(["one", "two", "three", "four", "five", "six", "seven", "eight"], from: 0)
        let mic = segment(["sure"], from: 3.5)
        let lines = assemble(mic: [mic], remote: [remote])
        let order = lines.map { "\($0.track.rawValue): \($0.text)" }
        #expect(
            order == ["remote: one two three four", "mic: sure", "remote: five six seven eight"],
            "got \(order)")
    }

    @Test("two replies inside one line make three pieces in the order spoken")
    func twoRepliesInsideOneLineMakeThreePieces() async throws {
        let mic = segment(
            ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l"], from: 0)
        let lines = assemble(
            mic: [mic],
            remote: [segment(["yes"], from: 2.5), segment(["right"], from: 7.5)]
        )
        let order = lines.map { "\($0.track.rawValue): \($0.text)" }
        #expect(
            order == [
                "mic: a b c", "remote: yes", "mic: d e f g h", "remote: right", "mic: i j k l",
            ], "got \(order)")
    }

    @Test("the pieces keep the speaker, the words and distinct identifiers")
    func thePiecesKeepTheSpeakerTheWordsAndDistinctIdentifiers() async throws {
        let mic = segment(["a", "b", "c", "d", "e", "f"], from: 0)
        let lines = assemble(mic: [mic], remote: [segment(["yes"], from: 2.5)])
        let pieces = lines.filter { $0.track == .mic }
        try #require(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.speakerKey == SpeakerLabel.localUser })
        #expect(pieces.map { $0.words?.count } == [3, 3])
        #expect(Set(lines.map(\.id)).count == lines.count)
        // The first piece keeps the line's start and the last its end, so no
        // audio belongs to nobody.
        #expect(pieces[0].start == 0)
        #expect(pieces[1].end == mic.end)
        #expect(pieces[1].start == 3)
    }

    @Test("a reply that starts with the line or after its last word leaves it whole")
    func aReplyOnTheEdgesLeavesTheLineWhole() async throws {
        let mic = segment(["a", "b", "c", "d"], from: 0)
        let lines = assemble(
            mic: [mic], remote: [segment(["yes"], from: 0), segment(["right"], from: 3.5)])
        #expect(lines.filter { $0.track == .mic }.map(\.text) == ["a b c d"])
    }

    @Test("a line whose words were never timed is left whole")
    func aLineWhoseWordsWereNeverTimedIsLeftWhole() async throws {
        let mic = segment(["a", "b", "c", "d", "e", "f"], from: 0, timed: false)
        let lines = assemble(mic: [mic], remote: [segment(["yes"], from: 3)])
        #expect(lines.filter { $0.track == .mic }.map(\.text) == ["a b c d e f"])
    }
}
