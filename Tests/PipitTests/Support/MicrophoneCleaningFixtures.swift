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
    /// The far end's own voice, playing for the whole call.
    ///
    /// None of these divide 16 kHz into a whole number of samples. A tone that
    /// does, 400 Hz at 40 samples, repeats exactly on the block grid, which
    /// leaves the delay between the reference and its copy in the microphone
    /// ambiguous at every multiple of the period. The canceller's filter never
    /// converges on it and it reports the 0.18 dB floor of its own estimator.
    public static let farToneA = 440.0
    /// A second far-end tone that starts halfway through, so the canceller has
    /// to keep tracking rather than settling on one frequency.
    public static let farToneB = 950.0
    /// The local user, talking over the far end for the middle third.
    public static let nearTone = 1_300.0
    /// What the room does to the far end on its way back to the capsule: a
    /// third of the level, 3 ms across the desk.
    public static let echoGain: Float = 0.35
    public static let echoDelaySamples = 48

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

    // MARK: - the two-track meeting every measurement is taken on

    /// A call on speakers. The far end plays throughout, the user talks over it
    /// for the middle third, and a third of the far end is back in the
    /// microphone 3 ms later.
    public static func makeCallOnSpeakers(
        root: URL, seconds: Double = 30, remoteStartOffset: Double = 2
    ) throws -> (metadata: MeetingMetadata, store: MeetingStore, repository: MeetingRepository) {
        let count = Int(seconds * rate)
        var remote = tone(count: count, frequency: farToneA, amplitude: 0.5)
        let second = tone(count: count, frequency: farToneB, amplitude: 0.4, from: count / 2)
        for index in 0..<count { remote[index] += second[index] }

        // The user, for the middle third of their own track.
        var mic = tone(
            count: count, frequency: nearTone, amplitude: 0.3,
            from: count / 3, upTo: 2 * count / 3
        )
        // The far end coming back through the air. The far end's first frame
        // landed `remoteStartOffset` seconds after the microphone's, so far-end
        // sample j was in the room at microphone sample j + offset + delay.
        let shift = Int(remoteStartOffset * rate) + echoDelaySamples
        for index in shift..<count { mic[index] += echoGain * remote[index - shift] }

        return try makeMeeting(
            root: root, mic: mic, remote: remote, remoteStartOffset: remoteStartOffset
        )
    }

    /// A call whose far end starts and stops the way a person talking does.
    ///
    /// A tone that never stops has a flat loudness envelope, and a flat
    /// envelope is the same envelope after any shift: it can be lined up
    /// anywhere and cancelled from anywhere, so it hides both the fault and the
    /// fix. Speech turns on and off, and that is the structure alignment is
    /// measured against. Deterministic, so a failure is reproducible.
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
        var remote = tone(count: count, frequency: farToneA, amplitude: 0.5)
        let second = tone(count: count, frequency: farToneB, amplitude: 0.4, from: count / 2)
        for index in 0..<count { remote[index] += second[index] }
        // Turns of 0.35 to 1.2 s with gaps of the same order, from a fixed
        // sequence rather than a generator, so every run sees the same call.
        var at = 0.0
        var step = 0
        let pattern: [(on: Double, off: Double)] = [
            (0.9, 0.5), (0.4, 0.7), (1.2, 0.4), (0.6, 0.9), (0.35, 0.5), (1.0, 0.6),
        ]
        while at < seconds {
            let turn = pattern[step % pattern.count]
            step += 1
            let quietFrom = Int((at + turn.on) * rate)
            let quietTo = min(count, Int((at + turn.on + turn.off) * rate))
            if quietFrom < count {
                for index in quietFrom..<max(quietFrom, quietTo) { remote[index] = 0 }
            }
            at += turn.on + turn.off
        }

        // The user, talking across the far end for the middle third.
        var mic = tone(
            count: count, frequency: nearTone, amplitude: 0.3,
            from: count / 3, upTo: 2 * count / 3
        )
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
