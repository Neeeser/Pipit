import AppKit
import Foundation
import PipitCore
import Synchronization

/// Reading the whole archive for the meetings window.
///
/// Every read here is file work over every meeting on disk, so none of it runs
/// on the main actor: at a few hundred meetings the walk alone is long enough
/// to drop frames in the window that asked for it, and that actor is also the
/// one arming the next recording.
extension PipitRuntime {
    /// Every meeting, with who was in it and the notes a search can match.
    ///
    /// A row is kept with the identities of the files it was built from, so an
    /// unchanged meeting costs a few `stat` calls rather than a decode of its
    /// metadata, speaker map and notes. Each row's speakers come from its
    /// `transcript.json`, the largest file in the folder; what that read finds
    /// is also cached on disk between launches, so the first list after a
    /// launch does not parse every transcript.
    ///
    /// Rows rather than the decoded files, because the rows are what the
    /// window holds anyway: caching every meeting's metadata and speaker map
    /// as well cost about eight kilobytes a meeting for as long as Pipit ran.
    public func meetingRows(priority: TaskPriority = .userInitiated) async -> [MeetingRow] {
        await folderChangesSettled()
        let repository = self.repository
        let caches = savedCaches
        let rows = await Task.detached(priority: priority) {
            for cache in caches { cache.restoreOnce() }
            let rows = Self.listRows(repository)
            // The recording lengths the player read since the last save go
            // out with this one too.
            for cache in caches { cache.saveIfChanged() }
            return rows
        }.value
        lastMeetingRows = rows
        return rows
    }

    /// What `listMeetings` lists, as rows, reusing every row whose files are
    /// unchanged since it was built.
    private nonisolated static func listRows(_ repository: MeetingRepository) -> [MeetingRow] {
        let root = repository.archive.root.path
        var rows: [MeetingRow] = []
        var built: [String: CachedRow] = [:]
        let held = rowCache.withLock { $0 }
        // Backwards, as `listMeetings` reads them, so the recordings in `Parts`
        // folders are seen before the meetings they belong to.
        for directory in repository.meetingDirectories().reversed() {
            let key = root + "\u{0}" + directory.path
            let inputs = rowInputs(directory)
            if let cached = held[key], cached.inputs == inputs {
                built[key] = cached
                if let row = cached.row { rows.append(row) }
                continue
            }
            let summary = repository.summary(forDirectory: directory)
            let row = summary.map { row(summary: $0, stores: repository.stores(ofConversation: $0)) }
            // A conversation in several recordings also reads the other
            // recordings' files, which these inputs do not cover, so it is
            // built again on every list. There are few of them.
            if (summary?.recordingCount ?? 1) == 1 {
                built[key] = CachedRow(inputs: inputs, row: row)
            }
            if let row { rows.append(row) }
        }
        // Only what this listing saw, so a deleted meeting's row goes too.
        rowCache.withLock { $0 = built.merging($0.filter { !$0.key.hasPrefix(root + "\u{0}") }) { new, _ in new } }
        return rows.sorted { $0.startedAt > $1.startedAt }
    }

    /// The files a single-recording row is built from.
    private nonisolated static func rowInputs(_ directory: URL) -> [FileIdentity?] {
        let layout = MeetingLayout(root: directory)
        return [
            layout.metadata, layout.legacyMetadata, layout.speakerMap, layout.canonicalTranscript,
            layout.notes, layout.folderSuggestion,
        ].map { FileIdentity(path: $0.path) }
    }

    private struct CachedRow: Sendable {
        var inputs: [FileIdentity?]
        /// Nil for a folder that lists no meeting, such as a folded half.
        var row: MeetingRow?
    }

    /// Keyed by the archive root and the meeting's folder, so choosing a new
    /// meetings folder in Settings starts from nothing.
    private nonisolated static let rowCache = Mutex<[String: CachedRow]>([:])

    /// Where the speakers read from each transcript are kept between launches.
    /// A cache: deleting it costs one slower first read and nothing else.
    public nonisolated var transcriptSpeakersCacheFile: URL {
        applicationSupport.appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("transcript-speakers.json")
    }

