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
    }
}
