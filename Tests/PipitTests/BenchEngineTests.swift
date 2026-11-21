import Foundation
import PipitCore
import Testing

@testable import PipitEval

@Suite("BenchEngines")
struct BenchEngineTests {
    @Test("every local engine is reachable by its raw value, Parakeet Ultra included")
    func everyLocalEngineIsReachableByItsRawValue() {
        for model in LocalTranscriptionModel.allCases {
            #expect(BenchCommand.Engine.parse(model.rawValue) == .local(model))
        }
        #expect(BenchCommand.Engine.parse("parakeet-ultra") == .local(.parakeetUltra))
        #expect(BenchCommand.Engine.valid.contains("parakeet-ultra"))
    }

    @Test("the install size of the Ultra engine counts its own weights, not Parakeet's")
    func theInstallSizeOfTheUltraEngineCountsItsOwnWeights() {
        let ultra = BenchCommand.installSize(engineName: "parakeet-ultra", diarizer: "local")
        let v3 = BenchCommand.installSize(engineName: "parakeet", diarizer: "local")
        #expect(ultra != v3)

        let units = LocalModelUnit.recommended(
            for: BenchCommand.settings(engine: .local(.parakeetUltra), diarizer: "local"))
        #expect(units.contains(.parakeetUltra))
        #expect(!units.contains(.parakeet))
        #expect(
            BenchCommand.installBytes(engineName: "parakeet-ultra", diarizer: "local")
                == units.reduce(Int64(0)) { $0 + $1.approximateBytes }
        )
    }

    @Test("Parakeet Ultra refuses the live flags it would silently ignore")
    func parakeetUltraRefusesTheLiveFlags() {
        var options = BenchCommand.Options(applicationSupport: FileManager.default.temporaryDirectory)
        #expect(BenchCommand.liveFlagConflict(engines: [.local(.parakeetUltra)], options: options) == nil)
        options.livePhrases = true
        options.liveEngine = true
        let message = BenchCommand.liveFlagConflict(engines: [.local(.parakeetUltra)], options: options)
        #expect(message?.contains("--live-phrases") == true)
        #expect(message?.contains("--live-engine") == true)
        #expect(BenchCommand.liveFlagConflict(engines: [.local(.parakeet)], options: options) == nil)
    }
}
