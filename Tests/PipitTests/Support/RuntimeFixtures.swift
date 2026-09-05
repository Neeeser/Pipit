import AppKit
import Foundation
import PipitCore
import PipitIntegrations
import PipitServices

/// A runtime and an archive under one temporary root.
public enum RuntimeFixtures {
    /// A calendar pinned to one zone, so a date in a test means the same thing
    /// on every machine that runs it.
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// A meeting on disk whose transcript holds the clusters named, plus the
    /// bucket for words no diarization interval claimed.
    public static func makeMeeting(
        root: URL, clusters: [String], words: String = "the northwind renewal",
        source: MeetingSource = .googleMeet, title: String = "Design review",
        startedAt: Date = Date(timeIntervalSince1970: 1_787_070_000)
    ) throws -> (id: String, store: MeetingStore) {
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = startedAt
        let created = try repository.createMeeting(
            source: source, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: title, timestampFallback: "f"), now: started
        )
        _ = try created.store.updateMetadata {
            $0.durationSeconds = 600
            $0.processing = ProcessingStatus(state: .complete, updatedAt: started)
        }
        let keys = clusters + [SpeakerLabel.unattributed(track: .remote)]
        let utterances = keys.enumerated().map { index, key in
            Utterance(
                id: "u\(index)", start: Double(index) * 10, end: Double(index) * 10 + 8,
                track: .remote, rawSpeakerLabel: key, speakerKey: key,
                text: words, chunkID: "c1", model: "m"
            )
        }
        try created.store.writeCanonicalTranscript(
            CanonicalTranscript(generatedAt: started, utterances: utterances)
        )
        return (created.metadata.id, created.store)
    }

    /// Where a runtime built here puts the meetings it trashes.
    public static func trashDirectory(under root: URL) -> URL {
        root.appendingPathComponent("Trash")
    }

    /// A runtime pointed at one temporary archive, with a Trash of its own.
    ///
    /// The Finder's own Trash would fill with the archives these tests build,
    /// so a trashed folder is moved here instead. It is also what lets a test
    /// see that a meeting was moved rather than unlinked.
    ///
    /// `backend` replaces the cloud client, so a test can make the runtime's own
    /// pipeline do something while it files a meeting.
    @MainActor
    public static func makeRuntime(root: URL, backend: (any AIBackend)? = nil) -> PipitRuntime {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let trash = trashDirectory(under: root)
        let runtime = PipitRuntime(settingsDirectory: root, backend: backend, trash: { folder in
            try FileManager.default.createDirectory(
                at: trash, withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(
                at: folder, to: trash.appendingPathComponent(folder.lastPathComponent)
            )
        })
        var settings = runtime.settings
        settings.storageRootPath = root.appendingPathComponent("Meetings").path
        runtime.update(settings: settings)
        return runtime
    }
}
