import Foundation

/// Keeps a conversation's recordings in one folder on disk.
///
/// A conversation is the recording it started with and every recording linked
/// to it afterwards. Linking writes a pointer each way in the metadata, and the
/// meetings window shows the recordings as one meeting. Finder showed them as
/// separate folders, one of which held a transcript of only the first few
/// minutes. Each linked recording's folder now sits in the `Parts` folder of
/// the recording the conversation started with, and a recording separated from
/// its conversation goes back beside it.
///
/// Folders move only when nothing is writing into them. A recording that is
/// still recording or processing stays where it is until the next tidy, and
/// `isHeld` names the recordings a job holds open. A move keeps the folder's
/// own name, so nothing inside the folder or its metadata changes, except for a
/// numbered suffix when the name is already taken where the folder lands.
extension MeetingRepository {
    public struct FolderMove: Sendable, Equatable {
        public var meetingID: String
        public var from: URL
        public var to: URL
    }

    /// Tidies every recording in the archive. Run at launch, which also moves
    /// conversations linked before this layout existed.
    @discardableResult
    public func tidyConversationFolders(isHeld: (String) -> Bool) -> [FolderMove] {
        tidy(meetingDirectories(), isHeld: isHeld)
    }

    /// Tidies the recordings of the conversations these meetings belong to,
    /// and any recording that was in one of their `Parts` folders.
    @discardableResult
    public func tidyConversationFolders(
        around meetingIDs: [String], isHeld: (String) -> Bool
    ) -> [FolderMove] {
        var directories: [URL] = []
        for id in meetingIDs {
            let roots =
                logicalMeeting(id: id)?.recordings.map(\.store.layout.root)
                ?? findMeeting(id: id, includingMerged: true).map { [$0.store.layout.root] } ?? []
            for root in roots {
                directories.append(root)
                directories.append(contentsOf: Self.partDirectories(of: root))
            }
        }
        var seen: Set<String> = []
        return tidy(directories.filter { seen.insert($0.standardizedFileURL.path).inserted }, isHeld: isHeld)
    }

    private func tidy(_ directories: [URL], isHeld: (String) -> Bool) -> [FolderMove] {
        var moves: [FolderMove] = []
        for directory in directories {
            guard let metadata = try? MeetingStore(layout: MeetingLayout(root: directory)).readMetadata(),
                Self.isSettled(metadata), !isHeld(metadata.id)
            else { continue }
            let destination: URL
            if let parentID = metadata.mergedIntoMeetingID {
                guard let owner = findMeeting(id: parentID, includingMerged: true),
                    owner.metadata.mergedIntoMeetingID == nil
                else { continue }
                destination = owner.store.layout.parts
            } else if Self.isPartDirectory(directory) {
                // Separated: back beside the recording it was a part of.
                destination = directory.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
            } else {
                continue
            }
            guard !Self.samePath(directory.deletingLastPathComponent(), destination) else { continue }
            if let move = moveFolder(directory, metadata: metadata, into: destination) {
                moves.append(move)
            }
        }
        return moves
    }

    /// Capture appends to paths it holds open and the pipeline holds absolute
    /// paths for the length of a run, so only a finished recording moves.
    private static func isSettled(_ metadata: MeetingMetadata) -> Bool {
        metadata.processing.state == .complete || metadata.processing.state == .failed
    }

    private func moveFolder(
        _ directory: URL, metadata: MeetingMetadata, into destination: URL
    ) -> FolderMove? {
        let fileManager = FileManager.default
        let name = Self.freeName(directory.lastPathComponent, in: destination)
        let target = destination.appendingPathComponent(name, isDirectory: true)
        do {
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            try fileManager.moveItem(at: directory, to: target)
        } catch {
            Log.storage.error("conversation folder not moved: \(logSafeDescription(error), privacy: .public)")
            return nil
        }
        Self.remember(id: metadata.id, directory: target, archiveRoot: archive.root)
        if name != directory.lastPathComponent, metadata.directoryName == directory.lastPathComponent {
            // Pipit named the folder, so it keeps owning the name it now has.
            // Left alone, the next settle would read the suffix as a rename
            // made by hand and stop following the title.
            do {
                _ = try MeetingStore(layout: MeetingLayout(root: target)).updateMetadata {
                    $0.directoryName = name
                }
            } catch {
                try? fileManager.moveItem(at: target, to: directory)
                Self.remember(id: metadata.id, directory: directory, archiveRoot: archive.root)
                return nil
            }
        }
        // A `Parts` folder left empty by the last part going is not kept.
        let source = directory.deletingLastPathComponent()
        if source.lastPathComponent == MeetingLayout.partsFolderName,
            (try? fileManager.contentsOfDirectory(atPath: source.path))?.isEmpty == true
        {
            try? fileManager.removeItem(at: source)
        }
        return FolderMove(meetingID: metadata.id, from: directory, to: target)
    }

    private static func freeName(_ base: String, in directory: URL) -> String {
        var candidate = base
        var suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = MeetingFolderName.fitToFilesystem("\(base) \(suffix)")
            suffix += 1
        }
        return candidate
    }

    private static func samePath(_ one: URL, _ other: URL) -> Bool {
        one.standardizedFileURL.resolvingSymlinksInPath().path
            == other.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
