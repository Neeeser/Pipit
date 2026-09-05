import Foundation
import PipitCore
import Testing

/// Walking a transcript: to one speaker's turns from their chip, and through
/// the places a word appears from Command-F.
@Suite("TranscriptNavigation")
struct TranscriptNavigationTests {
    private static func line(speaker: String, start: Double, text: String) -> CombinedLine {
        TranscriptGroupingTests.line(speaker: speaker, start: start, text: text)
    }

    private static func blocks() -> [CombinedLineBlock] {
        CombinedLineBlock.blocks(from: [
            line(speaker: "Marlow", start: 0, text: "You talking about the demo tomorrow?"),
            line(speaker: "Bryn Callister", start: 3, text: "Yeah, the one you said you wanted."),
            line(speaker: "Speaker 3", start: 6, text: "Sorry, can everyone hear me?"),
            line(speaker: "Marlow", start: 9, text: "Did you see the email from Ashcombe?"),
            line(speaker: "Marlow", start: 12, text: "He is a product manager at Ashcombe. Ashcombe runs Tessera."),
            line(speaker: "Speaker 3", start: 15, text: "Yes, loud and clear."),
        ])
    }

    @Test("a speaker walk lands on their first turn and steps through the rest, wrapping")
    func aSpeakerWalkLandsOnTheirFirstTurnAndStepsThroughTheRestWrapp() async throws {
        let all = Self.blocks()
        var walk = TranscriptNavigation.speaker("Speaker 3", recordingID: "rec-a", in: all)
        #expect(walk.targets.count == 2, "two turns, six seconds between them")
        #expect(walk.current?.blockID == all[2].id, "the first turn, not the chip's order")
        #expect(walk.counter == "1 of 2")
        #expect(walk.label == "Speaker 3")
        walk.next()
        #expect(walk.current?.blockID == all[4].id, "the last block, after Marlow's merged turn")
        walk.next()
        #expect(walk.current?.blockID == all[2].id, "the last turn is followed by the first")
        walk.previous()
        #expect(walk.counter == "2 of 2")
    }

    @Test("a name from another recording is not this recording's speaker")
    func aNameFromAnotherRecordingIsNotThisRecordingSSpeaker() async throws {
        let walk = TranscriptNavigation.speaker("Speaker 3", recordingID: "rec-b", in: Self.blocks())
        #expect(walk.targets == [], "Speaker 3 in the other half is somebody else")
        #expect(walk.counter == "0 of 0")
        #expect(walk.current == nil)
    }

    @Test("a search counts every occurrence, case-insensitively, in reading order")
    func aSearchCountsEveryOccurrenceCaseInsensitivelyInReadingOrder() async throws {
        let all = Self.blocks()
        // The question and the answer are consecutive Marlow lines, so
        // the grouping shows them as one block with three matches.
        let walk = TranscriptNavigation.find("ashcombe", in: all)
        #expect(all.count == 5)
        #expect(walk.targets.count == 3, "one in the question, two in the answer")
        #expect(walk.targets.map(\.blockID) == [all[3].id, all[3].id, all[3].id])
        #expect(walk.counter == "1 of 3")
        #expect(walk.isSearch)
        #expect(walk.targets[0].location < walk.targets[1].location
                && walk.targets[1].location < walk.targets[2].location, "in reading order inside the paragraph")
        // The block's own matches, for tinting, and which is current.
        let inBlock = walk.matches(in: all[3].id)
        #expect(inBlock.all.count == 3)
        #expect(inBlock.current?.length == 8)
        #expect(walk.matches(in: all[2].id).all == [], "nothing to tint elsewhere")
    }

    @Test("a blank search finds nothing rather than everything")
    func aBlankSearchFindsNothingRatherThanEverything() async throws {
        #expect(TranscriptNavigation.find("   ", in: Self.blocks()).targets == [])
        #expect(TranscriptNavigation.find("", in: Self.blocks()).targets == [])
    }

    @Test("a walk survives a correction and keeps its place where it still exists")
    func aWalkSurvivesACorrectionAndKeepsItsPlaceWhereItStillExists() async throws {
        let all = Self.blocks()
        var walk = TranscriptNavigation.find("Ashcombe", in: all)
        walk.next()
        walk.next()
        #expect(walk.counter == "3 of 3")
        // The answer is reassigned to Bryn, so it is a different block
        // with the same words in it.
        var lines = all.flatMap(\.lines)
        lines[4].speakerName = "Bryn Callister"
        let refreshed = walk.refreshed(in: CombinedLineBlock.blocks(from: lines))
        #expect(refreshed.targets.count == 3)
        #expect(refreshed.counter == "1 of 3", "the old place is gone, so it starts over")

        let named = TranscriptNavigation.speaker("Speaker 3", recordingID: "rec-a", in: all)
        #expect(named.refreshed(in: all) == named, "nothing changed, nothing moves")
    }

}
