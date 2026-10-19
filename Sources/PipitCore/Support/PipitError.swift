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
    case localProcessingFailed(reason: String, retryable: Bool)
    /// A model that writes about the meeting failed. Carries the provider's
    /// name because it is the wording that differs: the cases above speak of
    /// OpenAI, which is wrong for Ollama or an endpoint the person typed.
    case languageModel(provider: String, failure: LanguageModelFailure)

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .serverError, .transport, .emptyTranscript, .degenerateTranscript: true
        case .localProcessingFailed(_, let retryable): retryable
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
        case .localProcessingFailed(let reason, _): "local(\(reason))"
        case .languageModel(_, let failure): "languageModel(\(failure.logSafeDescription))"
        case .audioUnreadable(let path): "audioUnreadable(\(path))"
        case .utteranceNotFound: "utteranceNotFound"
        case .cancelled: "cancelled"
        }
    }

    /// The message shown to the user. Every one of these reassures about the audio,
    /// because the recording is safe in all of them.
    public var userMessage: String {
        switch self {
        case .missingAPIKey: "Add an OpenAI API key in Settings to transcribe this meeting. Your recording is safe."
        case .authenticationFailed: "OpenAI rejected the API key. Your recording is safe."
        case .rateLimited: "OpenAI is rate limiting requests. Pipit will retry. Your recording is safe."
        case .serverError: "OpenAI returned a server error. Pipit will retry. Your recording is safe."
        case .requestTooLarge: "An audio chunk exceeded the OpenAI upload limit. Your recording is safe."
        case .durationTooLong: "An audio chunk exceeded the OpenAI duration limit. Your recording is safe."
        case .malformedResponse: "OpenAI returned an unexpected response. Your recording is safe."
        case .emptyTranscript:
            "Transcription returned nothing for part of this meeting. Pipit will retry. Your recording is safe."
        case .degenerateTranscript:
            "Transcription repeated itself for part of this meeting. Pipit will retry. Your recording is safe."
        case .transport: "Pipit could not reach OpenAI. It will retry. Your recording is safe."
        case .audioUnreadable: "Pipit could not read the recorded audio for this stage."
        case .utteranceNotFound:
            "That line has moved since the transcript was last analysed. Reopen the meeting and try again."
        case .cancelled: "Processing was cancelled. Your recording is safe."
        case .localProcessingFailed(let reason, _): "\(reason) Your recording is safe."
        case .languageModel(let provider, let failure): "\(failure.message(provider: provider)) Your recording is safe."
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

    /// The statement and what happens next, for a meeting that hit it.
    public func message(provider: String) -> String {
        let what = statement(provider: provider)
        switch self {
        case .unreachable, .rateLimited, .serverError: return "\(what). Pipit will retry."
        case .modelNotFound: return "\(what). Choose another in Settings."
        case .rejected: return "\(what). Try another model in Settings."
        case .authenticationFailed, .unexpectedResponse: return "\(what)."
        }
    }
}
