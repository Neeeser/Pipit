import Foundation

/// Which audio processes one remote tap covers.
public enum RemoteTargetScope: Sendable, Equatable {
    /// The processes of one provider, matched by bundle identifier prefix. A
    /// detected call knows where its audio lives, and tapping only that keeps
    /// the rest of the machine out of the recording.
    case bundlePrefixes([String])
    /// Every audio process except Pipit's own. A recording the user starts by
    /// hand has no provider, so the far end is whatever application is playing
    /// the call: a browser's GPU process, Zoom, Teams, FaceTime.
    ///
    /// Anything else playing audio during the recording is on the track as
    /// well. That track is also what reaches the speakers, which is the right
    /// reference for echo cancellation, and a call is far likelier to be what
    /// the person is listening to than music is.
    case anyApplication

    /// True when nothing can match, which is how an in-person recording
    /// arms with no remote track at all.
    public var isEmpty: Bool {
        switch self {
        case .bundlePrefixes(let prefixes): prefixes.isEmpty
        case .anyApplication: false
        }
    }

    /// Whether the scope covers `target`. `ownProcessID` is Pipit's PID: tapping
    /// the process that plays Pipit's own notification sounds would write them
    /// into the far-end track.
    public func selects(_ target: RemoteAudioTarget, ownProcessID: Int32) -> Bool {
        switch self {
        case .bundlePrefixes(let prefixes):
            prefixes.contains { target.bundleIdentifier.hasPrefix($0) }
        case .anyApplication:
            target.processID != ownProcessID
        }
    }
}
