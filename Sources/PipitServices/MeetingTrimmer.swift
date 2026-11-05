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
    /// unless the swap had begun, and then launch finishes it.
    case filesNotWritten
    /// An earlier trim was interrupted. It has been finished, and the range the
    /// person chose was measured on the meeting as it was before.
    case interrupted
    /// The recording was imported from a file whose original is kept whole.
    case imported

    public var logSafeDescription: String {
        switch self {
        case .notFinished: "trim.not_finished"
        case .notArchived: "trim.not_archived"
        case .severalRuns: "trim.several_runs"
        case .invalidRange: "trim.invalid_range"
        case .verificationFailed(let track): "trim.verification_failed.\(track)"
        case .filesNotWritten: "trim.files_not_written"
        case .interrupted: "trim.interrupted"
        case .imported: "trim.imported"
        }
    }
}

/// Rewrites one finished recording so it holds only the range the person kept.
///
/// Every replacement file is written beside the one it replaces and checked
/// before anything is swapped in: the audio is decoded again and its length
/// compared with the cut. Then a journal listing every replacement is written,
/// and only then are the files moved over the originals, the metadata last. A
/// failure or a quit anywhere in the swap leaves the journal behind, and
/// `finishInterrupted` carries the swap to the end from it, so a meeting never
/// stays with cut audio and the record of the uncut one.
public struct MeetingTrimmer: Sendable {
    public let exporter: TrackArchiveExporter
    public let inspector: AudioFileInspector
    /// Called with the position of each swap just before it is made. A test
    /// throws from it to stop the swap part way, as a crash or a full disk
    /// would.
    public var beforeSwap: (@Sendable (Int) throws -> Void)?

    public init(
        exporter: TrackArchiveExporter = TrackArchiveExporter(), inspector: AudioFileInspector = .init(),
        beforeSwap: (@Sendable (Int) throws -> Void)? = nil
    ) {
        self.exporter = exporter
        self.inspector = inspector
        self.beforeSwap = beforeSwap
    }

    /// Whether the recording is in a state Trim can work on.
    public static func check(_ metadata: MeetingMetadata, layout: MeetingLayout) throws {
        // The original file of an import holds the whole recording, and it is
        // kept as it was. Trimming the rest would leave it behind.
        guard metadata.source != .imported else { throw TrimError.imported }
        guard !FileManager.default.fileExists(atPath: layout.trimJournal.path) else {
            throw TrimError.interrupted
        }
        guard metadata.processing.state == .complete, metadata.microphoneRedoRequestedAt == nil else {
            throw TrimError.notFinished
        }
        guard metadata.audioArchive != nil,
            !FileManager.default.fileExists(atPath: layout.segments.path)
        else { throw TrimError.notArchived }
        guard metadata.runs.count <= 1 else { throw TrimError.severalRuns }
    }

    /// Cuts the recording and swaps the result in. Returns the journal, which
    /// stays on disk until the caller has finished what follows the swap and
    /// removes it with `MeetingStore.removeTrimJournal`.
    @discardableResult
    public func trim(store: MeetingStore, to range: TrimRange, at now: Date) throws -> TrimJournal {
        let layout = store.layout
        let metadata = try store.readMetadata()
        try Self.check(metadata, layout: layout)
        guard let archive = metadata.audioArchive else { throw TrimError.notArchived }
        let length = MeetingTrim.timelineLength(archive)
        guard range.start < length, range.keepsEnd || range.end <= length + MeetingTrim.tolerance else {
            throw TrimError.invalidRange
        }

        var staging = Staging(root: layout.root)
        var committed = false
        // Replacements written before a later one failed are not left behind.
        // Once the journal is written they are the only copy of what is kept.
        defer { if !committed { staging.discard() } }

        let audio = try stageAudio(store: store, metadata: metadata, archive: archive, range: range, staging: &staging)
        try stageTimelineFiles(store: store, range: range, staging: &staging)
        staging.remove(layout.apiResponses)
        for url in [layout.summary, layout.structuredSummary, layout.transcriptMarkdown] { staging.remove(url) }

        // On disk before the journal says they are: a power loss after the
        // journal must not find a replacement that was only in the cache.
        let swaps = try staging.flushed()
        let journal = TrimJournal(
            createdAt: now, start: range.start, end: range.keepsEnd ? nil : range.end,
            swaps: swaps, removals: staging.removals.map(staging.relative),
            metadata: MeetingTrim.change(
                metadata, to: range, archive: audio.archive, cleanedMic: audio.cleaned, at: now)
        )
        do {
            try store.writeTrimJournal(journal)
        } catch {
            throw TrimError.filesNotWritten
        }
        committed = true
        do {
            return try finish(journal, store: store)
        } catch {
            // The journal is on disk, so launch finishes the swap.
            throw TrimError.filesNotWritten
        }
    }

