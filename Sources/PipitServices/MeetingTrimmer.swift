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
    /// A trim of this meeting is running or being finished, and what was asked
    /// would change the files it is working on.
    case inProgress
    /// A trim could not reach the voice memory, and changes to who said what
    /// wait until it has.
    case voicePending

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
        case .inProgress: "trim.in_progress"
        case .voicePending: "trim.voice_pending"
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
    /// Called just after the journal is written, and just before the journal
    /// records that the metadata is. A test throws from them to stop where a
    /// failed directory sync or a crash would.
    public var afterJournalWritten: (@Sendable () throws -> Void)?
    public var beforeJournalUpdate: (@Sendable () throws -> Void)?

    public init(
        exporter: TrackArchiveExporter = TrackArchiveExporter(), inspector: AudioFileInspector = .init(),
        beforeSwap: (@Sendable (Int) throws -> Void)? = nil,
        afterJournalWritten: (@Sendable () throws -> Void)? = nil,
        beforeJournalUpdate: (@Sendable () throws -> Void)? = nil
    ) {
        self.exporter = exporter
        self.inspector = inspector
        self.beforeSwap = beforeSwap
        self.afterJournalWritten = afterJournalWritten
        self.beforeJournalUpdate = beforeJournalUpdate
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
        // A mixdown from before the raw/ layout would be left whole beside the
        // cut recording.
        guard metadata.audioArchive != nil,
            !FileManager.default.fileExists(atPath: layout.segments.path),
            !FileManager.default.fileExists(atPath: layout.legacyMixedAudio.path)
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
        // Where the kept audio really begins. The timeline's zero is the
        // earliest first frame of the tracks that are left, so a cut that
        // takes the earliest track whole starts the meeting later than asked.
        guard let range = MeetingTrim.effective(range, archive: archive) else { throw TrimError.invalidRange }

        var staging = Staging(root: layout.root)
        var committed = false
        // Says that replacements may be on disk without a journal, for the
        // launch sweep. Gone once the journal is, or the replacements are.
        try AtomicFile.write(Data(), to: layout.trimStaging)
        // Replacements written before a later one failed are not left behind.
        // Once the journal is written they are the only copy of what is kept.
        defer {
            if !committed { staging.discard() }
            try? FileManager.default.removeItem(at: layout.trimStaging)
        }

        let audio = try stageAudio(store: store, metadata: metadata, archive: archive, range: range, staging: &staging)
        let clusterSeconds = try stageTimelineFiles(store: store, range: range, staging: &staging)
        staging.remove(layout.apiResponses)
        // The folder suggestion quotes the speech it was made from.
        for url in [layout.summary, layout.structuredSummary, layout.transcriptMarkdown, layout.folderSuggestion] {
            staging.remove(url)
        }

        // On disk before the journal says they are: a power loss after the
        // journal must not find a replacement that was only in the cache.
        let swaps = try staging.flushed()
        let journal = TrimJournal(
            createdAt: now, start: range.start, end: range.keepsEnd ? nil : range.end,
            swaps: swaps, removals: staging.removals.map(staging.relative),
            metadata: MeetingTrim.change(
                metadata, to: range, archive: audio.archive, cleanedMic: audio.cleaned, at: now),
            clusterSeconds: clusterSeconds
        )
        do {
            try store.writeTrimJournal(journal)
            try afterJournalWritten?()
        } catch {
            // The write can fail after the journal was renamed into place, in
            // the directory sync. The replacements are about to be deleted, so
            // the journal that names them goes first. If it cannot be removed
            // they are kept, and it finishes the trim.
            try? FileManager.default.removeItem(at: layout.trimJournal)
            if FileManager.default.fileExists(atPath: layout.trimJournal.path) { committed = true }
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
        let manager = FileManager.default
        // The marker a trim leaves while it stages outlives a crash, and with
        // the swap done it no longer says anything.
        defer { if journal.swapped { try? manager.removeItem(at: store.layout.trimStaging) } }
        guard !journal.swapped else { return journal }
        let root = store.layout.root
        for (position, swap) in journal.swaps.enumerated() {
            try beforeSwap?(position)
            let staged = root.appendingPathComponent(swap.staged)
            let target = root.appendingPathComponent(swap.target)
            // `rename(2)` is how a staged file stops being there, so one that is
            // gone has been swapped in, and the file at the target is it: an
            // edit made since, to a speaker map for instance, does not undo
            // that. One that is there with the wrong size is not the
            // replacement that was checked. If the target already has the
            // recorded size, it is an old file left by a swap that exchanged
            // instead of renaming, and holds the removed stretch.
            guard let stagedSize = Self.size(of: staged) else {
                guard manager.fileExists(atPath: target.path) else { throw TrimError.filesNotWritten }
                continue
            }
            if stagedSize != swap.size {
                guard Self.size(of: target) == swap.size else { throw TrimError.filesNotWritten }
                try manager.removeItem(at: staged)
                continue
            }
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            // rename(2) replaces the target in one step and never parks the
            // old file anywhere. `replaceItemAt` exchanges and then deletes,
            // and a stop between the two leaves the old file at the staged
            // path with the new one in place.
            guard rename(staged.path, target.path) == 0 else { throw TrimError.filesNotWritten }
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
        try beforeJournalUpdate?()
        var done = journal
        done.swapped = true
        try store.writeTrimJournal(done)
        try? manager.removeItem(at: store.layout.trimStaging)
        return done
    }

    private static func size(of url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    /// Removes what a trim that stopped before its journal was written left
    /// beside the files it meant to replace. With no journal nothing refers to
    /// them. They hold only the part that was to be kept, so they are clutter
    /// and a second copy of audio, not removed content.
    ///
    /// A trim leaves `raw/trim.staging` while it stages, so the launch sweep
    /// looks for that one file and not in every folder of every meeting.
    public static func removeLeftovers(layout: MeetingLayout) {
        guard !FileManager.default.fileExists(atPath: layout.trimJournal.path) else { return }
        let manager = FileManager.default
        defer { try? manager.removeItem(at: layout.trimStaging) }
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
        // Listed before it is written, so a failed export's partial is
        // discarded with the rest.
        staging.swaps.append((partial, source))
        let frames = try exporter.export(location: location, from: cut.from, to: cut.to, destination: partial)
        try verify(partial, seconds: cut.seconds, name: name)
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
        let partial = layout.root.appendingPathComponent("recording.trimming.m4a")
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
            staging.swaps.append((partial, layout.recordingAudio))
            try mixdown.export(location: location, from: range.start, to: to, destination: partial)
            try verify(partial, seconds: to - range.start, name: "mixdown")
        } catch {
            Log.processing.notice("mixdown not trimmed: \(logSafeDescription(error), privacy: .public)")
            // Not cut, so it is deleted; what a failed export wrote goes too.
            staging.swaps.removeAll { $0.from == partial }
            try? FileManager.default.removeItem(at: partial)
            staging.remove(layout.recordingAudio)
        }
    }

    /// Writes a replacement beside every file measured on the meeting's
    /// timeline.
    private func stageTimelineFiles(
        store: MeetingStore, range: TrimRange, staging: inout Staging
    ) throws -> [String: Double]? {
        let layout = store.layout
        let manager = FileManager.default
        var clusterSeconds: [String: Double]?
        if manager.fileExists(atPath: layout.rawTranscript.path) {
            try stageRawTranscript(store: store, range: range, staging: &staging)
        }
        if manager.fileExists(atPath: layout.rawDiarization.path) {
            let original = try store.readRawDiarization()
            let trimmed = MeetingTrim.trim(original, to: range)
            clusterSeconds = MeetingTrim.occurrenceSeconds(after: trimmed, before: original)
            try staging.stage(ArchiveCoding.encode(trimmed), for: layout.rawDiarization)
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
            let trimmed = MeetingTrim.trim(transcript, to: range)
            try staging.stage(ArchiveCoding.encode(trimmed), for: layout.canonicalTranscript)
            // The microphone has no diarization cluster; its occurrence row
            // holds the seconds the local user speaks in the transcript.
            func localSeconds(_ transcript: CanonicalTranscript) -> Double {
                transcript.speakers.first { $0.key == SpeakerLabel.localUser }?.speechSeconds ?? 0
            }
            if localSeconds(transcript) > 0 {
                clusterSeconds = (clusterSeconds ?? [:]).merging([SpeakerLabel.localUser: localSeconds(trimmed)]) { $1 }
            }
        }
        return clusterSeconds
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
