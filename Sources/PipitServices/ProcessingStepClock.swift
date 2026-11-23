import Foundation
import PipitCore

/// Times each step of the meetings being processed, from their progress
/// reports, and hands back a meeting's step times when it completes.
///
/// Only a run watched from its first step is timed. A run picked up after a
/// relaunch starts partway through a step, and that step's time would be too
/// short to learn from. Time spent waiting for a recording or another meeting
/// is left out, since it says nothing about how fast this Mac is.
public struct ProcessingStepClock: Sendable, Equatable {
    public struct Running: Sendable, Equatable {
        public var step: ProcessingStep
        public var startedAt: Date
        /// Waiting already over within this step.
        public var waitedSeconds: Double
        public var waitingSince: Date?
        /// The furthest the step's own progress has reached. A fraction that
        /// goes back, as alignment's after the words, never moves the bar back.
        public var reached: Double?
        var finished: [ProcessingStep: Double]
        var timedFromStart: Bool

        /// Seconds of work in the current step, waiting left out.
        public func secondsInStep(at now: Date) -> Double {
            let waiting = waitingSince.map { now.timeIntervalSince($0) } ?? 0
            return max(now.timeIntervalSince(startedAt) - waitedSeconds - waiting, 0)
        }
    }

    public private(set) var running: [String: Running] = [:]

    public init() {}

    /// Takes one report. Returns the meeting's step times when the report
    /// says it completed and the whole run was timed.
    public mutating func observe(_ progress: ProcessingPipeline.Progress, at now: Date) -> [ProcessingStep: Double]? {
        let id = progress.meetingID
        if progress.state == .complete {
            guard let entry = running.removeValue(forKey: id), entry.timedFromStart else { return nil }
            var finished = entry.finished
            finished[entry.step] = entry.secondsInStep(at: now)
            return finished
        }
        guard let step = progress.step else {
            running.removeValue(forKey: id)
            return nil
        }
        var entry =
            running[id]
            ?? Running(
                step: step, startedAt: now, waitedSeconds: 0, waitingSince: nil, reached: nil, finished: [:],
                timedFromStart: step == .save)
        if step != entry.step {
            // A failed stage ends the entry through `forget`, so a retry never
            // reaches here; the steps of one run only move forward.
            entry.finished[entry.step] = entry.secondsInStep(at: now)
            entry.step = step
            entry.startedAt = now
            entry.waitedSeconds = 0
            entry.waitingSince = nil
            entry.reached = nil
        }
        if progress.isWaiting {
            if entry.waitingSince == nil { entry.waitingSince = now }
        } else if let since = entry.waitingSince {
            entry.waitedSeconds += now.timeIntervalSince(since)
            entry.waitingSince = nil
        }
        if let fraction = Self.fraction(of: progress) {
            entry.reached = max(entry.reached ?? 0, fraction)
        }
        running[id] = entry
        return nil
    }

    /// Forgets a meeting whose run stopped without completing.
    public mutating func forget(_ meetingID: String) {
        running.removeValue(forKey: meetingID)
    }

    static func fraction(of progress: ProcessingPipeline.Progress) -> Double? {
        if let fraction = progress.fraction { return min(max(fraction, 0), 1) }
        guard progress.totalChunks > 0 else { return nil }
        return Double(progress.completedChunks) / Double(progress.totalChunks)
    }
}

/// This Mac's step times, kept in Application Support beside the settings.
public struct ProcessingTimeStore: Sendable {
    public let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("processing-times.json")
    }

    public func load() -> ProcessingTimeHistory {
        guard let data = try? Data(contentsOf: url),
            let history = try? ArchiveCoding.decode(ProcessingTimeHistory.self, from: data, path: url.path)
        else { return ProcessingTimeHistory() }
        return history
    }

    public func save(_ history: ProcessingTimeHistory) throws {
        try AtomicFile.write(try ArchiveCoding.encode(history), to: url)
    }
}
