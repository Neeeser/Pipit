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

/// What a later attempt at a failed stage would change.
///
/// The launch sweep stops starting a stage only when trying again gives the
/// same result. A failure that Settings or the passing of time can clear is
/// retried at every launch, since nothing else notices when it has cleared.
public enum FailureCause: String, Codable, Sendable, Equatable {
    /// The same input meets the same fault: an empty or looping transcript, a
    /// reply that cannot be read, a request the service refuses.
    case sameResultEachTime = "same_result"
    /// The person fixes it in Settings: a missing or refused key, a model that
    /// is not there. It fails before anything is sent.
    case fixedInSettings = "settings"
    /// A network, service or download problem that goes away by itself.
    case clearsByWaiting = "waiting"

    /// Whether the launch sweep leaves the stage after its attempts are used.
    public var isCappedAtLaunch: Bool { self == .sameResultEachTime }

    /// The cause of a failure stored before causes were recorded, read from its
    /// code. Anything unrecognised that was not retryable is treated as a
    /// Settings fix, which is how the sweep always handled it.
    init(code: DiagnosticCode?, isRetryable: Bool) {
        let raw = code?.rawValue ?? ""
        func matches(_ family: [String]) -> Bool {
            family.contains { raw == $0 || raw.hasPrefix($0 + ".") }
        }
        if matches(Self.legacyFixedInSettings) {
            self = .fixedInSettings
        } else if matches(Self.legacyClearsByWaiting) {
            self = .clearsByWaiting
        } else if matches(Self.legacySameResult) {
            self = .sameResultEachTime
        } else {
            self = isRetryable ? .sameResultEachTime : .fixedInSettings
        }
    }

    private static let legacyFixedInSettings = [
        "processing.missing_api_key", "processing.authentication_failed",
        "language_model.authentication_failed", "language_model.model_not_found",
        "model.not_installed",
    ]
    private static let legacyClearsByWaiting = [
        "processing.rate_limited", "processing.server_error", "processing.transport",
        "processing.cancelled", "language_model.unreachable", "language_model.rate_limited",
        "language_model.server_error",
        // A URL loading error from any layer, which is how older builds filed
        // a model download that lost its connection.
        "net",
        // Everything on this Mac that is not a model refusing audio: free to
        // run again, and how older builds filed the timing-model download.
        "processing.local_failed",
    ]
    /// Listed rather than read from `isRetryable`, since several of these were
    /// stored as not retryable and would otherwise read as a Settings fix.
    private static let legacySameResult = [
        "processing.empty_transcript", "processing.degenerate_transcript",
        "processing.malformed_response", "processing.request_too_large",
        "processing.duration_too_long", "processing.audio_unreadable",
        "model.audio_unreadable", "language_model.unexpected_response", "language_model.rejected",
    ]
}

public struct ProcessingFailure: Codable, Sendable, Equatable {
    public var stage: ProcessingState
    /// Written for the person, and never put in a diagnostic report. States
    /// what happens next as of the moment it was written.
    public var message: String
    /// Whether the pipeline retries the stage in the same run.
    public var isRetryable: Bool
    public var occurredAt: Date
    /// The failure's category, which a diagnostic report carries in place of
    /// the message. Absent from a meeting that failed before codes were
    /// recorded, which an older build reads past.
    public var code: DiagnosticCode?
    /// What another attempt would change. Absent from a failure recorded
    /// before causes were kept; `effectiveCause` reads one from the code.
    public var cause: FailureCause?

    public init(
        stage: ProcessingState, message: String, isRetryable: Bool, occurredAt: Date,
        code: DiagnosticCode? = nil, cause: FailureCause? = nil
    ) {
        self.stage = stage
        self.message = message
        self.isRetryable = isRetryable
        self.occurredAt = occurredAt
        self.code = code
        self.cause = cause
    }

    private enum CodingKeys: String, CodingKey {
        case stage, message, isRetryable, occurredAt, code, cause
    }

    /// Decoded by hand so a cause this build does not know reads as absent. A
    /// value written by a newer build must not make the whole `metadata.json`
    /// unreadable here.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stage = try container.decode(ProcessingState.self, forKey: .stage)
        message = try container.decode(String.self, forKey: .message)
        isRetryable = try container.decode(Bool.self, forKey: .isRetryable)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
        code = try container.decodeIfPresent(DiagnosticCode.self, forKey: .code)
        cause = (try? container.decodeIfPresent(FailureCause.self, forKey: .cause)) ?? nil
    }

    public var effectiveCause: FailureCause {
        cause ?? FailureCause(code: code, isRetryable: isRetryable)
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

    /// Whether every attempt at a failure that repeats has been used.
    ///
    /// The launch sweep leaves such a meeting for the Retry button, since
    /// another launch would give the same result. A failure that Settings or
    /// waiting clears is never out of attempts: nothing tells the sweep when it
    /// has cleared, and it fails quickly.
    public var isOutOfAttempts: Bool {
        guard state == .failed, let failure = lastFailure, failure.effectiveCause.isCappedAtLaunch,
            let stage = resumeStage
        else { return false }
        return attemptCount(for: stage) >= Self.maxAttemptsPerStage
    }

    /// The failure's message as it should read now.
    ///
    /// A failure written by an older build says Pipit will retry, which stopped
    /// being true for one that used its attempts. Those are reworded from the
    /// cause and the count. A newer one was worded when it was recorded.
    public var failureMessage: String? {
        guard let failure = lastFailure else { return nil }
        guard failure.cause == nil else { return failure.message }
        var message = failure.message
        for stale in [" Pipit will retry.", " It will retry."] {
            message = message.replacingOccurrences(of: stale, with: "")
        }
        let cause = failure.effectiveCause
        guard cause != .fixedInSettings else { return message }
        let outcome: FailureOutcome = isOutOfAttempts ? .stopped : .retryAtLaunch
        let sentence = outcome.sentence(advice: "")
        let safe = " Your recording is safe."
        if message.hasSuffix(safe) {
            return String(message.dropLast(safe.count)) + " " + sentence + safe
        }
        return message + " " + sentence
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
