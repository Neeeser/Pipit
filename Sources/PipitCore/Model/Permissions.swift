import Foundation

/// A macOS permission Pipit asks for.
///
/// The kind, what it is for, whether Pipit works without it and which System
/// Settings pane grants it are all decisions with no I/O, so they live here.
/// Probing and requesting live with `PermissionsService`.
public enum PermissionKind: String, Sendable, CaseIterable, Identifiable {
    case microphone
    case screenRecording
    case accessibility
    case calendar
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen and system audio"
        case .accessibility: "Accessibility"
        case .calendar: "Calendar"
        case .notifications: "Notifications"
        }
    }

    /// Why Pipit asks.
    public var rationale: String {
        switch self {
        case .microphone:
            "Records your side of the meeting."
        case .screenRecording:
            "Reads window titles to tell which meeting is on screen."
        case .accessibility:
            "Reads app windows to see when a huddle is on screen."
        case .calendar:
            "Matches a recording to the event on your calendar, which gives it the title and attendees."
        case .notifications:
            "Reports when recording starts, a meeting is saved, and a transcript is ready."
        }
    }

    /// Whether setup blocks on it.
    ///
    /// All three detection permissions block. Microphone is what records at all;
    /// without the other two Pipit misses the start of browser calls and every
    /// Slack huddle, which is a recorder that silently does not record.
    public var isRequired: Bool {
        switch self {
        case .microphone, .screenRecording, .accessibility: true
        case .calendar, .notifications: false
        }
    }

    /// Whether the pane accepts an application dropped into its list.
    ///
    /// The panes that hold a list of applications do; the ones granted through a
    /// system prompt have no list to drop onto.
    public var acceptsDroppedApplication: Bool {
        switch self {
        case .accessibility, .screenRecording: true
        case .microphone, .calendar, .notifications: false
        }
    }

    /// Whether macOS will ever show a prompt for it, or whether the only route is
    /// System Settings.
    public var isGrantedByPrompt: Bool {
        switch self {
        case .microphone, .calendar, .notifications: true
        case .accessibility, .screenRecording: false
        }
    }

    /// The System Settings pane that grants it.
    ///
    /// These are the Ventura-and-later identifiers. The `com.apple.preference.security`
    /// pane an earlier build used has not existed since System Settings replaced
    /// System Preferences, and opening it lands on the Settings root.
    public var settingsURL: URL? {
        let privacy = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
        switch self {
        case .microphone: return URL(string: "\(privacy)?Privacy_Microphone")
        case .screenRecording: return URL(string: "\(privacy)?Privacy_ScreenCapture")
        case .accessibility: return URL(string: "\(privacy)?Privacy_Accessibility")
        case .calendar: return URL(string: "\(privacy)?Privacy_Calendars")
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
    }

    /// The pane's own heading, reproduced in the illustration so the picture and
    /// the pane the user lands on read the same.
    ///
    /// These are what System Settings shows on macOS 27, checked against the
    /// panes themselves rather than from memory. Accessibility is the one that
    /// moved: the privacy pane the `Privacy_Accessibility` anchor opens is called
    /// Device Control and Data Access now, and it covers keyboard monitoring,
    /// mail, contacts and screen recording alongside application control. The
    /// Accessibility item still in the System Settings sidebar is the unrelated
    /// one holding VoiceOver and Zoom, so naming the picture after it would send
    /// people to the wrong place.
    public var paneTitle: String {
        switch self {
        case .microphone: "Microphone"
        case .screenRecording: "Screen & System Audio Recording"
        case .accessibility: "Device Control and Data Access"
        case .calendar: "Calendars"
        case .notifications: "Notifications"
        }
    }

    /// The line macOS prints above the list in that pane.
    public var paneCaption: String {
        switch self {
        case .microphone: "Allow the applications below to access your microphone."
        case .screenRecording:
            "Allow the applications below to record the content of your screen and audio, "
                + "even while using other applications."
        case .accessibility:
            "Apps with this access can view and send email, edit contacts and photos, "
                + "monitor your keyboard, track websites, record your screen, control any "
                + "app on your Mac, and more."
        case .calendar: "Allow the applications below to access your calendar."
        case .notifications: "Allow notifications from the applications below."
        }
    }
}

public enum PermissionState: String, Sendable, Equatable {
    case granted
    case denied
    case notDetermined
    /// System Settings shows this as enabled but the running build cannot use it.
    ///
    /// Observed after re-signing the application: the Accessibility toggle read as
    /// enabled while `AXIsProcessTrusted()` returned false. Removing Pipit from
    /// the list in System Settings and adding it again restores access.
    case grantedButNotEffective
}

public struct PermissionStatus: Sendable, Equatable, Identifiable {
    public let kind: PermissionKind
    public let state: PermissionState
    public var id: String { kind.rawValue }

    public init(kind: PermissionKind, state: PermissionState) {
        self.kind = kind
        self.state = state
    }

    public var isUsable: Bool { state == .granted }

    public var advice: String? {
        switch state {
        case .granted: nil
        case .notDetermined: "Not requested yet."
        case .denied where kind == .accessibility || kind == .screenRecording:
            "Switch Pipit on in System Settings. If it is already on, remove it "
                + "with the minus button and add it again."
        case .denied: "Enable it in System Settings, then return here."
        case .grantedButNotEffective:
            "\(kind.title) is on in System Settings but not active for this build. "
                + "Remove Pipit from the list and add it again."
        }
    }
}
