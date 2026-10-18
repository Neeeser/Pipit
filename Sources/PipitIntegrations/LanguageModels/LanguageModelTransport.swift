import Foundation
import PipitCore

/// Sends one request to a model's server and turns what comes back into the
/// failures Pipit tells a person about.
struct LanguageModelTransport: Sendable {
    let provider: LanguageModelProvider
    let session: URLSession
    /// Called when the server refuses the key, so a cached copy of it is not
    /// handed to the next request.
    var onAuthenticationFailure: @Sendable () -> Void = {}

    func send(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw ProcessingError.cancelled
            }
            throw failure(.unreachable)
        }
        guard let http = response as? HTTPURLResponse else {
            throw failure(.unexpectedResponse)
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401, 403:
            onAuthenticationFailure()
            throw failure(.authenticationFailed)
        case 404:
            throw failure(.modelNotFound)
        case 408:
            throw failure(.unreachable)
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(Double.init)
            throw failure(.rateLimited(retryAfter: retryAfter))
        case 500..<600:
            throw failure(.serverError(status: http.statusCode))
        default:
            throw failure(.rejected(status: http.statusCode))
        }
    }

    func failure(_ failure: LanguageModelFailure) -> ProcessingError {
        .languageModel(provider: provider.displayName, failure: failure)
    }
}
