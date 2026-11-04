import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitLocalAI
import PipitServices

/// Replays a recorded meeting through the live transcript the app runs.
///
/// Both raw tracks are cut into buffers the size the sources deliver and
/// pushed into the session's queue, as capture does, at recorded speed or as
/// fast as the machine allows. The report says whether the session kept up:
/// how far its processed audio fell behind the audio fed, and how many
/// buffers it dropped. No speaker store is opened, so voice names are not
/// looked up; the speaker passes still run.
enum LiveSessionCommand {
    struct Options {
        var meeting: URL
        var applicationSupport: URL
        var engine: LocalTranscriptionModel
        /// 1 feeds at recorded speed; 0 feeds as fast as the session drains.
        var pace: Double
        var limitSeconds: Double?
    }

    /// Frames per buffer at 16 kHz: the microphone tap delivers about 85 ms,
    /// the process tap about 10 ms.
    private static let micFrames = 1_365
    private static let remoteFrames = 160

    static func run(_ options: Options) async -> Int32 {
        let audio = options.meeting.appendingPathComponent("raw/audio", isDirectory: true)
        var tracks: [(CaptureTrack, [Float])] = []
        for (track, name) in [(CaptureTrack.mic, "mic.m4a"), (.remote, "system.m4a")] {
            let file = audio.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            guard var samples = try? MonoAudioDecoder.loadMono16k(file) else {
                note("live-session: cannot decode \(name)")
                return 1
            }
            if let limit = options.limitSeconds { samples = Array(samples.prefix(Int(limit * 16_000))) }
            tracks.append((track, samples))
        }
        guard !tracks.isEmpty else {
            note("live-session: no raw/audio tracks in \(options.meeting.path)")
            return 1
        }
        let seconds = Double(tracks.map(\.1.count).max() ?? 0) / 16_000

        let models = LocalModelManager(applicationSupport: options.applicationSupport)
        let model = await LiveTranscriptModel()
        let scratch = options.applicationSupport.appendingPathComponent("live-replay", isDirectory: true)
        let session = LiveTranscriptSession(
            meetingID: "replay", engine: options.engine, models: models, speakers: nil,
            speakerSettings: SpeakerRecognitionSettings(), scratch: scratch, model: model
        )
        let began = Date()
        await session.start()
        note(String(format: "live-session: engine ready in %.1fs", Date().timeIntervalSince(began)))
        if case .unavailable(let reason) = await model.state {
            note("live-session: \(reason)")
            return 2
        }

        let fedBox = LockedBox<Double>(0)
        let monitor = Task {
            var worst: Double = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                let fed = fedBox.withLock { $0 }
                let processed = await session.processedSeconds
                worst = max(worst, fed - processed)
            }
            return worst
        }

        // PIPIT_STALL_MAIN_SECONDS holds the main thread that long, 20 s in,
        // the way an open menu or a window appearing does in the app. The
        // session must not fall behind while it is held.
        if let stall = Double(ProcessInfo.processInfo.environment["PIPIT_STALL_MAIN_SECONDS"] ?? "") {
            Task.detached {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run { Thread.sleep(forTimeInterval: stall) }
            }
        }
        let feedStart = Date()
        let origin = 1_000.0
        var positions = Dictionary(uniqueKeysWithValues: tracks.map { ($0.0, 0) })
        while true {
            // The track that is furthest behind goes next, so the two arrive
            // interleaved the way the sources deliver them.
            let pending = tracks.filter { positions[$0.0, default: 0] < $0.1.count }
            guard
                let next = pending.min(by: {
                    positions[$0.0, default: 0] < positions[$1.0, default: 0]
                })
            else { break }
            let (track, samples) = next
            let start = positions[track, default: 0]
            let count = min(track == .mic ? micFrames : remoteFrames, samples.count - start)
            guard let packet = packet(samples[start..<start + count], hostTime: origin + Double(start) / 16_000)
            else { break }
            session.queue.push(packet, track: track)
            positions[track] = start + count
            let fed = Double(positions.values.min() ?? 0) / 16_000
            fedBox.withLock { $0 = fed }
            if options.pace == 0 {
                // As fast as the session drains, never faster, so the number
                // measured is its speed rather than the queue's size.
                while session.queue.count > session.queue.capacity / 2 {
                    try? await Task.sleep(nanoseconds: 2_000_000)
                }
            } else {
                let due = fed / options.pace - Date().timeIntervalSince(feedStart)
                if due > 0.005 { try? await Task.sleep(nanoseconds: UInt64(due * 1_000_000_000)) }
            }
        }
        let fedFor = Date().timeIntervalSince(feedStart)
        await session.stop()
        let total = Date().timeIntervalSince(feedStart)
        monitor.cancel()
        let worstLag = await monitor.value
        let transcript = await model.transcript
        let dropped = await session.droppedBuffers
        let speech = transcript.lines.filter { $0.kind != .note }
        let speakers = Set(transcript.turns.map(\.speaker))
        print(
            String(
                format: """
                    audio            %.0f s
                    fed in           %.0f s, settled after %.0f s (%.1fx real time)
                    worst lag        %.1f s behind the audio fed
                    dropped buffers  %d
                    lines            %d (%d you, %d others)
                    speakers         %d labelled on the far end
                    """,
                seconds, fedFor, total, seconds / max(total, 0.001), worstLag, dropped,
                speech.count, speech.filter { $0.kind == .speech(.mic) }.count,
                speech.filter { $0.kind == .speech(.remote) }.count, speakers.count
            ))
        return dropped == 0 ? 0 : 3
    }

    private static func packet(_ samples: ArraySlice<Float>, hostTime: Double) -> AudioBufferPacket? {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return AudioBufferPacket(buffer: buffer, hostTime: hostTime)
    }
}
