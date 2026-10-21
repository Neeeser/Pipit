import Foundation

/// The wire format between the Firefox native messaging host and Pipit.
///
/// The host is a thin relay: it speaks Firefox's length-prefixed protocol on one
/// side and newline-delimited JSON over a Unix socket on the other. Keeping the
/// two apart means a browser update that changes the extension side never touches
/// the app side.
public enum SensorMessage: Codable, Sendable, Equatable {
    case hello(Hello)
    case event(BrowserMeetingEvent)
    case tabClosed(browser: BrowserKind, tabID: Int)
    case goodbye(browser: BrowserKind)

    public struct Hello: Codable, Sendable, Equatable {
        public var browser: BrowserKind
        public var extensionVersion: String?
        public var hostVersion: String
        /// The wire shape the add-on speaks, judged by `SensorProtocol`. Nil
        /// from an add-on signed before the number existed.
        public var protocolVersion: Int?

        public init(
            browser: BrowserKind, extensionVersion: String?, hostVersion: String,
            protocolVersion: Int? = nil
        ) {
            self.browser = browser
            self.extensionVersion = extensionVersion
            self.hostVersion = hostVersion
            self.protocolVersion = protocolVersion
        }
    }

    /// The browser the message came from.
    public var browser: BrowserKind {
        switch self {
        case .hello(let hello): hello.browser
        case .event(let event): event.browser
        case .tabClosed(let browser, _), .goodbye(let browser): browser
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case hello
        case event
        case tabID
        case browser
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let payload):
            try container.encode("hello", forKey: .type)
            try container.encode(payload, forKey: .hello)
        case .event(let payload):
            try container.encode("event", forKey: .type)
            try container.encode(payload, forKey: .event)
        case .tabClosed(let browser, let tabID):
            try container.encode("tab_closed", forKey: .type)
            try container.encode(browser, forKey: .browser)
            try container.encode(tabID, forKey: .tabID)
        case .goodbye(let browser):
            try container.encode("goodbye", forKey: .type)
            try container.encode(browser, forKey: .browser)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "hello":
            self = .hello(try container.decode(Hello.self, forKey: .hello))
        case "event":
            self = .event(try container.decode(BrowserMeetingEvent.self, forKey: .event))
        case "tab_closed":
            self = .tabClosed(
                browser: try container.decodeIfPresent(BrowserKind.self, forKey: .browser) ?? .firefox,
                tabID: try container.decode(Int.self, forKey: .tabID)
            )
        case "goodbye":
            self = .goodbye(browser: try container.decodeIfPresent(BrowserKind.self, forKey: .browser) ?? .firefox)
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: container, debugDescription: "unknown sensor message \(other)"
            )
        }
    }
}

public enum SensorTransport {
    /// The socket the app listens on and the host connects to.
    ///
    /// Application Support, not Documents: a native messaging host installed under
    /// a TCC-protected directory never launches at all, silently.
    public static func socketURL(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("sensor.sock")
    }

    public static var defaultApplicationSupport: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pipit", isDirectory: true)
    }

    public static let nativeMessagingHostName = "com.pipit.sensor"

    /// Firefox reads per-user host manifests from here.
    public static var firefoxHostManifestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true)
    }

    public static var chromeHostManifestDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
    }

    /// The identifier Chrome gives the add-on, derived from the public key in
    /// `extension/chrome/manifest.json`. Pinning the key keeps it the same on
    /// every Mac and in every Chromium browser, which is what lets the host
    /// manifest name it. `extension/test/browsers.test.js` checks the two agree.
    public static let chromeExtensionID = "lcgklngllaakialhbekpihnjlciiijoc"

    /// A Chromium browser and the folder it keeps its data in.
    public struct ChromiumBrowser: Sendable, Equatable {
        public let name: String
        /// Present once the browser has run on this Mac.
        public let dataDirectory: URL

        /// Where the browser looks for native messaging host manifests.
        public var hostManifestDirectory: URL {
            dataDirectory.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        }
    }

    /// Every Chromium browser that loads the Chrome add-on. Each one reads host
    /// manifests from its own folder only, so the add-on in Brave cannot reach
    /// Pipit through a manifest written for Chrome.
    public static var chromiumBrowsers: [ChromiumBrowser] {
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let folders: [(String, String)] = [
            ("Chrome", "Google/Chrome"),
            ("Chrome Beta", "Google/Chrome Beta"),
            ("Chrome Canary", "Google/Chrome Canary"),
            ("Chromium", "Chromium"),
            ("Brave", "BraveSoftware/Brave-Browser"),
            ("Microsoft Edge", "Microsoft Edge"),
            ("Arc", "Arc/User Data"),
            ("Vivaldi", "Vivaldi"),
        ]
        return folders.map { folder in
            ChromiumBrowser(
                name: folder.0, dataDirectory: support.appendingPathComponent(folder.1, isDirectory: true)
            )
        }
    }

    /// The end of the app group Pipit shares with its Safari extension. The
    /// signed group carries the team identifier in front of it.
    ///
    /// Safari runs the extension in a sandbox, which cannot reach the socket in
    /// Application Support. The group's container is the one folder both sides
    /// can open, so Safari's socket lives there.
    public static let safariAppGroupSuffix = "com.pipit.sensor"

    /// The bundle identifier and code signing identifier of the Safari
    /// extension inside Pipit.app.
    public static let safariExtensionBundleIdentifier = "com.pipit.app.safari-extension"

    /// Where the extension's executable sits inside the application bundle.
    public static let safariExtensionExecutablePath =
        "Contents/PlugIns/PipitSafariExtension.appex/Contents/MacOS/PipitSafariExtension"

    /// The socket the Safari extension connects to, inside the shared container.
    public static func safariSocketURL(groupContainer: URL) -> URL {
        groupContainer.appendingPathComponent("sensor.sock")
    }

    /// The group from a process's own `com.apple.security.application-groups`
    /// entitlement. Nil for a build signed without one, which has no Safari
    /// extension to talk to.
    public static func safariAppGroup(in entitledGroups: [String]) -> String? {
        entitledGroups.first { $0 == safariAppGroupSuffix || $0.hasSuffix("." + safariAppGroupSuffix) }
    }

    /// Encodes one message as a single line.
    public static func encodeLine(_ message: SensorMessage) throws -> Data {
        var data = try JSONEncoder().encode(message)
        data.append(0x0A)
        return data
    }

    public static func decodeLine(_ data: Data) throws -> SensorMessage {
        try JSONDecoder().decode(SensorMessage.self, from: data)
    }
}

/// Fills a `sockaddr_un` for a filesystem path.
///
/// Kept in one place because both the listening app and the relay host need it,
/// and because writing into `sun_path` in place trips Swift's exclusivity rules.
public enum UnixSocketAddress {
    public static let maximumPathLength = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    public static func make(path: String) -> sockaddr_un? {
        var bytes = Array(path.utf8)
        guard bytes.count <= maximumPathLength else { return nil }
        bytes.append(0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { source in
                destination.baseAddress?.copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        return address
    }

    public static var size: socklen_t { socklen_t(MemoryLayout<sockaddr_un>.size) }
}
