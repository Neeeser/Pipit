import Foundation
import FoundationModels
import Testing

@testable import PipitCore
@testable import PipitIntegrations
@testable import PipitServices

/// Apple Intelligence as the provider that writes about a meeting: what it
/// needs, how it is reported, and when a new install starts with it.
@Suite("AppleIntelligenceProvider")
struct AppleIntelligenceProviderTests {
    @Test("Apple Intelligence needs no key, address or model choice")
    func appleIntelligenceNeedsNoKeyAddressOrModelChoice() {
        var settings = AIModelSettings()
        settings.metadataProvider = .appleIntelligence
        #expect(LanguageModelProvider.appleIntelligence.keyRequirement == .none)
        #expect(!LanguageModelProvider.appleIntelligence.choosesContextWindow)
        // A non-empty model is what lets the summary stages run at all.
        #expect(settings.metadata == LanguageModelProvider.appleOnDeviceModel)
        #expect(settings.metadataContextTokens == LanguageModelProvider.appleContextTokens)
    }

    @Test("a diagnostic report names the on-device model and nothing typed")
    func aDiagnosticReportNamesTheOnDeviceModelAndNothingTyped() {
        #expect(
            DiagnosticSnapshot.metadataModel("on-device", provider: .appleIntelligence) == "on-device"
        )
        #expect(DiagnosticSnapshot.metadataModel("CANARY", provider: .appleIntelligence) == "custom")
    }

    @Test("only no settings and no meetings counts as a new install")
    func onlyNoSettingsAndNoMeetingsCountsAsANewInstall() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("support", isDirectory: true)
        let meetings = root.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: settings, withIntermediateDirectories: true)
        let store = SettingsStore(directory: settings)
        // The meetings folder not existing yet is the usual new install.
        #expect(PipitRuntime.isNewInstall(store, meetings: meetings))
        try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try Data().write(to: meetings.appendingPathComponent(".DS_Store"))
        #expect(PipitRuntime.isNewInstall(store, meetings: meetings))
        // Someone who recorded without ever changing a setting has no file.
        try FileManager.default.createDirectory(
            at: meetings.appendingPathComponent("2026-11-17 Standup", isDirectory: true),
            withIntermediateDirectories: true
        )
        #expect(!PipitRuntime.isNewInstall(store, meetings: meetings))
        try FileManager.default.removeItem(at: meetings)
        try store.save(AppSettings())
        #expect(!PipitRuntime.isNewInstall(store, meetings: meetings))
    }

    @MainActor
    @Test("saved settings keep their provider when the app passes another")
    func savedSettingsKeepTheirProviderWhenTheAppPassesAnother() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var saved = AppSettings()
        saved.models.metadataProvider = .ollama
        try SettingsStore(directory: root).save(saved)
        let runtime = PipitRuntime(settingsDirectory: root, firstLaunchLanguageModel: .appleIntelligence)
        #expect(runtime.settings.models.metadataProvider == .ollama)
    }

    @MainActor
    @Test("without a first-launch provider a new install keeps the stored default")
    func withoutAFirstLaunchProviderANewInstallKeepsTheStoredDefault() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = PipitRuntime(settingsDirectory: root)
        #expect(runtime.settings.models.metadataProvider == AIModelSettings().metadataProvider)
    }

    #if compiler(>=6.4)
        @Test("the framework's errors read as the failures every provider reports")
        func theFrameworksErrorsReadAsTheFailuresEveryProviderReports() throws {
            guard #available(macOS 27.0, *) else { return }
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "")
            #expect(AppleIntelligenceClient.failure(of: .rateLimited(context)) == .rateLimited(retryAfter: nil))
            #expect(AppleIntelligenceClient.failure(of: .assetsUnavailable(context)) == .unreachable)
            #expect(AppleIntelligenceClient.failure(of: .guardrailViolation(context)) == .unexpectedResponse)
            #expect(AppleIntelligenceClient.failure(of: .exceededContextWindowSize(context)) == .unexpectedResponse)
        }

        @Test("only an answer that overran or did not decode is asked for again")
        func onlyAnAnswerThatOverranOrDidNotDecodeIsAskedForAgain() throws {
            guard #available(macOS 27.0, *) else { return }
            let context = LanguageModelSession.GenerationError.Context(debugDescription: "")
            #expect(AppleIntelligenceClient.isWorthAskingAgain(.exceededContextWindowSize(context)))
            #expect(AppleIntelligenceClient.isWorthAskingAgain(.decodingFailure(context)))
            #expect(!AppleIntelligenceClient.isWorthAskingAgain(.rateLimited(context)))
            #expect(!AppleIntelligenceClient.isWorthAskingAgain(.guardrailViolation(context)))
        }
    #endif
}
