import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import Testing

private func chunk(
    id: String, track: CaptureTrack, offset: Double, segments: [RawTranscriptSegment]
) -> RawTranscriptChunk {
    RawTranscriptChunk(
        id: id, track: track, timelineOffset: offset, durationSeconds: 600,
        model: "test", responseFormat: "diarized_json", segments: segments
    )
}

@Suite("ChunkPlanner")
struct ChunkPlannerTests {
    @Test("a short recording is a single request")
    func aShortRecordingIsASingleRequest() async throws {
        let plans = ChunkPlanner().plan(durationSeconds: 600)
        #expect(plans.count == 1)
        #expect(plans[0].start == 0)
        #expect(
            abs(plans[0].end - 600) <= 0.001,
            "expected \(600) ± \(0.001), got \(plans[0].end)"
        )
    }

    @Test("a plan fitted to a tighter limit never exceeds it, overlap included")
    func aPlanFittedToATighterLimitNeverExceedsItOverlapIncluded() async throws {
        // The local Cohere engine's window is 35 s, and one second over
        // it re-enters the library's own stitching, which is the thing
        // the limit exists to avoid.
        let limits = BackendAudioLimits(maximumSeconds: LocalCohereTuning.chunkSeconds)
        let configuration = try #require(ChunkPlanner.Configuration.fitting(limits))
        let plans = ChunkPlanner(configuration: configuration)
            .plan(durationSeconds: 600)
        #expect(plans.count > 15, "got \(plans.count) chunks of ten minutes")
        for plan in plans {
            #expect(
                plan.duration <= LocalCohereTuning.chunkSeconds + 0.001,
                "chunk \(plan.index) is \(plan.duration)s, past the model window"
            )
        }
        #expect(
            ChunkPlanner.Configuration.fitting(BackendAudioLimits.openAI) == nil,
            "the cloud limit keeps the measured default plan"
        )
    }

    @Test("a text-only backend is chunked for the aligner, not for its own limit")
    func aTextOnlyBackendIsChunkedForTheAlignerNotForItsOwnLimit() async throws {
        // gpt-transcribe may send 1400 seconds, but the words come back
        // without timings and the alignment trellis is frames times
        // tokens. At the API's own limit the trellis exceeded its cap,
        // alignment refused, and a nineteen-minute chunk became one
        // utterance on one speaker.
        let configuration = try #require(
            ChunkPlanner.Configuration.fitting(BackendAudioLimits.openAI, timing: .text)
        )
        let plans = ChunkPlanner(configuration: configuration)
            .plan(durationSeconds: 3_600)
        #expect(plans.count >= 12, "got \(plans.count) chunks for an hour")
        for plan in plans {
            #expect(
                plan.duration <= LocalAlignmentTuning.chunkSeconds + 0.001,
                "chunk \(plan.index) is \(plan.duration)s, past the alignment window"
            )
        }
    }

    @Test("a long recording is chunked under the model limit with overlap")
    func aLongRecordingIsChunkedUnderTheModelLimitWithOverlap() async throws {
        // Two hours, which is four to seven requests.
        let plans = ChunkPlanner().plan(durationSeconds: 7_200)
        #expect(plans.count >= 5, "got \(plans.count) chunks")
        for plan in plans {
            #expect(
                plan.duration <= AILimits.maximumDiarizationSeconds,
                "chunk \(plan.index) is \(plan.duration)s, over the 1400 s limit"
            )
            #expect(plan.duration > 0)
        }
        for (previous, next) in zip(plans, plans.dropFirst()) {
            #expect(next.start < previous.end, "chunks must overlap, not just abut")
            #expect(
                abs((previous.end - next.start) - 8) <= 0.5,
                "expected \(8) ± \(0.5), got \(previous.end - next.start)"
            )
        }
        #expect(
            abs((plans.last?.end ?? 0) - 7_200) <= 0.001,
            "expected \(7_200) ± \(0.001), got \(plans.last?.end ?? 0)"
        )
        #expect(plans.first?.start == 0)
    }

    @Test("boundaries move to the quietest nearby point")
    func boundariesMoveToTheQuietestNearbyPoint() async throws {
        // Speech everywhere except a clear pause 40 s before the ideal cut.
        let windowSeconds = 0.5
        let windowCount = Int(3_000 / windowSeconds)
        var values = [Float](repeating: 0.4, count: windowCount)
        let pauseCentre = 1_140.0 - 40
        let pauseStart = Int((pauseCentre - 1) / windowSeconds)
        let pauseEnd = Int((pauseCentre + 1) / windowSeconds)
        for index in pauseStart...pauseEnd { values[index] = 0.001 }

        let profile = EnergyProfile(windowSeconds: windowSeconds, values: values)
        let plans = ChunkPlanner().plan(durationSeconds: 3_000, energy: profile)
        #expect(plans.count >= 2)
        let boundary = plans[1].overlapEnd
        #expect(
            abs(boundary - pauseCentre) <= 2.0,
            "expected \(pauseCentre) ± \(2.0), got \(boundary) — boundary should land in the pause"
        )
    }

    @Test("chunk identifiers are namespaced so labels never collide")
    func chunkIdentifiersAreNamespacedSoLabelsNeverCollide() async throws {
        let plans = ChunkPlanner().plan(durationSeconds: 7_200)
        let ids = Set(plans.map(\.chunkID))
        #expect(ids.count == plans.count)
        #expect(plans[0].chunkID == "chunk_001")
        #expect(
            SpeakerLabel.namespaced(chunkID: "chunk_001", rawLabel: "A") == "chunk_001_speaker_00"
        )
        #expect(
            SpeakerLabel.namespaced(chunkID: "chunk_002", rawLabel: "A") == "chunk_002_speaker_00"
        )
        #expect(
            SpeakerLabel.namespaced(chunkID: "chunk_001", rawLabel: "A")
                != SpeakerLabel.namespaced(chunkID: "chunk_002", rawLabel: "A")
        )
    }
}

