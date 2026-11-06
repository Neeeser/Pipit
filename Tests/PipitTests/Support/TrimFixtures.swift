import AVFoundation
import Foundation
import PipitAudio
import PipitCore
import PipitServices

/// Finished, compacted meetings for the trim tests. Synthetic tones, and words
/// that stand for nothing anyone said.
public enum TrimFixtures {
    public static let started = Date(timeIntervalSince1970: 1_787_070_000)

    /// A finished two-track meeting whose audio is compacted, with the
    /// listening copy mixed. The microphone starts at capture time 100 and the
    /// far end `remoteStartOffset` seconds later.
    public static func makeCompacted(
        root: URL, micSeconds: Double = 20, remoteSeconds: Double = 20, remoteStartOffset: Double = 5
    ) throws -> MeetingStore {
        let rate = MicrophoneCleaningFixtures.rate
        let meeting = try MicrophoneCleaningFixtures.makeMeeting(
            root: root,
            mic: MicrophoneCleaningFixtures.tone(count: Int(micSeconds * rate), frequency: 440, amplitude: 0.4),
            remote: MicrophoneCleaningFixtures.tone(
                count: Int(remoteSeconds * rate), frequency: 220, amplitude: 0.4),
            remoteStartOffset: remoteStartOffset
        )
        _ = try meeting.store.updateMetadata {
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        _ = try AudioCompactor().compact(store: meeting.store)
        return meeting.store
    }

    /// A microphone recorded as three segments with a hole in the capture
    /// clock between the first two, and the last one never closed, the way a
    /// crash leaves it and recovery adopts it. The joined audio is 4 s, 4 s
    /// and 2 s; the second segment starts 6 s after the first one ended.
    public static func makeWithGapAndCrashTail(
        root: URL, withFarEnd: Bool = false, farEndOffset: Double = 0
    ) throws -> MeetingStore {
        let repository = MeetingRepository(root: root)
        let made = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started,
            titles: TitleCandidates(timestampFallback: "gap"), now: started
        )
        let store = made.store
        let layout = store.layout
        try FileManager.default.createDirectory(at: layout.segments, withIntermediateDirectories: true)
        let manifest = try ManifestWriter(url: layout.manifest)
        manifest.append(
            .sessionStart(
                .init(
                    meetingID: made.metadata.id, source: .manual, segmentSeconds: 30, appVersion: "test", processID: 1)
            ))
        let rate = 16_000.0
        let format = try requireFormat(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        // Where each segment starts on the capture clock; nil for the crash tail.
        typealias Part = (seconds: Double, host: Double?, closed: Bool)
        func write(_ track: CaptureTrack, _ parts: [Part]) throws {
            var frames: Int64 = 0
            for (offset, part) in parts.enumerated() {
                let index = offset + 1
                let url = layout.segmentFile(track: track, index: index)
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                try file.write(from: AudioFixtures.makeTone(seconds: part.seconds, sampleRate: rate, amplitude: 0.4))
                let count = Int64(part.seconds * rate)
                manifest.append(
                    .segmentOpen(
                        .init(
                            track: track, index: index, file: layout.segmentFileName(track: track, index: index),
                            firstFrameHostTime: part.host, startFrame: frames, sampleRate: rate, channelCount: 1,
                            reason: index == 1 ? "start" : "rotate"
                        )))
                if part.closed {
                    manifest.append(
                        .segmentClose(
                            .init(
                                track: track, index: index, frameCount: count, byteCount: 0, seconds: part.seconds,
                                firstFrameHostTime: part.host, reason: "rotate"
                            )))
                } else {
                    manifest.append(
                        .crashTailAdopted(
                            .init(track: track, index: index, frameCount: count, byteCount: 0, seconds: part.seconds)))
                }
                frames += count
            }
        }
        try write(.mic, [(4, 100, true), (4, 110, true), (2, nil, false)])
        // A far end with no gap, starting with the microphone.
        if withFarEnd { try write(.remote, [(10, 100 + farEndOffset, true)]) }
        manifest.append(.sessionEnd(.init(reason: "test", micSeconds: 10, remoteSeconds: withFarEnd ? 10 : 0)))
        manifest.close()
        _ = try store.updateMetadata {
            $0.durationSeconds = 10
            $0.endedAt = started.addingTimeInterval(10)
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        _ = try AudioCompactor().compact(store: store)
        return store
    }

    private static func requireFormat(_ format: AVAudioFormat?) throws -> AVAudioFormat {
        guard let format else { throw FixtureError.noFormat }
        return format
    }

    enum FixtureError: Error { case noFormat }

    /// Gives a compacted meeting a cleaned microphone: a copy of the archived
    /// microphone, recorded the way the cleaner records its own file.
    public static func addCleanedMicrophone(to store: MeetingStore) throws {
        let metadata = try store.readMetadata()
        let record = try requireTrack(metadata.audioArchive?.mic)
        let location = TrackAudioLocation.archived(
            track: .mic, record: record, directory: store.layout.trackArchiveDirectory, compactedAt: started
        )
        let frames = try TrackArchiveExporter().export(location: location, to: store.layout.cleanedMicFile)
        var cleaned = record
        cleaned.file = store.layout.cleanedMicFileName
        cleaned.frameCount = frames
        _ = try store.updateMetadata {
            $0.cleanedMic = CleanedMicrophone(
                track: cleaned, echoRemovedMedianDB: 12, farEndActiveWindows: 40, producedAt: started)
        }
    }

    private static func requireTrack(_ track: AudioArchive.Track?) throws -> AudioArchive.Track {
        guard let track else { throw FixtureError.noFormat }
        return track
    }

    /// The text files in a meeting folder that contain any of `words`. Audio is
    /// left out; the words are text.
    public static func textFiles(in root: URL, containing words: [String]) -> [String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        var found: [String] = []
        for case let url as URL in walker where !["m4a", "caf", "wav"].contains(url.pathExtension) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if words.contains(where: { text.contains($0) }) { found.append(url.lastPathComponent) }
        }
        return found.sorted()
    }

    /// Seconds in an audio file, decoded.
    public static func seconds(of url: URL) throws -> Double {
        let info = try AudioFileInspector().decode(url: url)
        return Double(info.frameCount) / info.sampleRate
    }
}
