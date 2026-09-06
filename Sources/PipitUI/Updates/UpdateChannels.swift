/// Which appcast channels this app accepts.
///
/// Sparkle shows an item with no `<sparkle:channel>` to everyone and an item
/// naming a channel only to an app that lists it. The rule is separate from the
/// updater so it can be read and tested without Sparkle.
public enum UpdateChannels {
    /// The channels to allow for a given beta setting. Empty means stable
    /// releases only.
    public static func allowed(receivesBeta: Bool) -> Set<String> {
        receivesBeta ? ["beta"] : []
    }
}
