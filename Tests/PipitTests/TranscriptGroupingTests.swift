import Foundation
import PipitCore
import Testing

/// The transcript pane groups consecutive lines by who spoke them, so one person
/// talking through five assembler splits reads as one block. Grouping is
/// display-only: every line keeps its identity and stays individually
/// correctable.
@Suite("TranscriptGrouping")
struct TranscriptGroupingTests {
    static func line(
        recording: String = "rec-a", speaker: String, start: Double, text: String
    ) -> CombinedLine {
        let utterance = Utterance(
            id: Utterance.identifier(chunkID: "c1", track: .remote, start: start, end: start + 2),
            start: start, end: start + 2, track: .remote,
            rawSpeakerLabel: "c1_speaker_00", speakerKey: "c1_speaker_00",
            text: text, chunkID: "c1", model: "test"
        )
        return CombinedLine(
            recordingID: recording, utterance: utterance, speakerName: speaker,
            timelineStart: start
        )
    }

    @Test("consecutive lines from one speaker form one block")
    func consecutiveLinesFromOneSpeakerFormOneBlock() async throws {
        let blocks = CombinedLineBlock.blocks(from: [
            Self.line(speaker: "Marlow", start: 0, text: "first"),
            Self.line(speaker: "Marlow", start: 3, text: "second"),
            Self.line(speaker: "Marlow", start: 7, text: "third"),
        ])
        #expect(blocks.count == 1, "one speaker, one block")
        #expect(blocks.first?.lines.count == 3, "all three lines kept")
        #expect(blocks.first?.speakerName == "Marlow", "block carries the name")
        #expect(
            blocks.first?.lines.map(\.utterance.text) == ["first", "second", "third"],
            "order preserved"
        )
    }

    @Test("a change of speaker starts a new block")
    func aChangeOfSpeakerStartsANewBlock() async throws {
        let blocks = CombinedLineBlock.blocks(from: [
            Self.line(speaker: "Marlow", start: 0, text: "a"),
            Self.line(speaker: "Dara", start: 3, text: "b"),
            Self.line(speaker: "Marlow", start: 6, text: "c"),
        ])
        #expect(blocks.count == 3, "interleaved speakers never merge")
        #expect(blocks.map(\.speakerName) == ["Marlow", "Dara", "Marlow"], "one block each")
    }

    @Test("the same display name in two recordings stays two blocks")
    func theSameDisplayNameInTwoRecordingsStaysTwoBlocks() async throws {
        // Two halves of a dropped call each have their own diarization,
        // so "Speaker 1" on either side can be different people.
        let blocks = CombinedLineBlock.blocks(from: [
            Self.line(recording: "rec-a", speaker: "Speaker 1", start: 0, text: "before the drop"),
            Self.line(recording: "rec-b", speaker: "Speaker 1", start: 3, text: "after the rejoin"),
        ])
        #expect(blocks.count == 2, "names are only comparable within one recording")
    }

    @Test("an empty transcript groups to nothing")
    func anEmptyTranscriptGroupsToNothing() async throws {
        #expect(CombinedLineBlock.blocks(from: []).count == 0, "no lines, no blocks")
    }

    @Test("a block is identified by its first line")
    func aBlockIsIdentifiedByItsFirstLine() async throws {
        let first = Self.line(speaker: "Marlow", start: 0, text: "a")
        let blocks = CombinedLineBlock.blocks(from: [
            first, Self.line(speaker: "Marlow", start: 3, text: "b"),
        ])
        #expect(blocks.first?.id == first.id, "stable identity for lazy rendering")
    }

}
