import AppKit
import Foundation
import PipitAudio
import PipitCore
import PipitIntegrations
import Testing

@testable import PipitDetection
@testable import PipitServices
@testable import PipitUI

/// The places that record diagnostic events, checked against what must never
/// reach the event log: anything said, typed or named in or around a meeting.
@Suite("DiagnosticsInstrumentation", .serialized)
struct DiagnosticsInstrumentationTests {
    /// Every string a meeting, the settings or a device brought in. Each is
    /// distinctive enough that finding it in a file can only mean it leaked.
    static let canaries = [
        "CanaryTitleQx7", "CanaryPersonZv3", "CanaryWordsKp9", "CanaryNotesHb2", "CanaryUserJw4",
        "CanaryHintMm8", "canary-endpoint-rt5", "sk-canaryKeyYy6", "CanaryPathLd1", "CanaryMicrophoneFn5",
    ]

    @Test("no meeting content, setting, path or device name reaches the diagnostics folder")
    func noMeetingContentReachesTheDiagnosticsFolder() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let archive = base.appendingPathComponent("CanaryPathLd1 Meetings", isDirectory: true)
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        let diagnostics = DiagnosticLog(layout: DiagnosticLayout(root: logs), freeSpace: { _ in .max })

        // A recording, armed and committed by the capture engine on a
        // microphone named the way people name theirs.
        let microphone = FakeMicrophoneEngine()
        microphone.setDevice(name: "CanaryMicrophoneFn5's microphone", transport: .usb)
        microphone.setDeviceUID("CanaryMicrophoneFn5-uid")
        let tap = FakeProcessTap()
        tap.setTargets([
            RemoteAudioTarget(
                audioObjectID: 7, processID: 42, bundleIdentifier: "com.example.CanaryTitleQx7",
                isRunningOutput: true
            )
        ])
        let engine = CaptureEngine(
            segmentSeconds: 60,
            makeMicrophone: { _, _ in microphone },
            makeTap: { _, _ in tap },
            diagnostics: diagnostics,
            delegate: QuietCaptureDelegate()
        )
        let session = DiagnosticSessionID()
        let recording = MeetingLayout(root: archive.appendingPathComponent("CanaryTitleQx7 recording"))
        try FileManager.default.createDirectory(at: recording.segments, withIntermediateDirectories: true)
        await engine.arm(scope: .bundlePrefixes(["com.example.CanaryTitleQx7"]), capturesRemote: true, session: session)
        try await engine.commit(layout: recording, meetingID: "CanaryTitleQx7-meeting", source: .googleMeet)
        _ = await engine.stop(reason: "test")
        #expect(try ManifestReader.timeline(contentsOf: recording.manifest).diagnosticSession == session)

