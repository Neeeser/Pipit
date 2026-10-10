import Foundation

/// Why a command stopped. Each case carries what the message needs, and the
/// message is written for the person or agent reading the terminal.
public enum CLIError: Error, Equatable, Sendable {
    case usage(String)
    case noArchive(path: String)
    case meetingNotFound(String)
    case ambiguousMeeting(String, matches: Int)
    case noAgentFound
    case skillSourceMissing(path: String)
    case linkBlocked(path: String, reason: String)
    case installFailed(path: String, reason: String)
    case outputNotEncodable

    /// 2 for a command line that could not be read, 1 for everything else.
    public var exitCode: Int32 {
        if case .usage = self { return 2 }
        return 1
    }

    public var message: String {
        switch self {
        case .usage(let detail):
            return "\(detail)\nRun `pipit --help` for the commands."
        case .noArchive(let path):
            return "No meetings folder at \(path). Open Pipit once, or pass --root."
        case .meetingNotFound(let id):
            return "No meeting matches \(id). `pipit meetings list` shows the identifiers."
        case .ambiguousMeeting(let id, let matches):
            return "\(id) matches \(matches) meetings. Use more of the identifier."
        case .noAgentFound:
            return "No agent folder found in this home directory. Pass --agent claude or --agent agents."
        case .skillSourceMissing(let path):
            return "The skill is not bundled at \(path). Run this from the Pipit app bundle."
        case .linkBlocked(let path, let reason):
            return "Did not link \(path): \(reason)"
        case .installFailed(let path, let reason):
            return "Could not write \(path): \(reason)"
        case .outputNotEncodable:
            return "Could not encode the output."
        }
    }
}
