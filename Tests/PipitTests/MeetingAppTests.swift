import Foundation
import PipitCore
import Testing

@Suite("MeetingApp")
struct MeetingAppTests {
    @Test("every provider but unknown has exactly one definition, and it points back")
    func everyProviderHasOneDefinition() {
        for provider in MeetingProvider.allCases where provider != .unknown {
            let matching = MeetingApp.all.filter { $0.provider == provider }
            #expect(matching.count == 1, "\(provider) has \(matching.count) definitions")
            #expect(provider.app?.provider == provider)
            #expect(provider.app?.source.provider == provider)
        }
        #expect(MeetingProvider.unknown.app == nil)
    }

    @Test("sources, settings keys and add-on names are each used once")
    func identifiersAreUnique() {
        let sources = MeetingApp.all.map(\.source)
        #expect(Set(sources).count == sources.count)
        let keys = MeetingApp.all.map(\.settingsKey)
        #expect(Set(keys).count == keys.count)
        let extensionIDs = MeetingApp.all.compactMap(\.browserExtensionID)
        #expect(Set(extensionIDs).count == extensionIDs.count)
        for app in MeetingApp.all {
            #expect(app.source.app == app)
            #expect(SessionController.source(for: app.provider) == app.source)
        }
        #expect(SessionController.source(for: .unknown) == .genericCall)
    }

    /// The sources that are not a meeting app. Every other source must have a
    /// definition, or it silently takes the name "Call", which then lands in
    /// folder names on disk.
    @Test("every source is either a meeting app or one of the four that are not")
    func everySourceIsAccountedFor() {
        let notApps: Set<MeetingSource> = [.genericCall, .manual, .inPerson, .imported]
        for source in MeetingSource.allCases {
            #expect((source.app != nil) != notApps.contains(source), "\(source) is neither or both")
        }
    }

    /// Folder names on disk and the settings file were written with these.
    @Test("names and settings keys are the ones already on disk")
    func shippedNamesAreUnchanged() {
        #expect(MeetingSource.slackHuddle.displayName == "Slack Huddle")
        #expect(MeetingSource.googleMeet.displayName == "Google Meet")
        #expect(MeetingSource.zoom.displayName == "Zoom")
        #expect(MeetingSource.faceTime.displayName == "FaceTime")
        #expect(MeetingSource.genericCall.displayName == "Call")
        #expect(MeetingProvider.slack.displayName == "Slack Huddle")
        #expect(MeetingProvider.unknown.displayName == "Call")
        #expect(MeetingApp.all.map(\.settingsKey) == ["slack", "googleMeet", "zoom", "faceTime"])
    }

    /// The add-on and the app are two halves of one list: a provider the
    /// add-on reports that the app has no definition for is filed as "Call".
    @Test("the add-on's meeting sites are exactly the apps with an add-on name")
    func browserSitesMatchDefinitions() throws {
        struct Site: Decodable { let provider: String }
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("extension/shared/meeting-sites.json")
        let sites = try JSONDecoder().decode([Site].self, from: Data(contentsOf: url))
        #expect(Set(sites.map(\.provider)) == Set(MeetingApp.all.compactMap(\.browserExtensionID)))
    }

    @Test("the add-on's provider names map to their apps")
    func relayMapsProviderNames() {
        func provider(_ name: String) -> MeetingProvider? {
            let raw: [String: Any] = ["type": "state", "provider": name, "state": "in_call"]
            guard case .event(let event) = SensorRelay.message(from: raw, browser: .chrome, hostVersion: "1")
            else { return nil }
            return event.provider
        }
        #expect(provider("meet") == .googleMeet)
        #expect(provider("zoom") == .zoom)
        #expect(provider("somewhere") == .unknown)
    }
}

@Suite("ProviderPolicies")
struct ProviderPoliciesTests {
    private static let savedBeforeDefinitions = """
        {"slack":{"autoStart":"never","autoStop":true},
         "googleMeet":{"autoStart":"always","autoStop":false},
         "zoom":{"autoStart":"ask","autoStop":true},
         "faceTime":{"autoStart":"always","autoStop":true},
         "unknownCalls":{"autoStart":"never","autoStop":true},
         "detectionPaused":true}
        """

    @Test("a settings file written before the definitions reads back the same choices")
    func readsTheOldShape() throws {
        let policies = try JSONDecoder().decode(
            ProviderPolicies.self, from: Data(Self.savedBeforeDefinitions.utf8)
        )
        #expect(policies[.slack] == ProviderPolicy(autoStart: .never, autoStop: true))
        #expect(policies[.googleMeet] == ProviderPolicy(autoStart: .always, autoStop: false))
        #expect(policies[.zoom].autoStart == .ask)
        #expect(policies[.faceTime].autoStart == .always)
        #expect(policies[.unknown].autoStart == .never)
        #expect(policies.detectionPaused)
    }

