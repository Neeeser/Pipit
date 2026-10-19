import Foundation
import PipitCore
import PipitIntegrations
import Testing

/// A meeting too long for the model's window is asked about in parts.
@Suite("ChunkedLanguageModel")
struct ChunkedLanguageModelTests {
    /// Answers from a script and keeps what it was asked.
    private final class Scripted: LanguageModelBackend, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [EnrichmentRequest] = []
        private var speakerRequests: [SpeakerResolutionRequest] = []
        var enrichmentFor: @Sendable (EnrichmentRequest) -> MeetingEnrichment = { _ in MeetingEnrichment() }
        var suggestionsFor: @Sendable (SpeakerResolutionRequest) -> [SpeakerSuggestion] = { _ in [] }

        var enrichments: [EnrichmentRequest] { lock.withLock { asked } }
        var speakers: [SpeakerResolutionRequest] { lock.withLock { speakerRequests } }

        func isConfigured() async -> Bool { true }
        func verifyCredentials(model: String) async throws {}

        func resolveSpeakers(
            _ request: SpeakerResolutionRequest, model: String
        ) async throws -> [SpeakerSuggestion] {
            lock.withLock { speakerRequests.append(request) }
            return suggestionsFor(request)
        }

        func enrich(_ request: EnrichmentRequest, model: String) async throws -> MeetingEnrichment {
            lock.withLock { asked.append(request) }
            return enrichmentFor(request)
        }
    }

    /// A 4K window leaves room for about 3,600 characters of transcript.
    private let smallWindow = 4_096

    private func transcript(lines: Int) -> String {
        (0..<lines).map { "[\(String(format: "%02d", $0 % 60)):00] Speaker \($0 % 3): line \($0) of the call" }
            .joined(separator: "\n")
    }

    private func request(
        _ transcript: String, folders: [EnrichmentFolder] = []
    ) -> EnrichmentRequest {
        EnrichmentRequest(
            transcript: transcript, humanNotes: nil, participants: ["Ana"], provider: .zoom,
            durationSeconds: 3_600, wantsTitle: true, wantsDescription: true, wantsSummary: true,
            wantsNotes: true, folders: folders
        )
    }

    @Test("a meeting that fits is sent as it is")
    func aMeetingThatFitsIsSentAsItIs() async throws {
        let base = Scripted()
        base.enrichmentFor = { _ in MeetingEnrichment(title: "Whole") }
        let model = ChunkedLanguageModel(base, contextTokens: 32_768)

        let result = try await model.enrich(request(transcript(lines: 40)), model: "m")

        #expect(result.title == "Whole")
        #expect(base.enrichments.count == 1)
        #expect(base.enrichments.first?.source == .transcript)
    }

    @Test("a long meeting is summarised in parts and then combined")
    func aLongMeetingIsSummarisedInPartsAndThenCombined() async throws {
        let base = Scripted()
        base.enrichmentFor = { request in
            switch request.source {
            case .part(let index, _):
                return MeetingEnrichment(summary: "Summary \(index)", notes: "- Decision \(index)")
            case .partNotes:
                return MeetingEnrichment(title: "Whole meeting", summary: "Combined summary")
            case .transcript:
                return MeetingEnrichment()
            }
        }
        let model = ChunkedLanguageModel(base, contextTokens: smallWindow)

        let result = try await model.enrich(request(transcript(lines: 200)), model: "m")

        let asked = base.enrichments
        let parts = asked.filter { if case .part = $0.source { true } else { false } }
        #expect(parts.count >= 3, "9,000 characters do not fit a 4K window")
        #expect(asked.count == parts.count + 1)
        #expect(
            parts.allSatisfy { !$0.wantsTitle && !$0.wantsDescription && $0.wantsSummary },
            "the title belongs to the whole meeting, so a part is not asked for one"
        )
        #expect(parts.allSatisfy { $0.transcript.count <= 3_700 })

        let last = try #require(asked.last)
        #expect(last.source == .partNotes(parts: parts.count))
        #expect(last.wantsTitle && last.wantsDescription && last.wantsSummary && last.wantsNotes)
        #expect(last.transcript.contains("Part 1") && last.transcript.contains("Summary 1"))
        #expect(last.transcript.contains("- Decision \(parts.count)"))
        #expect(last.folders.isEmpty, "the combining request has no transcript to quote")

        #expect(result.title == "Whole meeting")
        #expect(result.summary == "Combined summary")
    }

    @Test("notes that are themselves too long are condensed before they are combined")
    func notesThatAreThemselvesTooLongAreCondensedBeforeTheyAreCombined() async throws {
        let base = Scripted()
        let long = String(repeating: "Something was decided here. ", count: 20)
        base.enrichmentFor = { request in
            if case .partNotes = request.source, request.wantsTitle {
                return MeetingEnrichment(title: "Done")
            }
            return MeetingEnrichment(summary: long)
        }
        let model = ChunkedLanguageModel(base, contextTokens: smallWindow)

        let result = try await model.enrich(request(transcript(lines: 1_500)), model: "m")

        let asked = base.enrichments
        let last = try #require(asked.last)
        #expect(result.title == "Done")
        #expect(last.transcript.count <= 3_700, "what the last request reads fits the window")
        #expect(
            asked.contains { if case .partNotes = $0.source { !$0.wantsTitle } else { false } },
            "a level of condensing sat between the parts and the last request"
        )
    }

    @Test("the best two folders across the parts are kept, one entry each")
    func theBestTwoFoldersAcrossThePartsAreKeptOneEntryEach() async throws {
        let base = Scripted()
        base.enrichmentFor = { request in
            guard case .part(let index, _) = request.source else { return MeetingEnrichment(title: "T") }
            let candidates: [Int: [ModelFolderCandidate]] = [
                1: [ModelFolderCandidate(folderName: "Acme", confidence: 0.6, why: "named once")],
                2: [
                    ModelFolderCandidate(folderName: "Acme", confidence: 0.9, why: "named again"),
                    ModelFolderCandidate(folderName: "Hiring", confidence: 0.7, why: "interviews"),
                ],
                3: [ModelFolderCandidate(folderName: "Budget", confidence: 0.4, why: "mentioned")],
            ]
            return MeetingEnrichment(summary: "s", folderCandidates: candidates[index] ?? [])
        }
        let folders = [EnrichmentFolder(name: "Acme", about: "a client")]
        let model = ChunkedLanguageModel(base, contextTokens: smallWindow)

        let result = try await model.enrich(request(transcript(lines: 100), folders: folders), model: "m")

        #expect(result.folderCandidates.map(\.folderName) == ["Acme", "Hiring"])
        #expect(result.folderCandidates.first?.confidence == 0.9)
    }

    @Test("a name heard in one part is kept with the most confident answer")
    func aNameHeardInOnePartIsKeptWithTheMostConfidentAnswer() async throws {
        let base = Scripted()
        base.suggestionsFor = { request in
            let first = request.transcript.contains("line 0 ")
            return first
                ? [
                    SpeakerSuggestion(
                        label: "Speaker 1", name: "Ana", confidence: 0.9, quote: "Thanks, Ana.", atSeconds: 5)
                ]
                : [
                    SpeakerSuggestion(
                        label: "Speaker 1", name: "Anna", confidence: 0.5, quote: "Anna?", atSeconds: 900),
                    SpeakerSuggestion(
                        label: "Speaker 2", name: "Ben", confidence: 0.8, quote: "Ben, go ahead.", atSeconds: 1_200),
                ]
        }
        let model = ChunkedLanguageModel(base, contextTokens: smallWindow)

        let suggestions = try await model.resolveSpeakers(
            SpeakerResolutionRequest(
                transcript: transcript(lines: 200), labels: ["Speaker 1", "Speaker 2"],
                humanContext: nil, nameHints: [], localUserName: nil
            ),
            model: "m"
        )

        #expect(base.speakers.count >= 3)
        #expect(suggestions.map(\.name) == ["Ana", "Ben"])
    }
}
