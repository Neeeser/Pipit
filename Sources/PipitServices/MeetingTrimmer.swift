import Foundation
import PipitAudio
import PipitCore

/// Why a meeting cannot be trimmed. Each case is a state the person can see in
/// the app, so none carries meeting content.
public enum TrimError: LogSafeError, Equatable {
    /// Still recording or processing; the files are in use.
    case notFinished
    /// The audio has not been archived yet, so there is no single file per
    /// track to cut.
    case notArchived
    /// A call that dropped and was rejoined inside one recording. Its runs sit
    /// at separate places in time, and a cut has to know which one it is in.
    case severalRuns
    /// The range removes nothing or keeps too little.
    case invalidRange
    /// A rewritten track did not decode to the length it should have.
    case verificationFailed(track: String)
    /// A file could not be read or written; the recording is left as it was
    /// unless the swap had begun.
    case filesNotWritten

    public var logSafeDescription: String {
        switch self {
        case .notFinished: "trim.not_finished"
        case .notArchived: "trim.not_archived"
        case .severalRuns: "trim.several_runs"
        case .invalidRange: "trim.invalid_range"
        case .verificationFailed(let track): "trim.verification_failed.\(track)"
        case .filesNotWritten: "trim.files_not_written"
        }
    }
}

/// Rewrites one finished recording so it holds only the range the person kept.
///
/// Every replacement file is written beside the one it replaces and checked
/// before anything is swapped in. The audio is decoded again and its length
/// compared with the cut; only then are the files moved over the originals,
/// the metadata last, so a meeting whose metadata still describes the old
/// recording never points at audio it does not have.
public struct MeetingTrimmer: Sendable {
    public let exporter: TrackArchiveExporter
    public let inspector: AudioFileInspector

    public init(exporter: TrackArchiveExporter = TrackArchiveExporter(), inspector: AudioFileInspector = .init()) {
        self.exporter = exporter
        self.inspector = inspector
    }

    /// Whether the recording is in a state Trim can work on.
    public static func check(_ metadata: MeetingMetadata, layout: MeetingLayout) throws {
        guard metadata.processing.state == .complete, metadata.microphoneRedoRequestedAt == nil else {
            throw TrimError.notFinished
        }
        guard metadata.audioArchive != nil,
            !FileManager.default.fileExists(atPath: layout.segments.path)
        else { throw TrimError.notArchived }
        guard metadata.runs.count <= 1 else { throw TrimError.severalRuns }
    }

    public func trim(store: MeetingStore, to range: TrimRange, at now: Date) throws {
        let layout = store.layout
        let metadata = try store.readMetadata()
        try Self.check(metadata, layout: layout)
        guard let archive = metadata.audioArchive else { throw TrimError.notArchived }
        guard range.end <= metadata.durationSeconds + MeetingTrim.tolerance else { throw TrimError.invalidRange }
        let origin = MeetingTrim.origin(archive)

        // Audio first, into files beside the originals.
        var staged: [(from: URL, to: URL)] = []
        defer { for file in staged { try? FileManager.default.removeItem(at: file.from) } }
        var trimmedArchive = archive
        var keptSeconds: [CaptureTrack: Double] = [:]
        for track in CaptureTrack.allCases {
            guard let record = archive.track(track) else { continue }
            let result = try cutTrack(record, name: track.segmentPrefix, origin: origin, range: range, layout: layout)
            staged.append(contentsOf: result.staged)
            trimmedArchive.setTrack(track, to: result.record)
            keptSeconds[track] = result.record?.seconds ?? 0
        }
        var cleanedRecord: AudioArchive.Track?
        if let cleaned = metadata.cleanedMic {
            let result = try cutTrack(
                cleaned.track, name: "mic.cleaned", origin: origin, range: range, layout: layout
            )
            staged.append(contentsOf: result.staged)
            cleanedRecord = result.record
        }

        // Then everything measured on the timeline, as replacement files.
        staged.append(
            contentsOf: try stageTimelineFiles(
                store: store, range: range, origin: origin, keptSeconds: keptSeconds
            ))

        // Swap in. The metadata goes last, written through the store so its
        // lock is honoured.
        let manager = FileManager.default
        for file in staged {
            if manager.fileExists(atPath: file.to.path) {
                _ = try manager.replaceItemAt(file.to, withItemAt: file.from)
            } else {
                try manager.moveItem(at: file.from, to: file.to)
            }
        }
        staged.removeAll()
        for track in CaptureTrack.allCases where archive.track(track) != nil && trimmedArchive.track(track) == nil {
            try? manager.removeItem(at: layout.trackArchiveFile(track: track))
        }
        let trimmed = MeetingTrim.trim(
            metadata, to: range, archive: trimmedArchive, cleanedMic: cleanedRecord, at: now
        )
        try store.writeMetadata(trimmed)

        // Derived from the old audio. Processing writes the mixdown and the
        // summary again; the summary goes now so that, where no summary model
        // is set up, an old one never describes audio that is gone.
        for url in [layout.recordingAudio, layout.alignments, layout.summary, layout.structuredSummary] {
            try? manager.removeItem(at: url)
        }
    }

