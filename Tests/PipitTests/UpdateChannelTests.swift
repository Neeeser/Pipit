import Foundation
import PipitCore
import PipitUI
import Testing

@Suite("Updates")
struct UpdateChannelTests {
    @Test("the beta channel is off until the setting is on")
    func theBetaChannelIsOffUntilTheSettingIsOn() async throws {
        #expect(
            UpdateChannels.allowed(receivesBeta: false).isEmpty,
            "an unsubscribed app sees only the releases with no channel"
        )
        #expect(UpdateChannels.allowed(receivesBeta: true) == ["beta"])
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