    /// Carries an interrupted trim to the end of its swap. Returns nil when
    /// none was started. Every step can be repeated, so it does not matter
    /// where the earlier run stopped.
    public func finishInterrupted(store: MeetingStore) throws -> TrimJournal? {
        guard FileManager.default.fileExists(atPath: store.layout.trimJournal.path) else { return nil }
        let journal: TrimJournal
        do {
            guard let read = try store.readTrimJournal() else { return nil }
            journal = read
        } catch {
            throw TrimError.filesNotWritten
        }
        return try finish(journal, store: store)
    }

    /// Moves every replacement over the file it replaces, removes what held the
    /// cut stretch, and writes the metadata last, through the store so its
    /// lock is honoured and an edit made meanwhile is kept.
    func finish(_ journal: TrimJournal, store: MeetingStore) throws -> TrimJournal {
        guard !journal.swapped else { return journal }
        let manager = FileManager.default
        let root = store.layout.root
        for (position, swap) in journal.swaps.enumerated() {
            try beforeSwap?(position)
            let staged = root.appendingPathComponent(swap.staged)
            let target = root.appendingPathComponent(swap.target)
            guard manager.fileExists(atPath: staged.path) else {
                // Already swapped by an earlier run, which is the only reason
                // a replacement may be missing: the file in its place is it.
                guard Self.size(of: target) == swap.size else { throw TrimError.filesNotWritten }
                continue
            }
            guard Self.size(of: staged) == swap.size else { throw TrimError.filesNotWritten }
            if manager.fileExists(atPath: target.path) {
                _ = try manager.replaceItemAt(target, withItemAt: staged)
            } else {
                try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: staged, to: target)
            }
            try AtomicFile.flush(target)
            try AtomicFile.flush(target.deletingLastPathComponent())
        }
        // A removal that fails is an error, not a skipped step: what it holds
        // is what the person asked to delete.
        for removal in journal.removals {
            let url = root.appendingPathComponent(removal)
            if manager.fileExists(atPath: url.path) { try manager.removeItem(at: url) }
        }
        try store.updateMetadata { journal.metadata.apply(to: &$0) }
        var done = journal
        done.swapped = true
        try store.writeTrimJournal(done)
        return done
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Removes what a trim that stopped before its journal was written left
    /// beside the files it meant to replace. With no journal nothing refers to
    /// them, and they hold the very content the person was about to delete.
    public static func removeLeftovers(layout: MeetingLayout) {
        guard !FileManager.default.fileExists(atPath: layout.trimJournal.path) else { return }
        let manager = FileManager.default
        for folder in [layout.root, layout.raw, layout.trackArchiveDirectory, layout.alignments] {
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.contains(".trimming") {
                try? manager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
    }

    // MARK: staging

    /// Replacement files written beside the ones they replace, and the files
    /// that go.
    private struct Staging {
        let root: URL
        var swaps: [(from: URL, to: URL)] = []
        var removals: [URL] = []

        init(root: URL) { self.root = root }

        mutating func stage(_ data: Data, for url: URL) throws {
            let partial = url.appendingPathExtension("trimming")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: partial, options: .atomic)
            swaps.append((partial, url))
        }

        mutating func remove(_ url: URL) { removals.append(url) }

        /// Forces every replacement and the folders holding them to disk, and
        /// returns the journal's record of each.
        func flushed() throws -> [TrimJournal.Swap] {
            var folders = Set<URL>()
            var records: [TrimJournal.Swap] = []
            for file in swaps {
                try AtomicFile.flush(file.from)
                folders.insert(file.from.deletingLastPathComponent())
                let size =
                    (try FileManager.default.attributesOfItem(atPath: file.from.path)[.size] as? NSNumber)?
                    .int64Value ?? -1
                records.append(.init(staged: relative(file.from), target: relative(file.to), size: size))
            }
            for folder in folders { try AtomicFile.flush(folder) }
            return records
        }

        func discard() {
            for file in swaps { try? FileManager.default.removeItem(at: file.from) }
        }

        /// Relative to the meeting folder, so a journal still reads right
        /// after the folder is renamed or moved.
        func relative(_ url: URL) -> String {
            let base = root.standardizedFileURL.path + "/"
            let path = url.standardizedFileURL.path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
        }
    }

    private struct StagedAudio {
        var archive: AudioArchive
        var cleaned: AudioArchive.Track?
    }

    /// Cuts both tracks, the cleaned microphone and the mixdown, and the
    /// manifest that describes them.
    private func stageAudio(
        store: MeetingStore, metadata: MeetingMetadata, archive: AudioArchive, range: TrimRange,
        staging: inout Staging
    ) throws -> StagedAudio {
        let layout = store.layout
        let origin = MeetingTrim.origin(archive)
        var cuts: [CaptureTrack: MeetingTrim.TrackCut] = [:]
        for track in CaptureTrack.allCases {
            if let record = archive.track(track), let cut = MeetingTrim.cut(record, origin: origin, range: range) {
                cuts[track] = cut
            }
        }
        // The capture record is cut by the audio each track keeps, and its
        // track lengths and start times come out matching the new archives.
        let manifest = MeetingTrim.trim(
            try ManifestReader.read(contentsOf: layout.manifest).lines, to: range, origin: origin ?? 0, cuts: cuts,
            firstHostTimes: Dictionary(
                uniqueKeysWithValues: CaptureTrack.allCases.compactMap { name in
                    archive.track(name)?.firstFrameHostTime.map { (name, $0) }
                })
        )
        try staging.stage(try encodeManifest(manifest.lines), for: layout.manifest)

        var trimmed = archive
        for track in CaptureTrack.allCases {
            guard let record = archive.track(track) else { continue }
            guard let cut = cuts[track] else {
                trimmed.setTrack(track, to: nil)
                staging.remove(layout.trackArchiveDirectory.appendingPathComponent(record.file))
                continue
            }
            let frames = try cutAudio(record, name: track.segmentPrefix, cut: cut, layout: layout, staging: &staging)
            trimmed.setTrack(
                track,
                to: MeetingTrim.trimmed(
                    record, cut: cut, frameCount: frames, firstFrameHostTime: manifest.firstFrameHostTimes[track]
                ))
        }
        var cleaned: AudioArchive.Track?
        if let record = metadata.cleanedMic?.track {
            if let cut = MeetingTrim.cut(record, origin: origin, range: range) {
                let frames = try cutAudio(
                    record, name: "mic.cleaned", cut: cut, layout: layout, staging: &staging
                )
                cleaned = MeetingTrim.trimmed(
                    record, cut: cut, frameCount: frames, firstFrameHostTime: manifest.firstFrameHostTimes[.mic]
                )
            } else {
                // The microphone has nothing inside the range, so the cleaned
                // copy of what was said before it must not stay.
                staging.remove(layout.trackArchiveDirectory.appendingPathComponent(record.file))
            }
        }
        stageMixdown(layout: layout, range: range, staging: &staging)
        return StagedAudio(archive: trimmed, cleaned: cleaned)
    }

    private func encodeManifest(_ lines: [ManifestLine]) throws -> Data {
        let encoder = ManifestCoding.makeEncoder()
        var data = Data()
        for line in lines {
            data.append(try encoder.encode(line))
            data.append(0x0A)
        }
        return data
    }

    /// Writes the kept part of one archived file beside it and checks it.
    /// Returns the frames written.
    private func cutAudio(
        _ record: AudioArchive.Track, name: String, cut: MeetingTrim.TrackCut, layout: MeetingLayout,
        staging: inout Staging
    ) throws -> Int64 {
        let source = layout.trackArchiveDirectory.appendingPathComponent(record.file)
        let partial = layout.trackArchiveDirectory.appendingPathComponent("\(name).trimming.m4a")
        let location = TrackAudioLocation.archived(
            track: .mic, record: record, directory: layout.trackArchiveDirectory, compactedAt: Date()
        )
        let frames = try exporter.export(location: location, from: cut.from, to: cut.to, destination: partial)
        try verify(partial, seconds: cut.seconds, name: name)
        staging.swaps.append((partial, source))
        return frames
    }

    /// Decodes the new file and compares its length with what it should hold,
    /// with the allowance compaction gives a fresh archive.
    private func verify(_ url: URL, seconds: Double, name: String) throws {
        let info: AudioFileInfo
        do {
            info = try inspector.decode(url: url)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw TrimError.verificationFailed(track: name)
        }
        guard abs(info.seconds - seconds) <= max(0.5, min(seconds * 0.01, 2.0)) else {
            try? FileManager.default.removeItem(at: url)
            throw TrimError.verificationFailed(track: name)
        }
    }

    /// Trims the listening copy with the same range, at the rate it already
    /// has, so the far end is not brought down to the archive's rate. Where
    /// it cannot be cut it is deleted, and processing mixes it again: it holds
    /// the removed stretch, so it must not stay.
    private func stageMixdown(layout: MeetingLayout, range: TrimRange, staging: inout Staging) {
        guard FileManager.default.fileExists(atPath: layout.recordingAudio.path) else { return }
        do {
            let info = try inspector.inspect(url: layout.recordingAudio)
            let whole = Double(info.frameCount) / info.sampleRate
            let to = range.keepsEnd ? whole : min(whole, range.end)
            guard to - range.start > 0 else {
                staging.remove(layout.recordingAudio)
                return
            }
            let record = AudioArchive.Track(
                file: layout.recordingAudio.lastPathComponent, sampleRate: info.sampleRate,
                channelCount: info.channelCount, frameCount: info.frameCount, seconds: whole,
                firstFrameHostTime: nil
            )
            let location = TrackAudioLocation.archived(
                track: .mic, record: record, directory: layout.root, compactedAt: Date()
            )
            let mixdown = TrackArchiveExporter(
                settings: .init(sampleRate: info.sampleRate, channelCount: info.channelCount, bitRate: 64_000)
            )
            let partial = layout.root.appendingPathComponent("recording.trimming.m4a")
            try mixdown.export(location: location, from: range.start, to: to, destination: partial)
            try verify(partial, seconds: to - range.start, name: "mixdown")
            staging.swaps.append((partial, layout.recordingAudio))
        } catch {
            Log.processing.notice("mixdown not trimmed: \(logSafeDescription(error), privacy: .public)")
            staging.remove(layout.recordingAudio)
        }
    }

    /// Writes a replacement beside every file measured on the meeting's
    /// timeline.
    private func stageTimelineFiles(store: MeetingStore, range: TrimRange, staging: inout Staging) throws {
        let layout = store.layout
        let manager = FileManager.default
        if manager.fileExists(atPath: layout.rawTranscript.path) {
            try stageRawTranscript(store: store, range: range, staging: &staging)
        }
        if manager.fileExists(atPath: layout.rawDiarization.path) {
            try staging.stage(
                ArchiveCoding.encode(MeetingTrim.trim(store.readRawDiarization(), to: range)),
                for: layout.rawDiarization
            )
        }
        if let evidence = store.readSpeechEvidence() {
            try staging.stage(ArchiveCoding.encode(MeetingTrim.trim(evidence, to: range)), for: layout.speechEvidence)
        }
        if let sensors = store.readRawSensors() {
            try staging.stage(ArchiveCoding.encode(MeetingTrim.trim(sensors, to: range)), for: layout.rawSensors)
        }
        if manager.fileExists(atPath: layout.speakerMap.path) {
            try staging.stage(
                ArchiveCoding.encode(MeetingTrim.trim(store.readSpeakerMap(), to: range)), for: layout.speakerMap
            )
        }
        if manager.fileExists(atPath: layout.speakerSuggestions.path) {
            try staging.stage(
                ArchiveCoding.encode(MeetingTrim.trim(store.readSpeakerSuggestions(), to: range)),
                for: layout.speakerSuggestions
            )
        }
        // The assembled transcript as written, not as read: reading applies
        // the speaker map's line cuts, and those are moved separately above.
        if manager.fileExists(atPath: layout.canonicalTranscript.path) {
            let data = try Data(contentsOf: layout.canonicalTranscript)
            let transcript = try ArchiveCoding.decode(
                CanonicalTranscript.self, from: data, path: layout.canonicalTranscript.path
            )
            try staging.stage(
                ArchiveCoding.encode(MeetingTrim.trim(transcript, to: range)), for: layout.canonicalTranscript
            )
        }
    }

    /// The model's words with the timings derived from them. A chunk of text
    /// only is cut by its alignment, and the alignment moves with it. An
    /// alignment whose chunk is gone is removed along with the words.
    private func stageRawTranscript(store: MeetingStore, range: TrimRange, staging: inout Staging) throws {
        let layout = store.layout
        let raw = try store.readRawTranscript()
        var alignments: [String: ChunkAlignment] = [:]
        for chunk in raw.chunks {
            if let alignment = store.readAlignment(chunkID: chunk.id) { alignments[chunk.id] = alignment }
        }
        let trimmed = MeetingTrim.trim(raw, alignments: alignments, to: range)
        try staging.stage(ArchiveCoding.encode(trimmed.transcript), for: layout.rawTranscript)
        for (id, alignment) in trimmed.alignments.sorted(by: { $0.key < $1.key }) {
            try staging.stage(ArchiveCoding.encode(alignment), for: layout.alignmentFile(chunkID: id))
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: layout.alignments.path)) ?? []
        for name in files.sorted() where name.hasSuffix(".json") {
            if trimmed.alignments[String(name.dropLast(".json".count))] == nil {
                staging.remove(layout.alignments.appendingPathComponent(name))
            }
        }
    }
}
