/// Which appcast channels this app accepts.
///
/// Sparkle shows an item with no `<sparkle:channel>` to everyone and an item
/// naming a channel only to an app that lists it. The rule is separate from the
/// updater so it can be read and tested without Sparkle.
public enum UpdateChannels {
    /// The channels to allow for a given beta setting and running version.
    /// Empty means stable releases only.
    ///
    /// Every release below 1.0.0 is a pre-release and lands on the beta
    /// channel, so a 0.x build that honoured the setting alone would see no
    /// updates at all. A 0.x build therefore takes the beta channel whatever
    /// the setting says, and the setting starts deciding at 1.0.
    public static func allowed(receivesBeta: Bool, appVersion: String) -> Set<String> {
        receivesBeta || majorVersion(of: appVersion) == 0 ? ["beta"] : []
    }

    /// The leading number of a `MAJOR.MINOR.PATCH` string. A value that does
    /// not parse returns nil, which the rule treats as a non-zero major.
    static func majorVersion(of appVersion: String) -> Int? {
        guard let field = appVersion.split(separator: ".").first else { return nil }
        return Int(field)
    }
}
