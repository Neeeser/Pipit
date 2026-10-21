import Foundation
import PipitCore
import PipitDetection
import PipitUI
import Testing

/// The sensor in Safari and the Chromium browsers, beside the Firefox one.
struct BrowserSensorTests {
    @Test("the host tells a Chromium browser from Firefox by its arguments")
    func theHostTellsAChromiumBrowserFromFirefoxByItsArguments() async throws {
        let host = "/Users/x/Library/Application Support/Pipit/pipit-nativehost"
        // Chrome, Brave, Edge and Arc pass the calling origin and nothing that
        // names the browser. Reading only for "Chrome" took them for Firefox.
        let chrome = [host, "chrome-extension://lcgklngllaakialhbekpihnjlciiijoc/"]
        #expect(SensorRelay.browser(forArguments: chrome) == .chrome)
        let firefox = [
            host,
            "/Users/x/Library/Application Support/Mozilla/NativeMessagingHosts/com.pipit.sensor.json",
            "sensor@pipit.app",
        ]
        #expect(SensorRelay.browser(forArguments: firefox) == .firefox)
    }

    @Test("a Safari observation arrives as a Safari event with its roster")
    func aSafariObservationArrivesAsASafariEventWithItsRoster() async throws {
        let raw: [String: Any] = [
            "type": "state",
            "provider": "meet",
            "state": "in_call",
            "sentAt": 1_000_000.0,
            "meetingId": "abc-defg-hij",
            "tabId": 7,
            "people": [
                ["id": "spaces/a/devices/1", "name": "Participant One", "isSelf": true],
                ["id": "", "name": "No identifier"],
            ],
        ]
        let message = SensorRelay.message(from: raw, browser: .safari, hostVersion: "0.1.9")
        guard case .event(let event) = message else {
            Issue.record("expected an event, got \(String(describing: message))")
            return
        }
        #expect(event.browser == .safari)
        #expect(event.provider == .googleMeet)
        #expect(event.state == .inCall)
        #expect(event.timestamp == 1_000)
        #expect(event.tabID == 7)
        #expect(event.people?.map(\.id) == ["spaces/a/devices/1"], "a row without an identifier is dropped")
        #expect(message?.browser == .safari)

        let greeting: [String: Any] = ["type": "hello", "extensionVersion": "1.0.1", "protocol": 2]
        let hello = SensorRelay.message(from: greeting, browser: .safari, hostVersion: "0.1.9")
        let expected = SensorMessage.Hello(
            browser: .safari, extensionVersion: "1.0.1", hostVersion: "0.1.9", protocolVersion: 2
        )
        #expect(hello == .hello(expected))
        let nonsense: [String: Any] = ["type": "nonsense"]
        #expect(SensorRelay.message(from: nonsense, browser: .safari, hostVersion: "0.1.9") == nil)
    }

    @Test("Safari's meeting audio is matched in WebKit's processes")
    func safariSMeetingAudioIsMatchedInWebKitSProcesses() async throws {
        // Safari itself never holds the microphone; WebKit's GPU process does.
        #expect(BrowserKind.safari.audioBundlePrefixes.contains("com.apple.WebKit.GPU"))
        #expect(!BrowserKind.safari.bundleIdentifiers.contains("com.apple.WebKit.GPU"))
        #expect(BrowserKind.firefox.audioBundlePrefixes == BrowserKind.firefox.bundleIdentifiers)
        #expect(BrowserKind.chrome.bundleIdentifiers.contains("com.brave.Browser"))
        #expect(BrowserKind.chrome.bundleIdentifiers.contains("company.thebrowser.Browser"))

        var detector = BrowserMeetingDetector(browser: .safari)
        detector.sensorConnected(at: 100)
        detector.receive(
            BrowserMeetingEvent(
                browser: .safari, provider: .googleMeet, state: .inCall,
                timestamp: 1_000, meetingID: "abc-defg-hij", tabID: 1
            ),
            at: 100
        )
        let evidence = detector.update(
            native: .init(browserHoldsMicrophone: true, browserProducesOutput: true, windowTitles: []),
            at: 101
        )
        #expect(evidence.confidence == .confirmed)
        #expect(evidence.browser == .safari)
        #expect(evidence.audioBundlePrefixes.contains("com.apple.WebKit.GPU"), "the tap must follow Safari's audio")
    }

    @Test("the Safari socket's group is the one this build is signed into")
    func theSafariSocketSGroupIsTheOneThisBuildIsSignedInto() async throws {
        let signed = "ABCDE12345.com.pipit.sensor"
        #expect(SensorTransport.safariAppGroup(in: [signed]) == signed)
        #expect(SensorTransport.safariAppGroup(in: ["com.pipit.sensor"]) == "com.pipit.sensor")
        #expect(SensorTransport.safariAppGroup(in: ["ABCDE12345.com.example.notpipit.sensor"]) == nil)
        #expect(SensorTransport.safariAppGroup(in: []) == nil)
        let container = URL(fileURLWithPath: "/Users/x/Library/Group Containers/ABCDE12345.com.pipit.sensor")
        #expect(SensorTransport.safariSocketURL(groupContainer: container).lastPathComponent == "sensor.sock")
    }

