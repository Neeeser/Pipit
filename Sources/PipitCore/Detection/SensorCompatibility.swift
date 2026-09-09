import Foundation

/// The wire shape the browser add-on and the app agree on.
///
/// The add-on and the app are released together, but Firefox updates the add-on
/// on its own schedule and a person can postpone the app update, so either side
/// can be older than the other. Version strings say nothing useful about that:
/// most app releases leave the add-on alone. The number here moves only when
/// the app needs what a newer add-on sends, so an add-on behind it is worth
/// telling the person about and one ahead of it is not.
public enum SensorProtocol {
    /// The shape this build needs. Raise it in the same change that makes the
    /// app depend on something new from the add-on, and nowhere else.
    public static let required = 2

    /// What an add-on that sends no number is taken to speak. Every add-on
    /// signed before the number existed lands here.
    public static let unnumbered = 1

    public enum Compatibility: Sendable, Equatable {
        /// Older than this build needs. The person has to update it.
        case behind
        case current
        /// Newer than this build. Nothing is lost: each side reads only the
        /// fields it knows, and the newer add-on speaks the older shape.
        case ahead
    }

    /// Where a reported number stands against this build. Nil for an add-on
    /// that has never reported at all.
    public static func compatibility(of reported: Int?) -> Compatibility? {
        guard let reported else { return nil }
        if reported < required { return .behind }
        if reported > required { return .ahead }
        return .current
    }
}
