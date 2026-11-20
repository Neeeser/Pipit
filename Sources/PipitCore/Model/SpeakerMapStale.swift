import Foundation

extension SpeakerMap {
    /// Removes the names of cluster keys that a new diarization no longer has,
    /// and returns how many went.
    ///
    /// Processing a meeting again keeps its speaker map, so a person's names
    /// survive. A different diarizer numbers its clusters differently, so
    /// every automatic name in the old map is then keyed to nothing: it names
    /// no line, and it is still counted and shown as a named speaker.
    ///
    /// A name a person set is kept, because it is theirs and nothing here can
    /// say the voice is gone. The exception is a person who has been named
    /// again on a current key: the stale entry is that same person under a
    /// number that no longer exists, so it is carried over by being dropped.
    @discardableResult
    public mutating func dropEntriesForVanishedClusters(keeping liveKeys: Set<String>) -> Int {
        let stale = entries.filter { key, _ in
            key.contains("_speaker_") && !liveKeys.contains(key)
        }
        let namedNow = Set(
            entries.filter { liveKeys.contains($0.key) }.compactMap { $0.value.identityID }
        )
        var dropped = 0
        for (key, assignment) in stale {
            let carried = assignment.identityID.map(namedNow.contains) ?? false
            guard assignment.origin != .human || carried else { continue }
            entries.removeValue(forKey: key)
            dropped += 1
        }
        return dropped
    }
}
