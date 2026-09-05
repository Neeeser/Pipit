import Foundation
import PipitCore
import Testing

private func word(_ text: String, _ start: Double, _ end: Double) -> RawTranscriptWord {
    RawTranscriptWord(start: start, end: end, text: text)
}

/// "we ship on friday" as four timed words, one per second from `start`.
private func line(
    id: String = "c1", start: Double = 0, track: CaptureTrack = .remote,
    speaker: String = "c1_speaker_00", texts: [String] = ["we", "ship", "on", "friday"],
    timed: Bool = true
) -> Utterance {
    let words = texts.enumerated().map {
        word(" \($0.element)", start + Double($0.offset), start + Double($0.offset) + 0.8)
    }
    return Utterance(
        id: Utterance.identifier(
            chunkID: id, track: track, start: start, end: start + Double(texts.count)
        ),
        start: start, end: start + Double(texts.count), track: track,
        rawSpeakerLabel: speaker, speakerKey: speaker,
        text: texts.joined(separator: " "), chunkID: id, model: "test",
        words: timed ? words : nil
    )
}

private func cut(at seconds: Double, track: CaptureTrack = .remote, chunk: String? = "c1")
    -> LineCut {
    LineCut(track: track, atSeconds: seconds, chunkID: chunk, createdAt: Date())
}

