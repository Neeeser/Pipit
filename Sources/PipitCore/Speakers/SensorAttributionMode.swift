import Foundation

/// How the meeting client's speaker record and the diarizer share the work of
/// saying who spoke each word on the far end.
///
/// The application always runs `current`. The other modes exist so
/// `pipit-eval` can score the alternatives on the same audio.
public enum SensorAttributionMode: String, Sendable, CaseIterable, Equatable {
    /// Diarizer clusters label every word they reach. Turns label only the words
    /// no cluster reaches. A cluster takes a participant's name where that
    /// participant holds most of the speech the turns cover in it. A
    /// one-to-one call is labelled by the client alone.
    case current
    /// The client only names clusters. No word is filed under a participant's
    /// own key, and a one-to-one call goes through the diarizer too, with the
    /// other person's name on every far-end cluster.
    case diarizerNames = "diarizer-names"
    /// Turns label words first and clusters fill the rest. What the application
    /// did before clusters took precedence.
    case sensorFirst = "sensor-first"
    /// `current` with the narrower naming rule the application used before:
    /// one participant's turns must cover half of the whole cluster, and a
    /// turn of the local user counts in full as a rival. Voice enrolment still
    /// uses this rule in every mode.
    case strictNames = "strict-names"
}
