import AVFoundation
import Foundation
import PipitCore

/// Reads what a recorded file actually contains.
///
/// Crash recovery depends on this: a CAF written by a killed process has a data
/// chunk size of -1, so its real length comes from the file, not the header.
public struct AudioFileInspector: AudioFileInspecting {
    public init() {}

    public func inspect(url: URL) throws -> AudioFileInfo {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "unreadable audio file")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let format = file.processingFormat
        return AudioFileInfo(
            frameCount: file.length,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            byteCount: byteCount
        )
    }

    /// Decodes the whole file and reports what came out of it.
    ///
    /// A container whose atoms are intact and whose payload is not opens fine
    /// and reads a full length from the header. Only a decode of every frame
    /// tells the two apart, so this is what runs before a compacted archive
    /// replaces the segments it was made from. The returned frame count is the
    /// number of frames actually decoded.
    public func decode(url: URL) throws -> AudioFileInfo {
        guard let file = try? AVAudioFile(forReading: url) else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "unreadable audio file")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw StorageError.fileReadFailed(path: url.path, underlying: "buffer allocation failed")
        }

        // Bounded by the header length because AVAudioFile throws rather than
        // returning zero frames on a read that starts at the end.
        var decodedFrames: Int64 = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer)
            } catch {
                throw StorageError.fileReadFailed(path: url.path, underlying: "\(error)")
            }
            guard buffer.frameLength > 0 else { break }
            decodedFrames += Int64(buffer.frameLength)
        }

        return AudioFileInfo(
            frameCount: decodedFrames,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount),
            byteCount: byteCount
        )
    }
}

/// Reads media files chosen for import. Uses AVFoundation only, which decoded
/// WAV, M4A, MP3, CAF, AIFF and MP4 in feasibility testing with no FFmpeg.
public struct MediaFileInspector: Sendable {
    public struct Info: Sendable, Equatable {
        public let durationSeconds: Double
        public let sampleRate: Double
        public let channelCount: Int
        public let hasAudioTrack: Bool
    }

    public init() {}

    public func inspect(url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw ProcessingError.audioUnreadable(path: url.lastPathComponent)
        }
        guard let track = tracks.first else {
            return Info(durationSeconds: 0, sampleRate: 0, channelCount: 0, hasAudioTrack: false)
        }
        let duration = (try? await asset.load(.duration)) ?? .zero
        var sampleRate: Double = 0
        var channels = 0
        if let descriptions = try? await track.load(.formatDescriptions) {
            for description in descriptions {
                guard let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { continue }
                sampleRate = basic.pointee.mSampleRate
                channels = Int(basic.pointee.mChannelsPerFrame)
                break
            }
        }
        return Info(
            durationSeconds: CMTimeGetSeconds(duration),
            sampleRate: sampleRate,
            channelCount: channels,
            hasAudioTrack: true
        )
    }

    public static var supportedExtensions: [String] {
        ["wav", "m4a", "mp3", "caf", "aiff", "aif", "mp4", "mov", "aac", "flac", "m4v"]
    }
}

/// Reads the creation date a recorder wrote into a media file.
///
/// Three containers matter and each stores it differently: QuickTime and MP4
/// under `com.apple.quicktime.creationdate` and the ISO user-data date, MP3
/// under the ID3 recording time, and AAC in an iTunes release date. AVFoundation
/// hands most of them back through `AVAsset.creationDate`, and the rest need the
/// metadata list read directly.
///
/// A value that decodes to a date is used as it stands. One that only decodes to
/// a string goes through `RecordedDatePolicy.parseMetadataDate`, which refuses a
/// year on its own: a bare "2026" would put a meeting on the first of January.
public struct MediaCreationDateReader: Sendable {
    public init() {}

    public func creationDate(of url: URL) async -> Date? {
        let asset = AVURLAsset(url: url)
        if let item = try? await asset.load(.creationDate), let date = await Self.date(from: item) {
            return date
        }
        let common = (try? await asset.load(.commonMetadata)) ?? []
        let all = (try? await asset.load(.metadata)) ?? []
        for item in common + all where Self.namesACreationDate(item) {
            if let date = await Self.date(from: item) { return date }
        }
        return nil
    }

    /// The identifiers a creation date is written under, across the containers
    /// AVFoundation decodes.
    private static let creationIdentifiers: Set<AVMetadataIdentifier> = [
        .quickTimeMetadataCreationDate,
        .quickTimeUserDataCreationDate,
        .isoUserDataDate,
        .id3MetadataRecordingTime,
        .id3MetadataDate,
        .iTunesMetadataReleaseDate,
    ]

    private static func namesACreationDate(_ item: AVMetadataItem) -> Bool {
        if item.commonKey == .commonKeyCreationDate { return true }
        guard let identifier = item.identifier else { return false }
        return creationIdentifiers.contains(identifier)
    }

    private static func date(from item: AVMetadataItem) async -> Date? {
        if let date = try? await item.load(.dateValue) { return date }
        guard let text = try? await item.load(.stringValue) else { return nil }
        return RecordedDatePolicy.parseMetadataDate(text)
    }
}
