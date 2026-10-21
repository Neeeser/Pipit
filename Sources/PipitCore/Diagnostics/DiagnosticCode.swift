import Foundation

/// A stable name for a failure category: `<area>.<case>[.<detail>]`.
///
/// What a diagnostic event says about an error instead of its description.
/// A description is free text and routinely carries a path, a URL or a server's
/// own words, any of which can name the meeting. A code is built only from the
/// error's type, its case, and a number or a token Pipit chose.
///
/// The mappings below are exhaustive switches over each error enum, so a case
/// added to one does not compile until it has a code. Errors that belong to
/// another module conform to `DiagnosticCodeProviding` in that module.
public struct DiagnosticCode: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    /// What a code reads as when the parts given do not make one.
    public static let invalid = DiagnosticCode(validated: "invalid")

    /// A code from its parts. A part that is not a lowercase token, or a detail
    /// that is not a token or a number, makes the whole code `invalid`: these
    /// are written in Pipit's own source, and a bad one is a bug to see in a
    /// report rather than text to pass through.
    public init(_ area: String, _ name: String, detail: String? = nil) {
        guard Self.isToken(area), Self.isToken(name) else {
            self = .invalid
            return
        }
        var text = "\(area).\(name)"
        if let detail {
            guard Self.isDetail(detail) else {
                self = .invalid
                return
            }
            text += ".\(detail)"
        }
        self.init(checked: text)
    }

    /// A code with a numeric detail, such as an HTTP status.
    public init(_ area: String, _ name: String, number: Int) {
        self.init(area, name, detail: String(number))
    }

    /// A code read back from an event line, checked against the token rule a
    /// report must pass.
    public init(checked text: String) {
        self.rawValue = Self.isWellFormed(text) ? text : "invalid"
    }

    private init(validated text: String) { self.rawValue = text }

    public var description: String { rawValue }

    /// The code for an error with no mapping of its own: `error.<domain>.<code>`.
    ///
    /// A domain is a reverse-DNS string or a Swift type name, which is what
    /// makes it safe to keep. One that is not, or that would push the code past
    /// the 64 characters a report allows a string, is named `other`. URL
    /// loading errors read `net.NSURLErrorDomain.<code>`, so a network failure
    /// is one family whichever layer raised it.
    public static func error(domain: String, code: Int) -> DiagnosticCode {
        if domain == urlErrorDomain {
            return DiagnosticCode(checked: "net.\(urlErrorDomain).\(code)")
        }
        let safeDomain = isDomain(domain) ? domain : "other"
        let candidate = "error.\(safeDomain).\(code)"
        guard candidate.count <= maximumLength else {
            return DiagnosticCode(checked: "error.other.\(code)")
        }
        return DiagnosticCode(checked: candidate)
    }

    /// The code for any error, through its own mapping where it has one.
    public init(describing error: any Error) {
        if let coded = error as? any DiagnosticCodeProviding {
            self = coded.diagnosticCode
        } else if error is CancellationError {
            self = DiagnosticCode("processing", "cancelled")
        } else {
            let nsError = error as NSError
            self = .error(domain: nsError.domain, code: nsError.code)
        }
    }

    // MARK: - patterns

    /// `NSURLErrorDomain`, spelled out so this file needs no networking import.
    static let urlErrorDomain = "NSURLErrorDomain"

    /// The longest string a report may carry outside its free-text fields.
    static let maximumLength = 64

    /// A lowercase word with underscores: an area or a case name.
    static func isToken(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 40
            && text.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "_"
            }
    }

    /// A number, possibly negative, or a token.
    static func isDetail(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 24 else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || scalar == "_" || scalar == "-"
        }
    }

    /// `^[A-Za-z0-9_.]{1,64}$`, the contract's pattern for an error domain.
    static func isDomain(_ text: String) -> Bool {
        !text.isEmpty && text.count <= 64
            && text.unicodeScalars.allSatisfy { scalar in
                ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                    || scalar == "_" || scalar == "."
            }
    }

    /// Dotted parts of letters, digits, underscores and minus signs, within the
    /// report's string length.
    static func isWellFormed(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maximumLength else { return false }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty
                && part.unicodeScalars.allSatisfy { scalar in
                    ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
                        || ("0"..."9").contains(scalar) || scalar == "_" || scalar == "-"
                }
        }
    }
}