@Suite("TranscriptAssembler")
struct TranscriptAssemblerTests {
    @Test("overlapping chunks do not duplicate the sentence they share")
    func overlappingChunksDoNotDuplicateTheSentenceTheyShare() async throws {
        // The last sentence of chunk one is repeated at the start of chunk
        // two, which is exactly what the 8 s overlap produces.
        let first = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
            RawTranscriptSegment(start: 0, end: 3, text: "Let's start with retrieval.", speaker: "A"),
            RawTranscriptSegment(start: 4, end: 8, text: "The second pass is the slow one.", speaker: "B"),
        ])
        let second = chunk(id: "remote_chunk_002", track: .remote, offset: 4, segments: [
            RawTranscriptSegment(start: 0, end: 4, text: "The second pass is the slow one.", speaker: "A"),
            RawTranscriptSegment(start: 5, end: 9, text: "Agreed, let's cache it.", speaker: "B"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let texts = transcript.utterances.map(\.text)
        #expect(texts.count == 3, "got \(texts)")
        #expect(
            texts.filter { $0.contains("second pass") }.count == 1,
            "the overlapping sentence appears twice: \(texts)"
        )
        #expect(texts.contains("Agreed, let's cache it."))
    }

    @Test("continuous audio cannot merge into one multi-minute utterance")
    func continuousAudioCannotMergeIntoOneMultiMinuteUtterance() async throws {
        // Without headphones the microphone never goes silent, so the
        // pause rule alone chained a real recording into one 219-second
        // utterance and every remote reply rendered after the whole
        // block. A turn is capped so other speakers interleave.
        var segments: [RawTranscriptSegment] = []
        for index in 0..<12 {
            let start = Double(index) * 6.5
            segments.append(RawTranscriptSegment(
                start: start, end: start + 6,
                text: "Sentence number \(index) of a long stretch.", speaker: nil
            ))
        }
        let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: segments)
        let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
            RawTranscriptSegment(start: 35, end: 38, text: "A short remote reply.", speaker: "00"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [mic, remote]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let local = transcript.utterances.filter { $0.speakerKey == SpeakerLabel.localUser }
        #expect(local.count >= 3, "expected several turns, got \(local.count)")
        let longest = local.map { $0.end - $0.start }.max() ?? 0
        #expect(longest <= 30.01, "an utterance still spans \(longest)s")
        let order = transcript.utterances.map(\.track)
        #expect(
            order.firstIndex(of: .remote).map { $0 > 0 && $0 < order.count - 1 } == true,
            "the remote reply should land between local turns, not after the block"
        )
    }

    @Test("a phrase repeated inside one chunk is kept")
    func aPhraseRepeatedInsideOneChunkIsKept() async throws {
        // De-duplication exists for the overlap between chunks. A speaker
        // who repeats themselves inside a single chunk said it twice.
        let only = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
            RawTranscriptSegment(start: 0, end: 2, text: "Yes, exactly.", speaker: "A"),
            RawTranscriptSegment(start: 4, end: 8, text: "So the index is the slow part.", speaker: "B"),
            RawTranscriptSegment(start: 9, end: 11, text: "Yes, exactly.", speaker: "A"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [only]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let texts = transcript.utterances.map(\.text)
        #expect(
            texts.filter { $0 == "Yes, exactly." }.count == 2,
            "both repetitions should survive: \(texts)"
        )
    }

    @Test("anonymous labels from different chunks read as different speakers")
    func anonymousLabelsFromDifferentChunksReadAsDifferentSpeakers() async throws {
        let first = SpeakerMap.fallbackName(for: "remote_chunk_001_speaker_00")
        let second = SpeakerMap.fallbackName(for: "remote_chunk_002_speaker_00")
        #expect(first == "Speaker 1", "one chunk of audio should read plainly")
        #expect(
            first != second,
            "two chunks' labels are different clusters until someone maps them"
        )
        #expect(second == "Speaker 1 (part 2)")
        #expect(SpeakerMap.fallbackName(for: SpeakerLabel.localUser) == "Me")
    }

    @Test("timestamps stay monotonic across chunks")
    func timestampsStayMonotonicAcrossChunks() async throws {
        let first = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
            RawTranscriptSegment(start: 10, end: 12, text: "One.", speaker: "A"),
        ])
        let second = chunk(id: "remote_chunk_002", track: .remote, offset: 600, segments: [
            RawTranscriptSegment(start: 5, end: 7, text: "Two.", speaker: "A"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(transcript.utterances.map(\.start) == [10, 605])
        for (previous, next) in zip(transcript.utterances, transcript.utterances.dropFirst()) {
            #expect(next.start >= previous.start)
        }
    }

    @Test("the microphone track is the local user and is never diarized")
    func theMicrophoneTrackIsTheLocalUserAndIsNeverDiarized() async throws {
        let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
            RawTranscriptSegment(start: 1, end: 3, text: "I think we change retrieval.", speaker: nil),
        ])
        let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
            RawTranscriptSegment(start: 4, end: 6, text: "Yeah, on the second pass.", speaker: "A"),
            RawTranscriptSegment(start: 8, end: 10, text: "Would that affect latency?", speaker: "B"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [mic, remote]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(transcript.utterances.count == 3)
        #expect(transcript.utterances[0].speakerKey == SpeakerLabel.localUser)
        #expect(transcript.utterances[0].rawSpeakerLabel == nil)
        #expect(transcript.utterances[1].speakerKey == "remote_chunk_001_speaker_00")
        #expect(transcript.utterances[2].speakerKey == "remote_chunk_001_speaker_01")
    }

    @Test("short overlapping chunks do not repeat the words they share")
    func shortOverlappingChunksDoNotRepeatTheWordsTheyShare() async throws {
        // The Cohere path chunks at 35 s and aligns each chunk on its
        // own, so the planner's overlap arrives twice with the two
        // chunks grouping it into different turns. One 6-minute
        // recording came out with 35 repeated 8-grams and utterance
        // pairs overlapping by up to 8.6 s, the same sentence given to
        // two speakers. Grouping is not a unit either chunk agrees on,
        // so the near-duplicate merge never saw a duplicate.
        let vocabulary = [
            "we", "should", "surface", "the", "index", "to", "the", "user",
            "and", "push", "a", "button", "maybe", "to", "start", "talking",
            "about", "it", "before", "the", "second", "pass", "runs", "again",
            "so", "nobody", "waits", "for", "the", "slow", "one", "twice",
            "which", "is", "what", "we", "agreed", "on", "last", "friday",
            "and", "the", "week", "before", "that", "as", "well", "again",
            "now", "let", "us", "write", "it", "down", "somewhere", "useful",
            "for", "the", "next", "person",
        ]
        // One word every half second on the meeting timeline.
        func word(_ index: Int, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(
                start: Double(index) * 0.5 - offset,
                end: Double(index) * 0.5 + 0.4 - offset,
                text: " \(vocabulary[index])"
            )
        }
        func segment(_ indices: [Int], offset: Double, speaker: String) -> RawTranscriptSegment {
            let words = indices.map { word($0, offset: offset) }
            return RawTranscriptSegment(
                start: words[0].start, end: words[words.count - 1].end,
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                speaker: speaker, words: words
            )
        }

        // Chunk one holds 0 to 22 s as one turn; chunk two starts at
        // 14 s, repeats every word from there, and groups them in
        // fives under a different speaker.
        let firstIndices = Array(0..<44)
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [segment(firstIndices, offset: 0, speaker: "A")]
        )
        let secondIndices = Array(28..<vocabulary.count)
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 14,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: stride(from: 0, to: secondIndices.count, by: 5).map { start in
                segment(
                    Array(secondIndices[start..<min(start + 5, secondIndices.count)]),
                    offset: 14, speaker: "B"
                )
            }
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        var seen = Set<String>()
        var repeated: [String] = []
        if words.count >= 8 {
            for start in 0...(words.count - 8) {
                let gram = words[start..<(start + 8)].joined(separator: " ")
                if !seen.insert(gram).inserted { repeated.append(gram) }
            }
        }
        #expect(repeated.isEmpty, "repeated 8-grams: \(repeated)")

        var worstOverlap: Double = 0
        for (index, utterance) in transcript.utterances.enumerated() {
            for other in transcript.utterances[(index + 1)...] {
                let shared = min(utterance.end, other.end) - max(utterance.start, other.start)
                worstOverlap = max(worstOverlap, shared)
            }
        }
        #expect(
            worstOverlap <= 1,
            "utterances overlap in time by \(worstOverlap) s"
        )
        // And the words themselves survive: the overlap is cut, not dropped.
        #expect(words.count == vocabulary.count, "every word appears exactly once")
    }

    @Test("a seam keeps the words the later chunk never transcribed")
    func aSeamKeepsTheWordsTheLaterChunkNeverTranscribed() async throws {
        // Cutting the shared span at its midpoint assumed both chunks
        // had transcribed it. Where the later chunk's alignment starts
        // past the cut, which the 35 s Cohere windows do routinely, the
        // earlier chunk's words past the cut were deleted with nothing
        // to replace them: six minutes of ES2002b lost about 230 spoken
        // words over ten seams, 316 deletions becoming 470.
        let spoken = (0..<40).map { "alpha\($0)" }
        let later = (0..<8).map { "omega\($0)" }
        func word(_ text: String, at start: Double, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start - offset, end: start + 0.4 - offset, text: " \(text)")
        }
        func segment(_ words: [RawTranscriptWord], speaker: String) -> RawTranscriptSegment {
            RawTranscriptSegment(
                start: words[0].start, end: words[words.count - 1].end,
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                speaker: speaker, words: words
            )
        }
        // One chunk says everything from 0 to 19.9 s.
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [segment(
                spoken.enumerated().map { word($1, at: Double($0) * 0.5, offset: 0) },
                speaker: "A"
            )]
        )
        // The next one starts at 12 s and hears one word of the eight
        // seconds they share, then nothing until 22 s.
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 12,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [
                segment([word("alpha36", at: 18, offset: 12)], speaker: "B"),
                segment(
                    later.enumerated().map { word($1, at: 22 + Double($0) * 0.5, offset: 12) },
                    speaker: "B"
                ),
            ]
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        let missing = (spoken + later).filter { !words.contains($0) }
        #expect(missing.isEmpty, "words the later chunk never heard were dropped: \(missing)")
        // And the one word both chunks did hear is written once.
        #expect(words.filter { $0 == "alpha36" }.count == 1, "got \(words)")
        #expect(words.count == spoken.count + later.count, "got \(words)")
    }

    @Test("a chunk is deduplicated against every chunk it overlaps")
    func aChunkIsDeduplicatedAgainstEveryChunkItOverlaps() async throws {
        // Trimming consecutive pairs only left chunk N and chunk N+2
        // repeating whatever they share: the deciding ES2003a run came
        // back with 153 repeated 8-grams that way.
        let spoken = (0..<40).map { "alpha\($0)" }
        let fresh = (0..<8).map { "omega\($0)" }
        func word(_ text: String, at start: Double, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start - offset, end: start + 0.4 - offset, text: " \(text)")
        }
        func chunk(
            _ id: String, offset: Double, words: [RawTranscriptWord], speaker: String
        ) -> RawTranscriptChunk {
            RawTranscriptChunk(
                id: id, track: .remote, timelineOffset: offset,
                durationSeconds: 35, model: "cohere", responseFormat: "local_words",
                segments: [RawTranscriptSegment(
                    start: words[0].start, end: words[words.count - 1].end,
                    text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                    speaker: speaker, words: words
                )]
            )
        }
        func timed(_ range: Range<Int>, offset: Double) -> [RawTranscriptWord] {
            range.map { word(spoken[$0], at: Double($0) * 0.5, offset: offset) }
        }
        // 0 to 19.9 s, then 4 to 7.9 s, then 8 s onwards: the third
        // chunk shares twelve seconds with the first and none of them
        // with the second.
        let first = chunk("remote_chunk_001", offset: 0, words: timed(0..<40, offset: 0), speaker: "A")
        let second = chunk("remote_chunk_002", offset: 4, words: timed(8..<16, offset: 4), speaker: "B")
        // The third chunk opens on two words of its own, so the repeat
        // it then carries is not the prefix of a turn and the seam-repeat
        // trim above cannot see it.
        let third = chunk(
            "remote_chunk_003", offset: 8,
            words: [word("delta0", at: 7.6, offset: 8), word("delta1", at: 7.8, offset: 8)]
                + timed(16..<40, offset: 8)
                + fresh.enumerated().map { word($1, at: 20 + Double($0) * 0.5, offset: 8) },
            speaker: "C"
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second, third]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        var seen = Set<String>()
        var repeated: [String] = []
        if words.count >= 8 {
            for start in 0...(words.count - 8) {
                let gram = words[start..<(start + 8)].joined(separator: " ")
                if !seen.insert(gram).inserted { repeated.append(gram) }
            }
        }
        #expect(repeated.isEmpty, "repeated 8-grams: \(repeated)")
        #expect(words.count == spoken.count + fresh.count + 2, "got \(words)")
    }

    @Test("an overlap squeezed onto one timestamp is still recognised")
    func anOverlapSqueezedOntoOneTimestampIsStillRecognised() async throws {
        // ES2003a's Cohere run put whole phrases on a single timestamp,
        // and 193% DER with 266 insertions followed. A word matches by
        // what it says inside a band either side of when the other
        // chunk says it, so a squeezed phrase is deduplicated rather
        // than doubled, and the seconds around it survive.
        let spoken = (0..<40).map { "alpha\($0)" }
        let fresh = (0..<8).map { "omega\($0)" }
        func word(_ text: String, at start: Double, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start - offset, end: start + 0.4 - offset, text: " \(text)")
        }
        func segment(_ words: [RawTranscriptWord], speaker: String) -> RawTranscriptSegment {
            RawTranscriptSegment(
                start: words[0].start, end: words[words.count - 1].end,
                text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                speaker: speaker, words: words
            )
        }
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [segment(
                spoken.enumerated().map { word($1, at: Double($0) * 0.5, offset: 0) },
                speaker: "A"
            )]
        )
        // The same eight words the first chunk spreads over 12 to 15.5 s,
        // all reported at 13 s, and then a gap until 20.5 s.
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 12,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [
                segment((24..<32).map { word(spoken[$0], at: 13, offset: 12) }, speaker: "B"),
                segment(
                    fresh.enumerated().map { word($1, at: 20.5 + Double($0) * 0.5, offset: 12) },
                    speaker: "B"
                ),
            ]
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        let missing = (spoken + fresh).filter { !words.contains($0) }
        #expect(missing.isEmpty, "words lost at the seam: \(missing)")
        #expect(words.count == spoken.count + fresh.count, "got \(words)")
    }

    @Test("a refused alignment keeps its words as the later side of a seam")
    func aRefusedAlignmentKeepsItsWordsAsTheLaterSideOfASeam() async throws {
        // An alignment that refuses leaves one segment holding the whole
        // chunk's text and no timings, starting where the chunk starts.
        // The midpoint cut read that start, decided the segment belonged
        // before the cut, and dropped every word in it: 2 of 16 chunks
        // refused on one ES2002b Cohere run and took 118 transcribed
        // words with them, which is most of why that engine swung 6.6
        // WER points on identical audio.
        let spoken = (0..<40).map { "alpha\($0)" }
        let continued = (0..<54).map { "omega\($0)" }
        func word(_ text: String, at start: Double, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start - offset, end: start + 0.4 - offset, text: " \(text)")
        }
        // Aligned words for the first twenty seconds.
        let aligned = spoken.enumerated().map { word($1, at: Double($0) * 0.5, offset: 0) }
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [RawTranscriptSegment(
                start: aligned[0].start, end: aligned[aligned.count - 1].end,
                text: spoken.joined(separator: " "), speaker: "A", words: aligned
            )]
        )
        // The next chunk covers 12 s to 47 s and its alignment refused:
        // one wordless segment over the whole chunk, opening on the
        // eight seconds it shares with the chunk before it.
        let refusedText = (Array(spoken[24...]) + continued).joined(separator: " ")
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 12,
            durationSeconds: 35, model: "cohere", responseFormat: "local_text",
            segments: [RawTranscriptSegment(
                start: 0, end: 35, text: refusedText, speaker: nil, words: nil
            )]
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        let missing = (spoken + continued).filter { !words.contains($0) }
        #expect(missing.isEmpty, "the refused chunk was discarded: \(missing)")
        #expect(words.count == spoken.count + continued.count, "got \(words)")
    }

    @Test("a refused alignment does not swallow the chunk after it")
    func aRefusedAlignmentDoesNotSwallowTheChunkAfterIt() async throws {
        // The same segment as the earlier side of a seam: it starts
        // before any cut, so it was kept whole and spilled across it
        // while the chunk after it lost everything it heard before the
        // cut, including the words the refused chunk never carried.
        let spoken = (0..<70).map { "alpha\($0)" }
        let continued = (0..<10).map { "omega\($0)" }
        func word(_ text: String, at start: Double, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start - offset, end: start + 0.4 - offset, text: " \(text)")
        }
        let first = RawTranscriptChunk(
            id: "remote_chunk_001", track: .remote, timelineOffset: 0,
            durationSeconds: 35, model: "cohere", responseFormat: "local_text",
            segments: [RawTranscriptSegment(
                start: 0, end: 35, text: spoken.joined(separator: " "),
                speaker: nil, words: nil
            )]
        )
        // Aligned words from 23 s, so twelve seconds of what the refused
        // chunk already carries arrive again with timings on them, and
        // two words it missed arrive with them.
        let aligned = [word("delta0", at: 23.6, offset: 23), word("delta1", at: 23.8, offset: 23)]
            + (48..<70).map { word(spoken[$0], at: Double($0) * 0.5, offset: 23) }
            + continued.enumerated().map { word($1, at: 35 + Double($0) * 0.5, offset: 23) }
        let second = RawTranscriptChunk(
            id: "remote_chunk_002", track: .remote, timelineOffset: 23,
            durationSeconds: 35, model: "cohere", responseFormat: "local_words",
            segments: [RawTranscriptSegment(
                start: aligned[0].start, end: aligned[aligned.count - 1].end,
                text: aligned.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                speaker: "B", words: aligned
            )]
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        var seen = Set<String>()
        var repeated: [String] = []
        if words.count >= 8 {
            for start in 0...(words.count - 8) {
                let gram = words[start..<(start + 8)].joined(separator: " ")
                if !seen.insert(gram).inserted { repeated.append(gram) }
            }
        }
        #expect(repeated.isEmpty, "repeated 8-grams: \(repeated)")
        let missing = (spoken + continued + ["delta0", "delta1"])
            .filter { !words.contains($0) }
        #expect(missing.isEmpty, "words lost at the seam: \(missing)")
        #expect(words.count == spoken.count + continued.count + 2, "got \(words)")
    }

    @Test("two chunks that say the same thing minutes apart both keep it")
    func twoChunksThatSayTheSameThingMinutesApartBothKeepIt() async throws {
        // Two bounds keep the seam a seam: a chunk is compared against
        // the words that still reach it in time, and only inside the
        // span the two chunks share. Where one side has no timings,
        // which is every chunk whose aligner refused, they are all that
        // is left, because such a word pairs on what it says and on
        // nothing else. A meeting says "we should ship the new build on
        // friday if the tests pass" at 0 s, and a refused chunk forty
        // seconds later says it again; both are the meeting. Either
        // bound alone covers this fixture, so it is the pair being
        // pinned: drop both and the second "we" goes.
        let sentence = "we should ship the new build on friday if the tests pass"
            .components(separatedBy: " ")
        let between = (0..<45).map { "omega\($0)" }
        func word(_ text: String, at start: Double, offset: Double) -> RawTranscriptWord {
            RawTranscriptWord(start: start - offset, end: start + 0.4 - offset, text: " \(text)")
        }
        func timed(
            _ id: String, offset: Double, words: [RawTranscriptWord], speaker: String
        ) -> RawTranscriptChunk {
            RawTranscriptChunk(
                id: id, track: .remote, timelineOffset: offset,
                durationSeconds: 35, model: "cohere", responseFormat: "local_words",
                segments: [RawTranscriptSegment(
                    start: words[0].start, end: words[words.count - 1].end,
                    text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                    speaker: speaker, words: words
                )]
            )
        }
        let first = timed(
            "remote_chunk_001", offset: 0,
            words: sentence.enumerated().map { word($1, at: Double($0) * 0.5, offset: 0) },
            speaker: "A"
        )
        // Twenty-two seconds of other talk, running two seconds past
        // where the third chunk opens, so the third chunk does have
        // words to compare and it is the bounds that spare them.
        let second = timed(
            "remote_chunk_002", offset: 20,
            words: between.enumerated().map { word($1, at: 20 + Double($0) * 0.5, offset: 20) },
            speaker: "B"
        )
        // The aligner refused here: one wordless segment over the whole
        // chunk, so its words pair on text alone.
        let third = RawTranscriptChunk(
            id: "remote_chunk_003", track: .remote, timelineOffset: 40,
            durationSeconds: 35, model: "cohere", responseFormat: "local_text",
            segments: [RawTranscriptSegment(
                start: 0, end: 35, text: sentence.joined(separator: " "),
                speaker: nil, words: nil
            )]
        )

        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [first, second, third]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        let words = transcript.utterances.flatMap { TextSimilarity.normalise($0.text) }
        #expect(
            words == sentence + between + sentence,
            "a repeat outside the shared span is not a seam"
        )
        #expect(words.filter { $0 == "friday" }.count == 2, "got \(words)")
    }

    @Test("the diarizer the user chose beats labels embedded in the words")
    func theDiarizerTheUserChoseBeatsLabelsEmbeddedInTheWords() async throws {
        // Cloud transcription with diarization set to Local ran the
        // local diarizer, wrote an active run with the right four
        // speakers, and then assembled the transcriber's own ten
        // chunk-scoped labels anyway. The run comes from a different
        // producer than the words, so it is the answer the user asked
        // for and it wins on the first pass.
        var words = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
            RawTranscriptSegment(start: 0, end: 4, text: "One two.", speaker: "spk_0"),
            RawTranscriptSegment(start: 6, end: 9, text: "Three four.", speaker: "spk_1"),
        ])
        words.model = "gpt-4o-transcribe-diarize"
        func run(backend: String) -> RawDiarization {
            RawDiarization(runs: [DiarizationRun(
                id: "run-local", track: .mic, backend: backend,
                producedAt: Date(timeIntervalSince1970: 0), timelineOffset: 0,
                intervals: [
                    DiarizationInterval(start: 0, end: 5, clusterID: "S1"),
                    DiarizationInterval(start: 5, end: 10, clusterID: "S2"),
                ]
            )])
        }

        let local = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [words]),
            diarization: run(backend: "fluidaudio-offline-0.15.6"),
            micTrackIsLocalUser: false,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(local.utterances.count == 2)
        #expect(local.utterances[0].speakerKey == "run-local_speaker_00")
        #expect(local.utterances[1].speakerKey == "run-local_speaker_01")

        // Cloud words with a cloud diarizer: the run carries the same
        // producer as the words, so the embedded labels stand.
        let cloud = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [words]),
            diarization: run(backend: "gpt-4o-transcribe-diarize"),
            micTrackIsLocalUser: false,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(cloud.utterances[0].speakerKey == "mic_chunk_001_speaker_spk_0")
        #expect(cloud.utterances[1].speakerKey == "mic_chunk_001_speaker_spk_1")
    }

    @Test("an in-person recording keeps the raw labels on its only track")
    func anInPersonRecordingKeepsTheRawLabelsOnItsOnlyTrack() async throws {
        let mic = chunk(id: "mic_chunk_001", track: .mic, offset: 0, segments: [
            RawTranscriptSegment(start: 1, end: 3, text: "Morning.", speaker: "A"),
            RawTranscriptSegment(start: 4, end: 6, text: "Morning to you.", speaker: "B"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [mic]),
            micTrackIsLocalUser: false,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(transcript.utterances[0].speakerKey == "mic_chunk_001_speaker_00")
        #expect(transcript.utterances[1].speakerKey == "mic_chunk_001_speaker_01")
        #expect(transcript.utterances[0].speakerKey != SpeakerLabel.localUser)
    }

    @Test("consecutive segments from one speaker read as one turn")
    func consecutiveSegmentsFromOneSpeakerReadAsOneTurn() async throws {
        let remote = chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
            RawTranscriptSegment(start: 0, end: 0.4, text: "Hey,", speaker: "A"),
            RawTranscriptSegment(start: 0.5, end: 0.9, text: "Marlow,", speaker: "A"),
            RawTranscriptSegment(start: 1.0, end: 1.6, text: "Bryn here.", speaker: "A"),
            RawTranscriptSegment(start: 4.0, end: 5.0, text: "This is Owen.", speaker: "B"),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: RawTranscript(chunks: [remote]),
            micTrackIsLocalUser: true,
            generatedAt: Date(timeIntervalSince1970: 0)
        )
        #expect(transcript.utterances.count == 2)
        #expect(transcript.utterances[0].text == "Hey, Marlow, Bryn here.")
        #expect(
            abs(transcript.utterances[0].end - 1.6) <= 0.001,
            "expected \(1.6) ± \(0.001), got \(transcript.utterances[0].end)"
        )
    }

    @Test("renaming a speaker changes the rendering, not the raw data")
    func renamingASpeakerChangesTheRenderingNotTheRawData() async throws {
        let raw = RawTranscript(chunks: [
            chunk(id: "remote_chunk_001", track: .remote, offset: 0, segments: [
                RawTranscriptSegment(start: 0, end: 2, text: "Bryn here.", speaker: "A"),
            ]),
        ])
        let transcript = TranscriptAssembler().assemble(
            raw: raw, micTrackIsLocalUser: true, generatedAt: Date(timeIntervalSince1970: 0)
        )
        var speakers = SpeakerMap.withLocalUser(named: "Marlow")
        let renderer = TranscriptRenderer()

        let before = renderer.markdown(
            transcript: transcript, speakers: speakers, title: "Sync",
            startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 2,
            participants: []
        )
        #expect(before.contains("Speaker 1"), "unnamed speakers get a readable fallback")

        speakers.assign("Bryn", to: "remote_chunk_001_speaker_00")
        let after = renderer.markdown(
            transcript: transcript, speakers: speakers, title: "Sync",
            startedAt: Date(timeIntervalSince1970: 0), durationSeconds: 2,
            participants: []
        )
        #expect(after.contains("Bryn"))
        #expect(!after.contains("Speaker 1"))
        // The raw response is untouched by the rename.
        #expect(raw.chunks[0].segments[0].speaker == "A")
    }

    @Test("a human name is never overwritten by a suggestion")
    func aHumanNameIsNeverOverwrittenByASuggestion() async throws {
        var speakers = SpeakerMap()
        speakers.assign("Bryn", to: "remote_chunk_001_speaker_00")
        speakers.applySuggestion(
            SpeakerAssignment(displayName: "Owen", origin: .ai, confidence: 0.98),
            for: "remote_chunk_001_speaker_00"
        )
        #expect(speakers.resolvedName(for: "remote_chunk_001_speaker_00") == "Bryn")

        // A label the user has not named does take the suggestion.
        speakers.applySuggestion(
            SpeakerAssignment(displayName: "Owen", origin: .ai, confidence: 0.9),
            for: "remote_chunk_001_speaker_01"
        )
        #expect(speakers.resolvedName(for: "remote_chunk_001_speaker_01") == "Owen")
        // And a human correction wins over the suggestion afterwards.
        speakers.assign("John", to: "remote_chunk_001_speaker_01")
        #expect(speakers.entries["remote_chunk_001_speaker_01"]?.origin == .human)
    }

    @Test("similar text is recognised, unrelated text is not")
    func similarTextIsRecognisedUnrelatedTextIsNot() async throws {
        #expect(
            TextSimilarity.score(
                "The second pass is the slow one.", "the second pass is the slow one"
            ) > 0.9
        )
        #expect(
            TextSimilarity.score("Would that affect latency?", "Agreed, let's cache it.") < 0.2
        )
    }
}
