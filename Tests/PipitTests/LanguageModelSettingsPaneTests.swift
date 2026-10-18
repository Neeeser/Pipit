import AppKit
import Foundation
import PipitCore
import PipitIntegrations
import PipitServices
import Testing

@testable import PipitUI

/// The AI Features page: what it remembers per provider, how it sizes the
/// context window, and that every page it can show builds.
@MainActor
@Suite("LanguageModelSettingsPane")
struct LanguageModelSettingsPaneTests {
    private func makeModel() throws -> (SettingsModel, URL) {
        let root = try TestPaths.makeTemporaryDirectory()
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        return (SettingsModel(runtime: runtime), root)
    }

    @Test("each provider keeps the model chosen for it")
    func eachProviderKeepsTheModelChosenForIt() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        model.selectProvider(.ollama)
        model.chooseModel("llama3.1:8b")
        model.setContext(32_768)
        model.selectProvider(.openRouter)
        #expect(model.runtime.settings.models.metadata.isEmpty, "nothing is chosen for a provider until it is")
        model.chooseModel("meta-llama/llama-3.3-70b-instruct")
        model.selectProvider(.openAI)
        #expect(model.runtime.settings.models.metadata == AIModelSettings.defaultMetadataModel)

        model.selectProvider(.ollama)
        #expect(model.runtime.settings.models.metadata == "llama3.1:8b")
        #expect(model.contextTokens == 32_768)
        #expect(SettingsStore(directory: root).load().models.metadataProvider == .ollama, "and it is saved")
    }

    @Test("a hosted model sets the window from the figure its provider published")
    func aHostedModelSetsTheWindowFromTheFigureItsProviderPublished() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectProvider(.openRouter)

        model.chooseOption(LanguageModelOption(id: "a/small", name: "Small", contextTokens: 40_960))
        #expect(model.contextTokens == 32_768, "never more than the model reads")
        model.chooseOption(LanguageModelOption(id: "a/huge", name: "Huge", contextTokens: 1_048_576))
        #expect(model.contextTokens == 131_072, "more than a transcript needs is not asked for")
        model.chooseOption(LanguageModelOption(id: "a/unstated", name: "Unstated"))
        #expect(model.contextTokens == 131_072)
        #expect(model.runtime.settings.models.metadata == "a/unstated")

        model.selectProvider(.custom)
        model.setContext(16_384)
        model.chooseOption(LanguageModelOption(id: "local", name: "Local", contextTokens: 4_096))
        #expect(model.contextTokens == 16_384, "a server's window is the person's to say, not the listing's")
    }

    @Test("the slider stops at what the chosen Ollama model supports")
    func theSliderStopsAtWhatTheChosenOllamaModelSupports() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.selectProvider(.ollama)

        #expect(model.contextSizes == ContextWindow.sizes, "before Ollama has said")
        model.ollamaMaximumContext = 40_960
        #expect(model.contextSizes == [4_096, 8_192, 16_384, 32_768, 40_960])
        model.selectProvider(.custom)
        #expect(model.contextSizes == ContextWindow.sizes, "only Ollama reports a limit")
    }

    @Test("the model list narrows by search and by price")
    func theModelListNarrowsBySearchAndByPrice() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.modelList = [
            LanguageModelOption(id: "meta/llama-70b", name: "Llama 70B", promptPrice: 0.1, completionPrice: 0.3),
            LanguageModelOption(id: "meta/llama-70b:free", name: "Llama 70B (free)"),
            LanguageModelOption(id: "mistral/small", name: "Mistral Small"),
        ]
        #expect(model.visibleModels.count == 3)
        model.modelSearch = "LLAMA"
        #expect(model.visibleModels.map(\.id) == ["meta/llama-70b", "meta/llama-70b:free"])
        model.showsFreeModelsOnly = true
        #expect(model.visibleModels.map(\.id) == ["meta/llama-70b:free"])
        model.modelSearch = "mistral"
        #expect(model.visibleModels.isEmpty)
    }

    @Test("a price reads in dollars per million tokens")
    func aPriceReadsInDollarsPerMillionTokens() {
        let paid = LanguageModelOption(id: "a", name: "A", promptPrice: 0.12, completionPrice: 0.3)
        #expect(ModelSearchList.price(of: paid) == "$0.12 in, $0.30 out per million tokens")
        let dear = LanguageModelOption(id: "b", name: "B", promptPrice: 15, completionPrice: 75)
        #expect(ModelSearchList.price(of: dear) == "$15.00 in, $75.00 out per million tokens")
        let cheap = LanguageModelOption(id: "c", name: "C", promptPrice: 0.015, completionPrice: 0.02)
        #expect(ModelSearchList.price(of: cheap) == "$0.015 in, $0.02 out per million tokens")
        #expect(ModelSearchList.price(of: LanguageModelOption(id: "d:free", name: "D")) == "Free")
        #expect(ModelSearchList.price(of: LanguageModelOption(id: "e", name: "E")) == nil)

        let detail = ModelListPicker.detail(
            of: "a", in: [LanguageModelOption(id: "a", name: "A", contextTokens: 128_000)])
        #expect(detail == "128K context")
        #expect(ModelListPicker.detail(of: "missing", in: []) == nil)
    }

    @Test("every provider's page builds and lays out in every state")
    func everyProvidersPageBuildsAndLaysOutInEveryState() throws {
        let (model, root) = try makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        let installed = [
            OllamaModel(name: "llama3.1:8b", sizeBytes: 4_920_753_328, parameterSize: "8.0B", quantization: "Q4_K_M"),
            OllamaModel(name: "bare", sizeBytes: 0),
        ]
        let listed = [
            LanguageModelOption(
                id: "meta/llama-70b", name: "Llama 70B", contextTokens: 131_072,
                promptPrice: 0.12, completionPrice: 0.3),
            LanguageModelOption(id: "meta/llama-70b:free", name: "Llama 70B (free)", contextTokens: 65_536),
            LanguageModelOption(id: "plain", name: "plain"),
        ]

        for provider in LanguageModelProvider.allCases {
            model.selectProvider(provider)
            ViewFixtures.render(AIFeaturesSettingsPane(model: model))
        }

        model.selectProvider(.ollama)
        let statuses: [OllamaServer.Status?] = [
            nil, .notInstalled, .installedNotRunning, .running(models: []), .running(models: installed),
        ]
        for status in statuses {
            model.ollamaStatus = status
            ViewFixtures.render(AIFeaturesSettingsPane(model: model))
        }

        for provider in [LanguageModelProvider.openRouter, .custom] {
            model.selectProvider(provider)
            model.chooseModel("meta/llama-70b")
            for state in [SettingsModel.ModelListState.idle, .loading, .failed, .loaded] {
                model.modelListState = state
                model.modelList = state == .loaded ? listed : []
                ViewFixtures.render(AIFeaturesSettingsPane(model: model))
            }
            model.modelList = listed
            model.modelListState = .loaded
            model.typesModelName = true
            ViewFixtures.render(AIFeaturesSettingsPane(model: model))
            model.typesModelName = false
            ViewFixtures.render(ModelSearchList(model: model), size: NSSize(width: 460, height: 380))
        }
        // Nothing is asserted here. Reaching this line means no page trapped.
    }
}
