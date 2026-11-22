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
    /// "Named again" means a person's own name or a confident recognition
    /// (a saved voice at High confidence, or stronger), and it matches by
    /// identity or, for a name with no voice profile, by display name. A weaker
    /// guess on the new key does not count, since the person's own name would
    /// then be lost for a guess that may be wrong.
    @discardableResult
    public mutating func dropEntriesForVanishedClusters(keeping liveKeys: Set<String>) -> Int {
        let stale = entries.filter { key, _ in
            key.contains("_speaker_") && !liveKeys.contains(key)
        }
        let namedNow = entries.filter { key, assignment in
            liveKeys.contains(key) && (assignment.origin == .human || assignment.origin >= .voiceProfile)
        }.map(\.value)
        let namedIdentities = Set(namedNow.compactMap(\.identityID))
        let namedNames = Set(namedNow.filter { $0.origin == .human }.map { $0.displayName.lowercased() })
        var dropped = 0
        for (key, assignment) in stale {
            let carried =
                (assignment.identityID.map(namedIdentities.contains) ?? false)
                || namedNames.contains(assignment.displayName.lowercased())
            guard assignment.origin != .human || carried else { continue }
            entries.removeValue(forKey: key)
            dropped += 1
        }
        return dropped
    }
}
