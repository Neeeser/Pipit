import Foundation

/// Everything Pipit knows about one meeting app, in one place.
///
/// Settings, the meetings list, diagnostics, desktop detection and the browser
/// add-on's provider names all read from here, so supporting another app
/// starts with a definition in `MeetingApp+Known.swift` and cases in
/// `MeetingProvider` and `MeetingSource`. What a definition cannot say, such as
/// how to read an app's participants, stays in that app's detector code.
public struct MeetingApp: Sendable, Equatable, Identifiable {
    public let provider: MeetingProvider
    /// What a recording from this app is filed as.
    public let source: MeetingSource
    /// The name a person sees for a recording from this app.
    ///
    /// Folder names on disk are built from it, so an app's name stays as it
    /// shipped.
    public let name: String
    /// The shorter name the meetings list uses, where the row is tight.
    public let listName: String
    /// The symbol the meetings list draws for a recording from this app.
    /// Each app's is different from every other source's.
    public let symbolName: String
    public let tint: SourceColor
    /// The row label in Settings > Recording.
    public let settingsLabel: String
    /// The key this app's policy is saved under in the settings file. Fixed
    /// once shipped, since renaming it resets the person's choice.
    public let settingsKey: String
    /// What Pipit does with this app's calls until the person picks. An app
    /// found only by the microphone, with no reader that can tell a call from
    /// other microphone use, should ask first, as an unrecognised call does.
    public let defaultPolicy: ProviderPolicy
    /// The desktop app's bundle identifiers, the first being the main app.
    /// The meetings list draws the installed app's icon from the first.
    public let desktopBundleIdentifiers: [String]
    /// Bundle-identifier prefixes of the processes that hold the microphone
    /// and play the call's audio. Empty while the desktop app is not detected.
    ///
    /// An app without its own detector is found by the generic microphone
    /// detector, which files the call under this app instead of "Call".
    public let desktopAudioBundlePrefixes: [String]
    /// The app has a detector of its own, so the generic microphone detector
    /// leaves its processes alone. Slack's reads the huddle from
    /// accessibility.
    public let hasOwnDesktopDetector: Bool
    /// The provider name the browser add-on reports for this app's pages, the
    /// same string as in `extension/shared/meeting-sites.json`. Nil when the
    /// add-on does not read the app's web version.
    public let browserExtensionID: String?

    public var id: MeetingProvider { provider }

    public init(
        provider: MeetingProvider,
        source: MeetingSource,
        name: String,
        listName: String? = nil,
        symbolName: String,
        tint: SourceColor,
        settingsLabel: String? = nil,
        settingsKey: String,
        defaultPolicy: ProviderPolicy = ProviderPolicy(),
        desktopBundleIdentifiers: [String] = [],
        desktopAudioBundlePrefixes: [String] = [],
        hasOwnDesktopDetector: Bool = false,
        browserExtensionID: String? = nil
    ) {
        self.provider = provider
        self.source = source
        self.name = name
        self.listName = listName ?? name
        self.symbolName = symbolName
        self.tint = tint
        self.settingsLabel = settingsLabel ?? name
        self.settingsKey = settingsKey
        self.defaultPolicy = defaultPolicy
        self.desktopBundleIdentifiers = desktopBundleIdentifiers
        self.desktopAudioBundlePrefixes = desktopAudioBundlePrefixes
        self.hasOwnDesktopDetector = hasOwnDesktopDetector
        self.browserExtensionID = browserExtensionID
    }

    /// The app whose processes include this one, if any.
    public static func owning(bundleIdentifier: String, in apps: [MeetingApp] = all) -> MeetingApp? {
        // A dot boundary, so a prefix for one vendor's app does not claim
        // another app whose identifier merely starts with the same letters.
        apps.first { app in
            app.desktopAudioBundlePrefixes.contains { bundleIdentifier == $0 || bundleIdentifier.hasPrefix($0 + ".") }
        }
    }

    /// The app the browser add-on means by a provider name.
    public static func forBrowserExtensionID(_ id: String) -> MeetingApp? {
        all.first { $0.browserExtensionID == id }
    }
}

/// The colour a source's badge is drawn in, named rather than given as a
/// value so the interface maps it to the system's own semantic colour.
public enum SourceColor: String, Sendable, Equatable, CaseIterable {
    case purple, green, blue, mint, indigo, teal, orange, pink, red, yellow, cyan, brown, secondary
}

extension MeetingProvider {
    /// This provider's definition. Nil for `unknown`, which is any call in an
    /// app Pipit has no definition for.
    public var app: MeetingApp? {
        switch self {
        case .slack: .slack
        case .googleMeet: .googleMeet
        case .zoom: .zoom
        case .faceTime: .faceTime
        case .unknown: nil
        }
    }
}

extension MeetingSource {
    /// The definition of the app this kind of recording comes from. Nil for a
    /// generic call, a manual, in-person or imported recording.
    public var app: MeetingApp? {
        MeetingApp.all.first { $0.source == self }
    }
}