    /// The caches of what was read from meeting files that are kept on disk
    /// between launches, so the first list and the first click after a launch
    /// do not parse every transcript and open every recording again.
    private nonisolated var savedCaches: [any SavedFileCache] {
        let folder = applicationSupport.appendingPathComponent("Caches", isDirectory: true)
        return [
            SavedCache(
                cache: MeetingStore.transcriptSpeakersCache,
                format: MeetingStore.transcriptSpeakersFormat, file: transcriptSpeakersCacheFile
            ),
            SavedCache(
                cache: MeetingStore.recordingDurationCache, format: 1,
                file: folder.appendingPathComponent("recording-durations.json")
            ),
        ]
    }
    /// One meeting's row again, after something rewrote its files.
    ///
    /// `clusters` is what the pane open on the meeting has already read. The
    /// transcript is the largest file in the folder, so this reads the three
    /// small ones and takes the clusters from the caller. Passing nil reads
    /// them.
    ///
    /// The identifier is resolved through the whole conversation, so a
    /// correction made on the second half of a dropped call reaches the row the
    /// list draws for it. The row is always the conversation's own, which is
    /// what keeps a folded continuation out of the listing while an operation
    /// named by its identifier still lands.
    public func meetingRow(id: String, clusters: [TranscriptSpeaker]?) async -> MeetingRow? {
        await folderChangesSettled()
        let repository = self.repository
        return await Task.detached(priority: .userInitiated) {
            guard let logical = repository.logicalMeeting(id: id),
                let summary = repository.summary(
                    forDirectory: logical.primary.store.layout.root
                )
            else { return nil }
            return Self.row(
                summary: summary,
                stores: logical.recordings.map(\.store),
                clusters: clusters
            )
        }.value
    }

    /// A row's speakers are the clusters its transcript uses, named through its
    /// own `speakers.map.json`.
    ///
    /// The map rather than the identity store, which answers one query per
    /// meeting. The identifier on the entry is what keeps a person the same
    /// colour here and in the People window.
    ///
    /// The clusters come from the transcript because the map holds only the
    /// ones that have a name. Reading the speakers from the map alone reported
    /// no voices to name in exactly the meetings holding the most of them.
    /// Every recording of the conversation, because the list draws one row for
    /// a call that dropped and was rejoined. Reading the first half alone meant
    /// a voice that only spoke after the drop was in no row, and the Unnamed
    /// filter under-reported exactly the meetings that are hardest to work
    /// through.
    ///
    /// A cluster identifier names a speaker inside one recording, and both
    /// halves number theirs from zero, so each half's keys are qualified by the
    /// recording they came from before they are put in one list.
    private nonisolated static func row(
        summary: MeetingSummary, stores: [MeetingStore], clusters: [TranscriptSpeaker]? = nil
    ) -> MeetingRow {
        var speakers: [MeetingRowSpeaker] = []
        var notes: [String] = []
        for (index, store) in stores.enumerated() {
            let map = (try? store.readSpeakerMap()) ?? SpeakerMap()
            let named = map.entries
                .compactMap { key, assignment -> MeetingRowSpeaker? in
                    guard !assignment.displayName.isEmpty else { return nil }
                    return MeetingRowSpeaker(
                        key: key,
                        displayName: assignment.displayName,
                        identityID: assignment.identityID,
                        participantID: assignment.participantID
                    )
                }
                .sorted { $0.key < $1.key }
            // The clusters the caller passed belong to the recording the pane
            // is keyed on, which is the first. The rest are read.
            let keys =
                (index == 0 ? clusters : nil)
                ?? ((try? store.readTranscriptSpeakers()) ?? [])
            speakers.append(
                contentsOf: MeetingsDirectoryFilter.speakers(
                    clusters: keys, named: named, recordingIndex: index
                ))
            let text = store.readNotes()
            if !text.isEmpty { notes.append(text) }
        }
        // Only for a meeting that could still act on one. A filed meeting and a
        // meeting that turned the offer down are the common cases, and neither
        // costs a read.
        let offered = stores.first.flatMap { store -> FolderSuggestion? in
            guard summary.folderName == nil else { return nil }
            guard let metadata = try? store.readMetadata(),
                metadata.acceptsFolderSuggestion
            else { return nil }
            return store.readFolderSuggestion()
        }
        return MeetingRow(
            summary: summary, speakers: speakers, notes: notes.joined(separator: "\n"),
            folderSuggestion: offered
        )
    }

