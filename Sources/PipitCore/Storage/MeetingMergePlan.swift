import Foundation

/// Which of several selected meetings become one, and which stay out.
///
/// The earliest meeting by start time is the primary, so the conversation reads
/// from the beginning and keeps the identifier that a link or a notification
/// already carries. Every other eligible meeting is combined into it.
///
/// A meeting that is still being recorded or finalised is skipped: its audio is
/// still being written, and a row that stops being listed while the recorder
/// owns it would hide a live recording. Meetings that are only being processed
/// are eligible, because the audio is safe and `combine` writes metadata the
/// same way the reconnect path does for a recording that has just finished.
public struct MeetingMergePlan: Sendable, Equatable {
    public struct Candidate: Sendable, Equatable {
        public var id: String
        public var startedAt: Date
        public var state: ProcessingState

        public init(id: String, startedAt: Date, state: ProcessingState) {
            self.id = id
            self.startedAt = startedAt
            self.state = state
        }

        /// Whether the audio is complete on disk.
        var isSettled: Bool { state != .recording && state != .finalizing }
    }

    /// The meeting the others are combined into. Nil when fewer than two
    /// meetings are eligible, so there is nothing to merge.
    public let primaryID: String?
    /// The meetings to combine into the primary, earliest first.
    public let combineIDs: [String]
    /// Selected meetings left out because they are still being recorded.
    public let skippedIDs: [String]

    public var canMerge: Bool { primaryID != nil }

    public init(_ candidates: [Candidate]) {
        var seen: Set<String> = []
        let unique = candidates.filter { seen.insert($0.id).inserted }
        let eligible = unique.filter(\.isSettled).sorted {
            ($0.startedAt, $0.id) < ($1.startedAt, $1.id)
        }
        skippedIDs = unique.filter { !$0.isSettled }.map(\.id)
        if eligible.count >= 2 {
            primaryID = eligible[0].id
            combineIDs = eligible.dropFirst().map(\.id)
        } else {
            primaryID = nil
            combineIDs = []
        }
    }
}
