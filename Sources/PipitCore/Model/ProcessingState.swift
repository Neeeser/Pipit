import Foundation

/// The durable processing state machine. Each transition is written to disk before
/// the next stage starts, so an interrupted run resumes where it stopped.
///
/// `audioSafe` is the boundary that matters: nothing touches OpenAI before it, and
/// every stage after it is retryable without risking the recording.
public enum ProcessingState: String, Codable, Sendable, CaseIterable, Comparable {
    case recording
    case finalizing
    case audioSafe = "audio_safe"
    case transcribing
    case diarizing
    case resolvingSpeakers = "resolving_speakers"
    case enriching
    case complete
    case failed

    private var order: Int {
        switch self {
        case .recording: 0
        case .finalizing: 1
        case .audioSafe: 2
        case .transcribing: 3
        case .diarizing: 4
        case .resolvingSpeakers: 5
        case .enriching: 6
        case .complete: 7
        case .failed: 8
        }
    }

    public static func < (lhs: ProcessingState, rhs: ProcessingState) -> Bool {
        lhs.order < rhs.order
    }

    /// True once the source audio and its manifest are durable.
    public var isAudioSafe: Bool {
        switch self {
        case .recording, .finalizing: false
        case .audioSafe, .transcribing, .diarizing, .resolvingSpeakers, .enriching, .complete, .failed: true
        }
    }

    public var isTerminal: Bool { self == .complete }

    /// The stage that runs next when this one succeeds.
    public var next: ProcessingState? {
        switch self {
        case .recording: .finalizing
        case .finalizing: .audioSafe
        case .audioSafe: .transcribing
        case .transcribing: .diarizing
        case .diarizing: .resolvingSpeakers
        case .resolvingSpeakers: .enriching
        case .enriching: .complete
        case .complete, .failed: nil
        }
    }

    public var displayName: String {
        switch self {
        case .recording: "Recording"
        case .finalizing: "Finalizing"
        case .audioSafe: "Saved"
        case .transcribing: "Transcribing"
        case .diarizing: "Identifying speakers"
        case .resolvingSpeakers: "Matching names"
        case .enriching: "Writing notes"
        case .complete: "Complete"
        case .failed: "Needs attention"
        }
    }
}

public struct ProcessingFailure: Codable, Sendable, Equatable {
    public var stage: ProcessingState
    /// Written for the person, and never put in a diagnostic report.
    public var message: String
    public var isRetryable: Bool
    public var occurredAt: Date
    /// The failure's category, which a diagnostic report carries in place of
    /// the message. Absent from a meeting that failed before codes were
    /// recorded, which an older build reads past.
    public var code: DiagnosticCode?

    public init(
        stage: ProcessingState, message: String, isRetryable: Bool, occurredAt: Date, code: DiagnosticCode? = nil
    ) {
        self.stage = stage
        self.message = message
        self.isRetryable = isRetryable
        self.occurredAt = occurredAt
        self.code = code
    }
}

/// Persisted processing status for one meeting.
public struct ProcessingStatus: Codable, Sendable, Equatable {
    public var state: ProcessingState
    public var updatedAt: Date
    /// Stage name to the number of attempts that ended in a failure, so a retry
    /// loop is visible and boundable. An attempt that was interrupted by a quit
    /// is not counted, and a stage that succeeds starts again from zero.
    public var attempts: [String: Int]
    public var lastFailure: ProcessingFailure?
    /// Stages that finished successfully. A resumed run skips these.
    public var completedStages: [ProcessingState]
    /// The stage that failed, kept so `failed` knows where to resume from.
    public var failedStage: ProcessingState?
    /// Whether the cloud stages were passed over because no API key is stored.
    ///
    /// Recorded because skipping them is silent by design: a user who runs
    /// everything on this Mac never asked for a title or a summary and must not
    /// get a failure for one. That leaves a key which disappears looking
    /// exactly like a key which was never set, and the meeting completes with
    /// no summary and nothing on screen saying why.
    public var skippedForMissingKey: Bool

