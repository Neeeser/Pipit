import Foundation

/// What a trim changes in a meeting's own record, as absolute values.
///
/// Absolute rather than relative to the old record, so applying it twice
/// leaves the same result. A trim that was interrupted after this record was
/// written is finished by applying it again.
public struct TrimMetadataChange: Codable, Sendable, Equatable {
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Double
    public var audioArchive: AudioArchive
    /// The cleaned microphone's new record, or nil when it keeps its old one.
    public var cleanedMicrophone: AudioArchive.Track?
    /// The kept stretch holds no microphone audio, so the cleaned file and its
    /// record go.
    public var dropsCleanedMicrophone: Bool
    public var at: Date

    public init(
        startedAt: Date, endedAt: Date, durationSeconds: Double, audioArchive: AudioArchive,
        cleanedMicrophone: AudioArchive.Track?, dropsCleanedMicrophone: Bool, at: Date
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.audioArchive = audioArchive
        self.cleanedMicrophone = cleanedMicrophone
        self.dropsCleanedMicrophone = dropsCleanedMicrophone
        self.at = at
    }

    /// Writes only the fields a trim owns, so an edit the person made to the
    /// title or notes while the files were being cut is not overwritten.
    /// Processing goes back to enrichment, so the summary, the title and the
    /// description are written again from what is left.
    public func apply(to metadata: inout MeetingMetadata) {
        metadata.startedAt = startedAt
        metadata.endedAt = endedAt
        metadata.durationSeconds = durationSeconds
        metadata.runs = metadata.runs.map { run in
            var moved = run
            moved.startedAt = startedAt
            moved.endedAt = endedAt
            moved.durationSeconds = durationSeconds
            return moved
        }
        metadata.audioArchive = audioArchive
        if dropsCleanedMicrophone {
            metadata.cleanedMic = nil
        } else if let cleanedMicrophone, var cleaned = metadata.cleanedMic {
            cleaned.track = cleanedMicrophone
            metadata.cleanedMic = cleaned
        }
        // Enrichment fills the description only when it is empty, so the old
        // one, which describes the removed stretch too, has to go.
        metadata.descriptionText = nil
        // Likewise the generated title, which can name something said in the
        // removed stretch and would otherwise stay where enrichment is off or
        // fails.
        metadata.titles.ai = nil
        metadata.trimmedAt = at
        metadata.processing.attempts[ProcessingState.enriching.rawValue] = nil
        metadata.processing.state = .enriching
        metadata.processing.updatedAt = at
        metadata.processing.completedStages.removeAll { $0 == .enriching || $0 == .complete }
        metadata.processing.lastFailure = nil
        metadata.processing.failedStage = nil
    }
}

/// The record that a trim is being swapped in and followed up.
///
/// A trim replaces several files. The journal is written once every
/// replacement exists beside the file it replaces and has been checked, and it
/// is deleted when the follow-up is done: the transcript rebuilt and the
/// meeting processed again. While it exists the meeting is in one of three
/// states: nothing was swapped yet or only some files were, and the rest can
/// be finished from what the journal lists; or the swap is complete and the
/// follow-up is not. Launch carries on from whichever it finds, a new trim
/// refuses to start over it, and every step is safe to repeat.
///
/// Finished rather than rolled back, because the audio the person asked to
/// delete is already unrecoverable once the first file is swapped in, and the
/// replacements were checked before the journal was written.
public struct TrimJournal: Codable, Sendable, Equatable {
    /// A replacement and the file it replaces, relative to the meeting folder.
    public struct Swap: Codable, Sendable, Equatable {
        public var staged: String
        public var target: String
        /// The replacement's size when it was checked. Finishing the swap
        /// compares against it, so a replacement that is missing or changed
        /// is an error and not a step to skip.
        public var size: Int64

        public init(staged: String, target: String, size: Int64) {
            self.staged = staged
            self.target = target
            self.size = size
        }
    }

    public static let currentVersion = 1

    public var version: Int
    public var createdAt: Date
    /// The kept stretch on the old timeline. `end` is nil when everything to
    /// the end of the recording is kept.
    public var start: Double
    public var end: Double?
    public var swaps: [Swap]
    /// Files and folders that held content from the removed stretch, relative
    /// to the meeting folder.
    public var removals: [String]
    public var metadata: TrimMetadataChange
    /// Set once every file and the metadata are in place. What is left is
    /// adjusting the voice memory, which lives outside the meeting folder.
    public var swapped: Bool
    /// Speech seconds each diarization cluster has left, for the voice memory.
    public var clusterSeconds: [String: Double]?
    /// Set once the voice memory has been moved with the audio. Its times are
    /// shifted, which is not safe to repeat, so this is written straight after.
    public var voiceMemoryAdjusted: Bool

    public init(
        createdAt: Date, start: Double, end: Double?, swaps: [Swap], removals: [String],
        metadata: TrimMetadataChange, swapped: Bool = false, voiceMemoryAdjusted: Bool = false,
        clusterSeconds: [String: Double]? = nil
    ) {
        self.clusterSeconds = clusterSeconds
        self.version = Self.currentVersion
        self.createdAt = createdAt
        self.start = start
        self.end = end
        self.swaps = swaps
        self.removals = removals
        self.metadata = metadata
        self.swapped = swapped
        self.voiceMemoryAdjusted = voiceMemoryAdjusted
    }
}

extension MeetingStore {
    /// The trim being swapped in, if one was started and not finished.
    public func readTrimJournal() throws -> TrimJournal? {
        guard FileManager.default.fileExists(atPath: layout.trimJournal.path) else { return nil }
        let data = try Data(contentsOf: layout.trimJournal)
        return try ArchiveCoding.decode(TrimJournal.self, from: data, path: layout.trimJournal.path)
    }

    public func writeTrimJournal(_ journal: TrimJournal) throws {
        try AtomicFile.write(try ArchiveCoding.encode(journal), to: layout.trimJournal)
    }

    public func removeTrimJournal() {
        try? FileManager.default.removeItem(at: layout.trimJournal)
    }
}

/// What a trim still owes the voice memory, for when the memory could not be
/// reached while the trim was finished.
///
/// A file of its own rather than the journal, so that waiting for the voice
/// database does not keep the meeting locked against every other change. The
/// adjustments are applied in order when the database is next open, each at
/// most once.
public struct TrimVoiceAdjustment: Codable, Sendable, Equatable {
    public var trimID: String
    public var start: Double
    public var end: Double?
    public var clusterSeconds: [String: Double]?

    public init(trimID: String, start: Double, end: Double?, clusterSeconds: [String: Double]?) {
        self.trimID = trimID
        self.start = start
        self.end = end
        self.clusterSeconds = clusterSeconds
    }
}

extension MeetingStore {
    public func readPendingVoiceAdjustments() -> [TrimVoiceAdjustment] {
        guard let data = try? Data(contentsOf: layout.trimVoicePending) else { return [] }
        return (try? ArchiveCoding.decode([TrimVoiceAdjustment].self, from: data, path: layout.trimVoicePending.path))
            ?? []
    }

    public func writePendingVoiceAdjustments(_ adjustments: [TrimVoiceAdjustment]) throws {
        if adjustments.isEmpty {
            try? FileManager.default.removeItem(at: layout.trimVoicePending)
        } else {
            try AtomicFile.write(try ArchiveCoding.encode(adjustments), to: layout.trimVoicePending)
        }
    }
}
