import Foundation
import PipitCore
import Testing

/// What an error puts into a `privacy: .public` log line. The unified log is
/// collected whole by sysdiagnose, so a payload that carries meeting content
/// is a leak however rarely the line fires.
@Suite("LogSafety")
struct LogSafetyTests {
    @Test("an unreadable imported file is logged by its extension, not its name")
    func anUnreadableImportedFileIsLoggedByItsExtensionNotItsName() {
        let error = ProcessingError.audioUnreadable(path: "Weekly sync with Sample Person.m4a")
        #expect(error.logSafeDescription == "audioUnreadable(.m4a)")
    }

    @Test("a name with no short extension is logged as a dash")
    func aNameWithNoShortExtensionIsLoggedAsADash() {
        #expect(ProcessingError.audioUnreadable(path: "segments").logSafeDescription == "audioUnreadable(-)")
        #expect(
            ProcessingError.audioUnreadable(path: "notes.Sample Person").logSafeDescription
                == "audioUnreadable(-)"
        )
    }

    @Test("an error that cannot describe itself is logged by its domain and code")
    func anErrorThatCannotDescribeItselfIsLoggedByItsDomainAndCode() {
        let error = NSError(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet,
            userInfo: [NSLocalizedDescriptionKey: "Could not load https://example.invalid/sample-person"]
        )
        #expect(logSafeDescription(error) == "NSURLErrorDomain#-1009")
    }
}
