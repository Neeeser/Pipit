import Foundation
import PipitCore
import PipitServices
import PipitUI
import Testing

// Times the reads the meetings window makes when it opens, against an archive
// named in `PIPIT_TIMING_ARCHIVE`. The directory holds a `Meetings` folder.
// Skipped when the variable is unset.

private let timingRoot = ProcessInfo.processInfo.environment["PIPIT_TIMING_ARCHIVE"]
    .map { URL(fileURLWithPath: $0) }

@Suite("ArchiveLoadTiming", .enabled(if: timingRoot != nil))
struct ArchiveLoadTimingTests {
    @MainActor
    private static func time<T>(_ label: String, _ body: () async -> T) async -> T {
        let clock = ContinuousClock()
        let start = clock.now
        let value = await body()
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print(String(format: "TIMING %-48@ %9.1f ms", label as NSString, ms))
        return value
    }

    @Test("time the meetings window's reads")
    @MainActor
    func timeTheReads() async throws {
        guard let root = timingRoot else { return }
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let repository = runtime.repository
        for pass in 1...2 {
            print("TIMING pass \(pass)")
            let directories = await Self.time("meetingDirectories") { repository.meetingDirectories() }
            print("TIMING   \(directories.count) directories")
            _ = await Self.time("listMeetings") { repository.listMeetings() }
            let rows = await Self.time("runtime.meetingRows") { await runtime.meetingRows() }
            _ = await Self.time("runtime.folderRows") { await runtime.folderRows() }
            _ = await Self.time("transcriptSearchIndex(all)") {
                await runtime.transcriptSearchIndex(for: Set(rows.map(\.id)))
            }
            let model = MeetingsWindowModel(runtime: runtime)
            _ = await Self.time("MeetingsWindowModel.reload") { await model.reload() }
            _ = await Self.time("sections") { model.sections }
            let biggest = rows.max { $0.summary.durationSeconds < $1.summary.durationSeconds }
            if let biggest {
                print("TIMING   biggest \(Int(biggest.summary.durationSeconds / 60)) min")
                let detail = await Self.time("MeetingReviewModel.init (main actor)") {
                    MeetingReviewModel(runtime: runtime, meetingID: biggest.id)
                }
                _ = await Self.time("MeetingReviewModel.reloadSpeakers") { await detail.reloadSpeakers() }
                guard let logical = repository.logicalMeeting(id: biggest.id) else { return }
                _ = await Self.time("  readCanonicalTranscript") {
                    try? logical.primary.store.readCanonicalTranscript()
                }
                _ = await Self.time("  combinedTranscript") { logical.combinedTranscript() }
                _ = await Self.time("  runtime.speakers(inMeeting:)") {
                    await runtime.speakers(inMeeting: biggest.id)
                }
                _ = await Self.time("  runtime.speakerSuggestions") {
                    runtime.speakerSuggestions(inMeeting: biggest.id)
                }
                _ = await Self.time("  runtime.unnamedSpeakerCount") {
                    runtime.unnamedSpeakerCount(inMeeting: biggest.id)
                }
                _ = await Self.time("  runtime.speakerDirectory") {
                    await runtime.speakerDirectory(kind: .person)
                }
            }
            let seeded = await Self.time("MeetingsWindowModel showing the last list") {
                let model = MeetingsWindowModel(runtime: runtime)
                model.showLastList()
                return model
            }
            print("TIMING   seeded rows \(seeded.rows.count), detail \(seeded.detail != nil)")
            let ten = Array(rows.prefix(10))
            _ = await Self.time("select 10 meetings in turn (main actor)") {
                for row in ten { seeded.select(row.id, extending: false) }
            }
            seeded.query = "the"
            _ = await Self.time("sections with query 'the'") { seeded.sections }
            seeded.query = "zzqxv"
            _ = await Self.time("sections with query 'zzqxv'") { seeded.sections }
        }
    }
}