/// Boundaries a person put in the transcript, and the seam repeats the reader
/// would otherwise see once the lines are joined into a paragraph.
@Suite("TranscriptDivision")
struct TranscriptDivisionTests {
    @Test("a cut divides one line at the word it falls on")
    func aCutDividesOneLineAtTheWordItFallsOn() async throws {
        let pieces = LineDivision.divide(line(), at: [cut(at: 2)])
        #expect(pieces.count == 2, "one boundary, two pieces")
        #expect(pieces[0].text == "we ship")
        #expect(pieces[1].text == "on friday")
        #expect(
            abs(pieces[1].start - 2) <= 0.001,
            "expected \(2) ± \(0.001), got \(pieces[1].start) — the third word's own start"
        )
        #expect(
            abs(pieces[0].start - 0) <= 0.001,
            "expected \(0) ± \(0.001), got \(pieces[0].start) — the line keeps its outer edges"
        )
        #expect(abs(pieces[1].end - 4) <= 0.001, "expected \(4) ± \(0.001), got \(pieces[1].end)")
    }

    @Test("the pieces stay addressable and keep what the line was")
    func thePiecesStayAddressableAndKeepWhatTheLineWas() async throws {
        let original = line()
        let pieces = LineDivision.divide(original, at: [cut(at: 2)])
        #expect(pieces[0].id != pieces[1].id, "two lines, two identities")
        #expect(pieces[1].id == Utterance.identifier(
                chunkID: "c1", track: .remote, start: pieces[1].start, end: pieces[1].end
            ), "derived from where the piece sits, like any other line")
        #expect(pieces.map(\.speakerKey) == [original.speakerKey, original.speakerKey])
        #expect(pieces.map(\.chunkID) == ["c1", "c1"])
        #expect(pieces[1].words?.count == 2, "each piece keeps its own words")
    }

    @Test("two cuts pull a phrase out and leave the words either side")
    func twoCutsPullAPhraseOutAndLeaveTheWordsEitherSide() async throws {
        let pieces = LineDivision.divide(
            line(texts: ["so", "yes", "exactly", "anyway", "moving", "on"]),
            at: [cut(at: 1), cut(at: 3)]
        )
        #expect(pieces.count == 3)
        #expect(pieces.map(\.text) == ["so", "yes exactly", "anyway moving on"])
    }

    @Test("a line whose words were never timed is left whole")
    func aLineWhoseWordsWereNeverTimedIsLeftWhole() async throws {
        // A text-only backend whose aligner refused. Dividing it would
        // mean guessing where the boundary is, and a guessed span
        // decides which seconds of audio reach a voice profile.
        let pieces = LineDivision.divide(line(timed: false), at: [cut(at: 2)])
        #expect(pieces.count == 1)
        #expect(LineDivision.boundary(in: line(timed: false), near: 2) == nil)
    }

    @Test("a cut on another track or another chunk divides nothing")
    func aCutOnAnotherTrackOrAnotherChunkDividesNothing() async throws {
        #expect(LineDivision.divide(line(), at: [cut(at: 2, track: .mic)]).count == 1)
        #expect(LineDivision.divide(line(), at: [cut(at: 2, chunk: "c2")]).count == 1)
        #expect(LineDivision.divide(line(), at: [cut(at: 9)]).count == 1, "past the end")
    }

    @Test("a cut before the first word leaves the line whole")
    func aCutBeforeTheFirstWordLeavesTheLineWhole() async throws {
        // The boundary is already there. Dividing would make a piece
        // with nothing in it.
        #expect(LineDivision.divide(line(), at: [cut(at: 0)]).count == 1)
        #expect(LineDivision.boundary(in: line(), near: 0) == nil)
    }

    @Test("division applies across a transcript and keeps the order")
    func divisionAppliesAcrossATranscriptAndKeepsTheOrder() async throws {
        let lines = [line(start: 0), line(id: "c2", start: 10)]
        let divided = LineDivision.apply([cut(at: 2)], to: lines)
        #expect(divided.count == 3)
        #expect(divided.map(\.text) == ["we ship", "on friday", "we ship on friday"])
    }

    @Test("a correction made before the cut covers both pieces")
    func aCorrectionMadeBeforeTheCutCoversBothPieces() async throws {
        // Re-assembly and re-analysis split and merge lines all the
        // time, so a correction is anchored to a span. A piece of a
        // corrected line is inside that span and keeps the name.
        var speakers = SpeakerMap()
        let original = line()
        speakers.overrideUtterance(
            original,
            with: SpeakerAssignment(displayName: "Dana", origin: .human),
            at: Date()
        )
        let pieces = LineDivision.divide(original, at: [cut(at: 2)])
        #expect(speakers.resolvedName(for: pieces[0]) == "Dana")
        #expect(speakers.resolvedName(for: pieces[1]) == "Dana")
    }

    @Test("naming one piece does not confirm the other's audio")
    func namingOnePieceDoesNotConfirmTheOtherSAudio() async throws {
        // What separates display from enrolment. The name is right on
        // the piece it was set on; the seconds either side belong to
        // whoever was speaking there, and must not reach a profile.
        var speakers = SpeakerMap()
        let pieces = LineDivision.divide(line(), at: [cut(at: 2)])
        speakers.overrideUtterance(
            pieces[1],
            with: SpeakerAssignment(displayName: "Dana", origin: .human),
            at: Date()
        )
        #expect(speakers.confirms(pieces[1]), "the piece that was named")
        #expect(!speakers.confirms(pieces[0]), "the words before the boundary")
    }

    @Test("the same boundary is only recorded once")
    func theSameBoundaryIsOnlyRecordedOnce() async throws {
        var speakers = SpeakerMap()
        speakers.cut(cut(at: 2))
        speakers.cut(cut(at: 2))
        speakers.cut(cut(at: 2.0004))
        #expect(speakers.lineCuts.count == 1)
        speakers.cut(cut(at: 3))
        #expect(speakers.lineCuts.count == 2)
    }

    @Test("cuts decode as none in a map written before they existed")
    func cutsDecodeAsNoneInAMapWrittenBeforeTheyExisted() async throws {
        let json = Data(#"{"version":2,"entries":{},"utteranceOverrides":[]}"#.utf8)
        let map = try JSONDecoder().decode(SpeakerMap.self, from: json)
        #expect(map.lineCuts.isEmpty)
    }

}

