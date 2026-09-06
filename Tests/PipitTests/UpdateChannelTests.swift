import Foundation
import PipitCore
import PipitUI
import Testing

@Suite("Updates")
struct UpdateChannelTests {
    @Test("a 0.x build takes the beta channel with the setting off")
    func aZeroPointBuildTakesTheBetaChannelWithTheSettingOff() async throws {
        #expect(
            UpdateChannels.allowed(receivesBeta: false, appVersion: "0.1.0") == ["beta"],
            "every 0.x release is a pre-release, so a 0.x build that skipped the channel would never update"
        )
    }

    @Test("a 1.0 build follows the setting")
    func aOnePointZeroBuildFollowsTheSetting() async throws {
        #expect(
            UpdateChannels.allowed(receivesBeta: false, appVersion: "1.0.0").isEmpty,
            "an unsubscribed app sees only the releases with no channel"
        )
        #expect(UpdateChannels.allowed(receivesBeta: true, appVersion: "1.0.0") == ["beta"])
    }

    @Test("a version string that does not parse counts as a non-zero major")
    func aVersionStringThatDoesNotParseCountsAsANonZeroMajor() async throws {
        #expect(UpdateChannels.allowed(receivesBeta: false, appVersion: "not a version").isEmpty)
        #expect(UpdateChannels.allowed(receivesBeta: false, appVersion: "").isEmpty)
        #expect(UpdateChannels.allowed(receivesBeta: true, appVersion: "not a version") == ["beta"])
    }

    @Test("the channels follow the setting on the value the delegate reads")
    func theChannelsFollowTheSettingOnTheValueTheDelegateReads() async throws {
        var settings = AppSettings()
        #expect(
            UpdateChannels.allowed(
                receivesBeta: settings.receivesBetaUpdates, appVersion: "1.2.0"
            ).isEmpty
        )
        settings.receivesBetaUpdates = true
        #expect(
            UpdateChannels.allowed(
                receivesBeta: settings.receivesBetaUpdates, appVersion: "1.2.0"
            ) == ["beta"]
        )
    }

    @Test("the beta setting defaults to false and round-trips through disk")
    func theBetaSettingDefaultsToFalseAndRoundTripsThroughDisk() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)
        #expect(!store.load().receivesBetaUpdates, "a fresh install is on the stable channel")

        var settings = AppSettings()
        settings.receivesBetaUpdates = true
        try store.save(settings)
        #expect(SettingsStore(directory: root).load().receivesBetaUpdates)

        // A settings file written before the key existed decodes to the
        // stable channel rather than resetting every other field.
        let older = try JSONDecoder().decode(
            AppSettings.self, from: Data(#"{"version": 3, "localUserName": "Marlow"}"#.utf8)
        )
        #expect(!older.receivesBetaUpdates)
        #expect(older.localUserName == "Marlow")
    }
}
