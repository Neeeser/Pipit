import Foundation

/// Capture-side failures. These are distinguished on purpose: silence and an idle
/// remote application are normal, a rebuild in flight is temporary, and only the
/// last two categories mean audio is being lost right now.
public enum CaptureError: LogSafeError, Equatable {
    case microphonePermissionDenied
    case microphoneEngineStartFailed(status: Int32)
    case noMatchingAudioProcess(prefixes: [String])
    case processTapCreationFailed(status: Int32)
    case aggregateDeviceCreationFailed(status: Int32)
    case ioProcCreationFailed(status: Int32)
    case tapFormatUnavailable
    case segmentWriteFailed(path: String, underlying: String)
    case storageUnavailable(path: String)

    public var logSafeDescription: String {
        switch self {
        case .microphonePermissionDenied: "microphonePermissionDenied"
        case .microphoneEngineStartFailed(let status): "microphoneEngineStartFailed(\(status))"
        case .noMatchingAudioProcess(let prefixes): "noMatchingAudioProcess(\(prefixes.count) prefixes)"
        case .processTapCreationFailed(let status): "processTapCreationFailed(\(status))"
        case .aggregateDeviceCreationFailed(let status): "aggregateDeviceCreationFailed(\(status))"
        case .ioProcCreationFailed(let status): "ioProcCreationFailed(\(status))"
        case .tapFormatUnavailable: "tapFormatUnavailable"
        case .segmentWriteFailed: "segmentWriteFailed"
        case .storageUnavailable: "storageUnavailable"
        }
    }
}

/// Storage failures. Paths are included because they are Pipit's own directory
/// layout, not meeting content.
public enum StorageError: LogSafeError, Equatable {
    case directoryCreationFailed(path: String, underlying: String)
    case fileWriteFailed(path: String, underlying: String)
    case fileReadFailed(path: String, underlying: String)
    case decodeFailed(path: String, underlying: String)
    case meetingNotFound(id: String)

    /// Paths are omitted: a meeting directory's name embeds the meeting title,
    /// and the unified log is collected wholesale by sysdiagnose.
    public var logSafeDescription: String {
        switch self {
        case .directoryCreationFailed: "directoryCreationFailed"
        case .fileWriteFailed: "fileWriteFailed"
        case .fileReadFailed: "fileReadFailed"
        case .decodeFailed: "decodeFailed"
        case .meetingNotFound: "meetingNotFound"
        }
    }
}

/// Why cleaning the microphone and transcribing it again was refused.
///
/// Raised before anything on disk is touched, so a refusal leaves the meeting
/// exactly as it was.
public enum MicrophoneRedoError: LogSafeError, Equatable {
    /// An in-person or imported recording: one track holds everyone, so there is
    /// no far end recorded apart from the microphone to take out of it.
    case oneTrack
    /// The meeting is still being recorded or processed, or processing stopped
    /// before it finished. Redoing the microphone is for a finished transcript.
    case notFinished
    /// A job is writing into this meeting's folder right now.
    case busy
    /// A track has no audio, or the far end holds nothing. The microphone is
    /// then read as it was recorded whatever is done to it.
    case noFarEnd

    public var logSafeDescription: String {
        switch self {
        case .oneTrack: "microphoneRedo.oneTrack"
        case .notFinished: "microphoneRedo.notFinished"
        case .busy: "microphoneRedo.busy"
        case .noFarEnd: "microphoneRedo.noFarEnd"
        }
    }

    /// Worded for the person who pressed the button.
    public var message: String {
        switch self {
        case .oneTrack: "This recording has no separate microphone to redo."
        case .notFinished: "Wait for this meeting to finish processing first."
        case .busy: "This meeting is being worked on. Try again in a moment."
        case .noFarEnd: "The other side was not recorded in this meeting, so there is no echo to remove."
        }
    }
}

/// Failures from the AI backend. `retryable` drives the processing state machine:
/// a retryable failure keeps the job alive, a permanent one stops the retry loop
/// but never touches the source audio.
/// A failure raised by something running on this Mac.
///
/// Declared here so the pipeline can categorise one without importing the
/// concrete local backend: the error knows what to tell the user and whether
/// waiting could help, and nothing else has to know which module raised it.
public protocol LocalProcessingFailure: Error {
    var userMessage: String { get }
    var isRetryable: Bool { get }
    /// What a later attempt would change. Defaults to waiting: work on this
    /// Mac costs nothing to run again, so a failure the pipeline has no special
    /// knowledge of is tried at the next launch rather than left for Retry.
    var cause: FailureCause { get }
}

extension LocalProcessingFailure {
    public var cause: FailureCause { .clearsByWaiting }
}

