import Foundation
import PipitCore

/// Registers Pipit's native messaging host with the browsers on this Mac.
///
/// The host binary is copied out of the app bundle into Application Support and
/// the manifest points at that copy. Two measured constraints shape this: a host
/// under a TCC-protected directory such as Documents never launches, and a
/// `#!/usr/bin/env` shebang never resolves because browsers spawn hosts with a
/// minimal PATH. A compiled binary at an absolute path avoids both.
public struct NativeMessagingInstaller: Sendable {
    public struct Status: Sendable, Equatable {
        public var hostInstalled: Bool
        public var firefoxManifestInstalled: Bool
        /// A manifest is in place for at least one Chromium browser.
        public var chromeManifestInstalled: Bool
        public var installedHostPath: String?

        public var isReadyForFirefox: Bool { hostInstalled && firefoxManifestInstalled }
        public var isReadyForChrome: Bool { hostInstalled && chromeManifestInstalled }
    }

    public let applicationSupport: URL
    /// Extension identifiers allowed to talk to the host.
    public let firefoxExtensionIDs: [String]
    public let chromeExtensionIDs: [String]
    /// The Chromium browsers to register with. Injected so a test can point
    /// them at a temporary folder.
    public let chromiumBrowsers: [SensorTransport.ChromiumBrowser]

    public init(
        applicationSupport: URL = SensorTransport.defaultApplicationSupport,
        firefoxExtensionIDs: [String] = ["sensor@pipit.app"],
        chromeExtensionIDs: [String] = [SensorTransport.chromeExtensionID],
        chromiumBrowsers: [SensorTransport.ChromiumBrowser] = SensorTransport.chromiumBrowsers
    ) {
        self.applicationSupport = applicationSupport
        self.firefoxExtensionIDs = firefoxExtensionIDs
        self.chromeExtensionIDs = chromeExtensionIDs
        self.chromiumBrowsers = chromiumBrowsers
    }

    public var installedHostURL: URL {
        applicationSupport.appendingPathComponent("pipit-nativehost")
    }

    public func status() -> Status {
        let manager = FileManager.default
        return Status(
            hostInstalled: manager.isExecutableFile(atPath: installedHostURL.path),
            firefoxManifestInstalled: manager.fileExists(atPath: firefoxManifestURL.path),
            chromeManifestInstalled: chromiumManifestURLs.contains { manager.fileExists(atPath: $0.path) },
            installedHostPath: manager.fileExists(atPath: installedHostURL.path)
                ? installedHostURL.path : nil
        )
    }

    public var firefoxManifestURL: URL {
        SensorTransport.firefoxHostManifestDirectory
            .appendingPathComponent("\(SensorTransport.nativeMessagingHostName).json")
    }

    public var chromeManifestURL: URL {
        SensorTransport.chromeHostManifestDirectory
            .appendingPathComponent("\(SensorTransport.nativeMessagingHostName).json")
    }

    /// The manifest each Chromium browser reads, whether or not it is written.
    public var chromiumManifestURLs: [URL] {
        chromiumBrowsers.map(manifestURL(for:))
    }

    private func manifestURL(for browser: SensorTransport.ChromiumBrowser) -> URL {
        browser.hostManifestDirectory
            .appendingPathComponent("\(SensorTransport.nativeMessagingHostName).json")
    }

    /// Copies the host binary and writes the manifests. Safe to run on every launch.
    ///
    /// Chromium browsers keep their manifests inside their own data folders,
    /// and macOS 15 can ask the person before Pipit writes into another
    /// application's data. So the launch only refreshes manifests that already
    /// exist, and `registerChromium` is set when the person asks for the Chrome
    /// add-on, which is when a prompt makes sense to them.
    @discardableResult
    public func install(hostBinary: URL, registerChromium: Bool = false) throws -> Status {
        let manager = FileManager.default
        try manager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)