    @Test("it writes the same keys it always did")
    func writesTheOldKeys() throws {
        let data = try JSONEncoder().encode(ProviderPolicies())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(
            Set(object.keys) == ["slack", "googleMeet", "zoom", "faceTime", "unknownCalls", "detectionPaused"]
        )
    }

    /// A file from before an app had a definition has no entry for it.
    @Test("an app missing from the file gets its default, and equals a fresh policy")
    func missingAppGetsItsDefault() throws {
        let policies = try JSONDecoder().decode(
            ProviderPolicies.self, from: Data(#"{"slack":{"autoStart":"always","autoStop":true}}"#.utf8))
        #expect(policies == ProviderPolicies())
        #expect(policies[.faceTime] == MeetingApp.faceTime.defaultPolicy)
    }

    @Test("a policy survives a round trip and compares equal")
    func roundTrips() throws {
        var policies = ProviderPolicies()
        policies[.zoom] = ProviderPolicy(autoStart: .never, autoStop: false)
        policies[.unknown] = ProviderPolicy(autoStart: .always)
        let restored = try JSONDecoder().decode(ProviderPolicies.self, from: try JSONEncoder().encode(policies))
        #expect(restored == policies)
        #expect(restored.unknownCalls.autoStart == .always)
    }
}

@Suite("GenericCallDetector meeting apps")
struct GenericCallDetectorMeetingAppTests {
    /// A meeting app found by the microphone alone, as Zoom will be once its
    /// desktop prefixes are in its definition.
    private static let zoomDesktop = MeetingApp(
        provider: .zoom, source: .zoom, name: "Zoom", symbolName: "square.grid.2x2.fill", tint: .blue,
        settingsKey: "zoom", desktopBundleIdentifiers: ["us.zoom.xos"],
        desktopAudioBundlePrefixes: ["us.zoom"]
    )

    private static func holding(_ bundleIdentifier: String, pid: Int32) -> ApplicationAudioState {
        ApplicationAudioState(
            bundleIdentifier: bundleIdentifier, processID: pid, holdsMicrophone: true,
            producesOutput: true, isFrontmost: false, windowTitle: nil
        )
    }

    @Test("a known app's call is filed under it, once however many helpers hold the microphone")
    func knownAppIsLabelled() {
        var detector = GenericCallDetector(apps: [Self.zoomDesktop])
        let states = [
            Self.holding("us.zoom.xos", pid: 1),
            Self.holding("us.zoom.CptHost", pid: 2),
            Self.holding("com.example.voice", pid: 3),
        ]
        var now = 0.0
        while now < 30 {
            _ = detector.update(states: states, at: now)
            now += 0.5
        }
        let evidence = detector.currentEvidence()
        let zoom = evidence.filter { $0.provider == .zoom }
        #expect(zoom.count == 1)
        #expect(zoom.first?.confidence == .confirmed)
        #expect(zoom.first?.applicationBundleID == "us.zoom.xos")
        #expect(zoom.first?.audioBundlePrefixes == ["us.zoom"])
        #expect(evidence.filter { $0.provider == .unknown }.map(\.applicationBundleID) == ["com.example.voice"])
    }

    /// The prompt offers the app's main identifier, and that is what "Never
    /// record" saves, while a helper with another identifier holds the
    /// microphone.
    @Test("never and always record apply to a known app's helpers")
    func listsApplyToHelpers() {
        let helper = [Self.holding("us.zoom.CptHost", pid: 2)]
        var never = GenericCallDetector(
            configuration: GenericCallDetector.Configuration(neverRecord: ["us.zoom.xos"]), apps: [Self.zoomDesktop]
        )
        _ = never.update(states: helper, at: 0)
        #expect(never.currentEvidence().isEmpty)

        var always = GenericCallDetector(
            configuration: GenericCallDetector.Configuration(alwaysRecord: ["us.zoom.xos"]), apps: [Self.zoomDesktop]
        )
        let events = always.update(states: helper, at: 0)
        #expect(events.contains { if case .callLikely(let candidate) = $0 { candidate.isPreapproved } else { false } })
    }

    @Test("an app's prefix does not claim another app that starts with the same letters")
    func prefixHasADotBoundary() {
        #expect(MeetingApp.owning(bundleIdentifier: "us.zoom.xos", in: [Self.zoomDesktop]) != nil)
        #expect(MeetingApp.owning(bundleIdentifier: "us.zoomify.app", in: [Self.zoomDesktop]) == nil)
    }

    @Test("no shipped app is filed this way yet, so every call here is still a Call")
    func shippedAppsLeaveTheFallbackAlone() {
        let apps = GenericCallDetector().apps
        #expect(apps.allSatisfy { $0.desktopAudioBundlePrefixes.isEmpty })
    }
}
