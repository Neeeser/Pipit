import Foundation
import PipitAudio
import PipitBench
import PipitCore
import PipitLocalAI

/// Replays a recorded meeting as if it were happening now and transcribes it
/// the way a live transcript would: each track scored by the voice detector a
/// window at a time, cut into phrases at pauses, and each phrase sent through
/// Parakeet as soon as it closes.
///
/// Two clocks. `--pace 1` feeds the audio at the speed it was recorded and
/// reports what a person watching would have seen, wall clock and all, with
/// the processor and memory the work cost. `--pace 0` runs as fast as the
/// machine allows and replays the timing: every phrase is queued at the moment
/// it would have closed, both tracks share the one model, and each waits for
/// the phrase ahead of it. The model calls are real in both, so the delays
/// are measured, not estimated.
///
/// The live text is scored against the meeting's own post-call transcript,
/// track by track. Nothing is written to the meeting. Phrase text reaches the
/// screen only with `--show-text` and a file only with `--json`, so the
/// default output carries no meeting content.
enum LiveCommand {
    struct Options {
        var meeting: URL
        var applicationSupport: URL
        var pace: Double
        var limitSeconds: Double?
        var showText: Bool
        var json: URL?
        /// Reads the echo-cancelled microphone track instead of the raw one.
        /// A live transcript only has the raw one, so this separates what
        /// phrase cutting costs from what echo costs.
        var cleanedMic: Bool
        var engine: LocalTranscriptionModel
        /// The longest phrase before it is cut mid-speech, for trying a
        /// shorter wait for the first word against the accuracy it costs.
        var maximumPhraseSeconds: Double?
    }

    struct PhraseRecord: Codable {
        var track: String
        var audioStart: Double
        var audioEnd: Double
        var speechEnd: Double
        var closedAt: Double
        var queuedSeconds: Double
        var modelSeconds: Double
        /// From the moment the speaker stopped to the moment the text exists.
        var delayAfterSpeech: Double
        /// From the first word of the phrase to the moment the text exists:
        /// the longest any word in it waited.
        var delayFromStart: Double
        /// False for an engine's volatile guess, which later text replaces.
        var isFinal: Bool = true
        var text: String
    }

    struct TrackAudio {
        var name: String
        /// The track's name in the saved transcript.
        var reference: String
        var file: URL
        var samples: [Float]
    }

    static let windowSeconds = Double(LiveVoiceActivity.windowSamples) / 16_000

