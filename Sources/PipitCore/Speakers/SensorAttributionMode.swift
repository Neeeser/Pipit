import Foundation

/// How the meeting client's speaker record and the diarizer share the work of
/// saying who spoke each word on the far end.
///
/// The application always runs `current`. The other modes exist so
/// `pipit-eval` can score the alternatives on the same audio.
public enum SensorAttributionMode: String, Sendable, CaseIterable, Equatable {
    /// Diarizer clusters label every word they reach. Turns label only the words
    /// no cluster reaches. A cluster takes a participant's name where that
    /// participant covers most of it. A one-to-one call is labelled by the
    /// client alone.
    case current
    /// The client only names clusters. No word is filed under a participant's
    /// own key, and a one-to-one call goes through the diarizer too, with the
    /// other person's name on every far-end cluster.
    case diarizerNames = "diarizer-names"
    /// Turns label words first and clusters fill the rest. What the application
    /// did before clusters took precedence.
    case sensorFirst = "sensor-first"
    /// `current` with a wider rule for which participant a cluster is.
    ///
    /// The turns reach only part of a cluster's speech, because the client
    /// drops turns, releases them late and marks one person at a time, so the
    /// whole-cluster share `current` asks for goes unmet on a cluster that is
    /// plainly one person's. This reads the share a participant holds among
    /// the speech the turns do cover, and counts a turn of the local user, who
    /// talks over the far end all the time, at half weight as a rival.
    case relaxedNames = "relaxed-names"
}
