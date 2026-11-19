import AVFoundation
import Foundation
import PipitBench
import PipitCore
import Testing

@testable import PipitAudio

/// The simulated two-track call suite: how a call is imported, how the local
/// person is scored, and what the committed manifest says about the suite.
@Suite("CallBench")
struct CallBenchTests {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PipitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
    }

    private static func writeTone(
        _ url: URL, seconds: Double, frequency: Double, sampleRate: Double = 16_000
    ) throws {
        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
            ]
        )
        try file.write(
            from: AudioFixtures.makeTone(
                seconds: seconds, sampleRate: sampleRate, frequency: frequency
            ))
    }

    // MARK: import

    @Test("a call import writes both tracks into one manifest under the call's source")
    func aCallImportWritesBothTracksIntoOneManifestUnderTheCallsSource() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        // The generator writes both tracks under fixed names in one folder, so
        // the two inputs sit in different folders and share a file name here.
        let micFolder = root.appendingPathComponent("mic", isDirectory: true)
        let farFolder = root.appendingPathComponent("far", isDirectory: true)
        try FileManager.default.createDirectory(at: micFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: farFolder, withIntermediateDirectories: true)
        let microphone = micFolder.appendingPathComponent("track.wav")
        let remote = farFolder.appendingPathComponent("track.wav")
        try Self.writeTone(microphone, seconds: 5, frequency: 440)
        try Self.writeTone(remote, seconds: 4, frequency: 880)

        let repository = MeetingRepository(root: root.appendingPathComponent("archive"))
        let now = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .genericCall, provider: .unknown, startedAt: now, now: now
        )
        let result = try AudioImporter(segmentSeconds: 2).importCall(
            microphone: microphone, remote: remote, source: .genericCall,
            into: created.store, meetingID: created.metadata.id
        )

        #expect(abs(result.microphone.durationSeconds - 5) <= 0.1)
        #expect(abs(result.remote.durationSeconds - 4) <= 0.1)
        let timeline = try created.store.readTimeline()
        #expect(timeline.source == .genericCall)
        #expect(timeline.isComplete)
        #expect(abs(timeline.duration(track: .mic) - 5) <= 0.1)
        #expect(abs(timeline.duration(track: .remote) - 4) <= 0.1)
        #expect(timeline.segments(track: .mic).count == 3)
        #expect(timeline.segments(track: .remote).count == 2)

        // Both tracks began on the same host time, so the pipeline reads them
        // as captured together and the echo pass finds the offset by measuring.
        let run = try #require(timeline.runs.first)
        #expect(abs(try #require(run.referenceOffset)) <= 0.001)

        // Same-named inputs were both kept, and neither was rewritten.
        let originals = try FileManager.default.contentsOfDirectory(
            atPath: created.store.layout.originals.path
        ).sorted()
        #expect(originals == ["remote-track.wav", "track.wav"])
        #expect(
            try Data(contentsOf: created.store.layout.originals.appendingPathComponent("track.wav"))
                == Data(contentsOf: microphone)
        )
        #expect(
            try Data(
                contentsOf: created.store.layout.originals.appendingPathComponent("remote-track.wav")
            ) == Data(contentsOf: remote)
        )
    }

    @Test("a call import with an unreadable far end is recorded as failed")
    func aCallImportWithAnUnreadableFarEndIsRecordedAsFailed() throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let microphone = root.appendingPathComponent("mic.wav")
        let remote = root.appendingPathComponent("remote.wav")
        try Self.writeTone(microphone, seconds: 3, frequency: 440)
        try Data("not audio".utf8).write(to: remote)

        let repository = MeetingRepository(root: root.appendingPathComponent("archive"))
        let now = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .genericCall, provider: .unknown, startedAt: now, now: now
        )
        #expect(throws: ProcessingError.audioUnreadable(path: "remote.wav")) {
            try AudioImporter(segmentSeconds: 2).importCall(
                microphone: microphone, remote: remote, source: .genericCall,
                into: created.store, meetingID: created.metadata.id
            )
        }
        // The near-end segment closed cleanly, so only the session's own end
        // tells a reader the import stopped partway.
        let manifest = try String(contentsOf: created.store.layout.manifest, encoding: .utf8)
        let sessionEnds = manifest.split(separator: "\n").filter { $0.contains("session_end") }
        #expect(sessionEnds.count == 1)
        #expect(sessionEnds.first?.contains("import_failed") == true)
    }

    // MARK: scoring

    /// Two people on a call, one word per second each, in turns: the local
    /// person says "alpha" words and the far end says "bravo" words, so a
    /// transcript can be wrong about whose words are whose.
    private static func callTruth() -> BenchTruth {
        var words: [BenchTruth.Word] = []
        var turns: [BenchTruth.Turn] = []
        for block in 0..<6 {
            let start = Double(block) * 10
            let local = block.isMultiple(of: 2)
            let speaker = local ? "ME" : "THEM"
            let text = local ? "alpha" : "bravo"
            turns.append(.init(speaker: speaker, start: start, end: start + 10))
            for second in 0..<10 {
                words.append(
                    .init(
                        start: start + Double(second), end: start + Double(second) + 0.8,
                        text: text, speaker: speaker, truncated: false))
            }
        }
        return BenchTruth(
            meeting: "CALL", source: "none", windowStart: nil, windowSeconds: 60,
            speakers: ["ME", "THEM"], agentToSpeaker: ["A": "ME", "B": "THEM"],
            words: words, turns: turns
        )
    }

    private static func line(_ start: Double, _ text: String, key: String, words: Int = 10)
        -> BenchUtterance
    {
        BenchUtterance(
            start: start, end: start + Double(words),
            text: Array(repeating: text, count: words).joined(separator: " "), speakerKey: key
        )
    }

    @Test("a transcript that keeps each person's words reports no leaks and no losses")
    func aTranscriptThatKeepsEachPersonsWordsReportsNoLeaksAndNoLosses() {
        let utterances = [
            Self.line(0, "alpha", key: "local"), Self.line(10, "bravo", key: "speaker_1"),
            Self.line(20, "alpha", key: "local"), Self.line(30, "bravo", key: "speaker_1"),
            Self.line(40, "alpha", key: "local"), Self.line(50, "bravo", key: "speaker_1"),
        ]
        let score = BenchScorer.score(
            truth: Self.callTruth(), utterances: utterances,
            localPerson: (speaker: "ME", key: "local")
        )
        let local = score.localTrack
        #expect(local?.farEndWordsUnderLocal == 0)
        #expect(local?.localWordsLost == 0)
        #expect(local?.localWords == 30)
        #expect(local?.farEndWords == 30)
    }

    @Test("the far end's words under the local person's key are counted per minute")
    func theFarEndsWordsUnderTheLocalPersonsKeyAreCountedPerMinute() {
        // The far end's second turn is written under the local key as well.
        let utterances = [
            Self.line(0, "alpha", key: "local"), Self.line(10, "bravo", key: "speaker_1"),
            Self.line(20, "alpha", key: "local"), Self.line(30, "bravo", key: "local"),
            Self.line(40, "alpha", key: "local"), Self.line(50, "bravo", key: "speaker_1"),
        ]
        let local = BenchScorer.localTrack(
            truth: Self.callTruth(), utterances: utterances, localSpeaker: "ME", localKey: "local"
        )
        #expect(local.farEndWordsUnderLocal == 10)
        #expect(local.localWordsLost == 0)
        // 60 seconds is one minute.
        #expect(local.farEndWordsUnderLocalPerMinute == 10)
    }

    @Test("the local person's missing words are counted, and a far-end label does not hide them")
    func theLocalPersonsMissingWordsAreCounted() {
        // The middle block of the local person's speech is absent entirely.
        let missing = [
            Self.line(0, "alpha", key: "local"), Self.line(10, "bravo", key: "speaker_1"),
            Self.line(30, "bravo", key: "speaker_1"), Self.line(40, "alpha", key: "local"),
            Self.line(50, "bravo", key: "speaker_1"),
        ]
        let lost = BenchScorer.localTrack(
            truth: Self.callTruth(), utterances: missing, localSpeaker: "ME", localKey: "local"
        )
        #expect(lost.localWordsLost == 10)
        #expect(lost.localWordsLostPerMinute == 10)
        #expect(lost.farEndWordsUnderLocal == 0)

        // The same words under the other label are not lost, only mislabelled,
        // which the attribution scores charge and this number does not.
        let mislabelled = [
            Self.line(0, "alpha", key: "local"), Self.line(10, "bravo", key: "speaker_1"),
            Self.line(20, "alpha", key: "speaker_1"), Self.line(30, "bravo", key: "speaker_1"),
            Self.line(40, "alpha", key: "local"), Self.line(50, "bravo", key: "speaker_1"),
        ]
        let kept = BenchScorer.localTrack(
            truth: Self.callTruth(), utterances: mislabelled, localSpeaker: "ME", localKey: "local"
        )
        #expect(kept.localWordsLost == 0)
    }

    @Test("a word the local person said too is not a leak")
    func aWordTheLocalPersonSaidTooIsNotALeak() {
        var truth = Self.callTruth()
        // The local person also says "bravo" during the far end's first turn.
        truth.words.append(
            .init(start: 14, end: 14.5, text: "bravo", speaker: "ME", truncated: false))
        // The scorer reads a word only inside a turn of its speaker.
        truth.turns.append(.init(speaker: "ME", start: 14, end: 15))
        let utterances = [
            BenchUtterance(start: 14, end: 14.5, text: "bravo", speakerKey: "local")
        ]
        let local = BenchScorer.localTrack(
            truth: truth, utterances: utterances, localSpeaker: "ME", localKey: "local"
        )
        #expect(local.farEndWordsUnderLocal == 0)
    }

    @Test("a one-track score carries no local-track numbers")
    func aOneTrackScoreCarriesNoLocalTrackNumbers() {
        let score = BenchScorer.score(truth: Self.callTruth(), utterances: [])
        #expect(score.localTrack == nil)
    }

    @Test("a row recorded before calls existed still decodes")
    func aRowRecordedBeforeCallsExistedStillDecodes() throws {
        let score = BenchScorer.score(truth: Self.callTruth(), utterances: [])
        let row = BenchRow(
            engine: "parakeet", diarizer: "local", score: score, processingSeconds: 1,
            audioSeconds: 60, state: "complete", transcriptionModels: [],
            diarizationBackends: [], overlapRatio: nil
        )
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(row)) as? [String: Any]
        )
        object.removeValue(forKey: "call")
        var scoreObject = try #require(object["score"] as? [String: Any])
        scoreObject.removeValue(forKey: "localTrack")
        object["score"] = scoreObject
        let decoded = try JSONDecoder().decode(
            BenchRow.self, from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(decoded.call == nil)
        #expect(decoded.score.localTrack == nil)
    }

    // MARK: description and manifest

    @Test("the generator's case description decodes")
    func theGeneratorsCaseDescriptionDecodes() throws {
        let json = """
            {"case":"EN2002a-laptop","meeting":"EN2002a","variant":"laptop","seed":1,
             "localAgent":"C","localSpeaker":"FEO072","generatorVersion":1,
             "files":{"mic":{"name":"mic.wav","sha256":"aa"},
                      "remote":{"name":"remote.wav","sha256":"bb"}},
             "echo":{"targetCorrelation":0.69,"correlation":0.689,"reachedTarget":true,
                     "gain":2.1}}
            """
        let description = try JSONDecoder().decode(BenchCallCase.self, from: Data(json.utf8))
        #expect(description.localSpeaker == "FEO072")
        #expect(description.files.remote.name == "remote.wav")
        #expect(description.echo.targetCorrelation == 0.69)
    }

    @Test("the simulated meeting-client record reads as the app's own sensor file")
    func theSimulatedMeetingClientRecordReadsAsTheAppsOwnSensorFile() throws {
        // The shape `Benchmarks/calls/callsim.py` writes for a Meet call.
        let json = """
            {"version":1,"source":"google_meet-dom","selfIsAuthoritative":false,
             "participants":[{"id":"spaces/sim/devices/1","displayName":"You","isSelf":true},
                             {"id":"spaces/sim/devices/2","displayName":"SPK_B","isSelf":false}],
             "turns":[{"start":9.5,"end":16.0,"participantID":"spaces/sim/devices/2"}],
             "unmutedIDs":["spaces/sim/devices/2"]}
            """
        let sensors = try ArchiveCoding.decode(RawSensors.self, from: Data(json.utf8), path: "sensors.raw.json")
        #expect(sensors.source == "google_meet-dom")
        #expect(sensors.participants.filter(\.isSelf).count == 1)
        #expect(sensors.turns.count == 1)
        #expect(sensors.unmutedIDs == ["spaces/sim/devices/2"])

        let description = """
            {"case":"X-laptop-meet","meeting":"X","variant":"laptop-meet","localAgent":"A",
             "localSpeaker":"S","files":{"mic":{"name":"mic.wav","sha256":"a"},
             "remote":{"name":"remote.wav","sha256":"b"},
             "sensors":{"name":"sensors.raw.json","sha256":"c"}},
             "echo":{"targetCorrelation":0.69,"correlation":0.69,"reachedTarget":true}}
            """
        let call = try JSONDecoder().decode(BenchCallCase.self, from: Data(description.utf8))
        #expect(call.files.sensors?.name == "sensors.raw.json")
    }

    @Test("the committed calls suite is built from held-out meetings and complete channels")
    func theCommittedCallsSuiteIsBuiltFromHeldOutMeetingsAndCompleteChannels() throws {
        let layout = BenchLayout(root: Self.repositoryRoot.appendingPathComponent("Benchmarks"))
        let manifest = try BenchManifest.read(from: layout.manifest)
        let calls = try #require(manifest.calls)
        let partition = try #require(manifest.partition)
        #expect(!calls.meetings.isEmpty)
        #expect(calls.variants.map(\.name).contains("headphones"))
        #expect(calls.variants.filter { $0.echoCorrelation != nil }.count >= 1)
        #expect(calls.variants.contains { $0.sensors != nil })
        for (meeting, entry) in calls.meetings {
            // Candidate models trained on AMI's train and dev meetings, so a
            // suite that ranks them may not read those.
            let held = partition[meeting] ?? "missing"
            #expect(held == "ami-eval" || held == "clean", "\(meeting) is \(held)")
            let truth = try BenchTruth.read(from: layout.truth(meeting: meeting))
            #expect(Set(entry.channels.keys) == Set(truth.agentToSpeaker.keys), "\(meeting)")
            #expect(entry.channels[entry.localAgent] != nil, "\(meeting): local agent has no channel")
            #expect(
                Set(entry.channels.values.map(\.channel)).count == entry.channels.count,
                "\(meeting) shares a channel between two people"
            )
            for channel in entry.channels.values {
                #expect(channel.sha256.count == 64)
            }
        }
        let names = calls.caseNames
        #expect(names.count == calls.meetings.count * calls.variants.count)
        #expect(Set(names).count == names.count)
        for name in names {
            let parsed = try #require(calls.parse(case: name), "\(name) does not parse")
            #expect(name == "\(parsed.meeting)-\(parsed.variant.name)")
        }
        #expect(calls.parse(case: "EN2002a") == nil)
        #expect(calls.parse(case: "nothing-laptop") == nil)
    }
}
