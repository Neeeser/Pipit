import Foundation
import PipitCore

/// One meeting as the command line reports it. The shape is the contract the
/// bundled skill relies on, so a change that is not additive raises
/// `MeetingReport.schemaVersion`.
public struct MeetingEntry: Codable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var source: String
    public var provider: String
    public var processingState: String
    public var folder: String?
    public var archived: Bool
    public var hasTranscript: Bool
    public var directory: String
}

/// The files one recording of a meeting holds. A call that dropped and was
/// rejoined has more than one, each in its own folder.
public struct RecordingFiles: Codable, Sendable, Equatable {
    public var directory: String
    public var transcript: String?
    public var summary: String?
    public var notes: String?
    public var recording: String?
}

public struct MeetingPerson: Codable, Sendable, Equatable {
    public var name: String
    public var isLocalUser: Bool
}

public struct MeetingListing: Codable, Sendable, Equatable {
    public var schemaVersion = MeetingReport.schemaVersion
    public var root: String
    public var meetings: [MeetingEntry]
}

public struct MeetingDetail: Codable, Sendable, Equatable {
    public var schemaVersion = MeetingReport.schemaVersion
    public var meeting: MeetingEntry
    public var participants: [MeetingPerson]
    public var recordings: [RecordingFiles]
}

public struct RootReport: Codable, Sendable, Equatable {
    public var schemaVersion = MeetingReport.schemaVersion
    public var root: String
}

/// Reads meetings out of an archive. Nothing here writes.
public struct MeetingReport: Sendable {
    public static let schemaVersion = 1

    private let repository: MeetingRepository

    public init(root: URL) {
        repository = MeetingRepository(root: root)
    }

    public func list(_ options: Invocation.ListOptions) -> [MeetingEntry] {
        var summaries = repository.listMeetings().filter { options.includeArchived || !$0.isArchived }
        if let since = options.since {
            summaries.removeAll { $0.startedAt < since }
        }
        if let folder = options.folder {
            summaries.removeAll { $0.folderName?.caseInsensitiveCompare(folder) != .orderedSame }
        }
        if let title = options.title {
            summaries.removeAll { !$0.title.localizedCaseInsensitiveContains(title) }
        }
        if let limit = options.limit { summaries = Array(summaries.prefix(limit)) }
        return summaries.map(Self.entry)
    }

    /// The meeting with this identifier, or the only one whose identifier
    /// starts with it. Identifiers carry a date and a title slug, so a prefix
    /// is how a person types one.
    public func detail(id: String) throws -> MeetingDetail {
        let summaries = repository.listMeetings()
        let matches: [MeetingSummary]
        if let exact = summaries.first(where: { $0.id == id }) {
            matches = [exact]
        } else {
            matches = summaries.filter { $0.id.hasPrefix(id) }
        }
        guard let summary = matches.first else { throw CLIError.meetingNotFound(id) }
        guard matches.count == 1 else { throw CLIError.ambiguousMeeting(id, matches: matches.count) }

        let primary = MeetingStore(layout: MeetingLayout(root: summary.directory))
        let participants = ((try? primary.readMetadata())?.participants ?? []).map {
            MeetingPerson(name: $0.displayName, isLocalUser: $0.isLocalUser)
        }
        return MeetingDetail(
            meeting: Self.entry(summary),
            participants: participants,
            recordings: repository.stores(ofConversation: summary).map { Self.files(in: $0.layout) }
        )
    }

    private static func entry(_ summary: MeetingSummary) -> MeetingEntry {
        MeetingEntry(
            id: summary.id, title: summary.title, startedAt: summary.startedAt,
            durationSeconds: summary.durationSeconds, source: summary.source.rawValue,
            provider: summary.provider.rawValue, processingState: summary.processingState.rawValue,
            folder: summary.folderName, archived: summary.isArchived,
            hasTranscript: summary.hasTranscript, directory: summary.directory.path
        )
    }

    private static func files(in layout: MeetingLayout) -> RecordingFiles {
        func existing(_ url: URL) -> String? {
            FileManager.default.fileExists(atPath: url.path) ? url.path : nil
        }
        return RecordingFiles(
            directory: layout.root.path, transcript: existing(layout.transcriptMarkdown),
            summary: existing(layout.summary), notes: existing(layout.notes),
            recording: existing(layout.recordingAudio)
        )
    }
}
