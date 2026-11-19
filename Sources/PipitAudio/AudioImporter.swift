import AVFoundation
import Foundation
import PipitCore

/// Brings an existing recording into the archive.
///
/// The original file is copied in untouched and kept. The decoded copy is written
/// as ordinary CAF segments with a manifest, so an imported meeting travels the
/// same pipeline as a captured one and nothing downstream needs a special case.
public struct AudioImporter: Sendable {
    public struct Result: Sendable, Equatable {
        public let durationSeconds: Double
        public let originalFilename: String
        public let segmentCount: Int
    }

    /// The two tracks of an imported call.
    public struct CallResult: Sendable, Equatable {
        public let microphone: Result
        public let remote: Result
    }

    public let segmentSeconds: Double
    private let clock: any Clock

    public init(segmentSeconds: Double = 30, clock: any Clock = SystemClock()) {
        self.segmentSeconds = segmentSeconds
        self.clock = clock
    }

    /// `session` is the diagnostic session written into the manifest's
    /// `session_start`, so the import can be found from its events.
    public func `import`(
        source: URL, into store: MeetingStore, meetingID: String, session: DiagnosticSessionID? = nil
    ) throws -> Result {
        try store.createDirectories()
        let preserved = try preserve(source, as: source.lastPathComponent, in: store)

        let manifest = try ManifestWriter(url: store.layout.manifest)
        defer { manifest.close() }
        appendSessionStart(to: manifest, meetingID: meetingID, source: .imported, session: session)

        // Imported audio is written mono: an imported recording has no separate
        // local speaker, so the whole file is diarized as one track.
        var decoded = 0.0
        do {
            let result = try write(
                preserved, originalName: source.lastPathComponent, track: .mic, store: store,
                manifest: manifest, hostOrigin: clock.monotonicSeconds, decodedSeconds: &decoded
            )
            appendSessionEnd(
                to: manifest, reason: "import_complete", microphone: result.durationSeconds, remote: 0
            )
            return result
        } catch {
            appendSessionEnd(to: manifest, reason: "import_failed", microphone: decoded, remote: 0)
            throw error
        }
    }

    /// Imports a two-track call: a microphone recording and a recording of
    /// everyone else, laid out the way a capture writes them.
    ///
    /// Both tracks go into one manifest under `source`, which must be a source
    /// that records the far end separately. Each track starts at the same host
    /// time, so the pipeline reads the two as captured together and the echo
    /// pass lines the far end up by measurement alone. This is how the
    /// benchmark feeds the pipeline a call whose answer is known.
    public func importCall(
        microphone: URL, remote: URL, source: MeetingSource, into store: MeetingStore,
        meetingID: String, session: DiagnosticSessionID? = nil
    ) throws -> CallResult {
        precondition(source.capturesRemoteAudio, "a call import needs a source with a far end")
        try store.createDirectories()
        // Two files can share a name, and the second would then be taken for a
        // copy of the first and never preserved.
        let microphoneName = microphone.lastPathComponent
        let remoteName =
            remote.lastPathComponent == microphoneName
            ? "remote-\(remote.lastPathComponent)" : remote.lastPathComponent
        let preservedMicrophone = try preserve(microphone, as: microphoneName, in: store)
        let preservedRemote = try preserve(remote, as: remoteName, in: store)

        let manifest = try ManifestWriter(url: store.layout.manifest)
        defer { manifest.close() }
        appendSessionStart(to: manifest, meetingID: meetingID, source: source, session: session)

        let origin = clock.monotonicSeconds
        var microphoneSeconds = 0.0
        var remoteSeconds = 0.0
        do {
            let first = try write(
                preservedMicrophone, originalName: microphoneName, track: .mic, store: store,
                manifest: manifest, hostOrigin: origin, decodedSeconds: &microphoneSeconds
            )
            microphoneSeconds = first.durationSeconds
            let second = try write(
                preservedRemote, originalName: remoteName, track: .remote, store: store,
                manifest: manifest, hostOrigin: origin, decodedSeconds: &remoteSeconds
            )
            appendSessionEnd(
                to: manifest, reason: "import_complete", microphone: first.durationSeconds,
                remote: second.durationSeconds
            )
            return CallResult(microphone: first, remote: second)
        } catch {
            appendSessionEnd(
                to: manifest, reason: "import_failed", microphone: microphoneSeconds,
                remote: remoteSeconds
            )
            throw error
        }
    }