        // A meeting processed end to end, with a retried failure that carries
        // the meeting's words in its reason.
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: archive)
        _ = try meeting.store.updateMetadata { $0.titles.human = "CanaryTitleQx7 planning" }
        try meeting.store.writeNotes("CanaryNotesHb2: follow up with CanaryPersonZv3")
        let backend = FakeAIBackend()
        backend.transcriptionSegments = [
            RawTranscriptSegment(start: 0, end: 2, text: "CanaryWordsKp9 from the microphone.", speaker: nil)
        ]
        backend.diarizationSegments = [
            RawTranscriptSegment(start: 0, end: 2, text: "CanaryPersonZv3 here, CanaryWordsKp9.", speaker: "A")
        ]
        backend.suggestions = [
            SpeakerSuggestion(
                label: "remote_chunk_001_speaker_00", name: "CanaryPersonZv3",
                confidence: 0.98, quote: "CanaryPersonZv3 here", atSeconds: 0
            )
        ]
        backend.enrichment = MeetingEnrichment(title: "CanaryTitleQx7", summary: "CanaryWordsKp9 discussed.")
        backend.failNextTranscription = .transport(reason: "CanaryWordsKp9 sk-canaryKeyYy6 canary-endpoint-rt5")
        var settings = AppSettings()
        settings.storageRootPath = archive.path
        settings.localUserName = "CanaryUserJw4"
        settings.models.vocabularyHints = "CanaryHintMm8, CanaryPersonZv3"
        settings.models.customEndpoint = "https://canary-endpoint-rt5.example.invalid/v1"
        let pipeline = ProcessingPipeline(
            repository: meeting.repository,
            backend: backend,
            clock: ManualClock(),
            diagnostics: diagnostics,
            settingsProvider: { [settings] in settings },
            wait: { _ in }
        )
        await pipeline.process(meetingID: meeting.metadata.id)
        // Enrichment titles the meeting, which renames its folder, so it is
        // found again by identifier rather than through the old store.
        #expect(meeting.repository.findMeeting(id: meeting.metadata.id)?.metadata.processing.state == .complete)

        // Errors whose own words carry a path, an address and a key.
        let described = NSError(
            domain: "NSCocoaErrorDomain", code: 4,
            userInfo: [
                NSFilePathErrorKey: archive.path,
                NSLocalizedDescriptionKey: "CanaryTitleQx7 at https://canary-endpoint-rt5.example.invalid",
            ]
        )
        diagnostics.record(
            .processingStageFailed(
                stage: .enriching, attempt: 1, code: DiagnosticCode(describing: described), retryable: false
            ))
        diagnostics.record(
            .processingStageFailed(
                stage: .transcribing, attempt: 1,
                code: DiagnosticCode(describing: ProcessingError.audioUnreadable(path: "CanaryTitleQx7.m4a")),
                retryable: false
            ))
        diagnostics.record(
            .captureWarning(code: .word(CaptureWarning.storageUnavailable(path: archive.path).dedupKey))
        )
        diagnostics.record(
            .browserAddonConnected(
                browser: .firefox, addonVersion: .version("CanaryTitleQx7"), hostVersion: .version("sk-canaryKeyYy6 1"),
                protocolVersion: 1
            ))
        #expect(diagnostics.flush())

        let contents = try Self.everyFile(under: logs)
        #expect(!contents.isEmpty)
        let lowercased = contents.lowercased()
        for canary in Self.canaries {
            #expect(!lowercased.contains(canary.lowercased()), "\(canary) reached the diagnostics folder")
        }
        // The run was recorded, so the check above looked at something.
        for kind in [
            "capture.bound", "session", "processing.stage_started", "processing.stage_failed",
            "processing.stage_finished",
        ] {
            #expect(contents.contains(kind), "\(kind) was not recorded")
        }
        #expect(contents.contains(#""transport":"usb""#))
        #expect(contents.contains(#""code":"processing.transport""#))
    }

    @Test("a processing attempt carries its recording's session and a job of its own")
    func aProcessingAttemptCarriesItsSessionAndJob() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        let diagnostics = DiagnosticLog(layout: DiagnosticLayout(root: logs), freeSpace: { _ in .max })
        let meeting = try PipelineFixtures.makeRecordedMeeting(root: base.appendingPathComponent("Meetings"))
        let session = DiagnosticSessionID()
        // The fixture writes a manifest without a session; this one carries it.
        let manifest = try ManifestWriter(url: meeting.store.layout.manifest)
        manifest.append(
            .sessionStart(
                .init(
                    meetingID: meeting.metadata.id, source: .googleMeet, segmentSeconds: 30, appVersion: "test",
                    processID: 1, diagnosticSession: session.description
                )))
        manifest.close()

        let backend = FakeAIBackend()
        backend.alwaysFailTranscription = .serverError(status: 503)
        let pipeline = ProcessingPipeline(
            repository: meeting.repository, backend: backend, clock: ManualClock(), diagnostics: diagnostics,
            settingsProvider: { AppSettings() }, wait: { _ in }
        )
        await pipeline.process(meetingID: meeting.metadata.id)
        #expect(diagnostics.flush())

        let events = try Self.events(under: logs)
        let failures = events.filter {
            if case .processingStageFailed(.transcribing, _, let code, true) = $0.kind {
                return code.rawValue == "processing.server_error.503"
            }
            return false
        }
        #expect(failures.count == 3)
        #expect(failures.allSatisfy { $0.session == session })
        #expect(Set(failures.compactMap(\.job)).count == 3, "each attempt has its own job")
        let attempts = failures.compactMap { event -> Int? in
            if case .processingStageFailed(_, let attempt, _, _) = event.kind { return attempt }
            return nil
        }
        #expect(attempts == [1, 2, 3])
    }

    @Test("a manifest written before diagnostics still decodes, with no session")
    func aManifestWrittenBeforeDiagnosticsStillDecodes() throws {
        // One line, as a manifest holds it. A raw string keeps the quotes
        // readable; its `\` is literal, so the line is joined rather than
        // continued.
        let line =
            #"{"ev":"session_start","host":1,"t":"2026-08-18T18:00:00.000Z","meetingID":"m","source":"manual","#
            + #""segmentSeconds":30,"appVersion":"1.0.0","processID":1}"#
        let decoded = try ManifestCoding.makeDecoder().decode(ManifestLine.self, from: Data(line.utf8))
        guard case .sessionStart(let start) = decoded.event else {
            Issue.record("not a session start")
            return
        }
        #expect(start.diagnosticSession == nil)
        #expect(
            ManifestReader.timeline(
                from: ManifestReadResult(lines: [decoded], hasTruncatedTail: false, unrecognisedLines: 0)
            )
            .diagnosticSession == nil)
    }

    @Test("a new manifest carries its session, and an old reader's shape is unchanged without one")
    func aNewManifestCarriesItsSession() throws {
        let session = DiagnosticSessionID()
        let encoder = ManifestCoding.makeEncoder()
        let with = ManifestLine(
            hostTime: 1, wallClock: Date(timeIntervalSince1970: 1_787_076_000),
            event: .sessionStart(
                .init(
                    meetingID: "m", source: .manual, segmentSeconds: 30, appVersion: "1", processID: 1,
                    diagnosticSession: session.description
                ))
        )
        let text = String(decoding: try encoder.encode(with), as: UTF8.self)
        #expect(text.contains(#""diagnosticSession":"\#(session.description)""#))
        let decoded = try ManifestCoding.makeDecoder().decode(ManifestLine.self, from: Data(text.utf8))
        #expect(decoded == with)

        let without = ManifestLine(
            hostTime: 1, wallClock: Date(timeIntervalSince1970: 1_787_076_000),
            event: .sessionStart(
                .init(meetingID: "m", source: .manual, segmentSeconds: 30, appVersion: "1", processID: 1)
            )
        )
        #expect(!String(decoding: try encoder.encode(without), as: UTF8.self).contains("diagnosticSession"))
    }

    @Test("a peer that is not Pipit's relay is recorded as rejected")
    func aPeerThatIsNotPipitsRelayIsRecordedAsRejected() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        let diagnostics = DiagnosticLog(layout: DiagnosticLayout(root: logs), freeSpace: { _ in .max })
        let socket = base.appendingPathComponent("s")
        let server = BrowserSensorServer(
            socketURL: socket,
            verifier: SensorPeerVerifier(allowedHostPaths: [], requiresBrowserParent: false),
            diagnostics: diagnostics,
            onMessage: { _ in }
        )
        try server.start()
        defer { server.stop() }
        let client = SensorAppConnection(socketPath: socket.path)
        _ = client.connect()
        defer { client.disconnect() }

        let deadline = ContinuousClock.now + .seconds(2)
        var rejected = false
        while !rejected, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            diagnostics.flush()
            rejected = try Self.events(under: logs).contains {
                $0.kind == .browserConnectionRejected(browser: nil, reason: .peerVerification)
            }
        }
        #expect(rejected)
    }

    @Test("detection evidence maps to the contract's kinds")
    func detectionEvidenceMapsToTheContractsKinds() {
        func evidence(_ provider: MeetingProvider, _ source: EvidenceSource, browser: BrowserKind? = nil)
            -> DiagnosticEvent.Evidence?
        {
            DetectionEngine.diagnosticEvidence(
                for: ProviderEvidence(provider: provider, confidence: .confirmed, source: source, browser: browser)
            )
        }
        #expect(evidence(.googleMeet, .browserSensor, browser: .safari) == .browserAddon)
        #expect(evidence(.slack, .accessibility) == .slack)
        #expect(evidence(.zoom, .accessibility) == .accessibility)
        #expect(evidence(.googleMeet, .native, browser: .chrome) == .windowTitle)
        #expect(evidence(.unknown, .native) == .processAudio)
        #expect(evidence(.unknown, .manual) == nil)
    }

    @Test("a session's start and stop are read from its source and its reason")
    func aSessionsTriggersAreReadFromItsSourceAndReason() {
        #expect(PipitRuntime.startTrigger(for: .googleMeet) == .auto)
        #expect(PipitRuntime.startTrigger(for: .inPerson) == .manual)
        #expect(PipitRuntime.startTrigger(for: .imported) == .imported)
        #expect(PipitRuntime.stopTrigger(for: "user_stopped") == .manual)
        #expect(PipitRuntime.stopTrigger(for: "app_quit") == .quit)
        #expect(PipitRuntime.stopTrigger(for: "commit_failed") == .error)
        #expect(PipitRuntime.stopTrigger(for: "provider_ended") == .auto)
    }

    @Test("a permission is recorded when it changes, not on every probe")
    @MainActor
    func aPermissionIsRecordedWhenItChanges() async throws {
        let base = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let logs = base.appendingPathComponent("Logs", isDirectory: true)
        let diagnostics = DiagnosticLog(layout: DiagnosticLayout(root: logs), freeSpace: { _ in .max })
        let runtime = PipitRuntime(settingsDirectory: base, diagnostics: diagnostics)
        runtime.permissionsDidChange([PermissionStatus(kind: .screenRecording, state: .denied)])
        runtime.permissionsDidChange([PermissionStatus(kind: .screenRecording, state: .denied)])
        runtime.permissionsDidChange([PermissionStatus(kind: .screenRecording, state: .granted)])
        #expect(diagnostics.flush())
        let kinds = try Self.events(under: logs).map(\.kind)
        #expect(
            kinds == [
                .permissionState(permission: .systemAudio, state: .denied),
                .permissionState(permission: .systemAudio, state: .granted),
            ])
    }

    @Test("the Diagnostics page builds with no log and with one")
    @MainActor
    func theDiagnosticsPageBuilds() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let logs = DiagnosticLog(layout: DiagnosticLayout(root: root.appendingPathComponent("Logs")))
        for log in [DiagnosticLog.disabled, logs] {
            let runtime = PipitRuntime(settingsDirectory: root, diagnostics: log)
            let model = SettingsModel(runtime: runtime, storedKeyLookup: { _ in false })
            ViewFixtures.render(DiagnosticsSettingsPane(model: model))
        }
    }

    // MARK: - helpers

    /// Every file under the folder, read as text and joined.
    static func everyFile(under root: URL) throws -> String {
        let fileManager = FileManager.default
        guard let walker = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) else { return "" }
        var text = ""
        for case let url as URL in walker {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue
            else { continue }
            text += url.lastPathComponent + "\n"
            text += String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        return text
    }

    static func events(under root: URL) throws -> [DiagnosticEvent] {
        let events = DiagnosticLayout(root: root).events
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: events.path)) ?? []).sorted()
        return try names.flatMap { name in
            DiagnosticEventCoding.events(in: try Data(contentsOf: events.appendingPathComponent(name)))
        }
    }
}

private final class QuietCaptureDelegate: CaptureEngineDelegate, @unchecked Sendable {
    func captureEngineDidUpdateHealth(_ snapshot: CaptureHealthSnapshot) {}
    func captureEngineDidRaiseWarning(_ warning: CaptureWarning) {}
}
