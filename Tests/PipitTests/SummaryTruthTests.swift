import Foundation
import PipitCore
import Testing

/// The answer keys `pipit-eval summaries` scores against.
///
/// A key item that was never said would fail every model on it, so each one
/// carries the line it rests on, and this checks that line is in the
/// transcript where the key says it is.
@Suite("Summary answer keys")
struct SummaryTruthTests {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Benchmarks/summaries")

    private static var meetings: [String] {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("truth").path)) ?? []
        return names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    /// Letters and digits only, so a quote matches through punctuation.
    private static func plain(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    @Test("there are answer keys, each with its transcript")
    func thereAreAnswerKeysEachWithItsTranscript() {
        #expect(Self.meetings.count >= 10)
        for meeting in Self.meetings {
            let transcript = Self.directory.appendingPathComponent("transcripts/\(meeting).txt")
            #expect(FileManager.default.fileExists(atPath: transcript.path), "\(meeting) has no transcript")
        }
    }

    @Test("every key item's quote is on a transcript line within thirty seconds of its time", arguments: meetings)
    func everyKeyItemsQuoteIsOnATranscriptLine(meeting: String) throws {
        let transcript = try String(
            contentsOf: Self.directory.appendingPathComponent("transcripts/\(meeting).txt"), encoding: .utf8
        )
        let lines = transcript.split(separator: "\n").compactMap { line -> (Double, String)? in
            let text = String(line)
            guard let close = text.firstIndex(of: "]"),
                let seconds = GeneratedSummary.seconds(fromTimecode: String(text[text.startIndex...close]))
            else { return nil }
            return (seconds, Self.plain(String(text[close..<text.endIndex])))
        }
        let data = try Data(contentsOf: Self.directory.appendingPathComponent("truth/\(meeting).json"))
        let truth = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(truth["meeting"] as? String == meeting)
        #expect(!((truth["overview"] as? String) ?? "").isEmpty)
        #expect(!((truth["topics"] as? [[String: Any]]) ?? []).isEmpty)

        for kind in ["action_items", "decisions", "open_questions"] {
            for item in try #require(truth[kind] as? [[String: Any]], "\(meeting) has no \(kind)") {
                let text = (item["task"] ?? item["text"]) as? String ?? ""
                #expect(!text.isEmpty, "\(meeting) \(kind) item has no text")
                #expect(item["must_find"] is Bool, "\(meeting) \(kind) item has no must_find")
                let at = try #require(GeneratedSummary.seconds(fromTimecode: item["at"] as? String ?? ""))
                // The first sixty letters are enough to place the line, and
                // spare a quote that runs on into the next one.
                let quote = String(Self.plain(item["quote"] as? String ?? "").prefix(60))
                #expect(!quote.isEmpty, "\(meeting) \(kind) item at \(at) has no quote")
                let found = lines.contains { abs($0.0 - at) <= 30 && $0.1.contains(quote) }
                #expect(found, "\(meeting): the quote for \(text.prefix(50)) is not near \(item["at"] ?? "")")
            }
        }
    }
}