    /// Copies the original into the meeting folder and returns the copy.
    private func preserve(_ source: URL, as name: String, in store: MeetingStore) throws -> URL {
        try FileManager.default.createDirectory(
            at: store.layout.originals, withIntermediateDirectories: true
        )
        let preserved = store.layout.originals.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: preserved.path) {
            do {
                try FileManager.default.copyItem(at: source, to: preserved)
            } catch {
                throw StorageError.fileWriteFailed(path: preserved.path, underlying: "\(error)")
            }
        }
        return preserved
    }

    private func appendSessionStart(
        to manifest: ManifestWriter, meetingID: String, source: MeetingSource,
        session: DiagnosticSessionID?
    ) {
        manifest.append(
            .sessionStart(
                .init(
                    meetingID: meetingID, source: source, segmentSeconds: segmentSeconds,
                    appVersion: PipitVersion.current,
                    processID: ProcessInfo.processInfo.processIdentifier,
                    diagnosticSession: session?.description
                )),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )
    }

    private func appendSessionEnd(
        to manifest: ManifestWriter, reason: String, microphone: Double, remote: Double
    ) {
        manifest.append(
            .sessionEnd(.init(reason: reason, micSeconds: microphone, remoteSeconds: remote)),
            hostTime: clock.monotonicSeconds, wallClock: clock.now
        )
    }

    /// Decodes one preserved file into mono segments of `track`, at the file's
    /// own sample rate. `decodedSeconds` holds what was written so far when this
    /// throws, so the caller's session end can say how far an import got.
    private func write(
        _ preserved: URL, originalName: String, track: CaptureTrack, store: MeetingStore,
        manifest: ManifestWriter, hostOrigin: Double, decodedSeconds: inout Double
    ) throws -> Result {
        guard let input = try? AVAudioFile(forReading: preserved) else {
            throw ProcessingError.audioUnreadable(path: originalName)
        }
        let sourceFormat = input.processingFormat
        guard sourceFormat.sampleRate > 0,
            let targetFormat = AVAudioFormat(
                standardFormatWithSampleRate: sourceFormat.sampleRate, channels: 1
            )
        else {
            throw ProcessingError.audioUnreadable(path: originalName)
        }

        let writer = SegmentWriter(
            track: track, layout: store.layout, manifest: manifest, format: targetFormat,
            segmentSeconds: segmentSeconds, clock: clock
        )
        func abandon() -> ProcessingError {
            writer.finish(reason: "import_failed")
            decodedSeconds = writer.stats.totalSeconds
            return ProcessingError.audioUnreadable(path: originalName)
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
            let readBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 16_384)
        else {
            throw abandon()
        }
        // More than two channels with no surround layout has no mixdown matrix,
        // and the converter would produce silence.
        if sourceFormat.channelCount > 2 {
            converter.channelMap = (0..<Int(targetFormat.channelCount)).map { NSNumber(value: $0) }
        }

        var hostTime = hostOrigin
        while input.framePosition < input.length {
            readBuffer.frameLength = 0
            do {
                try input.read(into: readBuffer)
            } catch {
                throw abandon()
            }
            guard readBuffer.frameLength > 0 else { break }

            let capacity = AVAudioFrameCount(
                Double(readBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate + 1_024
            )
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                throw abandon()
            }
            // The converter calls the input block synchronously on this thread,
            // but the block is typed `@Sendable`. The box carries the buffer and
            // the consumed-once flag across that boundary as one value: it holds
            // the buffer until the block hands it over, and nil afterwards.
            let pending = LockedBox<AVAudioPCMBuffer?>(readBuffer)
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, statusPointer in
                pending.withLock { buffer in
                    guard let ready = buffer else {
                        statusPointer.pointee = .noDataNow
                        return nil
                    }
                    buffer = nil
                    statusPointer.pointee = .haveData
                    return ready
                }
            }
            if status == .error {
                throw abandon()
            }
            guard output.frameLength > 0 else { continue }

            writer.enqueueSynchronously(AudioBufferPacket(buffer: output, hostTime: hostTime))
            hostTime += Double(output.frameLength) / targetFormat.sampleRate
        }

        writer.finish(reason: "import_complete")
        let stats = writer.stats
        return Result(
            durationSeconds: stats.totalSeconds, originalFilename: originalName,
            segmentCount: stats.segmentCount
        )
    }
}