extension DiagnosticCode: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(checked: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// An error that names its own failure category.
public protocol DiagnosticCodeProviding: Error {
    var diagnosticCode: DiagnosticCode { get }
}

// MARK: - mappings

extension ProcessingError: DiagnosticCodeProviding {
    /// The reasons and chunk names some cases carry are left out: a reason is
    /// a server's own words and a chunk name is a file name.
    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .missingAPIKey: DiagnosticCode("processing", "missing_api_key")
        case .authenticationFailed: DiagnosticCode("processing", "authentication_failed")
        case .rateLimited: DiagnosticCode("processing", "rate_limited")
        case .serverError(let status): DiagnosticCode("processing", "server_error", number: status)
        case .requestTooLarge: DiagnosticCode("processing", "request_too_large")
        case .durationTooLong: DiagnosticCode("processing", "duration_too_long")
        case .malformedResponse: DiagnosticCode("processing", "malformed_response")
        case .emptyTranscript: DiagnosticCode("processing", "empty_transcript")
        case .degenerateTranscript: DiagnosticCode("processing", "degenerate_transcript")
        case .transport: DiagnosticCode("processing", "transport")
        case .audioUnreadable: DiagnosticCode("processing", "audio_unreadable")
        case .utteranceNotFound: DiagnosticCode("processing", "utterance_not_found")
        case .cancelled: DiagnosticCode("processing", "cancelled")
        case .localProcessingFailed: DiagnosticCode("processing", "local_failed")
        case .languageModel(_, let failure): failure.diagnosticCode
        }
    }
}

extension LanguageModelFailure {
    /// The provider's name is not part of the code: it can be an address the
    /// person typed.
    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .authenticationFailed: DiagnosticCode("language_model", "authentication_failed")
        case .unreachable: DiagnosticCode("language_model", "unreachable")
        case .rateLimited: DiagnosticCode("language_model", "rate_limited")
        case .serverError(let status): DiagnosticCode("language_model", "server_error", number: status)
        case .modelNotFound: DiagnosticCode("language_model", "model_not_found")
        case .rejected(let status): DiagnosticCode("language_model", "rejected", number: status)
        case .unexpectedResponse: DiagnosticCode("language_model", "unexpected_response")
        }
    }
}

extension CaptureError: DiagnosticCodeProviding {
    /// An OSStatus is kept as the detail, because it is the one thing that says
    /// which CoreAudio call refused. Bundle prefixes and paths are not.
    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .microphonePermissionDenied:
            DiagnosticCode("capture", "microphone_permission_denied")
        case .microphoneEngineStartFailed(let status):
            DiagnosticCode("capture", "microphone_engine_start_failed", number: Int(status))
        case .noMatchingAudioProcess:
            DiagnosticCode("capture", "no_matching_audio_process")
        case .processTapCreationFailed(let status):
            DiagnosticCode("capture", "process_tap_creation_failed", number: Int(status))
        case .aggregateDeviceCreationFailed(let status):
            DiagnosticCode("capture", "aggregate_device_creation_failed", number: Int(status))
        case .ioProcCreationFailed(let status):
            DiagnosticCode("capture", "io_proc_creation_failed", number: Int(status))
        case .tapFormatUnavailable:
            DiagnosticCode("capture", "tap_format_unavailable")
        case .segmentWriteFailed:
            DiagnosticCode("capture", "segment_write_failed")
        case .storageUnavailable:
            DiagnosticCode("capture", "storage_unavailable")
        }
    }
}

extension StorageError: DiagnosticCodeProviding {
    /// Paths are left out: a meeting folder is named for its title.
    public var diagnosticCode: DiagnosticCode {
        switch self {
        case .directoryCreationFailed: DiagnosticCode("storage", "directory_creation_failed")
        case .fileWriteFailed: DiagnosticCode("storage", "file_write_failed")
        case .fileReadFailed: DiagnosticCode("storage", "file_read_failed")
        case .decodeFailed: DiagnosticCode("storage", "decode_failed")
        case .meetingNotFound: DiagnosticCode("storage", "meeting_not_found")
        }
    }
}

extension DiagnosticCode {
    /// Why installing a model failed, for an error raised by a download or a
    /// write rather than by Pipit's own model code.
    ///
    /// The network and a full disk are the two causes a person can act on, so
    /// they are named whichever layer reported them. A full disk arrives as
    /// Cocoa's out-of-space error or as a POSIX `ENOSPC`, sometimes wrapped as
    /// the underlying error of another.
    public static func modelInstall(_ error: any Error) -> DiagnosticCode {
        if let coded = error as? any DiagnosticCodeProviding { return coded.diagnosticCode }
        if error is CancellationError { return DiagnosticCode("model", "install", detail: "cancelled") }
        let nsError = error as NSError
        if nsError.domain == urlErrorDomain {
            return DiagnosticCode("model", "install", detail: "network")
        }
        if isOutOfSpace(nsError) { return DiagnosticCode("model", "install", detail: "disk_full") }
        return DiagnosticCode(describing: error)
    }

    /// `NSFileWriteOutOfSpaceError` is 640 in the Cocoa domain and `ENOSPC` is
    /// 28 in the POSIX one.
    static func isOutOfSpace(_ error: NSError) -> Bool {
        if error.domain == "NSCocoaErrorDomain", error.code == 640 { return true }
        if error.domain == "NSPOSIXErrorDomain", error.code == 28 { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isOutOfSpace(underlying)
        }
        return false
    }
}