public enum ProcessingError: LogSafeError, Equatable {
    case missingAPIKey
    case authenticationFailed
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    case requestTooLarge(bytes: Int, limit: Int)
    case durationTooLong(seconds: Double, limit: Double)
    case malformedResponse(reason: String)
    /// A transcription request returned neither words nor text for audio that
    /// carries speech. Retryable: filing it as a finished chunk drops that part
    /// of the meeting while the meeting still reports success.
    case emptyTranscript(chunk: String)
    /// A transcription request came back looping one phrase for the length of
    /// the chunk. Retryable for the same reason as an empty one: the words are
    /// not what was said, and recording them puts invented sentences in the
    /// transcript with the meeting reporting success.
    case degenerateTranscript(chunk: String)
    case transport(reason: String)
    case audioUnreadable(path: String)
    /// A correction arrived for a transcript line that no longer exists,
    /// which happens when a re-analysis lands between the click and the write.
    case utteranceNotFound(id: String)
    case cancelled
    /// A stage that runs on this Mac failed. Carries its own message because
    /// the cloud wording is wrong for it and often wrong about the cause.
    case localProcessingFailed(
        reason: String, retryable: Bool, cause: FailureCause = .clearsByWaiting)
    /// A model that writes about the meeting failed. Carries the provider's
    /// name because it is the wording that differs: the cases above speak of
    /// OpenAI, which is wrong for Ollama or an endpoint the person typed.
    case languageModel(provider: String, failure: LanguageModelFailure)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .transport, .emptyTranscript, .degenerateTranscript: true
        case .localProcessingFailed(_, let retryable, _): retryable
        case .languageModel(_, let failure): failure.isRetryable
        case .missingAPIKey, .authenticationFailed, .requestTooLarge, .durationTooLong,
            .malformedResponse, .audioUnreadable, .utteranceNotFound, .cancelled:
            false
        }
    }

    public var logSafeDescription: String {
        switch self {
        case .missingAPIKey: "missingAPIKey"
        case .authenticationFailed: "authenticationFailed"
        case .rateLimited(let after): "rateLimited(retryAfter: \(after.map { String(format: "%.0f", $0) } ?? "-"))"
        case .serverError(let status): "serverError(\(status))"
        case .requestTooLarge(let bytes, let limit): "requestTooLarge(\(bytes)/\(limit))"
        case .durationTooLong(let seconds, let limit): "durationTooLong(\(Int(seconds))/\(Int(limit)))"
        case .malformedResponse(let reason): "malformedResponse(\(reason))"
        case .emptyTranscript(let chunk): "emptyTranscript(\(chunk))"
        case .degenerateTranscript(let chunk): "degenerateTranscript(\(chunk))"
        case .transport(let reason): "transport(\(reason))"
        case .localProcessingFailed(let reason, _, _): "local(\(reason))"
        case .languageModel(_, let failure): "languageModel(\(failure.logSafeDescription))"
        case .audioUnreadable(let path): "audioUnreadable(\(Self.logSafeExtension(of: path)))"
        case .utteranceNotFound: "utteranceNotFound"
        case .cancelled: "cancelled"
        }
    }

    /// The extension of a file name, which says what kind of audio failed.
    /// The rest of the name stays out of the log: an imported recording is
    /// named by the person who made it, often after the meeting. Anything that
    /// is not a short alphanumeric extension is logged as `-`.
    static func logSafeExtension(of name: String) -> String {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        guard (1...5).contains(pathExtension.count),
            pathExtension.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })
        else { return "-" }
        return "." + pathExtension
    }

    /// What a later attempt would change, which decides whether the launch
    /// sweep keeps starting the stage on its own.
    ///
    /// The one place that sorts a failure. Group by what the person or the
    /// passing of time does to it, not by what raised it.
    public var cause: FailureCause {
        switch self {
        case .missingAPIKey, .authenticationFailed: .fixedInSettings
        // A cancelled run is a quit, and the next launch is its retry.
        case .rateLimited, .serverError, .transport, .cancelled: .clearsByWaiting
        case .requestTooLarge, .durationTooLong, .malformedResponse, .emptyTranscript,
            .degenerateTranscript, .audioUnreadable, .utteranceNotFound:
            .sameResultEachTime
        case .localProcessingFailed(_, _, let cause): cause
        case .languageModel(_, let failure): failure.cause
        }
    }

    /// The message with no word on what happens next.
    public var userMessage: String { message(outcome: nil) }

    /// The message shown to the user. Every one of these reassures about the
    /// audio, because the recording is safe in all of them.
    ///
    /// `outcome` says what happens next, and is left out for a cause the
    /// person fixes in Settings, where the message already says what to do.
    public func message(outcome: FailureOutcome?) -> String {
        var parts = [statement]
        if let outcome, cause != .fixedInSettings, !isNeverStored {
            parts.append(outcome.sentence(advice: stoppedAdvice))
        }
        if reassuresAboutAudio { parts.append("Your recording is safe.") }
        return parts.joined(separator: " ")
    }

    /// A correction to a line that has moved is refused where it is made. It is
    /// never the failure a meeting stops on.
    private var isNeverStored: Bool {
        if case .utteranceNotFound = self { return true }
        return false
    }

    private var reassuresAboutAudio: Bool {
        switch self {
        case .audioUnreadable, .utteranceNotFound: false
        default: true
        }
    }

    /// What else the person can do once Pipit has stopped. The Retry button is
    /// already on screen, so only a different way forward is said. A message
    /// that already points to Settings adds nothing.
    private var stoppedAdvice: String {
        switch self {
        case .emptyTranscript, .degenerateTranscript:
            "You can choose another transcription model in Settings."
        default: ""
        }
    }

    private var statement: String {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Settings to transcribe this meeting."
        case .authenticationFailed: "OpenAI rejected the API key."
        case .rateLimited: "OpenAI is rate limiting requests."
        case .serverError: "OpenAI returned a server error."
        case .requestTooLarge: "An audio chunk exceeded the OpenAI upload limit."
        case .durationTooLong: "An audio chunk exceeded the OpenAI duration limit."
        case .malformedResponse: "OpenAI returned an unexpected response."
        case .emptyTranscript: "Transcription returned nothing for part of this meeting."
        case .degenerateTranscript: "Transcription repeated itself for part of this meeting."
        case .transport: "Pipit could not reach OpenAI."
        case .audioUnreadable: "Pipit could not read the recorded audio for this stage."
        case .utteranceNotFound:
            "That line has moved since the transcript was last analysed. Reopen the meeting and try again."
        case .cancelled: "Processing was cancelled."
        case .localProcessingFailed(let reason, _, _): reason
        case .languageModel(let provider, let failure): failure.advice(provider: provider)
        }
    }
}

