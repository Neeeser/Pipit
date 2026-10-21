import Foundation
import Testing

@testable import PipitCore

/// The pure half of sending reports: the body's encoding, the deletion code,
/// the service's answers, the backoff, the outbox and receipts on disk, and
/// the rules of automatic sharing and the crash prompt
/// (`docs/DIAGNOSTICS.md`, Report service and Automatic sharing).
@Suite("Diagnostic delivery policy")
struct DiagnosticDeliveryPolicyTests {
    // MARK: - gzip

    @Test("a compressed body is gzip that the system's gzip reads back to the same bytes")
    func aCompressedBodyIsGzipThatTheSystemsGzipReadsBack() throws {
        let report = try DiagnosticDeliveryFixtures.report()
        let json = try report.encoded()
        for original in [json, Data(), Data(repeating: 0x41, count: 200_000)] {
            let compressed = DiagnosticGzip.compress(original)
            #expect(compressed.prefix(3) == Data([0x1f, 0x8b, 0x08]))
            #expect(try Self.gunzip(compressed) == original)
        }
        // The same JSON frames the same way: no time or name in the header.
        #expect(DiagnosticGzip.compress(json) == DiagnosticGzip.compress(json))
    }

    @Test("stored blocks split at 65,535 bytes and keep every byte")
    func storedBlocksSplitAndKeepEveryByte() throws {
        let original = Data((0..<140_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let framed = DiagnosticGzip.frame(deflated: DiagnosticGzip.stored(original), original: original)
        #expect(try Self.gunzip(framed) == original)
        #expect(DiagnosticGzip.crc32(Data("123456789".utf8)) == 0xcbf4_3926)
    }

    // MARK: - deletion code

    @Test("the fixture's deletion hash is canonical base64url of 32 bytes")
    func theFixturesDeletionHashIsCanonical() throws {
        let report = try DiagnosticDeliveryFixtures.report()
        #expect(report.deletionSecretHash == "zJk90jTVjCvAIbe9mWlHJMzML8SbnpzjNUx1hwySPi0")
        #expect(DiagnosticBase64URL.isCanonical(report.deletionSecretHash, byteCount: 32))
        #expect(report.deletionSecretHash.count == 43)
    }

    @Test("base64url has no padding, no plus or slash, and one spelling per value")
    func base64URLHasOneSpellingPerValue() {
        let bytes = Data([0xfb, 0xff, 0xbf, 0x00, 0x01])
        #expect(DiagnosticBase64URL.encode(bytes) == "-_-_AAE")
        #expect(DiagnosticBase64URL.decode("-_-_AAE") == bytes)
        let secret = DiagnosticBase64URL.encode(Data(repeating: 7, count: 32))
        #expect(secret.count == 43)
        #expect(DiagnosticDeletionCode.isSecret(secret))
        // The last character carries two unused bits; only zeros are canonical.
        var lastChanged = secret
        lastChanged.removeLast()
        #expect(!DiagnosticDeletionCode.isSecret(lastChanged + "d"))
        #expect(!DiagnosticDeletionCode.isSecret(secret + "="))
        #expect(!DiagnosticDeletionCode.isSecret(secret.replacingOccurrences(of: "B", with: "+")))
        #expect(!DiagnosticDeletionCode.isSecret(DiagnosticBase64URL.encode(Data(repeating: 7, count: 31))))
    }

    @Test("a deletion code is the lowercase report ID, a dot, and the secret, and reads back")
    func aDeletionCodeReadsBack() throws {
        let secret = DiagnosticBase64URL.encode(Data(repeating: 9, count: 32))
        let reportID = "5B0C6A3E-8F1D-4C2A-9E7B-1D2F3A4B5C6D"
        let code = DiagnosticDeletionCode.make(reportID: reportID, secret: secret)
        #expect(code == "5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d.\(secret)")
        let parsed = try #require(DiagnosticDeletionCode.parse("  \(code)\n"))
        #expect(parsed.reportID == "5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d")
        #expect(parsed.secret == secret)
        #expect(DiagnosticDeletionCode.parse("not-a-uuid.\(secret)") == nil)
        #expect(DiagnosticDeletionCode.parse(reportID) == nil)
    }

    // MARK: - the service's answers

    @Test("each status the service gives maps to its own result")
    func eachStatusMapsToItsOwnResult() throws {
        let reportID = "5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d"
        let now = DiagnosticDeliveryFixtures.start
        let receiptBody = Data(
            #"{"reportID":"\#(reportID)","receivedAt":"2026-10-21T03:18:16Z","expiresAt":"2027-01-19T03:18:16Z"}"#.utf8
        )
        let receipt = DiagnosticServiceReceipt(
            reportID: reportID, receivedAt: DiagnosticsFixtures.utc("2026-10-21T03:18:16Z"),
            expiresAt: DiagnosticsFixtures.utc("2027-01-19T03:18:16Z")
        )
        func result(_ status: Int, _ body: Data = Data(), retryAfter: String? = nil) -> DiagnosticSubmitResult {
            .from(status: status, body: body, retryAfter: retryAfter, reportID: reportID, now: now)
        }
        #expect(result(201, receiptBody) == .accepted(receipt))
        #expect(result(200, receiptBody) == .replayed(receipt))
        #expect(result(201, Data("{}".utf8)) == .unreadableReceipt(status: 201))
        #expect(result(409, Data(#"{"error":"conflict"}"#.utf8)) == .conflict)
        #expect(result(400, Data(#"{"error":"token_rule"}"#.utf8)) == .invalid(error: "token_rule"))
        // A 400 body that is not the service's own is not repeated.
        #expect(result(400, Data(#"{"error":"Weekly sync title"}"#.utf8)) == .invalid(error: nil))
        #expect(result(413) == .tooLarge)
        #expect(result(415) == .unsupportedMediaType)
        #expect(result(429, retryAfter: "120") == .rateLimited(retryAfter: 120))
        #expect(result(429) == .rateLimited(retryAfter: nil))
        #expect(result(503, retryAfter: "30") == .unavailable(status: 503, retryAfter: 30))
        #expect(result(500) == .unavailable(status: 500, retryAfter: nil))
        #expect(result(404) == .unexpected(status: 404))
        // A receipt for another report is not this one's.
        let otherBody = Data(
            (#"{"reportID":"00000000-0000-4000-8000-000000000000","#
                + #""receivedAt":"2026-10-21T03:18:16Z","expiresAt":"2027-01-19T03:18:16Z"}"#).utf8
        )
        #expect(result(201, otherBody) == .unreadableReceipt(status: 201))

        #expect(DiagnosticLookupResult.from(status: 200, body: receiptBody, reportID: reportID) == .found(receipt))
        #expect(DiagnosticLookupResult.from(status: 404, body: Data(), reportID: reportID) == .notFound)
        #expect(DiagnosticDeleteResult.from(status: 204) == .deleted)
        #expect(DiagnosticDeleteResult.from(status: 404) == .notFound)
        #expect(DiagnosticDeleteResult.from(status: 500) == .failed(status: 500))
        #expect(DiagnosticDeleteResult.deleted.isGone && DiagnosticDeleteResult.notFound.isGone)
        #expect(!DiagnosticDeleteResult.failed(status: nil).isGone)
    }

    @Test("Retry-After is read as seconds or as an HTTP date")
    func retryAfterIsReadAsSecondsOrAnHTTPDate() {
        let now = DiagnosticsFixtures.utc("2026-10-21T09:00:00Z")
        #expect(DiagnosticRetryAfter.seconds("90", now: now) == 90)
        #expect(DiagnosticRetryAfter.seconds(" 0 ", now: now) == 0)
        #expect(DiagnosticRetryAfter.seconds("-5", now: now) == 0)
        #expect(DiagnosticRetryAfter.seconds("Wed, 21 Oct 2026 09:02:00 GMT", now: now) == 120)
        #expect(DiagnosticRetryAfter.seconds("Wed, 21 Oct 2026 08:00:00 GMT", now: now) == 0)
        #expect(DiagnosticRetryAfter.seconds("soon", now: now) == nil)
        #expect(DiagnosticRetryAfter.seconds(nil, now: now) == nil)
    }

    @Test("stored and replayed reports are confirmed, refused ones dropped, and the rest retried")
    func dispositions() {
        let receipt = FakeReportTransport.receipt("5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d")
        let cases: [(DiagnosticSubmitResult, DiagnosticSendPolicy.Disposition, DiagnosticEvent.ReportOutcome)] = [
            (.accepted(receipt), .confirmed(receipt), .accepted),
            (.replayed(receipt), .confirmed(receipt), .replayed),
            (.conflict, .dropped, .rejected),
            (.invalid(error: "token_rule"), .dropped, .rejected),
            (.tooLarge, .dropped, .rejected),
            (.unsupportedMediaType, .dropped, .rejected),
            (.unexpected(status: 404), .dropped, .rejected),
            (.rateLimited(retryAfter: 60), .retry(retryAfter: 60), .failed),
            (.unavailable(status: 503, retryAfter: nil), .retry(retryAfter: nil), .failed),
            (.unreadableReceipt(status: 201), .retry(retryAfter: nil), .failed),
            (.network(DiagnosticCode.error(domain: "NSURLErrorDomain", code: -1001)), .retry(retryAfter: nil), .failed),
        ]
        for (result, disposition, outcome) in cases {
            #expect(DiagnosticSendPolicy.disposition(for: result) == disposition, "\(result)")
            #expect(DiagnosticSendPolicy.eventOutcome(for: result) == outcome, "\(result)")
        }
    }

    @Test("the retry wait doubles, is jittered in its upper half, is capped, and honours Retry-After")
    func theRetryWaitDoublesAndIsCapped() {
        let policy = DiagnosticSendPolicy.self
        #expect(policy.retryDelay(afterAttempts: 1, retryAfter: nil, random: 0) == 30)
        #expect(policy.retryDelay(afterAttempts: 1, retryAfter: nil, random: 1) == 60)
        #expect(policy.retryDelay(afterAttempts: 2, retryAfter: nil, random: 1) == 120)
        #expect(policy.retryDelay(afterAttempts: 4, retryAfter: nil, random: 0.5) == 360)
        #expect(policy.retryDelay(afterAttempts: 40, retryAfter: nil, random: 1) == policy.maximumDelay)
        #expect(policy.retryDelay(afterAttempts: 40, retryAfter: nil, random: 0) == policy.maximumDelay / 2)
        #expect(policy.retryDelay(afterAttempts: 1, retryAfter: 600, random: 0) == 600)
        #expect(policy.retryDelay(afterAttempts: 1, retryAfter: 86_400 * 30, random: 0) == policy.maximumDelay)
    }

    // MARK: - outbox and receipts

    @Test("the outbox keeps the exact body, lists entries oldest first, and sweeps strays")
    func theOutboxKeepsTheExactBody() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DiagnosticLayout(root: root)
        let outbox = DiagnosticOutbox(layout: layout)
        let start = DiagnosticDeliveryFixtures.start
        let first = DiagnosticOutboxEntry(
            reportID: "5B0C6A3E-8F1D-4C2A-9E7B-1D2F3A4B5C6D", kind: .user, createdAt: start, queuedAt: start,
            automatic: false, bytes: 3
        )
        let second = DiagnosticOutboxEntry(
            reportID: UUID().uuidString, kind: .automatic, createdAt: start, queuedAt: start.addingTimeInterval(5),
            automatic: true, bytes: 2
        )
        try outbox.enqueue(second, body: Data([4, 5]))
        try outbox.enqueue(first, body: Data([1, 2, 3]))
        #expect(outbox.entries() == [first, second])
        #expect(outbox.body(for: first.reportID) == Data([1, 2, 3]))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: layout.outbox.path).sorted().contains(
                "5b0c6a3e-8f1d-4c2a-9e7b-1d2f3a4b5c6d.json.gz"))

        var retried = first
        retried.attempts = 2
        try outbox.update(retried)
        #expect(outbox.entry(for: first.reportID) == retried)
        #expect(outbox.body(for: first.reportID) == Data([1, 2, 3]))

        // A body whose entry was never written, and a stray temporary file.
        let orphan = UUID().uuidString.lowercased()
        try Data([9]).write(to: layout.outbox.appendingPathComponent("\(orphan).json.gz"))
        try Data([9]).write(to: layout.outbox.appendingPathComponent(".x.json.gz.tmp"))
        #expect(outbox.entries().count == 2)
        #expect(outbox.removeStrays() == [orphan])
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.outbox.path).count == 4)

        outbox.remove(first.reportID)
        #expect(outbox.entries() == [second])
        #expect(outbox.bodyFile(for: "../sent") == nil)
        #expect(!second.isExpired(now: start.addingTimeInterval(6 * 86_400)))
        #expect(second.isExpired(now: start.addingTimeInterval(7 * 86_400 + 5)))
    }

    @Test("receipts are kept newest first, replaced by report ID, and hold no secret")
    func receiptsAreKeptNewestFirst() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticReceiptStore(layout: DiagnosticLayout(root: root))
        #expect(store.load().isEmpty)
        let start = DiagnosticDeliveryFixtures.start
        let older = DiagnosticReceipt(
            reportID: UUID().uuidString, kind: .user, sentAt: start, receivedAt: start,
            expiresAt: start.addingTimeInterval(90 * 86_400), bytes: 100
        )
        var newer = older
        newer.reportID = UUID().uuidString.lowercased()
        newer.sentAt = start.addingTimeInterval(60)
        try store.add(older)
        try store.add(newer)
        #expect(store.load() == [newer, older])
        var replaced = older
        replaced.bytes = 200
        try store.add(replaced)
        #expect(store.load() == [newer, replaced])
        try store.remove(reportID: newer.reportID.uppercased())
        #expect(store.load() == [replaced])

        let text = try String(contentsOf: DiagnosticLayout(root: root).sentReceipts, encoding: .utf8)
        let object = try #require(JSONValue.parse(Data(text.utf8))?.objectValue)
        #expect(Set(object.keys) == ["receipts"])
        let first = try #require(
            object["receipts"].flatMap { value -> JSONValue? in
                if case .array(let items) = value { return items.first }
                return nil
            }?.objectValue)
        #expect(Set(first.keys) == ["reportID", "kind", "sentAt", "receivedAt", "expiresAt", "bytes"])
        try store.removeAll()
        #expect(store.load().isEmpty)
    }

    // MARK: - automatic sharing

    @Test("sharing starts with no earlier events and the first daily report a day later")
    func sharingStartsFromNow() {
        let now = DiagnosticDeliveryFixtures.start
        let state = DiagnosticSharingPolicy.started(now: now, random: 0.5)
        #expect(state.eventsSince == now)
        #expect(state.nextDailyAt == now.addingTimeInterval(86_400 + 1_800))
        #expect(state.pendingCrashes.isEmpty)
    }

    @Test("busy, offline, Low Data Mode and an expensive network each hold automatic sharing back")
    func eachConditionHoldsSharingBack() {
        let policy = DiagnosticSharingPolicy.self
        #expect(policy.blocker(isBusy: false, network: .unmetered) == nil)
        #expect(policy.blocker(isBusy: true, network: .unmetered) == .busy)
        #expect(policy.blocker(isBusy: false, network: .unknown) == .offline)
        #expect(policy.blocker(isBusy: false, network: .init(isSatisfied: true, isConstrained: true)) == .constrained)
        #expect(policy.blocker(isBusy: false, network: .init(isSatisfied: true, isExpensive: true)) == .expensive)
    }

    @Test("a crash is noted once, and the daily cut-off only moves forward")
    func aCrashIsNotedOnce() {
        let now = DiagnosticDeliveryFixtures.start
        var state = DiagnosticSharingPolicy.started(now: now, random: 0)
        state = DiagnosticSharingPolicy.noting(crash: "ABC", since: now, now: now, in: state)
        state = DiagnosticSharingPolicy.noting(crash: "abc", since: now, now: now, in: state)
        #expect(state.pendingCrashes.map(\.incident) == ["abc"])
        state = DiagnosticSharingPolicy.handled(crash: "abc", in: state)
        #expect(state.pendingCrashes.isEmpty)
        state = DiagnosticSharingPolicy.noting(crash: "abc", since: now, now: now, in: state)
        #expect(state.pendingCrashes.isEmpty)

        let later = DiagnosticSharingPolicy.confirmedDaily(createdAt: now.addingTimeInterval(100), in: state)
        #expect(later.eventsSince == now.addingTimeInterval(100))
        #expect(DiagnosticSharingPolicy.confirmedDaily(createdAt: now, in: later).eventsSince == later.eventsSince)
    }

    @Test("the sharing state reads back from state/")
    func theSharingStateReadsBack() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DiagnosticSharingStateStore(layout: DiagnosticLayout(root: root))
        #expect(store.file.path.hasSuffix("state/automatic-sharing.json"))
        #expect(store.load() == nil)
        let now = DiagnosticDeliveryFixtures.start
        let state = DiagnosticSharingPolicy.noting(
            crash: "a1", since: now, now: now, in: DiagnosticSharingPolicy.started(now: now, random: 0)
        )
        try store.save(state)
        #expect(store.load() == state)
        store.remove()
        #expect(store.load() == nil)
    }

    // MARK: - the crash prompt

    @Test("only a confirmed crash is offered, and only while automatic sharing is off")
    func onlyAConfirmedCrashIsOffered() {
        let crash = ExitClassification(.crash, incident: "ABC-1")
        #expect(DiagnosticCrashRoute.route(crash, sharesAutomatically: false) == .offer(incident: "abc-1"))
        #expect(DiagnosticCrashRoute.route(crash, sharesAutomatically: true) == .share(incident: "abc-1"))
        for other in [ExitClass.clean, .hang, .systemRestart, .uncleanUnknown] {
            #expect(DiagnosticCrashRoute.route(ExitClassification(other), sharesAutomatically: false) == .none)
            #expect(DiagnosticCrashRoute.route(ExitClassification(other), sharesAutomatically: true) == .none)
        }
        #expect(DiagnosticCrashRoute.route(ExitClassification(.crash), sharesAutomatically: false) == .none)
    }

    @Test("each crash incident is offered once, across launches")
    func eachCrashIncidentIsOfferedOnce() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = DiagnosticLayout(root: root)
        let now = DiagnosticDeliveryFixtures.start
        #expect(DiagnosticCrashOffers(layout: layout).claim("Incident-1", now: now))
        #expect(!DiagnosticCrashOffers(layout: layout).claim("incident-1", now: now))
        #expect(DiagnosticCrashOffers(layout: layout).hasOffered("INCIDENT-1"))
        #expect(DiagnosticCrashOffers(layout: layout).claim("incident-2", now: now))
        for index in 0..<60 { _ = DiagnosticCrashOffers(layout: layout).claim("n\(index)", now: now) }
        #expect(DiagnosticCrashOffers(layout: layout).offers().count == DiagnosticCrashOffers.remembered)
    }

    // MARK: - settings

    @Test("a settings file written before automatic sharing existed reads with it off")
    func oldSettingsReadWithSharingOff() throws {
        #expect(AppSettings().sharesDiagnosticsAutomatically == false)
        let old = Data(#"{"version":3,"launchAtLogin":true,"showNotifications":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(decoded.sharesDiagnosticsAutomatically == false)
        #expect(decoded.launchAtLogin)
        let garbled = Data(#"{"version":3,"sharesDiagnosticsAutomatically":"yes"}"#.utf8)
        #expect(try JSONDecoder().decode(AppSettings.self, from: garbled).sharesDiagnosticsAutomatically == false)

        var settings = AppSettings()
        settings.sharesDiagnosticsAutomatically = true
        let roundTrip = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        #expect(roundTrip.sharesDiagnosticsAutomatically)
    }

    // MARK: - helpers

    /// The bytes the system's gzip reads out of `data`.
    static func gunzip(_ data: Data) throws -> Data {
        let gzip = try #require(
            ["/usr/bin/gzip", "/bin/gzip"].first { FileManager.default.isExecutableFile(atPath: $0) }
        )
        let directory = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let input = directory.appendingPathComponent("body.gz")
        try data.write(to: input)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gzip)
        process.arguments = ["-dc", input.path]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return result
    }
}
