import Foundation

extension MeetingApp {
    /// Every app Pipit has a definition for, in the order Settings lists them.
    public static let all: [MeetingApp] = [.slack, .googleMeet, .zoom, .faceTime]

    public static let slack = MeetingApp(
        provider: .slack,
        source: .slackHuddle,
        name: "Slack Huddle",
        symbolName: "headphones",
        tint: .purple,
        settingsLabel: "Slack Huddles",
        settingsKey: "slack",
        desktopBundleIdentifiers: ["com.tinyspeck.slackmacgap"],
        desktopAudioBundlePrefixes: ["com.tinyspeck.slackmacgap"],
        hasOwnDesktopDetector: true
    )

    /// Browser only: Meet has no desktop app.
    public static let googleMeet = MeetingApp(
        provider: .googleMeet,
        source: .googleMeet,
        name: "Google Meet",
        symbolName: "video.fill",
        tint: .green,
        settingsKey: "googleMeet",
        browserExtensionID: "meet"
    )

    /// The desktop app is left to the generic detector, as "Call", until it has
    /// its own prefixes here.
    public static let zoom = MeetingApp(
        provider: .zoom,
        source: .zoom,
        name: "Zoom",
        symbolName: "square.grid.2x2.fill",
        tint: .blue,
        settingsKey: "zoom",
        browserExtensionID: "zoom"
    )

    /// Not detected yet: a FaceTime call is found by the generic detector, as
    /// "Call". Asks first by default, like any unrecognised call.
    public static let faceTime = MeetingApp(
        provider: .faceTime,
        source: .faceTime,
        name: "FaceTime",
        symbolName: "person.crop.rectangle.fill",
        tint: .mint,
        settingsKey: "faceTime",
        defaultPolicy: ProviderPolicy(autoStart: .ask)
    )
}
