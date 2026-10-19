import Foundation
import PipitCore
import Testing

/// The meeting player plays each recording's mixdown end to end and follows
/// the transcript with it. These pin how a position maps to a recording, to
/// the clock the transcript prints, to a speaker's lane, and to a word.
@Suite("PlaybackTimeline")
struct PlaybackTimelineTests {
    static let audioA = URL(fileURLWithPath: "/meetings/a/recording.m4a")
    static let audioB = URL(fileURLWithPath: "/meetings/b/recording.m4a")

    static func line(
        recording: String = "rec-a", speaker: String, start: Double, end: Double, text: String,
        words: [RawTranscriptWord]? = nil, timelineOffset: Double = 0
    ) -> CombinedLine {
        let utterance = Utterance(
            id: Utterance.identifier(chunkID: "c1", track: .remote, start: start, end: end),
            start: start, end: end, track: .remote,
            rawSpeakerLabel: "c1_speaker_00", speakerKey: "c1_speaker_00",
            text: text, chunkID: "c1", model: "test", words: words
        )
        return CombinedLine(
            recordingID: recording, utterance: utterance, speakerName: speaker,
            timelineStart: timelineOffset + start
        )
    }

    /// Two recordings of one call: 60 seconds, a two-minute drop, then 40.
    static let split = PlaybackTimeline([
        .init(recordingID: "rec-a", audio: audioA, duration: 60, timelineOffset: 0),
        .init(recordingID: "rec-b", audio: audioB, duration: 40, timelineOffset: 180),
    ])

    @Test("parts sit end to end without the gap between recordings")
    func partsSitEndToEnd() {
        #expect(Self.split.duration == 100, "the drop is on no recording")
        #expect(Self.split.boundaries == [60], "one mark, where the second part starts")
        #expect(Self.split.parts.map(\.start) == [0, 60])
    }

    @Test("a position resolves to a part and the seconds into its file")
    func positionResolvesToPart() {
        #expect(Self.split.locate(30)?.part == 0)
        #expect(Self.split.locate(30)?.seconds == 30)
        #expect(Self.split.locate(60)?.part == 1, "a boundary belongs to the part starting there")
        #expect(Self.split.locate(75)?.seconds == 15)
        #expect(Self.split.locate(500)?.seconds == 40, "past the end is the last moment")
        #expect(Self.split.locate(-5)?.seconds == 0)
        #expect(PlaybackTimeline().locate(10)?.part == nil, "nothing to play, nowhere to be")
    }

    @Test("the clock printed is the one the transcript headers read")
    func clockMatchesTranscript() {
        #expect(Self.split.timelineSeconds(at: 30) == 30)
        #expect(Self.split.timelineSeconds(at: 75) == 195, "15 seconds into a part that began at 3:00")
        #expect(Self.split.timelineDuration == 220)
    }

    @Test("a moment in a recording maps to a playback position")
    func momentMapsToPosition() {
        #expect(Self.split.position(recordingID: "rec-b", seconds: 10) == 70)
        #expect(Self.split.position(recordingID: "rec-a", seconds: 90) == 60, "clamped into the part")
        #expect(Self.split.position(recordingID: "rec-x", seconds: 10) == nil, "no audio, no position")
    }

    @Test("a recording with no audio takes no room")
    func emptySourceTakesNoRoom() {
        let timeline = PlaybackTimeline([
            .init(recordingID: "rec-a", audio: Self.audioA, duration: 0, timelineOffset: 0),
            .init(recordingID: "rec-b", audio: Self.audioB, duration: 40, timelineOffset: 180),
        ])
        #expect(timeline.parts.map(\.recordingID) == ["rec-b"])
        #expect(timeline.position(recordingID: "rec-b", seconds: 0) == 0)
    }

    @Test("lanes follow the order given, merge near stretches, and skip unplayable lines")
    func lanes() {
        let lines = [
            Self.line(speaker: "Speaker 2", start: 0, end: 5, text: "a"),
            Self.line(speaker: "Speaker 2", start: 5.5, end: 9, text: "b"),
            Self.line(speaker: "Speaker 1", start: 10, end: 14, text: "c"),
            Self.line(speaker: "Speaker 2", start: 20, end: 25, text: "d"),
            Self.line(recording: "rec-b", speaker: "Speaker 1", start: 2, end: 6, text: "e"),
            Self.line(recording: "rec-x", speaker: "Speaker 3", start: 0, end: 4, text: "f"),
        ]
        let lanes = Self.split.lanes(for: lines, order: ["Speaker 1"])
        #expect(lanes.map(\.name) == ["Speaker 1", "Speaker 2"], "ordered, then by first heard")
        #expect(
            lanes[1].spans == [.init(start: 0, end: 9), .init(start: 20, end: 25)],
            "half a second apart reads as one stretch"
        )
        #expect(
            lanes[0].spans == [.init(start: 10, end: 14), .init(start: 62, end: 66)],
            "the second recording lands after the first"
        )
    }

    @Test("the cursor finds the turn and the word being spoken")
    func cursorFindsWord() {
        let words = [
            RawTranscriptWord(start: 10, end: 10.5, text: "the"),
            RawTranscriptWord(start: 10.5, end: 11, text: "second"),
            RawTranscriptWord(start: 11, end: 11.8, text: "step"),
        ]
        let lines = [
            Self.line(speaker: "Speaker 1", start: 0, end: 4, text: "hello there"),
            Self.line(speaker: "Speaker 2", start: 10, end: 11.8, text: "the second step", words: words),
        ]
        let blocks = CombinedLineBlock.blocks(from: lines)
        let cursor = Self.split.cursor(at: 10.7, in: blocks)
        #expect(cursor?.blockID == blocks[1].id)
        #expect(cursor?.speakerName == "Speaker 2")
        #expect(cursor?.isSpeaking == true)
        #expect(cursor?.word?.location == 4, "\"second\" starts at character four")
        #expect(cursor?.word?.length == 6)
    }

    @Test("a line without word timings highlights the turn and no word")
    func lineWithoutWordsHasNoWord() {
        let lines = [Self.line(speaker: "Speaker 1", start: 0, end: 4, text: "hello there")]
        let cursor = Self.split.cursor(at: 2, in: CombinedLineBlock.blocks(from: lines))
        #expect(cursor?.isSpeaking == true)
        #expect(cursor?.word == nil)
    }

    @Test("in a pause the band stays on the turn just heard")
    func pauseKeepsLastTurn() {
        let lines = [
            Self.line(speaker: "Speaker 1", start: 0, end: 4, text: "a"),
            Self.line(speaker: "Speaker 2", start: 10, end: 12, text: "b"),
        ]
        let blocks = CombinedLineBlock.blocks(from: lines)
        let cursor = Self.split.cursor(at: 6, in: blocks)
        #expect(cursor?.blockID == blocks[0].id)
        #expect(cursor?.isSpeaking == false, "nobody is talking")
        #expect(cursor?.word == nil)
    }

    @Test("the cursor in the second part reads that recording's lines")
    func cursorInSecondPart() {
        let lines = [
            Self.line(speaker: "Speaker 1", start: 0, end: 50, text: "first half"),
            Self.line(
                recording: "rec-b", speaker: "Speaker 1", start: 0, end: 10, text: "second half",
                timelineOffset: 180
            ),
        ]
        let blocks = CombinedLineBlock.blocks(from: lines)
        let cursor = Self.split.cursor(at: 65, in: blocks)
        #expect(cursor?.recordingID == "rec-b")
        #expect(cursor?.blockID == blocks[1].id, "five seconds into the second recording")
    }
}