    @Test("Pipit's Safari extension is trusted without a browser parent, and nothing else is")
    func pipitSSafariExtensionIsTrustedWithoutABrowserParentAndNothingElseIs() async throws {
        let executable = "/Applications/Pipit.app/" + SensorTransport.safariExtensionExecutablePath
        let verifier = SensorPeerVerifier(
            allowedHostPaths: [executable],
            allowedParentBundleIDs: [],
            requiresBrowserParent: false,
            signingIdentifier: SensorTransport.safariExtensionBundleIdentifier
        )
        // The system starts the extension for Safari, so its parent is launchd.
        let genuine = SensorPeerVerifier.Peer(
            processID: 300, executablePath: executable,
            parentPath: "/sbin/launchd", parentBundleIdentifier: nil
        )
        #expect(verifier.isTrusted(genuine))

        let imposter = SensorPeerVerifier.Peer(
            processID: 301, executablePath: "/tmp/attacker",
            parentPath: "/sbin/launchd", parentBundleIdentifier: nil
        )
        #expect(!verifier.isTrusted(imposter))

        let resigned = SensorPeerVerifier.Peer(
            processID: 302, executablePath: executable,
            parentPath: "/sbin/launchd", parentBundleIdentifier: nil, signature: .mismatched
        )
        #expect(!verifier.isTrusted(resigned), "the path alone does not identify the code running there")

        // The host's own verifier still insists on a browser.
        let host = SensorPeerVerifier(
            allowedHostPaths: [executable], allowedParentBundleIDs: ["com.apple.Safari"]
        )
        #expect(!host.isTrusted(genuine))
    }

    @Test("the Chrome add-on is copied out of the bundle and kept current")
    func theChromeAddOnIsCopiedOutOfTheBundleAndKeptCurrent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipit-chrome-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle/chrome", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        try Data("{\"version\": \"1\"}".utf8).write(to: bundled.appendingPathComponent("manifest.json"))
        let installer = NativeMessagingInstaller(
            applicationSupport: root.appendingPathComponent("support", isDirectory: true),
            chromiumBrowsers: []
        )

        // A launch never creates the copy; the person asking for it does.
        #expect(installer.installChromeAddOn(from: bundled, onlyIfPresent: true) == nil)
        let folder = try #require(installer.installChromeAddOn(from: bundled))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        let obsolete = folder.appendingPathComponent("removed-script.js")
        try Data("obsolete".utf8).write(to: obsolete)

        // An app update reaches a copy a browser already loads.
        try Data("{\"version\": \"2\"}".utf8).write(to: bundled.appendingPathComponent("manifest.json"))
        #expect(installer.installChromeAddOn(from: bundled, onlyIfPresent: true) == folder)
        let copied = try String(contentsOf: folder.appendingPathComponent("manifest.json"), encoding: .utf8)
        #expect(copied.contains("\"2\""))
        #expect(!FileManager.default.fileExists(atPath: obsolete.path))
    }

    @Test("a failed Chrome add-on update preserves the installed copy")
    func aFailedChromeAddOnUpdatePreservesTheInstalledCopy() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bundled = root.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let original = Data("{\"version\":\"1\"}".utf8)
        try original.write(to: bundled.appendingPathComponent("manifest.json"))
        let installer = NativeMessagingInstaller(applicationSupport: root.appendingPathComponent("support"))
        let installed = try #require(installer.installChromeAddOn(from: bundled))
        let missingUpdate = root.appendingPathComponent("missing-update")
        #expect(installer.installChromeAddOn(from: missingUpdate, onlyIfPresent: true) == nil)
        #expect(try Data(contentsOf: installed.appendingPathComponent("manifest.json")) == original)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: installer.applicationSupport.path) == ["Chrome Add-on"])
    }

    @Test("the Safari and Chrome cards read the connection and what the build carries")
    func theSafariAndChromeCardsReadTheConnectionAndWhatTheBuildCarries() async throws {
        #expect(BrowserAddOnState(connection: .fresh, isBundled: true) == .on)
        #expect(BrowserAddOnState(connection: .stale, isBundled: true) == .on, "loaded with no meeting open")
        #expect(BrowserAddOnState(connection: .absent, isBundled: true) == .off)
        #expect(BrowserAddOnState(connection: .disconnected, isBundled: true).offersSetUp)
        #expect(BrowserAddOnState(connection: .absent, isBundled: false) == .unavailable)
        #expect(!BrowserAddOnState(connection: .absent, isBundled: false).offersSetUp)
    }
}
