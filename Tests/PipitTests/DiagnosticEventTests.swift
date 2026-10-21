import Foundation
import PipitCore
import Testing

/// The event line against `docs/DIAGNOSTICS.md`. Each kind is encoded and
/// compared with the JSON the contract describes, so a payload key that
/// drifts from the table fails here before a report reaches the server.
@Suite("DiagnosticEvent")
struct DiagnosticEventTests {
    static let launch = DiagnosticLaunchID(string: "9F1C2A4E-0000-4000-8000-000000000001")!
    static let session = DiagnosticSessionID(string: "9F1C2A4E-0000-4000-8000-000000000002")!
    static let job = DiagnosticJobID(string: "9F1C2A4E-0000-4000-8000-000000000003")!
    /// 2026-10-21T03:18:16.125Z.
    static let time = Date(timeIntervalSince1970: 1_792_552_696.125)

    /// One instance of every kind, and the payload the contract gives it.
    static let samples: [(DiagnosticEvent.Kind, String)] = [
        (
            .appLaunched(
                DiagnosticEvent.AppLaunch(
                    version: "0.1.8", build: "812", commit: String(repeating: "a1", count: 20),
                    os: "15.6.1", osBuild: "24G90", hardware: "Mac15,3", arch: .appleSilicon
                )),
            """
            {"version":"0.1.8","build":"812","commit":"\(String(repeating: "a1", count: 20))","os":"15.6.1",\
            "osBuild":"24G90","hardware":"Mac15,3","arch":"arm64"}
            """
        ),
        (.appTerminated, "{}"),
        (
            .appPreviousExit(exitClass: .uncleanUnknown, previousLaunch: launch),
            #"{"class":"unclean_unknown","previousLaunch":"9F1C2A4E-0000-4000-8000-000000000001"}"#
        ),
        (
            .permissionState(permission: .systemAudio, state: .notDetermined),
            #"{"permission":"system_audio","state":"not_determined"}"#
        ),
        (
            .detectionMeeting(source: .googleMeet, evidence: .browserAddon, browser: .safari),
            #"{"source":"google_meet","evidence":"browser_addon","browser":"safari"}"#
        ),
        (
            .detectionMeeting(source: .slackHuddle, evidence: .slack, browser: nil),
            #"{"source":"slack_huddle","evidence":"slack"}"#
        ),
        (
            .sessionStarted(source: .zoom, trigger: .imported, segmentSeconds: 30),
            #"{"source":"zoom","trigger":"import","segmentSeconds":30}"#
        ),
        (
            .sessionStopped(trigger: .quit, seconds: 1_834.5, segments: 124),
            #"{"trigger":"quit","seconds":1834.5,"segments":124}"#
        ),
        (
            .captureBound(track: .mic, transport: .bluetooth, sampleRate: 24_000, channels: 1, targets: nil),
            #"{"track":"mic","transport":"bluetooth","sampleRate":24000,"channels":1}"#
        ),
        (
            .captureBound(track: .remote, transport: .aggregate, sampleRate: 48_000, channels: 2, targets: 3),
            #"{"track":"remote","transport":"aggregate","sampleRate":48000,"channels":2,"targets":3}"#
        ),
        (
            .captureRestarted(track: .mic, reason: .watchdog, count: 2),
            #"{"track":"mic","reason":"watchdog","count":2}"#
        ),
        (
            .captureHealth(track: .remote, state: .idleButBound),
            #"{"track":"remote","state":"idle_but_bound"}"#
        ),
        (.captureWarning(code: .word("rebuild_loop")), #"{"code":"rebuild_loop"}"#),
        (
            .processingStageStarted(stage: .resolvingSpeakers, attempt: 1),
            #"{"stage":"resolving_speakers","attempt":1}"#
        ),
        (
            .processingStageFinished(stage: .diarizing, attempt: 2, seconds: 12.3456),
            #"{"stage":"diarizing","attempt":2,"seconds":12.346}"#
        ),
        (
            .processingStageFailed(
                stage: .transcribing, attempt: 2, code: ProcessingError.rateLimited(retryAfter: 4).diagnosticCode,
                retryable: true
            ),
            #"{"stage":"transcribing","attempt":2,"code":"processing.rate_limited","retryable":true}"#
        ),
        (.modelInstallStarted(unit: .voiceActivity), #"{"unit":"voice-activity"}"#),
        (
            .modelInstallFinished(unit: .ctcAligner, bytes: 1_234_567_890, seconds: 61),
            #"{"unit":"ctc-aligner","bytes":1234567890,"seconds":61}"#
        ),
        (
            .modelInstallFailed(unit: .parakeet, code: DiagnosticCode("model", "install", detail: "disk_full")),
            #"{"unit":"parakeet","code":"model.install.disk_full"}"#
        ),
        (.updateChecked(outcome: .upToDate, code: nil), #"{"outcome":"up_to_date"}"#),
        (
            .updateChecked(outcome: .failed, code: .error(domain: "SUSparkleErrorDomain", code: 2001)),
            #"{"outcome":"failed","code":"error.SUSparkleErrorDomain.2001"}"#
        ),
        (
            .browserAddonConnected(
                browser: .firefox, addonVersion: .version("1.4.0"), hostVersion: .version("1.2.0"),
                protocolVersion: 3
            ),
            #"{"browser":"firefox","addonVersion":"1.4.0","hostVersion":"1.2.0","protocol":3}"#
        ),
        (
            .browserAddonDisconnected(browser: .safari, reason: .silence),
            #"{"browser":"safari","reason":"silence"}"#
        ),
        (
            .browserConnectionRejected(browser: nil, reason: .peerVerification),
            #"{"reason":"peer_verification"}"#
        ),
        (
            .browserConnectionRejected(browser: .chrome, reason: .protocolViolation),
            #"{"browser":"chrome","reason":"protocol"}"#
        ),
        (.browserMessageUnparsable(browser: .unknown), #"{"browser":"unknown"}"#),
        (.nativeHostStarted(browser: .chrome), #"{"browser":"chrome"}"#),
        (
            .nativeHostAppUnreachable(code: DiagnosticCode("nativehost", "connect", number: 2)),
            #"{"code":"nativehost.connect.2"}"#
        ),
        (.nativeHostExited(reason: .browserClosed, relayed: 41), #"{"reason":"browser_closed","relayed":41}"#),
        (.diagnosticsDropped(count: 7), #"{"count":7}"#),
        (
            .reportSent(kind: .automatic, bytes: 20_480, outcome: .accepted, status: 201),
            #"{"kind":"automatic","bytes":20480,"outcome":"accepted","status":201}"#
        ),
    ]

    @Test("every kind encodes the payload the contract lists")
    func everyKindEncodesThePayloadTheContractLists() throws {
        let encoder = DiagnosticCoding.makeEncoder()
        for (kind, payload) in Self.samples {
            let event = DiagnosticEvent(time: Self.time, launch: Self.launch, kind: kind)
            let line = try Self.object(encoder.encode(event))
            #expect(line["kind"] as? String == kind.name)
            let encoded = try Self.normalized(JSONSerialization.data(withJSONObject: line["p"] ?? [:]))
            #expect(encoded == (try Self.normalized(Data(payload.utf8))), "\(kind.name)")
        }
    }

    @Test("the samples cover every kind in the contract's table")
    func theSamplesCoverEveryKindInTheContractsTable() throws {
        let contract = try String(contentsOf: Self.contractURL, encoding: .utf8)
        // Rows of the kinds table: "| `kind.name` | payload |".
        let rows = contract.components(separatedBy: "### Kinds")[1].components(separatedBy: "\n## ")[0]
        let named = rows.split(separator: "\n").compactMap { row -> String? in
            guard row.hasPrefix("| `") else { return nil }
            return row.dropFirst(3).split(separator: "`").first.map(String.init)
        }
        #expect(Set(named) == Set(Self.samples.map(\.0.name)))
        #expect(named.count == 27)
    }

    @Test("a whole line carries the contract's keys")
    func aWholeLineCarriesTheContractsKeys() throws {
        let event = DiagnosticEvent(
            time: Self.time, launch: Self.launch, session: Self.session, job: Self.job,
            kind: .processingStageFailed(
                stage: .transcribing, attempt: 2, code: ProcessingError.rateLimited(retryAfter: nil).diagnosticCode,
                retryable: true
            ),
            count: 3
        )
        let line = try #require(DiagnosticCoding.line(event, encoder: DiagnosticCoding.makeEncoder()))
        #expect(line.last == 0x0A)
        let expected = """
            {"v":1,"t":"2026-10-21T03:18:16.125Z","launch":"9F1C2A4E-0000-4000-8000-000000000001",\
            "session":"9F1C2A4E-0000-4000-8000-000000000002","job":"9F1C2A4E-0000-4000-8000-000000000003",\
            "kind":"processing.stage_failed","p":{"stage":"transcribing","attempt":2,\
            "code":"processing.rate_limited","retryable":true},"n":3}
            """
        #expect(try Self.normalized(line.dropLast()) == (try Self.normalized(Data(expected.utf8))))
    }

    @Test("a single event carries no n, session or job")
    func aSingleEventCarriesNoCountSessionOrJob() throws {
        let event = DiagnosticEvent(time: Self.time, launch: Self.launch, kind: .appTerminated)
        let line = try Self.object(DiagnosticCoding.makeEncoder().encode(event))
        #expect(Set(line.keys) == ["v", "t", "launch", "kind", "p"])
    }

    @Test("every kind decodes back to itself")
    func everyKindDecodesBackToItself() throws {
        let encoder = DiagnosticCoding.makeEncoder()
        let decoder = DiagnosticCoding.makeDecoder()
        for (kind, _) in Self.samples {
            let event = DiagnosticEvent(
                time: Self.time, launch: Self.launch, session: Self.session, job: Self.job, kind: kind, count: 2
            )
            let decoded = try decoder.decode(DiagnosticEvent.self, from: encoder.encode(event))
            // Doubles are kept to the millisecond, which the one sample with
            // more digits than that loses.
            if case .processingStageFinished(let stage, let attempt, _) = kind {
                #expect(decoded.kind == .processingStageFinished(stage: stage, attempt: attempt, seconds: 12.346))
            } else {
                #expect(decoded == event, "\(kind.name)")
            }
        }
    }

    @Test("a line from a newer schema, a kind this build lacks, or a cut-off tail is skipped")
    func linesThisBuildCannotReadAreSkipped() throws {
        let encoder = DiagnosticCoding.makeEncoder()
        let good = try #require(
            DiagnosticCoding.line(
                DiagnosticEvent(time: Self.time, launch: Self.launch, kind: .appTerminated), encoder: encoder
            ))
        var data = good
        data.append(Data(#"{"v":2,"t":"2026-10-21T03:18:16.123Z","launch":"x","kind":"app.terminated","p":{}}"#.utf8))
        data.append(0x0A)
        let launch = Self.launch.description
        data.append(
            Data(#"{"v":1,"t":"2026-10-21T03:18:16.123Z","launch":"\#(launch)","kind":"app.future","p":{}}"#.utf8)
        )
        data.append(0x0A)
        data.append(good)
        data.append(good.prefix(20))
        #expect(DiagnosticCoding.events(in: data).count == 2)
    }

    @Test("non-finite and over-precise doubles are written as finite milliseconds")
    func doublesAreWrittenAsFiniteMilliseconds() throws {
        let event = DiagnosticEvent(
            time: Self.time, launch: Self.launch,
            kind: .sessionStopped(trigger: .auto, seconds: .infinity, segments: 0)
        )
        let line = try Self.object(DiagnosticCoding.makeEncoder().encode(event))
        let payload = try #require(line["p"] as? [String: Any])
        #expect((payload["seconds"] as? NSNumber)?.doubleValue == 0)
    }

    // MARK: - patterns

    @Test("a version from outside Pipit passes its pattern or reads invalid")
    func versionsAreCheckedAgainstTheirPattern() {
        #expect(DiagnosticToken.version("1.4.0-beta.2+7").value == "1.4.0-beta.2+7")
        #expect(DiagnosticToken.version("0.1.0-dev.4f2a9c1").value == "0.1.0-dev.4f2a9c1")
        #expect(DiagnosticToken.version(nil) == .unknown)
        #expect(DiagnosticToken.version("").value == "invalid")
        #expect(DiagnosticToken.version("1.0 Sample Person").value == "invalid")
        #expect(DiagnosticToken.version("https://example.invalid/x").value == "invalid")
        #expect(DiagnosticToken.version(String(repeating: "1", count: 33)).value == "invalid")
        #expect(DiagnosticToken.hardware("Mac15,3").value == "Mac15,3")
        #expect(DiagnosticToken.hardware("Sample's Mac").value == "invalid")
        #expect(DiagnosticToken.commit("unknown") == .unknown)
        #expect(DiagnosticToken.commit("ABCDEF0").value == "invalid")
        #expect(DiagnosticToken.word("segment_write_failed_mic").value == "segment_write_failed_mic")
        #expect(DiagnosticToken.word("Weekly sync").value == "invalid")
    }

    @Test("a decoded token is checked again")
    func aDecodedTokenIsCheckedAgain() throws {
        let launch = Self.launch.description
        let line = """
            {"v":1,"t":"2026-10-21T03:18:16.123Z","launch":"\(launch)","kind":"browser.addon_connected",\
            "p":{"browser":"firefox","addonVersion":"Sample Person","hostVersion":"1.2.0"}}
            """
        let event = try DiagnosticCoding.makeDecoder().decode(DiagnosticEvent.self, from: Data(line.utf8))
        #expect(
            event.kind
                == .browserAddonConnected(
                    browser: .firefox, addonVersion: .invalid, hostVersion: .version("1.2.0"), protocolVersion: nil
                ))
    }

    @Test("an identifier that is not a UUID is refused")
    func anIdentifierThatIsNotAUUIDIsRefused() {
        #expect(DiagnosticSessionID(string: "weekly-sync-2026-10-21") == nil)
        #expect(DiagnosticSessionID(string: Self.session.description) == Self.session)
    }

    @Test("a transport is read from CoreAudio's four-character code")
    func aTransportIsReadFromCoreAudiosCode() {
        func code(_ text: String) -> UInt32 { text.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: code("bltn")) == .builtIn)
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: code("usb ")) == .usb)
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: code("blea")) == .bluetooth)
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: code("fgrp")) == .aggregate)
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: code("virt")) == .virtual)
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: code("hdmi")) == .other)
        #expect(DiagnosticEvent.Transport(coreAudioTransportType: 0) == .other)
    }

    // MARK: - codes

    @Test("processing errors map to codes without their payloads")
    func processingErrorsMapToCodes() {
        #expect(ProcessingError.serverError(status: 503).diagnosticCode.rawValue == "processing.server_error.503")
        #expect(
            ProcessingError.audioUnreadable(path: "Weekly sync.m4a").diagnosticCode.rawValue
                == "processing.audio_unreadable")
        #expect(
            ProcessingError.malformedResponse(reason: "Sample Person said").diagnosticCode.rawValue
                == "processing.malformed_response")
        #expect(
            ProcessingError.languageModel(provider: "http://192.0.2.1:11434", failure: .modelNotFound)
                .diagnosticCode.rawValue == "language_model.model_not_found"
        )
        #expect(LanguageModelFailure.rejected(status: 422).diagnosticCode.rawValue == "language_model.rejected.422")
        #expect(
            CaptureError.processTapCreationFailed(status: -50).diagnosticCode.rawValue
                == "capture.process_tap_creation_failed.-50"
        )
        #expect(
            StorageError.fileWriteFailed(path: "/Users/sample/Weekly sync", underlying: "x").diagnosticCode.rawValue
                == "storage.file_write_failed"
        )
        #expect(DiagnosticCode(describing: CancellationError()).rawValue == "processing.cancelled")
    }

    @Test("an unmapped error is named by its domain and code")
    func anUnmappedErrorIsNamedByItsDomainAndCode() {
        let network = NSError(
            domain: "NSURLErrorDomain", code: -1_009,
            userInfo: [NSLocalizedDescriptionKey: "Could not load https://example.invalid/sample-person"]
        )
        #expect(DiagnosticCode(describing: network).rawValue == "net.NSURLErrorDomain.-1009")
        #expect(
            DiagnosticCode(describing: NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_868)).rawValue
                == "error.com.apple.coreaudio.avfaudio.-10868")
        #expect(DiagnosticCode(describing: NSError(domain: "Weekly sync/notes", code: 1)).rawValue == "error.other.1")
        let long = String(repeating: "a", count: 64)
        #expect(DiagnosticCode(describing: NSError(domain: long, code: 1)).rawValue == "error.other.1")
    }

    @Test("a code built from bad parts reads invalid")
    func aCodeBuiltFromBadPartsReadsInvalid() {
        #expect(DiagnosticCode("model", "install", detail: "disk_full").rawValue == "model.install.disk_full")
        #expect(DiagnosticCode("Model", "install") == .invalid)
        #expect(DiagnosticCode("model", "install", detail: "a b") == .invalid)
        #expect(DiagnosticCode(checked: "processing.rate_limited").rawValue == "processing.rate_limited")
        #expect(DiagnosticCode(checked: "Sample Person") == .invalid)
        #expect(DiagnosticCode(checked: "processing") == .invalid)
    }

    @Test("an install failure names the network and a full disk")
    func anInstallFailureNamesTheNetworkAndAFullDisk() {
        #expect(
            DiagnosticCode.modelInstall(NSError(domain: "NSURLErrorDomain", code: -1_001)).rawValue
                == "model.install.network")
        let full = NSError(
            domain: "NSCocoaErrorDomain", code: 4,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: "NSPOSIXErrorDomain", code: 28)]
        )
        #expect(DiagnosticCode.modelInstall(full).rawValue == "model.install.disk_full")
        #expect(DiagnosticCode.modelInstall(CancellationError()).rawValue == "model.install.cancelled")
    }

    // MARK: - helpers

    static var contractURL: URL {
        URL(fileURLWithPath: #filePath).resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/DIAGNOSTICS.md")
    }

    static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The same JSON however its keys were ordered.
    static func normalized(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let sorted = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: sorted, as: UTF8.self)
    }
}