        if manager.fileExists(atPath: installedHostURL.path) {
            let existing = try? Data(contentsOf: installedHostURL)
            let incoming = try? Data(contentsOf: hostBinary)
            if existing != incoming {
                try? manager.removeItem(at: installedHostURL)
                try manager.copyItem(at: hostBinary, to: installedHostURL)
            }
        } else {
            try manager.copyItem(at: hostBinary, to: installedHostURL)
        }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedHostURL.path)

        try writeManifest(
            to: firefoxManifestURL,
            allowedKey: "allowed_extensions",
            allowed: firefoxExtensionIDs
        )
        // Only browsers that have run here: writing for the rest would create
        // a folder in Application Support for every browser the person does
        // not use. One browser refusing the write does not stop the others.
        if !chromeExtensionIDs.isEmpty {
            let origins = chromeExtensionIDs.map { "chrome-extension://\($0)/" }
            for browser in chromiumBrowsers {
                let url = manifestURL(for: browser)
                let wanted =
                    registerChromium
                    ? manager.fileExists(atPath: browser.dataDirectory.path)
                    : manager.fileExists(atPath: url.path)
                guard wanted else { continue }
                try? writeManifest(to: url, allowedKey: "allowed_origins", allowed: origins)
            }
        }
        return status()
    }

    public func uninstall() {
        try? FileManager.default.removeItem(at: firefoxManifestURL)
        for url in chromiumManifestURLs { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: installedHostURL)
    }

    private func writeManifest(to url: URL, allowedKey: String, allowed: [String]) throws {
        let manifest: [String: Any] = [
            "name": SensorTransport.nativeMessagingHostName,
            "description": "Pipit browser sensor relay",
            "path": installedHostURL.path,
            "type": "stdio",
            allowedKey: allowed,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try AtomicFile.write(data, to: url)
    }

    /// Where Pipit keeps the Chrome add-on for a browser to load.
    ///
    /// Outside the app bundle on purpose. A Chromium browser keeps loading an
    /// unpacked add-on from the folder it was pointed at, and that folder has to
    /// survive the bundle being replaced by an update or moved to Applications.
    public var chromeAddOnURL: URL {
        applicationSupport.appendingPathComponent("Chrome Add-on", isDirectory: true)
    }

    /// Copies the Chrome add-on out of the bundle, and returns where it is.
    ///
    /// A launch passes `onlyIfPresent`, which refreshes a copy a browser
    /// already loads and never creates one, so an app update reaches the
    /// add-on the next time the browser starts. An unchanged copy is left
    /// alone rather than replaced under a running browser.
    @discardableResult
    public func installChromeAddOn(from bundled: URL, onlyIfPresent: Bool = false) -> URL? {
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: chromeAddOnURL.path)
        if onlyIfPresent, !exists { return nil }
        if exists, manager.contentsEqual(atPath: bundled.path, andPath: chromeAddOnURL.path) {
            return chromeAddOnURL
        }
        let staged = applicationSupport.appendingPathComponent(".Chrome Add-on.\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: staged) }
        do {
            try manager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
            // Finish copying before replacing the folder a browser loads. Both
            // folders share a filesystem, so replacement can be atomic.
            try manager.copyItem(at: bundled, to: staged)
            if exists {
                _ = try manager.replaceItemAt(chromeAddOnURL, withItemAt: staged)
            } else {
                try manager.moveItem(at: staged, to: chromeAddOnURL)
            }
            return chromeAddOnURL
        } catch {
            return nil
        }
    }

    /// The Chrome add-on the bundle carries, built by extension/build.sh.
    public static func bundledChromeAddOnURL(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let addOn = resources.appendingPathComponent("extension/chrome", isDirectory: true)
        let manifest = addOn.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: manifest.path) ? addOn : nil
    }

    /// The signed add-on, which release Firefox installs permanently.
    ///
    /// Absent from a local build: release Firefox refuses an unsigned add-on,
    /// so a build that has not been through Mozilla has nothing to offer.
    public static func bundledFirefoxAddOnURL(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let addOn = resources.appendingPathComponent("extension/pipit-sensor.xpi")
        return FileManager.default.fileExists(atPath: addOn.path) ? addOn : nil
    }

    /// Where the host binary lives inside a packaged app, falling back to the
    /// build directory during development.
    public static func bundledHostURL(bundle: Bundle = .main) -> URL? {
        if let helpers = bundle.executableURL?.deletingLastPathComponent() {
            let candidate = helpers.appendingPathComponent("pipit-nativehost")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        if let resource = bundle.url(forResource: "pipit-nativehost", withExtension: nil) {
            return resource
        }
        return nil
    }
}
