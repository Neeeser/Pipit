import PipitCore
import PipitUI
import Testing

/// What setup tells the person when checking their OpenAI key fails.
@Suite("Setup key check")
struct SetupKeyCheckTests {
    @Test("a model that OpenAI does not have does not reject the key or stop setup")
    func aModelThatOpenAIDoesNotHaveDoesNotRejectTheKeyOrStopSetup() {
        let missing = SetupModel.keyState(
            after: .languageModel(provider: "OpenAI", failure: .modelNotFound))
        guard case .unreachable(let message) = missing else {
            Issue.record("expected a state setup can continue from, got \(missing)")
            return
        }
        #expect(message == "OpenAI does not have the selected model.")
        #expect(
            SetupModel.keyState(after: .authenticationFailed)
                == .rejected(ProcessingError.authenticationFailed.userMessage),
            "a refused key is still rejected"
        )
        #expect(
            SetupModel.keyState(after: .transport(reason: "offline"))
                == .unreachable(ProcessingError.transport(reason: "offline").userMessage)
        )
    }
}