    public init(
        state: ProcessingState = .recording,
        updatedAt: Date = Date(),
        attempts: [String: Int] = [:],
        lastFailure: ProcessingFailure? = nil,
        completedStages: [ProcessingState] = [],
        failedStage: ProcessingState? = nil,
        skippedForMissingKey: Bool = false
    ) {
        self.state = state
        self.updatedAt = updatedAt
        self.attempts = attempts
        self.lastFailure = lastFailure
        self.completedStages = completedStages
        self.failedStage = failedStage
        self.skippedForMissingKey = skippedForMissingKey
    }

    /// Decoded by hand for one field only.
    ///
    /// Every `metadata.json` written before `skippedForMissingKey` existed has
    /// no key for it, and the synthesised decoder treats an absent key for a
    /// non-optional as a failure. That would make every meeting already on disk
    /// unreadable, so the field defaults to false and the rest decode as they
    /// always did.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(ProcessingState.self, forKey: .state)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        attempts = try container.decodeIfPresent([String: Int].self, forKey: .attempts) ?? [:]
        lastFailure = try container.decodeIfPresent(ProcessingFailure.self, forKey: .lastFailure)
        completedStages =
            try container.decodeIfPresent(
                [ProcessingState].self, forKey: .completedStages
            ) ?? []
        failedStage = try container.decodeIfPresent(ProcessingState.self, forKey: .failedStage)
        skippedForMissingKey =
            try container.decodeIfPresent(
                Bool.self, forKey: .skippedForMissingKey
            ) ?? false
    }

    public func hasCompleted(_ stage: ProcessingState) -> Bool {
        completedStages.contains(stage)
    }

    public func attemptCount(for stage: ProcessingState) -> Int {
        attempts[stage.rawValue] ?? 0
    }

    /// Failed attempts a stage gets before Pipit stops starting it on its own.
    public static let maxAttemptsPerStage = 3

    /// Whether the failure on this meeting is one that waiting can clear and
    /// every attempt at it has failed.
    ///
    /// The launch sweep leaves such a meeting for the Retry button, since
    /// another launch would repeat the same failure. A cause that does not
    /// clear by waiting (a missing key, a model that is not installed) is not
    /// counted: the person fixes it in Settings, nothing tells the sweep when
    /// they have, and it fails quickly without sending anything.
    public var isOutOfAttempts: Bool {
        guard state == .failed, let failure = lastFailure, failure.isRetryable,
            let stage = resumeStage
        else { return false }
        return attemptCount(for: stage) >= Self.maxAttemptsPerStage
    }

    /// The stage a resumed run should start from. A failed job resumes at the stage
    /// that failed; source audio is never revisited.
    public var resumeStage: ProcessingState? {
        if state == .complete { return nil }
        if state == .failed { return failedStage ?? .audioSafe }
        return state
    }

    public mutating func advance(to stage: ProcessingState, at date: Date) {
        if let current = state.next, current == stage || stage == .complete {
            if !completedStages.contains(state), state != .failed { completedStages.append(state) }
        }
        state = stage
        updatedAt = date
        if stage != .failed {
            lastFailure = nil
            failedStage = nil
        }
    }

    /// Counts an attempt at `stage` that failed.
    public mutating func recordAttempt(for stage: ProcessingState) {
        attempts[stage.rawValue, default: 0] += 1
    }

    /// Forgets the failed attempts at a stage that has now succeeded, so a
    /// later run of the same stage starts with all of its attempts.
    public mutating func clearAttempts(for stage: ProcessingState) {
        attempts[stage.rawValue] = nil
    }

    public mutating func recordFailure(_ failure: ProcessingFailure, at date: Date) {
        state = .failed
        failedStage = failure.stage
        lastFailure = failure
        updatedAt = date
    }
}