/// The paragraph a block renders as, and where each word sits in it.
@Suite("TranscriptParagraph")
struct TranscriptParagraphTests {
    @Test("a block's words are located in the text the reader sees")
    func aBlockSWordsAreLocatedInTheTextTheReaderSees() async throws {
        let block = CombinedLineBlock(lines: [
            CombinedLine(
                recordingID: "rec", utterance: line(), speakerName: "Dana",
                timelineStart: 0
            ),
            CombinedLine(
                recordingID: "rec", utterance: line(id: "c1", start: 4),
                speakerName: "Dana", timelineStart: 4
            ),
        ])
        let (text, spans) = block.paragraph()
        #expect(text == "we ship on friday we ship on friday", "the lines joined")
        #expect(spans.count == 8, "one span per word")
        let nsText = text as NSString
        for span in spans {
            #expect(span.location + span.length <= nsText.length, "inside the paragraph")
        }
        #expect(nsText.substring(with: NSRange(
            location: spans[5].location, length: spans[5].length
        )) == "ship")
        #expect(
            abs(spans[5].startSeconds - 5) <= 0.001,
            "expected \(5) ± \(0.001), got \(spans[5].startSeconds) — the second line's own time"
        )
    }

    @Test("a line without timings contributes one span covering it")
    func aLineWithoutTimingsContributesOneSpanCoveringIt() async throws {
        let block = CombinedLineBlock(lines: [CombinedLine(
            recordingID: "rec", utterance: line(timed: false), speakerName: "Dana",
            timelineStart: 0
        )])
        let (text, spans) = block.paragraph()
        #expect(spans.count == 1)
        #expect(spans[0].length == (text as NSString).length)
        #expect(
            abs(spans[0].endSeconds - 4) <= 0.001,
            "expected \(4) ± \(0.001), got \(spans[0].endSeconds)"
        )
    }

    @Test("a block reports the range it covers")
    func aBlockReportsTheRangeItCovers() async throws {
        let block = CombinedLineBlock(lines: [
            CombinedLine(
                recordingID: "rec", utterance: line(), speakerName: "Dana",
                timelineStart: 60
            ),
            CombinedLine(
                recordingID: "rec", utterance: line(start: 4), speakerName: "Dana",
                timelineStart: 64
            ),
        ])
        #expect(
            abs(block.timelineStart - 60) <= 0.001,
            "expected \(60) ± \(0.001), got \(block.timelineStart)"
        )
        #expect(abs(block.timelineEnd - 68) <= 0.001, "expected \(68) ± \(0.001), got \(block.timelineEnd)")
    }

}

