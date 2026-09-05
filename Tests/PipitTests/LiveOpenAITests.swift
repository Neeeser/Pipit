import Foundation
import PipitCore
import PipitIntegrations
import Testing

/// Opt-in tests that talk to the real API.
///
/// Skipped unless `PIPIT_LIVE_OPENAI=1` and `OPENAI_API_KEY` are both set, so
/// an ordinary run costs nothing. The audio is synthesised locally by
/// `scripts/make-live-fixture.sh`, which keeps the fixture free and reproducible;
/// only the requests are live.
@Suite("LiveOpenAI")
struct LiveOpenAITests {
    static let liveReason: Comment = "set PIPIT_LIVE_OPENAI=1 to run live API tests"
    static let keyReason: Comment = "OPENAI_API_KEY is not set"
    static let fixtureReason: Comment = "run scripts/make-live-fixture.sh and set PIPIT_LIVE_FIXTURE"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PIPIT_LIVE_OPENAI"] == "1"
    }

    static var hasKey: Bool {
        (try? EnvironmentAPIKeyStore().apiKey()) != nil
    }

    static var fixtureDirectory: URL? {
        if let path = ProcessInfo.processInfo.environment["PIPIT_LIVE_FIXTURE"] {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var hasFixture: Bool {
        guard let fixtures = fixtureDirectory else { return false }
        return FileManager.default.fileExists(
            atPath: fixtures.appendingPathComponent("conversation.wav").path
        )
    }

    /// Synthesised speech transcribes with some variation, so assertions count how
    /// many expected terms survived rather than demanding one exact word.
    static func mentions(_ text: String, atLeast count: Int, of terms: [String]) -> Bool {
        terms.filter { text.localizedCaseInsensitiveContains($0) }.count >= count
    }

    static let expectedTerms = [
        "replica", "provision", "capacity", "rollback", "runbook",
        "production", "staging", "morning", "twenty",
    ]

    /// The client and the fixture directory the gated tests were let through on.
    static func live() throws -> (client: OpenAIClient, fixtures: URL) {
        let store = EnvironmentAPIKeyStore()
        let fixtures = try #require(fixtureDirectory, fixtureReason)
        return (OpenAIClient(keyProvider: store), fixtures)
    }

    /// The key alone, for the checks that need no audio.
    ///
    /// Speaker resolution reads a transcript, so pinning its contract costs one
    /// text request and does not need the fixture to have been built.
    static func client() throws -> OpenAIClient {
        OpenAIClient(keyProvider: EnvironmentAPIKeyStore())
    }

    @Test(
        "the key and the diarization model are both reachable",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func theKeyAndTheDiarizationModelAreBothReachable() async throws {
        let (client, _) = try Self.live()
        try await client.verifyCredentials(model: AIModelSettings().diarization)
        // An invalid key must fail loudly rather than silently degrade.
        let broken = OpenAIClient(keyProvider: StaticKey(value: "sk-not-a-real-key"))
        await #expect(throws: (any Error).self) {
            try await broken.verifyCredentials(model: AIModelSettings().diarization)
        }
    }

    @Test(
        "transcription returns the segment timings the timeline needs",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func transcriptionReturnsTheSegmentTimingsTheTimelineNeeds() async throws {
        let (client, fixtures) = try Self.live()
        let response = try await client.transcribe(TranscriptionRequest(
            audio: fixtures.appendingPathComponent("conversation.mic.wav"),
            model: AIModelSettings().transcription
        ))
        #expect(!response.segments.isEmpty, "no segments returned")
        #expect(
            Self.mentions(response.text, atLeast: 2, of: Self.expectedTerms),
            "transcript does not look like the fixture: \(response.text.prefix(200))"
        )
        for segment in response.segments {
            #expect(segment.end >= segment.start, "segment times are inverted")
        }
        #expect((response.segments.last?.end ?? 0) > 5, "timings should span the recording")
    }

    @Test(
        "diarization separates the remote speakers",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func diarizationSeparatesTheRemoteSpeakers() async throws {
        let (client, fixtures) = try Self.live()
        let response = try await client.diarize(DiarizationRequest(
            audio: fixtures.appendingPathComponent("conversation.remote.wav"),
            model: AIModelSettings().diarization
        ))
        let labels = Set(response.segments.compactMap(\.speaker))
        #expect(labels.count >= 2, "expected at least two remote speakers, got \(labels.sorted())")
        #expect(
            Self.mentions(response.text, atLeast: 3, of: Self.expectedTerms),
            "transcript does not look like the fixture: \(response.text.prefix(200))"
        )
    }

    @Test(
        "the assembled transcript keeps the local speaker separate",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func theAssembledTranscriptKeepsTheLocalSpeakerSeparate() async throws {
        let (client, fixtures) = try Self.live()
        async let micResponse = client.transcribe(TranscriptionRequest(
            audio: fixtures.appendingPathComponent("conversation.mic.wav"),
            model: AIModelSettings().transcription
        ))
        async let remoteResponse = client.diarize(DiarizationRequest(
            audio: fixtures.appendingPathComponent("conversation.remote.wav"),
            model: AIModelSettings().diarization
        ))
        let (mic, remote) = try await (micResponse, remoteResponse)

        let raw = RawTranscript(chunks: [
            RawTranscriptChunk(
                id: "mic_chunk_001", track: .mic, timelineOffset: 0,
                durationSeconds: 40, model: AIModelSettings().transcription,
                responseFormat: "verbose_json", segments: mic.segments
            ),
            RawTranscriptChunk(
                id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                durationSeconds: 40, model: AIModelSettings().diarization,
                responseFormat: "diarized_json", segments: remote.segments
            ),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: raw, micTrackIsLocalUser: true, generatedAt: Date()
        )
        let micUtterances = transcript.utterances.filter { $0.track == .mic }
        #expect(!micUtterances.isEmpty)
        for utterance in micUtterances {
            #expect(
                utterance.speakerKey == SpeakerLabel.localUser,
                "the microphone track is the local user by construction"
            )
        }
        let remoteKeys = Set(
            transcript.utterances.filter { $0.track == .remote }.map(\.speakerKey)
        )
        #expect(remoteKeys.count >= 2, "got remote speakers \(remoteKeys.sorted())")
        for key in remoteKeys {
            #expect(key.hasPrefix("remote_chunk_001_speaker_"), "unexpected key \(key)")
        }
    }

    @Test(
        "speaker resolution names the remote speakers from their introductions",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func speakerResolutionNamesTheRemoteSpeakersFromTheirIntroduction() async throws {
        let (client, fixtures) = try Self.live()
        let remote = try await client.diarize(DiarizationRequest(
            audio: fixtures.appendingPathComponent("conversation.remote.wav"),
            model: AIModelSettings().diarization
        ))
        let raw = RawTranscript(chunks: [
            RawTranscriptChunk(
                id: "remote_chunk_001", track: .remote, timelineOffset: 0,
                durationSeconds: 40, model: AIModelSettings().diarization,
                responseFormat: "diarized_json", segments: remote.segments
            ),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: raw, micTrackIsLocalUser: true, generatedAt: Date()
        )
        let renderer = TranscriptRenderer()
        let anonymous = transcript.utterances
            .map { "[\(renderer.timecode($0.start))] \($0.speakerKey): \($0.text)" }
            .joined(separator: "\n")

        let suggestions = try await client.resolveSpeakers(
            SpeakerResolutionRequest(
                transcript: anonymous,
                labels: transcript.speakerKeys,
                humanContext: "Call with me (Marlow), my boss Bryn, and Owen from the platform team.",
                nameHints: [],
                localUserName: "Marlow"
            ),
            model: AIModelSettings().metadata
        )
        let names = Set(suggestions.map { $0.name.split(separator: " ").first.map(String.init) ?? $0.name })
        #expect(names.contains("Bryn"), "expected Bryn among \(names.sorted())")
        #expect(names.contains("Owen"), "expected Owen among \(names.sorted())")
        for suggestion in suggestions {
            #expect(
                transcript.speakerKeys.contains(suggestion.label),
                "suggested a label that is not in the transcript: \(suggestion.label)"
            )
        }
    }

    @Test(
        "a suggestion names only who was addressed, and quotes the line",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason)
    )
    func aSuggestionNamesOnlyWhoWasAddressedAndQuotesTheLine() async throws {
        let client = try Self.client()
        // Two unnamed speakers. One is called by name and answers; the
        // other says a good deal and is never named by anybody. The
        // second is the case that used to produce a confident guess out
        // of nothing.
        let transcript = """
        [00:12] Bryn C: The retain numbers landed overnight and they look clean.
        [00:19] Bryn C: Ellis, do you want to take the ingestion question?
        [00:24] remote-001_speaker_03: Yeah. The chunker is still the slow part, but I \
        pulled the embedding call out of the loop and it dropped to about four seconds a document.
        [00:41] remote-001_speaker_07: I looked at the same path last week. The batching \
        helps but the tokenizer is doing twice the work it needs to on short documents.
        [00:58] Bryn C: Good. Let us pick it up tomorrow.
        """

        let suggestions = try await client.resolveSpeakers(
            SpeakerResolutionRequest(
                transcript: transcript,
                labels: ["remote-001_speaker_03", "remote-001_speaker_07"],
                humanContext: nil,
                nameHints: ["Ellis Marchetti", "Bryn Callister", "Renee Balfour"],
                localUserName: "Marlow"
            ),
            model: AIModelSettings().metadata
        )

        let named = Dictionary(
            uniqueKeysWithValues: suggestions.map { ($0.label, $0) }
        )
        let ellis = try #require(named["remote-001_speaker_03"])
        #expect(
            ellis.name.localizedCaseInsensitiveContains("Ellis"),
            "expected Ellis for the addressed speaker, got \(ellis.name)"
        )
        // The quote is the whole point: it has to be a line that is
        // actually in the transcript.
        #expect(
            transcript.localizedCaseInsensitiveContains(
                ellis.quote.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
            ),
            "quote is not in the transcript: \(ellis.quote)"
        )
        #expect(ellis.confidence > 0.5, "confidence was \(ellis.confidence)")

        // Nobody said this speaker's name, so nothing may be proposed
        // for them above the floor the strip draws at.
        if let unnamed = named["remote-001_speaker_07"] {
            #expect(
                unnamed.confidence < SpeakerNameSuggestion.minimumConfidence,
                "named a speaker nobody addressed: \(unnamed.name) at \(unnamed.confidence)"
            )
        }
    }

    @Test(
        "enrichment writes a title and a summary from the transcript",
        .enabled(if: LiveOpenAITests.isEnabled, LiveOpenAITests.liveReason),
        .enabled(if: LiveOpenAITests.hasKey, LiveOpenAITests.keyReason),
        .enabled(if: LiveOpenAITests.hasFixture, LiveOpenAITests.fixtureReason)
    )
    func enrichmentWritesATitleAndASummaryFromTheTranscript() async throws {
        let (client, fixtures) = try Self.live()
        let response = try await client.transcribe(TranscriptionRequest(
            audio: fixtures.appendingPathComponent("conversation.wav"),
            model: AIModelSettings().transcription
        ))
        let enrichment = try await client.enrich(
            EnrichmentRequest(
                transcript: response.text,
                humanNotes: nil,
                participants: ["Marlow", "Bryn", "Owen"],
                provider: .googleMeet,
                durationSeconds: 40,
                wantsTitle: true,
                wantsDescription: false,
                wantsSummary: true,
                wantsNotes: true
            ),
            model: AIModelSettings().metadata
        )
        let title = try #require(enrichment.title)
        #expect(!title.isEmpty)
        #expect(title.count < 80, "a title should be short, got: \(title)")
        let summary = try #require(enrichment.summary)
        #expect(summary.count > 40, "summary looks empty")
    }
}

private struct StaticKey: APIKeyProviding {
    let value: String
    func apiKey() throws -> String { value }
}