    static func run(_ options: Options) async -> Int32 {
        let audioFolder = options.meeting.appendingPathComponent("raw/audio", isDirectory: true)
        let micFile = audioFolder.appendingPathComponent(options.cleanedMic ? "mic.cleaned.m4a" : "mic.m4a")
        let systemFile = audioFolder.appendingPathComponent("system.m4a")
        var tracks: [TrackAudio] = []
        for (name, reference, file) in [("mic", "mic", micFile), ("system", "remote", systemFile)] {
            guard FileManager.default.fileExists(atPath: file.path) else {
                note("live: no \(file.lastPathComponent), skipping that track")
                continue
            }
            do {
                var samples = try MonoAudioDecoder.loadMono16k(file)
                if let limit = options.limitSeconds, samples.count > Int(limit * 16_000) {
                    samples = Array(samples.prefix(Int(limit * 16_000)))
                }
                tracks.append(TrackAudio(name: name, reference: reference, file: file, samples: samples))
            } catch {
                note("live: cannot decode \(file.lastPathComponent): \(error)")
                return 1
            }
        }
        guard !tracks.isEmpty else { return 1 }

        let support = options.engine.liveTranscription
        guard support != .none else {
            note("live: \(options.engine.rawValue) writes its transcript after the meeting only")
            return 2
        }
        let manager = LocalModelManager(applicationSupport: options.applicationSupport)
        // A streaming engine brings its own model; the phrase path needs
        // Parakeet and the voice detector.
        if support == .phrases {
            do {
                _ = try await manager.install(units: [.parakeet, .voiceActivity])
                // The first call compiles and warms the model. Paid once when a
                // recording starts, not once per phrase, so it is kept out of the
                // per-phrase numbers and reported on its own.
                let warm = Date()
                _ = try await manager.transcribeLivePhrase(Array(repeating: 0, count: 16_000))
                note(String(format: "live: model warm in %.2fs", Date().timeIntervalSince(warm)))
            } catch {
                note("live: models unavailable: \(error)")
                return 1
            }
        }

        var tuning = LiveSpeechSegmenter.Tuning.default
        if let seconds = options.maximumPhraseSeconds {
            tuning.maximumWindows = max(2, Int((seconds / windowSeconds).rounded()))
        }

        let usageBefore = processorSeconds()
        let wallBefore = Date()
        let records: [PhraseRecord]
        do {
            if support == .streaming {
                records = try await streamed(tracks, pace: options.pace, showText: options.showText)
            } else if options.pace > 0 {
                records = try await paced(
                    tracks, manager: manager, tuning: tuning, pace: options.pace, showText: options.showText)
            } else {
                records = try await replayed(tracks, manager: manager, tuning: tuning, showText: options.showText)
            }
        } catch {
            note("live: \(error)")
            return 1
        }
        let wall = Date().timeIntervalSince(wallBefore)
        let processor = processorSeconds() - usageBefore
        let audioSeconds = tracks.map { Double($0.samples.count) / 16_000 }.max() ?? 0

        // The same engine over each whole track, the way the post-call pass
        // runs it, so the live text is scored against what that engine would
        // have written after the call on the same audio. The saved transcript
        // is the second reference: it is what the owner reads, but it was
        // made by whichever engine the meeting used, from the cleaned
        // microphone, with the speech gate applied.
        var afterCall: [String: [String]] = [:]
        let backend: any TranscriptionBackend =
            support == .streaming
            ? AppleSpeechTranscriptionBackend() : ParakeetTranscriptionBackend(models: manager)
        for track in tracks {
            do {
                let output = try await backend.transcribe(audio: track.file) { _ in }
                afterCall[track.name] = output.segments.filter { $0.start < audioSeconds }.map(\.text)
            } catch {
                note("live: after-call pass on \(track.name) failed: \(error)")
            }
        }

        report(
            records: records, tracks: tracks, meeting: options.meeting, afterCall: afterCall,
            audioSeconds: audioSeconds, wall: wall, processor: processor,
            delaysMeaningful: options.pace > 0 || support == .phrases,
            mode: options.pace > 0
                ? "real time x\(options.pace)"
                : support == .phrases ? "fast replay, real-time queueing" : "fast, text only"
        )
        if let json = options.json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(records).write(to: json, options: .atomic)
                print("wrote           \(json.path)")
            } catch {
                note("live: cannot write \(json.path): \(error)")
            }
        }
        return 0
    }

    // MARK: - fast replay

    /// Every phrase each track would have produced, with the audio time its
    /// closing window arrived.
    private static func phrases(
        of track: TrackAudio, detector: LiveVoiceActivity, tuning: LiveSpeechSegmenter.Tuning
    ) async throws -> [(phrase: LiveSpeechSegmenter.Phrase, closedAt: Double)] {
        var segmenter = LiveSpeechSegmenter(tuning: tuning)
        var out: [(LiveSpeechSegmenter.Phrase, Double)] = []
        let window = LiveVoiceActivity.windowSamples
        var offset = 0
        var index = 0
        while offset + window <= track.samples.count {
            let probability = try await detector.probability(Array(track.samples[offset..<offset + window]))
            if let phrase = segmenter.push(probability) {
                out.append((phrase, Double(index + 1) * windowSeconds))
            }
            offset += window
            index += 1
        }
        if let phrase = segmenter.finish() {
            out.append((phrase, Double(index) * windowSeconds))
        }
        return out
    }

    private static func replayed(
        _ tracks: [TrackAudio], manager: LocalModelManager, tuning: LiveSpeechSegmenter.Tuning, showText: Bool
    ) async throws -> [PhraseRecord] {
        var queue: [(track: TrackAudio, phrase: LiveSpeechSegmenter.Phrase, closedAt: Double)] = []
        for track in tracks {
            let detector = try await manager.liveVoiceActivity()
            for found in try await phrases(of: track, detector: detector, tuning: tuning) {
                queue.append((track, found.phrase, found.closedAt))
            }
        }
        queue.sort { $0.closedAt < $1.closedAt }

        // One model, shared by both tracks, so a phrase that closes while the
        // model is busy waits for it.
        var busyUntil = 0.0
        var records: [PhraseRecord] = []
        for item in queue {
            let samples = slice(item.track.samples, item.phrase)
            let started = Date()
            let text = try await manager.transcribeLivePhrase(samples)
            let modelSeconds = Date().timeIntervalSince(started)
            let begins = max(item.closedAt, busyUntil)
            busyUntil = begins + modelSeconds
            let record = PhraseRecord(
                track: item.track.name,
                audioStart: Double(item.phrase.start) * windowSeconds,
                audioEnd: Double(item.phrase.end) * windowSeconds,
                speechEnd: Double(item.phrase.lastSpeechEnd) * windowSeconds,
                closedAt: item.closedAt,
                queuedSeconds: begins - item.closedAt,
                modelSeconds: modelSeconds,
                delayAfterSpeech: busyUntil - Double(item.phrase.lastSpeechEnd) * windowSeconds,
                delayFromStart: busyUntil - Double(item.phrase.start + 1) * windowSeconds,
                text: text.text
            )
            if showText { printLine(record) }
            records.append(record)
        }
        return records
    }

    // MARK: - real-time replay

    private actor Collector {
        var records: [PhraseRecord] = []
        func add(_ record: PhraseRecord) { records.append(record) }
    }

    private static func paced(
        _ tracks: [TrackAudio], manager: LocalModelManager, tuning: LiveSpeechSegmenter.Tuning, pace: Double,
        showText: Bool
    ) async throws -> [PhraseRecord] {
        let collector = Collector()
        let origin = Date()
        // The wall clock moment a given audio time is fed in.
        let wallAt: @Sendable (Double) -> Date = { origin.addingTimeInterval($0 / pace) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for track in tracks {
                let detector = try await manager.liveVoiceActivity()
                // The capture side hands closed phrases to a transcriber of
                // its own, so a slow phrase delays the next phrase's text and
                // never the audio.
                let (closed, closing) = AsyncStream<(LiveSpeechSegmenter.Phrase, Double)>.makeStream()
                group.addTask {
                    defer { closing.finish() }
                    var segmenter = LiveSpeechSegmenter(tuning: tuning)
                    let window = LiveVoiceActivity.windowSamples
                    var offset = 0
                    var index = 0
                    while offset + window <= track.samples.count {
                        let arrives = wallAt(Double(index + 1) * windowSeconds)
                        let wait = arrives.timeIntervalSinceNow
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                        let probability = try await detector.probability(
                            Array(track.samples[offset..<offset + window]))
                        if let phrase = segmenter.push(probability) {
                            closing.yield((phrase, Double(index + 1) * windowSeconds))
                        }
                        offset += window
                        index += 1
                    }
                }
                group.addTask {
                    for await (phrase, closedAt) in closed {
                        let samples = slice(track.samples, phrase)
                        let started = Date()
                        let text = try await manager.transcribeLivePhrase(samples)
                        let done = Date()
                        let record = PhraseRecord(
                            track: track.name,
                            audioStart: Double(phrase.start) * windowSeconds,
                            audioEnd: Double(phrase.end) * windowSeconds,
                            speechEnd: Double(phrase.lastSpeechEnd) * windowSeconds,
                            closedAt: closedAt,
                            queuedSeconds: max(0, started.timeIntervalSince(wallAt(closedAt))),
                            modelSeconds: done.timeIntervalSince(started),
                            delayAfterSpeech: done.timeIntervalSince(
                                wallAt(Double(phrase.lastSpeechEnd) * windowSeconds)),
                            delayFromStart: done.timeIntervalSince(
                                wallAt(Double(phrase.start + 1) * windowSeconds)),
                            text: text.text
                        )
                        if showText { printLine(record) }
                        await collector.add(record)
                    }
                }
            }
            try await group.waitForAll()
        }
        return await collector.records.sorted { $0.closedAt < $1.closedAt }
    }

    // MARK: - streaming engine

    /// Apple's SpeechAnalyzer, one per track, fed a window at a time. Every
    /// result is kept: the volatile ones say how fresh the guess on screen
    /// is, the final ones are the text that stays.
    ///
    /// At `--pace 0` the audio goes in as fast as the analyzer takes it, so
    /// the delays measure nothing a person would see; only the text counts.
    private static func streamed(
        _ tracks: [TrackAudio], pace: Double, showText: Bool
    ) async throws -> [PhraseRecord] {
        #if compiler(>=6.2)
            guard #available(macOS 26.0, *) else { throw AppleSpeechError.requiresNewerMacOS }
            let collector = Collector()
            let origin = Date()
            let speed = pace > 0 ? pace : 1
            let wallAt: @Sendable (Double) -> Date = { origin.addingTimeInterval($0 / speed) }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for track in tracks {
                    let live = try await AppleLiveTranscriber.start()
                    group.addTask {
                        let window = LiveVoiceActivity.windowSamples
                        var offset = 0
                        while offset + window <= track.samples.count {
                            if pace > 0 {
                                let wait = wallAt(Double(offset + window) / 16_000).timeIntervalSinceNow
                                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                            }
                            await live.feed(Array(track.samples[offset..<offset + window]))
                            offset += window
                        }
                        try await live.finish()
                    }
                    group.addTask {
                        for try await result in live.results {
                            let done = Date()
                            let record = PhraseRecord(
                                track: track.name, audioStart: result.start, audioEnd: result.end,
                                speechEnd: result.end, closedAt: result.end, queuedSeconds: 0, modelSeconds: 0,
                                delayAfterSpeech: done.timeIntervalSince(wallAt(result.end)),
                                delayFromStart: done.timeIntervalSince(wallAt(result.start)),
                                isFinal: result.isFinal, text: result.text
                            )
                            if showText, result.isFinal { printLine(record) }
                            await collector.add(record)
                        }
                    }
                }
                try await group.waitForAll()
            }
            return await collector.records
        #else
            throw AppleSpeechError.requiresNewerMacOS
        #endif
    }

    // MARK: - report

    private static func slice(_ samples: [Float], _ phrase: LiveSpeechSegmenter.Phrase) -> [Float] {
        let window = LiveVoiceActivity.windowSamples
        let start = min(phrase.start * window, samples.count)
        let end = min(phrase.end * window, samples.count)
        return Array(samples[start..<end])
    }

    private static func printLine(_ record: PhraseRecord) {
        let label = record.track == "mic" ? "me" : "them"
        print(
            String(
                format: "[%@ +%.1fs] %@: %@", clock(record.audioStart), record.delayAfterSpeech, label,
                record.text))
    }

    private static func clock(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private static func wordError(reference: [String], live: [String]) -> String {
        let reference = BenchScorer.normalise(reference.joined(separator: " "))
        let distance = BenchScorer.editDistance(reference: reference, hypothesis: live)
        let wer = reference.isEmpty ? 0 : Double(distance.distance) / Double(reference.count)
        return String(
            format: "%5.1f%% of %d (sub %d, ins %d, del %d)", 100 * wer, reference.count,
            distance.substitutions, distance.insertions, distance.deletions)
    }

    private static func report(
        records: [PhraseRecord], tracks: [TrackAudio], meeting: URL, afterCall: [String: [String]],
        audioSeconds: Double, wall: Double, processor: Double, delaysMeaningful: Bool, mode: String
    ) {
        let final = finalTranscript(meeting: meeting)
        print("mode            \(mode)")
        print(String(format: "audio           %.0fs per track, %d tracks", audioSeconds, tracks.count))
        print(String(format: "wall            %.1fs", wall))
        print(
            String(
                format: "processor       %.1fs, %.1f%% of one core over the run", processor,
                100 * processor / max(wall, 0.001)))
        print("peak resident   \(megabytes(peakResidentBytes()))")
        print("")
        print("track   phrases  after-speech p50/p90/max   from-start p50/p90   model p50/p90   live words")
        for track in tracks {
            let mine = records.filter { $0.track == track.name && $0.isFinal }
            let after = mine.map(\.delayAfterSpeech).sorted()
            let fromStart = mine.map(\.delayFromStart).sorted()
            let model = mine.map(\.modelSeconds).sorted()
            let live = BenchScorer.normalise(mine.map(\.text).joined(separator: " "))
            let delays =
                delaysMeaningful
                ? String(
                    format: "%5.1f / %5.1f / %5.1f s   %5.1f / %5.1f s", percentile(after, 0.5),
                    percentile(after, 0.9), after.last ?? 0, percentile(fromStart, 0.5),
                    percentile(fromStart, 0.9))
                : "      not measured at this pace       "
            print(
                String(
                    format: "%-7@ %7d   %@   %4.2f / %4.2f s   %6d", track.name, mine.count, delays,
                    percentile(model, 0.5), percentile(model, 0.9), live.count))
            let sameEngine = wordError(reference: afterCall[track.name] ?? [], live: live)
            print("        vs same engine after the call  \(sameEngine)")
            // Only the words inside the replayed span count, so a `--seconds`
            // run is scored against the same stretch of the call.
            let saved = (final[track.reference] ?? []).filter { $0.start < audioSeconds }.map(\.text)
            print("        vs saved meeting transcript    \(wordError(reference: saved, live: live))")
        }
        let guesses = records.filter { !$0.isFinal }.map(\.delayAfterSpeech).sorted()
        if !guesses.isEmpty {
            print(
                String(
                    format: "volatile text   %d updates, behind the audio p50 %.1f s, p90 %.1f s",
                    guesses.count, percentile(guesses, 0.5), percentile(guesses, 0.9)))
        }
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
    }

    private struct FinalUtterance: Decodable {
        var start: Double
        var text: String
        var track: String
    }

    private struct FinalTranscript: Decodable {
        var utterances: [FinalUtterance]
    }

    /// The post-call transcript's utterances, by track, in time order.
    private static func finalTranscript(meeting: URL) -> [String: [FinalUtterance]] {
        let file = meeting.appendingPathComponent("raw/transcript.json")
        guard let data = try? Data(contentsOf: file),
            let decoded = try? JSONDecoder().decode(FinalTranscript.self, from: data)
        else {
            note("live: no post-call transcript to score against")
            return [:]
        }
        return Dictionary(grouping: decoded.utterances.sorted { $0.start < $1.start }, by: \.track)
    }

    private static func processorSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }
}