/// A chunk carries eight seconds of the one before it so a sentence on the
/// boundary lands whole somewhere, and the model transcribes that overlap
/// twice.
@Suite("TranscriptSeam")
struct TranscriptSeamTests {
    @Test("a line that opens by repeating the one before it is trimmed")
    func aLineThatOpensByRepeatingTheOneBeforeItIsTrimmed() async throws {
        // Measured on a 25-minute meeting: 21 of 148 consecutive pairs
        // repeated between 3 and 17 words at a chunk boundary.
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [RawTranscriptSegment(
                start: 0, end: 6, text: "so the plan is we ship on friday", speaker: "A",
                words: [
                    word(" so", 0, 0.4), word(" the", 0.5, 0.8), word(" plan", 0.9, 1.3),
                    word(" is", 1.4, 1.7), word(" we", 3.0, 3.3),
                    word(" ship", 3.4, 3.8), word(" on", 3.9, 4.1),
                    word(" friday", 4.2, 4.8),
                ]
            )]
        )
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 3, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [RawTranscriptSegment(
                start: 0, end: 5, text: "we ship on friday unless qa says otherwise",
                speaker: "A",
                words: [
                    word(" we", 0, 0.3), word(" ship", 0.4, 0.8), word(" on", 0.9, 1.1),
                    word(" friday", 1.2, 1.8), word(" unless", 2.0, 2.4),
                    word(" qa", 2.5, 2.8), word(" says", 2.9, 3.2),
                    word(" otherwise", 3.3, 3.9),
                ]
            )]
        )
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: false, generatedAt: Date()
        )
        #expect(transcript.utterances.count == 2)
        #expect(transcript.utterances[0].text == "so the plan is we ship on friday")
        #expect(
            transcript.utterances[1].text == "unless qa says otherwise",
            "the four repeated words are gone and the rest of the sentence is not"
        )
        #expect(
            abs(transcript.utterances[1].start - 5.0) <= 0.001,
            "expected \(5.0) ± \(0.001), got \(transcript.utterances[1].start) — the line starts where its first surviving word does"
        )
    }

    @Test("a phrase said twice in a row inside one chunk is kept")
    func aPhraseSaidTwiceInARowInsideOneChunkIsKept() async throws {
        let chunk = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [
                RawTranscriptSegment(
                    start: 0, end: 2, text: "that is fine", speaker: "A",
                    words: [word(" that", 0, 0.4), word(" is", 0.5, 0.8), word(" fine", 0.9, 1.4)]
                ),
                RawTranscriptSegment(
                    start: 8, end: 10, text: "that is fine", speaker: "B",
                    words: [word(" that", 8, 8.4), word(" is", 8.5, 8.8), word(" fine", 8.9, 9.4)]
                ),
            ]
        )
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [chunk]),
            micTrackIsLocalUser: false, generatedAt: Date()
        )
        #expect(transcript.utterances.count == 2, "one chunk repeating itself is speech")
        #expect(transcript.utterances.map(\.text) == ["that is fine", "that is fine"])
    }

    @Test("two words in common are not a seam")
    func twoWordsInCommonAreNotASeam() async throws {
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [RawTranscriptSegment(
                start: 0, end: 3, text: "well that is fine", speaker: "A",
                words: [
                    word(" well", 0, 0.4), word(" that", 0.5, 0.9),
                    word(" is", 1.0, 1.2), word(" fine", 1.3, 1.8),
                ]
            )]
        )
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 4, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [RawTranscriptSegment(
                start: 0, end: 3, text: "is fine by me honestly", speaker: "A",
                words: [
                    word(" is", 0, 0.3), word(" fine", 0.4, 0.9), word(" by", 1.0, 1.2),
                    word(" me", 1.3, 1.5), word(" honestly", 1.6, 2.2),
                ]
            )]
        )
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: false, generatedAt: Date()
        )
        #expect(transcript.utterances[1].text == "is fine by me honestly")
    }

    @Test("a turn where one segment was not timed carries no words at all")
    func aTurnWhereOneSegmentWasNotTimedCarriesNoWordsAtAll() async throws {
        // A dividing line rebuilds its text from its words, so a list
        // covering half the turn would delete the other half from the
        // panel and everything derived from it. A decoder does return
        // a segment whose word alignment produced nothing.
        let chunk = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [
                RawTranscriptSegment(
                    start: 0, end: 1.5, text: "hello there", speaker: "A",
                    words: [word(" hello", 0, 0.6), word(" there", 0.7, 1.4)]
                ),
                RawTranscriptSegment(
                    start: 1.6, end: 3, text: "and then we shipped", speaker: "A",
                    words: []
                ),
            ]
        )
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [chunk]),
            micTrackIsLocalUser: false, generatedAt: Date()
        )
        let line = try #require(transcript.utterances.first)
        #expect(line.text == "hello there and then we shipped", "all of it is there")
        #expect(line.words == nil, "and none of it can be divided away")
    }

    @Test("the words behind a line reach the transcript on the meeting clock")
    func theWordsBehindALineReachTheTranscriptOnTheMeetingClock() async throws {
        // What a division is measured against. Chunk-relative timings
        // would put a boundary somewhere else entirely on any chunk
        // after the first.
        let chunk = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 60, durationSeconds: 20,
            model: "test", responseFormat: "json",
            segments: [RawTranscriptSegment(
                start: 1, end: 3, text: "we ship friday", speaker: "A",
                words: [word(" we", 1, 1.4), word(" ship", 1.5, 1.9), word(" friday", 2.0, 2.6)]
            )]
        )
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [chunk]),
            micTrackIsLocalUser: false, generatedAt: Date()
        )
        let words = try #require(transcript.utterances.first?.words)
        #expect(words.count == 3)
        #expect(abs(words[0].start - 61) <= 0.001, "expected \(61) ± \(0.001), got \(words[0].start)")
        #expect(abs(words[2].end - 62.6) <= 0.001, "expected \(62.6) ± \(0.001), got \(words[2].end)")
    }

}
