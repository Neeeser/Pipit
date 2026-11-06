import Foundation
import PipitCore
import PipitIntegrations
import Testing

/// How the OpenAI client sorts an HTTP answer, which decides whether a later
/// launch tries the stage again.
@Suite("OpenAIClient statuses")
struct OpenAIStatusTests {
    private struct Key: APIKeyProviding {
        func apiKey() throws -> String { "test-key" }
        var isKnownAbsent: Bool { false }
        func invalidateCachedKey() {}
    }

    private func failure(status: Int) async -> ProcessingError? {
        let server = StubServer { _ in StubReply(status: status) }
        let client = OpenAIClient(
            configuration: .init(baseURL: server.baseURL()), keyProvider: Key(), session: server.session)
        do {
            try await client.verifyCredentials(model: "m")
            return nil
        } catch {
            return error as? ProcessingError
        }
    }

    @Test("a model that is gone is fixed in Settings, and another refusal repeats")
    func aModelThatIsGoneIsFixedInSettingsAndAnotherRefusalRepeats() async {
        let gone = await failure(status: 404)
        #expect(gone == .languageModel(provider: "OpenAI", failure: .modelNotFound))
        #expect(gone?.cause == .fixedInSettings)
        for status in [409, 422] {
            let refused = await failure(status: status)
            #expect(refused?.cause == .sameResultEachTime, "\(status)")
        }
        let timeout = await failure(status: 408)
        #expect(timeout?.cause == .clearsByWaiting)
        let outage = await failure(status: 503)
        #expect(outage?.cause == .clearsByWaiting)
    }
}