/// What happens to a failed stage next, said to the person.
public enum FailureOutcome: Equatable, Sendable {
    /// The pipeline is about to try the stage again.
    case retryingNow
    /// Nothing is running, and the next launch starts the stage again.
    case retryAtLaunch
    /// Every attempt failed and nothing starts the stage until Retry.
    case stopped

    /// `advice` follows "stopped", since what to do differs by cause.
    func sentence(advice: String) -> String {
        switch self {
        case .retryingNow: "Pipit will retry."
        case .retryAtLaunch: "Pipit will try again the next time it opens."
        case .stopped: advice.isEmpty ? "Pipit stopped retrying." : "Pipit stopped retrying. \(advice)"
        }
    }
}

/// How a request to a model that writes about the meeting went wrong.
public enum LanguageModelFailure: Equatable, Sendable {
    case authenticationFailed
    /// Nothing answered: the server is not running, the network is down, or the
    /// request timed out.
    case unreachable
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(status: Int)
    /// The server does not have the model, or does not have the address.
    case modelNotFound
    /// The server refused the request itself, after the fallback that drops the
    /// optional parts of it.
    case rejected(status: Int)
    case unexpectedResponse

    public var isRetryable: Bool {
        switch self {
        case .unreachable, .rateLimited, .serverError: true
        case .authenticationFailed, .modelNotFound, .rejected, .unexpectedResponse: false
        }
    }

    public var logSafeDescription: String {
        switch self {
        case .authenticationFailed: "authenticationFailed"
        case .unreachable: "unreachable"
        case .rateLimited(let after): "rateLimited(retryAfter: \(after.map { String(format: "%.0f", $0) } ?? "-"))"
        case .serverError(let status): "serverError(\(status))"
        case .modelNotFound: "modelNotFound"
        case .rejected(let status): "rejected(\(status))"
        case .unexpectedResponse: "unexpectedResponse"
        }
    }

    /// What happened, as a plain statement. Settings shows this beside the
    /// button that was pressed.
    public func statement(provider: String) -> String {
        switch self {
        case .authenticationFailed: "\(provider) rejected the API key"
        case .unreachable: "Could not reach \(provider)"
        case .rateLimited: "\(provider) is rate limiting requests"
        case .serverError: "\(provider) returned a server error"
        case .modelNotFound: "\(provider) does not have the selected model"
        case .rejected: "\(provider) refused the request"
        case .unexpectedResponse: "\(provider) returned an unexpected response"
        }
    }

    /// What a retry would change.
    public var cause: FailureCause {
        switch self {
        case .authenticationFailed, .modelNotFound: .fixedInSettings
        case .unreachable, .rateLimited, .serverError: .clearsByWaiting
        case .rejected, .unexpectedResponse: .sameResultEachTime
        }
    }

    /// The statement and what to do about it, with nothing on what happens next.
    public func advice(provider: String) -> String {
        let what = statement(provider: provider)
        switch self {
        case .modelNotFound: return "\(what). Choose another in Settings."
        case .rejected: return "\(what). Try another model in Settings."
        case .unreachable, .rateLimited, .serverError, .authenticationFailed, .unexpectedResponse:
            return "\(what)."
        }
    }
}