    /// The transcripts of the meetings named, lowercased, for searching.
    ///
    /// Built in the background after the list is already on screen, and
    /// searched only once it is ready. A search that works on titles
    /// immediately and gains the words a moment later beats a list that waits
    /// for a hundred file reads before it draws.
    ///
    /// The identifiers are named rather than the archive walked, so a rename
    /// and a rebuild each cost one meeting's read instead of the whole archive.
    /// A meeting with nothing written yet is absent from the result rather than
    /// present and empty, which is what lets the caller ask again once it has
    /// words.
    ///
    /// Answers under the conversation's identifier, holding every recording of
    /// it. A call that dropped and was rejoined keeps the second half's words in
    /// the second half's own folder, and the list draws one row for both, so an
    /// index built from the first half alone could not find anything said after
    /// the drop.
    ///
    /// The markdown is read rather than the canonical JSON, because it is the
    /// smaller of the two and holds the same words.
    public func transcriptSearchIndex(for meetingIDs: Set<String>) async -> [String: String] {
        await folderChangesSettled()
        let repository = self.repository
        return await Task.detached(priority: .utility) {
            var index: [String: String] = [:]
            for meetingID in meetingIDs {
                guard let logical = repository.logicalMeeting(id: meetingID) else { continue }
                let text = ([logical.primary] + logical.continuations)
                    .compactMap { recording in
                        // A part can move into or out of its conversation's
                        // folder between the lookup and the read, so a file
                        // that is gone is looked up once more where it went.
                        Self.readTranscript(recording.store)
                            ?? repository.findMeeting(id: recording.metadata.id, includingMerged: true)
                            .flatMap { Self.readTranscript($0.store) }
                    }
                    .joined(separator: "\n")
                guard !text.isEmpty else { continue }
                index[logical.id] = text.lowercased()
            }
            return index
        }.value
    }

    private nonisolated static func readTranscript(_ store: MeetingStore) -> String? {
        try? String(contentsOf: store.layout.transcriptMarkdown, encoding: .utf8)
    }

    /// Opens the folder holding every meeting.
    public func revealArchive() {
        NSWorkspace.shared.open(repository.archive.root)
    }

    /// Total recorded time across the meetings named, for the footer and the
    /// multiple-selection panel.
    public static func totalDuration(of rows: [MeetingRow]) -> Double {
        rows.reduce(0) { $0 + $1.summary.durationSeconds }
    }
}

/// One `FileReadCache` and the file it is kept in between launches.
protocol SavedFileCache: Sendable {
    /// Reads the file into the cache, the first time it is asked in this
    /// process.
    func restoreOnce()
    /// Writes the cache out when it holds entries the file does not.
    func saveIfChanged()
}

private struct SavedCache<Value: Codable & Sendable>: SavedFileCache {
    let cache: FileReadCache<Value>
    let format: Int
    let file: URL

    /// Under the lock, so a second list that starts while the file is being
    /// read waits for it rather than parsing every transcript itself.
    func restoreOnce() {
        savedCacheState.withLock { state in
            guard state[file.path] == nil else { return }
            state[file.path] = cache.changeCount
            guard let data = try? Data(contentsOf: file) else { return }
            cache.restore(from: data, format: format)
        }
    }

    /// Under the lock too, so two saves cannot leave the older copy on disk.
    func saveIfChanged() {
        savedCacheState.withLock { state in
            let count = cache.changeCount
            guard state[file.path] != count else { return }
            state[file.path] = count
            write()
        }
    }

    private func write() {
        do {
            let data = try cache.encoded(format: format)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try AtomicFile.write(data, to: file)
        } catch {
            Log.storage.error("cache not saved: \(logSafeDescription(error), privacy: .public)")
        }
    }
}

/// Per cache file read in this process, the cache's change count when the
/// file last matched it.
private let savedCacheState = Mutex<[String: Int]>([:])
