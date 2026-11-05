import Foundation

/// Keeps far-end speaker labels steady across repeated speaker passes.
///
/// Each pass over the audio so far clusters from scratch, so its cluster names
/// mean nothing from one pass to the next. A new cluster takes the label of
/// the earlier speaker it overlaps most in time; one that overlaps nobody, or
/// whose best match is already taken by a better-overlapping cluster, gets a
/// fresh label. Without this a line's speaker number would change every time
/// a pass finished.
public enum LiveSpeakerLabels {
    public struct Interval: Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var cluster: String

        public init(start: Double, end: Double, cluster: String) {
            self.start = start
            self.end = end
            self.cluster = cluster
        }
    }

    /// The turns of the new pass under steady labels, and which label each of
    /// its clusters became.
    ///
    /// - Parameter used: every label handed out so far in this recording, so
    ///   a fresh label never reuses one a past line still shows.
    public static func stabilize(
        previous: [LiveSpeakerTurn], intervals: [Interval], used: Set<String>
    ) -> (turns: [LiveSpeakerTurn], labels: [String: String]) {
        var overlap: [String: [String: Double]] = [:]
        for interval in intervals {
            for turn in previous where turn.end > interval.start && turn.start < interval.end {
                let shared = min(turn.end, interval.end) - max(turn.start, interval.start)
                overlap[interval.cluster, default: [:]][turn.speaker, default: 0] += shared
            }
        }
        // Strongest pairs first, so two clusters that both touch one earlier
        // speaker do not both take its label.
        var pairs: [(cluster: String, label: String, seconds: Double)] = []
        for (cluster, labels) in overlap {
            for (label, seconds) in labels where seconds > 0 { pairs.append((cluster, label, seconds)) }
        }
        pairs.sort { $0.seconds == $1.seconds ? $0.cluster < $1.cluster : $0.seconds > $1.seconds }
        var labels: [String: String] = [:]
        var taken: Set<String> = []
        for pair in pairs where labels[pair.cluster] == nil && !taken.contains(pair.label) {
            labels[pair.cluster] = pair.label
            taken.insert(pair.label)
        }
        var allUsed = used.union(taken)
        let clusters = intervals.sorted { $0.start < $1.start }.map(\.cluster)
        var next = 1
        for cluster in clusters where labels[cluster] == nil {
            while allUsed.contains("live-\(next)") { next += 1 }
            labels[cluster] = "live-\(next)"
            allUsed.insert("live-\(next)")
        }
        let turns = intervals.compactMap { interval -> LiveSpeakerTurn? in
            guard let label = labels[interval.cluster], interval.end > interval.start else { return nil }
            return LiveSpeakerTurn(start: interval.start, end: interval.end, speaker: label)
        }
        return (turns.sorted { $0.start < $1.start }, labels)
    }
}