    /// Writes a replacement beside every file measured on the meeting's
    /// timeline. Returns each replacement and the file it replaces.
    private func stageTimelineFiles(
        store: MeetingStore, range: TrimRange, origin: Double?, keptSeconds: [CaptureTrack: Double]
    ) throws -> [(from: URL, to: URL)] {
        let layout = store.layout
        var staged: [(from: URL, to: URL)] = []
        var finished = false
        // A replacement written before a later one failed is not left behind.
        defer {
            if !finished { for file in staged { try? FileManager.default.removeItem(at: file.from) } }
        }
        func stage(_ data: Data, for url: URL) throws {
            let partial = url.appendingPathExtension("trimming")
            try data.write(to: partial, options: .atomic)
            staged.append((partial, url))
        }
        if FileManager.default.fileExists(atPath: layout.rawTranscript.path) {
            try stage(
                ArchiveCoding.encode(MeetingTrim.trim(store.readRawTranscript(), to: range)), for: layout.rawTranscript)
        }
        if FileManager.default.fileExists(atPath: layout.rawDiarization.path) {
            try stage(
                ArchiveCoding.encode(MeetingTrim.trim(store.readRawDiarization(), to: range)),
                for: layout.rawDiarization
            )
        }
        if let evidence = store.readSpeechEvidence() {
            try stage(ArchiveCoding.encode(MeetingTrim.trim(evidence, to: range)), for: layout.speechEvidence)
        }
        if let sensors = store.readRawSensors() {
            try stage(ArchiveCoding.encode(MeetingTrim.trim(sensors, to: range)), for: layout.rawSensors)
        }
        if FileManager.default.fileExists(atPath: layout.speakerMap.path) {
            try stage(ArchiveCoding.encode(MeetingTrim.trim(store.readSpeakerMap(), to: range)), for: layout.speakerMap)
        }
        if FileManager.default.fileExists(atPath: layout.speakerSuggestions.path) {
            try stage(
                ArchiveCoding.encode(MeetingTrim.trim(store.readSpeakerSuggestions(), to: range)),
                for: layout.speakerSuggestions
            )
        }
        // The assembled transcript as written, not as read: reading applies
        // the speaker map's line cuts, and those are moved separately above.
        if FileManager.default.fileExists(atPath: layout.canonicalTranscript.path) {
            let data = try Data(contentsOf: layout.canonicalTranscript)
            let transcript = try ArchiveCoding.decode(
                CanonicalTranscript.self, from: data, path: layout.canonicalTranscript.path
            )
            try stage(ArchiveCoding.encode(MeetingTrim.trim(transcript, to: range)), for: layout.canonicalTranscript)
        }
        let manifest = try ManifestReader.read(contentsOf: layout.manifest)
        let lines = MeetingTrim.trim(
            manifest.lines, to: range, origin: origin ?? 0, keptSeconds: keptSeconds
        )
        let encoder = ManifestCoding.makeEncoder()
        var manifestData = Data()
        for line in lines {
            manifestData.append(try encoder.encode(line))
            manifestData.append(0x0A)
        }
        try stage(manifestData, for: layout.manifest)
        finished = true
        return staged
    }

    private struct CutResult {
        var record: AudioArchive.Track?
        var staged: [(from: URL, to: URL)]
    }

    /// Writes the kept part of one archived file beside it and checks it.
    private func cutTrack(
        _ record: AudioArchive.Track, name: String, origin: Double?, range: TrimRange, layout: MeetingLayout
    ) throws -> CutResult {
        let source = layout.trackArchiveDirectory.appendingPathComponent(record.file)
        guard let cut = MeetingTrim.cut(record, origin: origin, range: range) else {
            return CutResult(record: nil, staged: [])
        }
        let partial = layout.trackArchiveDirectory.appendingPathComponent("\(name).trimming.m4a")
        let location = TrackAudioLocation.archived(
            track: .mic, record: record, directory: layout.trackArchiveDirectory, compactedAt: Date()
        )
        let frames = try exporter.export(location: location, from: cut.from, to: cut.to, destination: partial)
        let info: AudioFileInfo
        do {
            info = try inspector.decode(url: partial)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw TrimError.verificationFailed(track: name)
        }
        // The same allowance compaction gives a fresh archive.
        guard abs(info.seconds - cut.seconds) <= max(0.5, min(cut.seconds * 0.01, 2.0)) else {
            try? FileManager.default.removeItem(at: partial)
            throw TrimError.verificationFailed(track: name)
        }
        return CutResult(
            record: MeetingTrim.trimmed(record, cut: cut, frameCount: frames),
            staged: [(partial, source)]
        )
    }
}
