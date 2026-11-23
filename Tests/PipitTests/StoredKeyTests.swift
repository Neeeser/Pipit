import Foundation
import PipitBench
import PipitCore
import Testing

/// Files already on disk keep the key names they were written with.
///
/// The properties behind these keys were renamed in code, and their stored
/// keys were kept so that `metadata.json` in existing meeting folders and
/// recorded benchmark results still decode. Each test reads or writes the
/// stored name directly.
@Suite("Stored keys")
struct StoredKeyTests {
    @Test("a cleaned microphone record keeps its stored window count key")
    func aCleanedMicrophoneRecordKeepsItsStoredWindowCountKey() throws {
        let record = CleanedMicrophone(
            track: AudioArchive.Track(
                file: "mic.cleaned.m4a", sampleRate: 16_000, channelCount: 1, frameCount: 16_000,
                seconds: 1, firstFrameHostTime: nil
            ),
            echoRemovedMedianDB: 12, remoteActiveWindows: 37, producedAt: Date(timeIntervalSince1970: 0)
        )
        let data = try JSONEncoder().encode(record)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["farEndActiveWindows"] as? Int == 37)
        #expect(object["remoteActiveWindows"] == nil)
        #expect(try JSONDecoder().decode(CleanedMicrophone.self, from: data) == record)
    }

    @Test("a recorded benchmark results file still decodes its call counts")
    func aRecordedBenchmarkResultsFileStillDecodesItsCallCounts() throws {
        struct Recorded: Decodable {
            var runs: [String: [BenchRow]]
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // PipitTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()
        let url = repository.appendingPathComponent(
            "Benchmarks/results/2026-11-22-engines-and-synthetic-pilot/whisper-runs.json"
        )
        let rows = try JSONDecoder().decode(Recorded.self, from: Data(contentsOf: url)).runs.values.flatMap(\.self)
        let calls = rows.filter { $0.call != nil }
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.remoteWords != nil && $0.remoteNames != nil })
        #expect(calls.contains { $0.score.localTrack?.remoteWords ?? 0 > 0 })
    }
}
