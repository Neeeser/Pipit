import AVFoundation
import Foundation
import PipitAudio
import PipitCore

/// Two-track recordings whose echo path is known, and the measurements taken
/// on them.
///
/// The problem they stand for, measured on a huddle of 3 September 2026: most
/// of the words on the microphone were the far end's, arriving through the air
/// from the speakers.
public enum MicrophoneCleaningFixtures {
    public static let rate = 16_000.0
    /// The far end's voice and the user's, from the system's own speech
    /// synthesis. The canceller that ships is a network trained on speech: it
    /// takes a steady tone for something to remove, and a tone repeats every
    /// period, so an echo of one can be lined up at any multiple of the
    /// period and never tests the alignment. Speech is what the pass is for.
    public static let farVoice = "Daniel"
    public static let userVoice = "Karen"
    /// Tones, for the fixtures that never run the canceller and only need a
    /// signal a Goertzel probe can find again: compaction, the pipeline's
    /// track routing, a far end that never played. None divides 16 kHz into
    /// a whole number of samples.
    public static let farToneA = 440.0
    public static let farToneB = 950.0
    public static let nearTone = 1_300.0
    /// What the room does to the far end on its way back to the capsule: a
    /// third of the level, 3 ms across the desk.
    public static let echoGain: Float = 0.35
    public static let echoDelaySamples = 48

    /// Sentences long enough to fill a call, with natural pauses between them.
    static let farText = [
        "We should look at the deployment plan before Friday and decide who owns the follow up.",
        "The second cluster is still on the old build, so the migration has to wait for the window.",
        "If the numbers hold up we can move the review to Tuesday and give everyone the morning back.",
        "Let me share the dashboard and walk through the three alerts from last night.",
    ]
    static let userText = [
        "I think the budget needs another pass before we commit to that date.",
        "Can we keep the old cluster running until the second window closes?",
        "That works for me, and I will send the notes out this afternoon.",
    ]

    private static let speechCache = SpeechCache()

    /// A voice reading a text, as 16 kHz mono samples. Rendered once per
    /// process by the system's speech synthesis and cached, so every fixture
    /// hears the same audio.
    public static func speech(voice: String, text: String) -> [Float] {
        speechCache.samples(voice: voice, text: text)
    }

