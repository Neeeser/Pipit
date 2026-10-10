import Foundation

/// How two spellings of a person's name are compared.
///
/// A meeting platform renders the name an account was created with
/// ("Firstname Lastname") while the people list usually holds the short form
/// a person typed ("Firstname L"), and diacritics and capitals come and go
/// between the two. Every comparison between a platform name and a stored name
/// goes through here so they agree on what counts as the same string.
public enum PersonName {
    /// The name with case, diacritics, and runs of whitespace removed from the
    /// comparison.
    public static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// Whether two names are the same string once case and diacritics are
    /// ignored. Empty names are never the same as anything.
    public static func isSame(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalized(lhs)
        return !left.isEmpty && left == normalized(rhs)
    }

    /// Whether a platform name could be the long form of a stored short name.
    ///
    /// The first names agree, and the stored last name is empty, an initial, or
    /// the start of the platform's last name: "Firstname Lastname" fits
    /// "Firstname L" and "Firstname". It is a test for whether two spellings
    /// can be one person, not evidence that they are. A caller needs a second
    /// fact, such as a voice match, before treating them as the same person.
    public static func isCompatible(platform: String, stored: String) -> Bool {
        let theirs = tokens(of: platform)
        let ours = tokens(of: stored)
        guard let theirFirst = theirs.first, let ourFirst = ours.first,
            theirFirst == ourFirst
        else { return false }
        // A stored first name alone, or a platform name that is only a first
        // name, says nothing about the rest.
        guard ours.count > 1, theirs.count > 1 else { return true }
        return theirs[theirs.count - 1].hasPrefix(ours[ours.count - 1])
    }

    private static func tokens(of name: String) -> [String] {
        normalized(name)
            .split(separator: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty }
    }
}
