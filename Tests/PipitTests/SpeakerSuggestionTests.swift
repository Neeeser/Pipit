import Foundation
import PipitCore
import Testing

/// The gate between what a model proposes and what the speaker strip draws.
///
/// Every rule here exists because the alternative is a wrong name on screen
/// asking to be accepted, which is worse than no name at all.
@Suite("SpeakerSuggestions")
struct SpeakerSuggestionTests {

    private static func suggestion(
        _ label: String, _ name: String, confidence: Double = 0.9,
        quote: String = "Ellis, do you want to take this?", atSeconds: Double = 12
    ) -> SpeakerNameSuggestion {
        SpeakerNameSuggestion(
            label: label, name: name, confidence: confidence, quote: quote, atSeconds: atSeconds
        )
    }

    @Test("a suggestion is drawn only for a speaker who still has no name")
    func aSuggestionIsDrawnOnlyForASpeakerWhoStillHasNoName() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis"),
            Self.suggestion("speaker_01", "Joe"),
        ])
        // speaker_01 was named by hand after the model answered, so its
        // pill goes away without anything having to delete it.
        let visible = set.visible(forUnnamed: ["speaker_00"])
        #expect(visible.count == 1)
        #expect(visible.first?.name == "Ellis")
    }

    @Test("a dismissed label is not offered again")
    func aDismissedLabelIsNotOfferedAgain() async throws {
        var set = SpeakerSuggestionSet(suggestions: [Self.suggestion("speaker_00", "Ellis")])
        #expect(set.visible(forUnnamed: ["speaker_00"]).count == 1)
        set.dismiss("speaker_00")
        #expect(
            set.visible(forUnnamed: ["speaker_00"]).isEmpty,
            "a name turned down came back"
        )
        // A second dismissal of the same label must not grow the list.
        set.dismiss("speaker_00")
        #expect(set.dismissedLabels.count == 1)
    }

    @Test("a re-run keeps dismissals but replaces the suggestions")
    func aReRunKeepsDismissalsButReplacesTheSuggestions() async throws {
        var set = SpeakerSuggestionSet(suggestions: [Self.suggestion("speaker_00", "Ellis")])
        set.dismiss("speaker_00")
        set.suggestions = [
            Self.suggestion("speaker_00", "Benjamin"), Self.suggestion("speaker_02", "Nicolo"),
        ]
        let visible = set.visible(forUnnamed: ["speaker_00", "speaker_02"])
        #expect(visible.count == 1, "the dismissed speaker came back under a new name")
        #expect(visible.first?.name == "Nicolo")
    }

    @Test("a guess below the floor is not drawn")
    func aGuessBelowTheFloorIsNotDrawn() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis", confidence: 0.49),
            Self.suggestion("speaker_01", "Joe", confidence: 0.5),
        ])
        let visible = set.visible(forUnnamed: ["speaker_00", "speaker_01"])
        #expect(visible.count == 1)
        #expect(visible.first?.name == "Joe", "the floor is inclusive")
    }

    @Test("a name with no line behind it is dropped")
    func aNameWithNoLineBehindItIsDropped() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis", quote: ""),
            Self.suggestion("speaker_01", "", quote: "Thanks Joe."),
        ])
        #expect(
            set.visible(forUnnamed: ["speaker_00", "speaker_01"]).isEmpty,
            "a suggestion with no quote or no name reached the strip"
        )
    }

    @Test("the most confident guess is drawn first")
    func theMostConfidentGuessIsDrawnFirst() async throws {
        let set = SpeakerSuggestionSet(suggestions: [
            Self.suggestion("speaker_00", "Ellis", confidence: 0.62),
            Self.suggestion("speaker_01", "Joe", confidence: 0.94),
        ])
        let visible = set.visible(forUnnamed: ["speaker_00", "speaker_01"])
        #expect(visible.map(\.name) == ["Joe", "Ellis"])
    }

    @Test("the band reads as a word rather than a percentage")
    func theBandReadsAsAWordRatherThanAPercentage() async throws {
        #expect(Self.suggestion("s", "Ellis", confidence: 0.94).band == .high)
        #expect(Self.suggestion("s", "Ellis", confidence: 0.62).band == .medium)
    }

    @Test("a meeting with no suggestions file reads as an empty set")
    func aMeetingWithNoSuggestionsFileReadsAsAnEmptySet() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-suggestions-\(UUID().uuidString)")
        let store = MeetingStore(layout: MeetingLayout(root: directory))
        try store.createDirectories()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(store.readSpeakerSuggestions().suggestions.isEmpty)

        try store.writeSpeakerSuggestions(
            SpeakerSuggestionSet(suggestions: [Self.suggestion("speaker_00", "Ellis")])
        )
        let read = store.readSpeakerSuggestions()
        #expect(read.suggestions.count == 1)
        #expect(read.suggestions.first?.quote == "Ellis, do you want to take this?")
        // Never in the speaker map: that file is what the meeting
        // concluded, and this is a proposal about what it could not.
        let mapEntries = try store.readSpeakerMap().entries
        #expect(mapEntries.isEmpty)
    }

    @Test("metadata written before the missing-key flag existed still decodes")
    func metadataWrittenBeforeTheMissingKeyFlagExistedStillDecodes() async throws {
        // Every meeting already on disk lacks this key. Decoding one as
        // a failure would make the whole archive unreadable.
        let json = """
        {"state":"complete","updatedAt":"2026-08-26T16:00:29.792Z",
         "attempts":{"enriching":1},"completedStages":["recording","enriching"]}
        """
        let status = try ArchiveCoding.decode(
            ProcessingStatus.self, from: Data(json.utf8), path: "metadata.json"
        )
        #expect(status.state == .complete)
        #expect(!status.skippedForMissingKey)
    }
}