    /// `count` samples of one voice reading its sentences in turn with
    /// `gapSeconds` of silence between them, starting over when they run out.
    public static func talking(
        voice: String, texts: [String], count: Int, gapSeconds: Double = 0.6
    ) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        var at = 0
        var index = 0
        let gap = Int(gapSeconds * rate)
        while at < count {
            let sentence = speech(voice: voice, text: texts[index % texts.count])
            let take = min(sentence.count, count - at)
            for offset in 0..<take { out[at + offset] = sentence[offset] }
            at += take + gap
            index += 1
        }
        return out
    }

    /// Broadband energy per sample.
    public static func energy(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
    }

    // MARK: - building a meeting

    /// A recorded two-track meeting whose audio is exactly the samples given.
    ///
    /// `remoteStartOffset` puts the far end's first frame that many seconds
    /// after the microphone's, which is what a real recording looks like: the
    /// remote writer opens on the first packet from the meeting application,
    /// and that is always after the microphone begins.
    public static func makeMeeting(
        root: URL, source: MeetingSource = .slackHuddle,
        mic: [Float], remote: [Float]?, remoteStartOffset: Double = 0
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let repository = MeetingRepository(root: root)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: source, provider: source.provider, startedAt: started,
            titles: TitleCandidates(provider: "Huddle", timestampFallback: "fallback"),
            now: started
        )
        let manifest = try ManifestWriter(url: created.store.layout.manifest)
        manifest.append(
            .sessionStart(
                .init(
                    meetingID: created.metadata.id, source: source, segmentSeconds: 600,
                    appVersion: "test", processID: 1
                )))
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!

        let micWriter = SegmentWriter(
            track: .mic, layout: created.store.layout, manifest: manifest,
            format: format, segmentSeconds: 600
        )
        micWriter.enqueueSynchronously(AudioBufferPacket(buffer: buffer(mic, format: format), hostTime: 100))
        micWriter.finish(reason: "test")

        if let remote {
            let remoteWriter = SegmentWriter(
                track: .remote, layout: created.store.layout, manifest: manifest,
                format: format, segmentSeconds: 600
            )
            remoteWriter.enqueueSynchronously(
                AudioBufferPacket(
                    buffer: buffer(remote, format: format), hostTime: 100 + remoteStartOffset
                ))
            remoteWriter.finish(reason: "test")
        }
        let seconds = Double(mic.count) / rate
        manifest.append(
            .sessionEnd(
                .init(
                    reason: "test", micSeconds: seconds,
                    remoteSeconds: remote.map { Double($0.count) / rate } ?? 0
                )))
        manifest.close()

        var metadata = created.metadata
        metadata.endedAt = started.addingTimeInterval(seconds)
        metadata.durationSeconds = seconds
        metadata.processing = ProcessingStatus(state: .audioSafe, updatedAt: started)
        try created.store.writeMetadata(metadata)
        return (metadata, created.store, repository)
    }

    public static func buffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer {
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        out.frameLength = AVAudioFrameCount(samples.count)
        let data = out.floatChannelData!
        for index in samples.indices { data[0][index] = samples[index] }
        return out
    }

    public static func tone(
        count: Int, frequency: Double, amplitude: Float, from: Int = 0, upTo: Int? = nil
    ) -> [Float] {
        var samples = [Float](repeating: 0, count: count)
        for index in from..<min(upTo ?? count, count) {
            samples[index] = amplitude * Float(sin(2 * Double.pi * frequency * Double(index) / rate))
        }
        return samples
    }

    /// Every sample of a track, read the way the pipeline reads it.
    public static func samples(_ location: TrackAudioLocation) throws -> [Float] {
        let stream = TrackAudioStream(
            segments: location.segments, segmentsDirectory: location.directory,
            format: AudioFormatDescriptor(sampleRate: rate, channelCount: 1)
        )
        var out: [Float] = []
        try stream.forEachBuffer(from: 0, to: location.seconds) { buffer, _ in
            if let data = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength)))
            }
            return true
        }
        return out
    }

    public static func seconds(_ from: Double, _ to: Double, of samples: [Float]) -> [Float] {
        let start = min(samples.count, Int(from * rate))
        let end = min(samples.count, Int(to * rate))
        guard end > start else { return [] }
        return Array(samples[start..<end])
    }

    /// Energy at one frequency, by the Goertzel recurrence. Broadband energy
    /// after cancellation is mostly residue from subtracting the far end, so it
    /// says nothing about the tone actually asked about.
    public static func toneEnergy(_ samples: [Float], frequency: Double) -> Double {
        AudioFixtures.toneEnergy(samples, frequency: frequency, sampleRate: rate)
    }

    public static func dropDB(from before: Double, to after: Double) -> Double {
        10 * log10((before + 1e-12) / (after + 1e-12))
    }

    /// Decibels the broadband level over one stretch came down between two
    /// tracks. Positive is level taken out. Measured over a stretch where only
    /// one party talks, this is what that party lost.
    public static func dropDB(before: [Float], after: [Float], from: Double, to: Double) -> Double {
        dropDB(from: energy(seconds(from, to, of: before)), to: energy(seconds(from, to, of: after)))
    }

    // MARK: - the two-track meeting every measurement is taken on

    /// A call on speakers. The far end talks throughout except for a pause
    /// in the middle, the user talks over seconds 10 to 18, and a third of
    /// the far end is back in the microphone 3 ms later.
    ///
    /// Every stretch below is on the microphone's clock, which is the clock
    /// the cleaned track is measured on. Seconds 12 to 16 hold the user
    /// alone: the far end pauses there, which is what lets a measurement say
    /// whether the user survived. Seconds 10 to 12 and 16 to 18 hold both.
    /// Seconds 20 to 30 hold the far end alone, which is where its removal is
    /// measured.
    ///
    /// - Parameter echoDelaySeconds: how long after the far end's own clock
    ///   its copy lands in the microphone. Positive is the room. Negative is
    ///   what a tap whose timestamps run late produces: the manifest then says
    ///   the far end arrived after the microphone heard it, which no causal
    ///   filter can model. Measured at -2.4 ms on a call of 11 September 2026.
    public static func makeCallOnSpeakers(
        root: URL, seconds: Double = 30, remoteStartOffset: Double = 2,
        echoDelaySeconds: Double = Double(echoDelaySamples) / rate
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let count = Int(seconds * rate)
        var remote = talking(voice: farVoice, texts: farText, count: count)
        let shift = Int(remoteStartOffset * rate) + Int((echoDelaySeconds * rate).rounded())
        // The pause is placed by where it lands in the microphone, so the
        // user-alone stretch sits at 12 to 16 s of the recording whatever the
        // far end's own clock says.
        let pause = max(0, Int(12 * rate) - shift)..<max(0, min(count, Int(16 * rate) - shift))
        for index in pause { remote[index] = 0 }
        var mic = [Float](repeating: 0, count: count)
        let user = talking(voice: userVoice, texts: userText, count: Int(8 * rate))
        let from = Int(10 * rate)
        for index in 0..<user.count where from + index < count { mic[from + index] = user[index] }
        for index in max(0, shift)..<count where index - shift < count {
            mic[index] += echoGain * remote[index - shift]
        }
        return try makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: remoteStartOffset
        )
    }

    /// A call whose far end talks in sentences, so the pair can be moved.
    ///
    /// Speech turns on and off, and that is the structure alignment is
    /// measured against. The far end talks throughout, and the user answers
    /// once, over seconds 14 to 20, at half the synthesiser's level. That is
    /// the shape of the recordings the alignment bars were set on: the far
    /// end carries the call, and the loudness envelope of the microphone
    /// follows it. A user who talks over a third of the call 10 dB above
    /// the echo drives the two envelopes' agreement down to 0.26 at the
    /// true offset, under the 0.40 the alignment needs to act on it.
    /// Deterministic, so a failure is reproducible.
    ///
    /// - Parameter micLostSeconds: audio the microphone dropped mid-recording
    ///   with nothing written for it, so every later sample of that track sits
    ///   that much earlier than the manifest says. Zero is a healthy recording.
    /// - Parameter micHoldsEcho: false for a call taken on headphones, where
    ///   the far end never reaches the capsule.
    public static func makeSpokenCall(
        root: URL, seconds: Double = 40, remoteStartOffset: Double = 2,
        micLostSeconds: Double = 0, micHoldsEcho: Bool = true
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let count = Int(seconds * rate)
        let remote = talking(voice: farVoice, texts: farText, count: count)
        var mic = [Float](repeating: 0, count: count)
        // The user, talking across the far end for six seconds.
        let user = talking(voice: userVoice, texts: userText, count: Int(6 * rate))
        let from = Int(14 * rate)
        for index in 0..<user.count where from + index < count { mic[from + index] = 0.5 * user[index] }
        if micHoldsEcho {
            let shift =
                Int(remoteStartOffset * rate) + echoDelaySamples - Int(micLostSeconds * rate)
            for index in max(0, shift)..<count where index - shift < count {
                mic[index] += echoGain * remote[index - shift]
            }
        }
        return try makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: remoteStartOffset
        )
    }
}

/// Speech from the system synthesiser, rendered once per voice and text.
private final class SpeechCache: @unchecked Sendable {
    private let lock = NSLock()
    private var rendered: [String: [Float]] = [:]
    private let directory: URL = {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-tests-speech-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func samples(voice: String, text: String) -> [Float] {
        let key = "\(voice)|\(text)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = rendered[key] { return cached }
        let file = directory.appendingPathComponent("\(rendered.count).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = [
            "-v", voice, "-r", "175", "--data-format=LEF32@16000", "-o", file.path, text,
        ]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fatalError("could not run say: \(error)")
        }
        guard process.terminationStatus == 0, let samples = try? MonoAudioDecoder.loadMono16k(file)
        else { fatalError("say produced nothing for \(voice)") }
        rendered[key] = samples
        return samples
    }
}
