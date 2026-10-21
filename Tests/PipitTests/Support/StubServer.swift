import Foundation

/// What a stubbed server was sent.
struct StubRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data

    /// The JSON body as an object, for the requests that carry one.
    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// What a stubbed server answers.
struct StubReply: Sendable {
    var status: Int = 200
    var body: Data = Data()
    var headers: [String: String] = [:]
    /// Fails the connection instead of answering, as a server that is down does.
    var connectionFails = false
    /// The error a failed connection reports.
    var failure: URLError.Code = .cannotConnectToHost

    static func json(_ object: Any, status: Int = 200) -> StubReply {
        StubReply(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data())
    }

    static let down = StubReply(connectionFails: true)

    /// No answer, failing with `code`, as a request that times out does.
    static func fails(_ code: URLError.Code) -> StubReply {
        StubReply(connectionFails: true, failure: code)
    }
}

/// A server that exists only inside one `URLSession`.
///
/// Each server answers for a host name of its own, so tests that run side by
/// side do not hear each other's requests, and nothing leaves the machine.
final class StubServer: @unchecked Sendable {
    let host = "stub-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var captured: [StubRequest] = []
    private let respond: @Sendable (StubRequest) -> StubReply

    init(respond: @escaping @Sendable (StubRequest) -> StubReply) {
        self.respond = respond
        StubURLProtocol.register(host: host, server: self)
    }

    deinit { StubURLProtocol.unregister(host: host) }

    /// The base URL a client is pointed at.
    func baseURL(path: String = "") -> URL { URL(string: "http://\(host)\(path)")! }

    var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    var requests: [StubRequest] { lock.withLock { captured } }

    fileprivate func answer(_ request: StubRequest) -> StubReply {
        lock.withLock { captured.append(request) }
        return respond(request)
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(host: String, server: StubServer) {
        lock.withLock { servers[host] = server }
    }

    static func unregister(host: String) {
        _ = lock.withLock { servers.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
            let server = Self.lock.withLock({ Self.servers[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = server.answer(
            StubRequest(
                method: request.httpMethod ?? "GET",
                path: url.path,
                headers: request.allHTTPHeaderFields ?? [:],
                body: bodyData()
            )
        )
        if reply.connectionFails {
            client?.urlProtocol(self, didFailWithError: URLError(reply.failure))
            return
        }
        let response = HTTPURLResponse(
            url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// A body handed to a session arrives as a stream.
    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
