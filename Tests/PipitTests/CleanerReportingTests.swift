import Foundation
import PipitAudio
import PipitCore
import PipitServices
import Testing

/// A canceller that leaves every block exactly as it came, standing in for a
/// pass that could not take the far end out.
private final class PassThroughCanceller: EchoCancelling {
    let blockFrames = 160
    let latencyFrames = 0
    var reportedRemovalDB: Double? { nil }
    func process(microphone: inout [Float], reference: [Float]) -> Bool { true }
}

/// The cleaner writes down what happened to the far end, measured on the
/// audio, so a meeting whose microphone still holds the speakers says so.
/// The fixture is the spoken call, where the far end dominates the
/// microphone the way it does on a call taken on speakers: the envelope bar
/// was calibrated on such calls, and a call where the user out-talks the
/// echo reads under it before and after.
/// On the Zoom call of 11 September 2026 the pass took 10 dB off a far end
/// that needed 30, recorded the outcome as cleaned, and 249 of 268 lines on
/// the microphone were the far end's words with nothing on the meeting to
/// say why.
@Suite("CleanerReporting")
struct CleanerReportingTests {
    @Test("a cleaned call on speakers records the far end gone from the microphone")
    func aCleanedCallRecordsTheFarEndGone() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeSpokenCall(root: root)
        let store = meeting.store
        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner().clean(
            store: store, metadata: &carried, timeline: try store.readTimeline()
        )
        #expect(outcome == CleaningOutcome.cleaned)
        let cleaned = try #require(try store.readMetadata().cleanedMic)
        let before = try #require(cleaned.echoCorrelationBefore)
        let after = try #require(cleaned.echoCorrelationAfter)
        #expect(before >= CleanedMicrophone.echoCorrelationBar, "the recording holds an echo path: \(before)")
        #expect(after < CleanedMicrophone.echoCorrelationBar, "the cleaned track still follows the far end: \(after)")
        #expect(!cleaned.echoRemains)
        #expect(cleaned.echoRemovedMedianDB > 10, "measured \(cleaned.echoRemovedMedianDB) dB")
    }

    @Test("a pass that left the far end in the microphone is recorded as such")
    func aPassThatLeftTheFarEndIsRecorded() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let meeting = try MicrophoneCleaningFixtures.makeSpokenCall(root: root)
        let store = meeting.store
        var carried = meeting.metadata
        let outcome = try MicrophoneCleaner(canceller: { PassThroughCanceller() }).clean(
            store: store, metadata: &carried, timeline: try store.readTimeline()
        )
        // Nothing was removed and nothing was harmed, so the pass is kept
        // and what it left is written down.
        #expect(outcome == CleaningOutcome.cleaned)
        let cleaned = try #require(try store.readMetadata().cleanedMic)
        let after = try #require(cleaned.echoCorrelationAfter)
        #expect(after >= CleanedMicrophone.echoCorrelationBar, "the far end is still there: \(after)")
        #expect(cleaned.echoRemains)
        #expect(abs(cleaned.echoRemovedMedianDB) < 1, "measured \(cleaned.echoRemovedMedianDB) dB")
    }

    @Test("a record without the measurement does not claim the far end remained")
    func aRecordWithoutTheMeasurementClaimsNothing() {
        let record = CleanedMicrophone(
            track: AudioArchive.Track(
                file: "mic.cleaned.m4a", sampleRate: 16_000, channelCount: 1, frameCount: 16_000,
                seconds: 1, firstFrameHostTime: nil
            ),
            echoRemovedMedianDB: 0.2, farEndActiveWindows: 200, producedAt: Date()
        )
        #expect(!record.echoRemains)
    }
}
