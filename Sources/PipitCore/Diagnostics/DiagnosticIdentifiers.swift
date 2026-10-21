import Foundation

/// The scopes a diagnostic identifier can belong to.
///
/// Each is a type only so the three identifiers cannot be passed for one
/// another: a launch identifier in the `session` field would join two
/// unrelated recordings in a report.
public enum DiagnosticScope {
    /// One process launch.
    public enum Launch {}
    /// One recording session, from arming capture to the meeting being saved.
    public enum Session {}
    /// One attempt at one processing stage.
    public enum Job {}
}

/// A random identifier scoped to one launch, one recording, or one processing
/// attempt.
///
/// Random on purpose. Nothing about the Mac, the person or the meeting goes
/// into it, so a report carries no identifier that follows a Mac from one
/// launch to the next. A meeting identifier is never used here because it
/// embeds a slug of the title.
public struct DiagnosticID<Scope>: Hashable, Sendable, CustomStringConvertible {
    public let uuid: UUID

    public init() { self.uuid = UUID() }

    public init(uuid: UUID) { self.uuid = uuid }

    /// Nil for anything that is not a UUID, which is how a manifest or a
    /// state file written by something else is kept from smuggling text in.
    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.uuid = uuid
    }

    public var description: String { uuid.uuidString }
}

extension DiagnosticID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let uuid = UUID(uuidString: text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a UUID")
        }
        self.uuid = uuid
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(uuid.uuidString)
    }
}

public typealias DiagnosticLaunchID = DiagnosticID<DiagnosticScope.Launch>
public typealias DiagnosticSessionID = DiagnosticID<DiagnosticScope.Session>
public typealias DiagnosticJobID = DiagnosticID<DiagnosticScope.Job>
