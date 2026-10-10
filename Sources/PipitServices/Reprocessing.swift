import Foundation
import PipitCore

/// Puts a finished meeting back to the point where processing starts, so the
/// pipeline runs cleaning, transcription and diarization over it again.
///
/// The recording and the manifest are never touched. What goes is what was
/// derived from them: the raw and assembled transcripts, the diarization, the
/// speech evidence, the cleaned microphone, the alignments, the model
/// responses, the markdown and the summary. The speaker map stays, because it
/// holds the names a person typed and the line corrections they made, and the
/// pipeline reads those back the way it does after a re-analysis.
public enum Reprocessing {
    /// What was on disk before the reset, for a caller that wants a copy.
    public static func derivedFiles(in layout: MeetingLayout) -> [URL] {
        [
            layout.rawTranscript, layout.canonicalTranscript, layout.rawDiarization,
            layout.speechEvidence, layout.speakerMap, layout.speakerSuggestions,
            layout.alignments, layout.apiResponses, layout.transcriptMarkdown,
            layout.summary, layout.cleanedMicFile,
        ]
    }

    /// Where a backup of one meeting goes: a folder per meeting under `root`, and
    /// inside it one per backup, named for the moment it was taken.
    public static func backupDirectory(under root: URL, meetingID: String, at date: Date) -> URL {
        let stamp = ISO8601DateFormatter().string(from: date)
            .replacingOccurrences(of: ":", with: "-")
        return root.appendingPathComponent(meetingID, isDirectory: true)
            .appendingPathComponent(stamp, isDirectory: true)
    }

    /// Copies every derived file that exists into `directory`, keeping the
    /// meeting folder's own layout under it.
    public static func backUp(store: MeetingStore, to directory: URL) throws {
        try backUp(store: store, files: derivedFiles(in: store.layout), to: directory)
    }

    /// Copies the given files, and the metadata, into `directory`.
    ///
    /// A file that does not exist is skipped. A failure to copy one throws, so a
    /// caller that is about to replace the files can stop before it does.
    public static func backUp(store: MeetingStore, files: [URL], to directory: URL) throws {
        let root = store.layout.root
        for url in files + [store.layout.metadata] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let relative = url.path.dropFirst(root.path.count + 1)
            let destination = directory.appendingPathComponent(String(relative))
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
        }
    }

    /// The derived files that depend on the microphone alone, and so are the
    /// ones that change when the microphone is cleaned and transcribed again.
    ///
    /// The far end's words, its diarization, the summary and the typed speaker
    /// suggestions are not here: nothing done to the microphone changes them.
    /// The speaker map is, because the lines it corrects on the microphone
    /// cannot survive a new transcription.
    public static func microphoneDerivedFiles(store: MeetingStore) -> [URL] {
        let layout = store.layout
        var files = [
            layout.rawTranscript, layout.canonicalTranscript, layout.speechEvidence,
            layout.speakerMap, layout.transcriptMarkdown, layout.recordingAudio,
            layout.cleanedMicFile,
        ]
        let chunks = ((try? store.readRawTranscript())?.chunks ?? []).filter { $0.track == .mic }
        for chunk in chunks {
            files.append(layout.alignmentFile(chunkID: chunk.id))
            if let response = chunk.rawResponseFile {
                files.append(layout.raw.appendingPathComponent(response))
            }
        }
        return files
    }

    /// Removes the derived files and rewinds the processing state.
    ///
    /// Returns the metadata as written. The speaker map is kept on disk, and
    /// the cleaned microphone's record is cleared so the cleaner runs again
    /// from the recording.
    @discardableResult
    public static func reset(store: MeetingStore, now: Date = Date()) throws -> MeetingMetadata {
        var metadata = try store.readMetadata()
        for url in derivedFiles(in: store.layout) where url != store.layout.speakerMap {
            try? FileManager.default.removeItem(at: url)
        }
        metadata.processing = ProcessingStatus(state: .audioSafe, updatedAt: now)
        metadata.cleanedMic = nil
        metadata.cleaningOutcome = nil
        try store.writeMetadata(metadata)
        return metadata
    }
}
