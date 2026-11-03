import Foundation
import PipitCore
import PipitIntegrations

/// `pipit-eval summaries`: scores the summary and notes each model writes for
/// public meetings against a hand-checked answer key.
///
/// Every model goes through the client the app would use for it, with the
/// app's prompt or a draft passed with `--instructions`, so a score is a score
/// for what a person would see. Answers and verdicts are kept in the output
/// folder and reused, so adding a model or a repeat only runs what is new.
enum SummaryEvalCommand {
    struct Options {
        var models: [String] = []
        var judge: String? = "openai:gpt-6-luna"
        var embedder = "openai:text-embedding-3-small"
        var meetings: [String] = []
        var repeats = 3
        var instructions: URL?
        var contextTokens = ContextWindow.defaultTokens
        var benchmarks = URL(fileURLWithPath: "Benchmarks/summaries", isDirectory: true)
        var out: URL?
    }

    struct KindScore: Codable, Sendable {
        var truth = 0
        var mustFind = 0
        var found = 0
        var foundMustFind = 0
        var given = 0

        mutating func add(_ other: KindScore) {
            truth += other.truth
            mustFind += other.mustFind
            found += other.found
            foundMustFind += other.foundMustFind
            given += other.given
        }
    }

    struct Scores: Codable, Sendable {
        var actions = KindScore()
        var decisions = KindScore()
        var questions = KindScore()
        var ownerRight = 0
        var ownerChecked = 0
        var timesOnLines = 0
        var timesGiven = 0
        var timesNear = 0
        var timesNearChecked = 0
        var topicsCovered = 0
        var keyTopics = 0
    }

    /// One key item and what the model wrote for it, for reading a run by
    /// hand: the model's text and the similarity when it matched, nothing when
    /// it was missed.
    struct KeyItem: Codable, Sendable {
        var kind: String
        var key: String
        var mustFind: Bool
        var model: String?
        var similarity: Double?
    }

    struct Answer: Codable, Sendable {
        var seconds: Double
        var error: String?
        var summary: GeneratedSummary?
    }

    struct Run: Codable, Sendable {
        var model: String
        var meeting: String
        var run: Int
        var answer: Answer
        var scores: Scores?
        var unmatched: [SummaryJudge.UnmatchedItem]
        var keyItems: [KeyItem] = []
        var judgeModel: String?
        var judgeVersion: Int?
        var verdict: SummaryJudge.Verdict?
        var judgeError: String?
    }

    static func run(_ options: Options) async -> Int32 {
        guard !options.models.isEmpty else {
            note("summaries: name at least one --model, such as ollama:qwen3.5:4b or openai:gpt-6-luna")
            return 2
        }
        let models = options.models.compactMap(SummaryModel.init)
        guard models.count == options.models.count else {
            note("summaries: a --model is openai:, openrouter: or ollama: and a model, or custom:<url>|<model>")
            return 2
        }
        let judgeModel = options.judge.flatMap(SummaryModel.init)
        if options.judge != nil, judgeModel == nil {
            note("summaries: --judge takes the same form as --model")
            return 2
        }

        let meetings = options.meetings.isEmpty ? SummaryCase.available(in: options.benchmarks) : options.meetings
        let cases: [SummaryCase]
        do {
            cases = try meetings.map { try SummaryCase.load(meeting: $0, from: options.benchmarks) }
        } catch {
            note("summaries: cannot read the meetings in \(options.benchmarks.path): \(error)")
            return 1
        }
        guard !cases.isEmpty else {
            note("summaries: no meetings in \(options.benchmarks.path)")
            return 1
        }
        var override: String?
        if let file = options.instructions {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else {
                note("summaries: cannot read \(file.path)")
                return 1
            }
            override = text
        }
        guard let embedder = SummaryEmbedder(options.embedder) else {
            note("summaries: --embedder is openai:<model> or ollama:<model>")
            return 2
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let out = options.out ?? URL(fileURLWithPath: "bench-scratch/summaries/\(stamp)", isDirectory: true)
        let matcher = SummaryMatcher(
            embedder: embedder, cache: out.appendingPathComponent("embeddings/\(embedder.model.slug).json")
        )
        let promptName = options.instructions?.lastPathComponent ?? "built-in"
        print("summaries: \(cases.count) meetings, \(options.repeats) runs each, prompt \(promptName)")
        print("matching:  \(embedder.model.label) embeddings, threshold \(SummaryMatcher.threshold)")
        print("judge:     \(judgeModel.map { "\($0.label), instructions version \(SummaryJudge.version)" } ?? "none")")
        print("output:    \(out.path)")

        let judge = judgeModel.map {
            Judging(
                label: $0.label, slug: $0.slug,
                judge: SummaryJudge(
                    client: $0.structured(contextTokens: options.contextTokens), model: $0.model))
        }
        var runs: [Run] = []
        for model in models {
            let summarizer = model.summarizer(contextTokens: options.contextTokens)
            for meeting in cases {
                for index in 1...options.repeats {
                    let answer = await answer(
                        model: model, summarizer: summarizer, meeting: meeting, run: index,
                        instructions: override, out: out
                    )
                    var record = Run(
                        model: model.label, meeting: meeting.meeting, run: index, answer: answer, unmatched: []
                    )
                    do {
                        try await grade(
                            &record, model: model, meeting: meeting, matcher: matcher, judge: judge, out: out)
                    } catch {
                        note("summaries: \(error.localizedDescription)")
                        return 1
                    }
                    let status =
                        answer.error.map { "failed: \($0.prefix(80))" }
                        ?? String(format: "%.0fs, %d topics", answer.seconds, answer.summary?.topics.count ?? 0)
                    print("  \(model.label)  \(meeting.meeting) run \(index): \(status)")
                    runs.append(record)
                }
            }
        }

        let report = SummaryReport(runs: runs, models: models.map(\.label), judge: judgeModel?.label)
        print("")
        print(report.text)
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(runs).write(to: out.appendingPathComponent("runs.json"))
            try report.text.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            try nearMisses(runs: runs, cases: cases, matcher: matcher)
                .write(to: out.appendingPathComponent("near-misses.txt"), atomically: true, encoding: .utf8)
        } catch {
            note("summaries: cannot write the results: \(error)")
            return 1
        }
        print("full detail in \(out.path)")
        return 0
    }

    // MARK: - answering

    private static func answer(
        model: SummaryModel, summarizer: any LanguageModelBackend, meeting: SummaryCase, run: Int,
        instructions: String?, out: URL
    ) async -> Answer {
        let file = out.appendingPathComponent("answers/\(model.slug)/\(meeting.meeting).\(run).json")
        if let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(Answer.self, from: data) {
            return cached
        }
        let request = EnrichmentRequest(
            transcript: meeting.transcript, humanNotes: nil, participants: meeting.participants,
            provider: .unknown, durationSeconds: meeting.durationSeconds, wantsTitle: true,
            wantsDescription: false, wantsSummary: true, wantsNotes: true, instructions: instructions
        )
        let started = Date()
        var answer: Answer
        do {
            let result = try await summarizer.enrich(request, model: model.model)
            answer = Answer(seconds: Date().timeIntervalSince(started), summary: result.generatedSummary)
            if result.generatedSummary == nil { answer.error = "no summary in the answer" }
        } catch {
            answer = Answer(seconds: Date().timeIntervalSince(started), error: String(describing: error))
        }
        save(answer, to: file)
        return answer
    }

    /// The judge for a run, with the names its verdicts are filed under.
    struct Judging {
        var label: String
        var slug: String
        var judge: SummaryJudge
    }

    /// Scores an answer by matching, then by the judge. Throws only when the
    /// embeddings cannot be fetched, since no score means anything without
    /// them; a judge that fails is recorded on the run.
    private static func grade(
        _ record: inout Run, model: SummaryModel, meeting: SummaryCase, matcher: SummaryMatcher,
        judge: Judging?, out: URL
    ) async throws {
        guard let summary = record.answer.summary else { return }
        try await matcher.prepare(texts(of: summary) + texts(of: meeting.truth))
        let scored = score(summary: summary, meeting: meeting, matcher: matcher)
        record.scores = scored.scores
        record.unmatched = scored.unmatched
        record.keyItems = scored.keyItems
        guard let judge else { return }
        record.judgeModel = judge.label
        record.judgeVersion = SummaryJudge.version
        let file = out.appendingPathComponent(
            "verdicts/\(judge.slug)-v\(SummaryJudge.version)/\(model.slug)/\(meeting.meeting).\(record.run).json"
        )
        if let data = try? Data(contentsOf: file),
            let cached = try? JSONDecoder().decode(SummaryJudge.Verdict.self, from: data)
        {
            record.verdict = cached
            return
        }
        do {
            let verdict = try await judge.judge.judge(meeting: meeting, summary: summary, unmatched: scored.unmatched)
            save(verdict, to: file)
            record.verdict = verdict
        } catch {
            record.judgeError = String(describing: error)
        }
    }

    private static func save(_ value: some Encodable, to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: file, options: .atomic)
    }

    // MARK: - scoring

    private static func texts(of summary: GeneratedSummary) -> [String] {
        summary.actionItems.map(\.task) + summary.decisions.map(\.text) + summary.openQuestions.map(\.text)
    }

    private static func texts(of truth: SummaryTruth) -> [String] {
        truth.actionItems.map(\.task) + truth.decisions.map(\.text) + truth.openQuestions.map(\.text)
    }

    static func score(
        summary: GeneratedSummary, meeting: SummaryCase, matcher: SummaryMatcher
    ) -> (scores: Scores, unmatched: [SummaryJudge.UnmatchedItem], keyItems: [KeyItem]) {
        let truth = meeting.truth
        var scores = Scores()
        var unmatched: [SummaryJudge.UnmatchedItem] = []
        var keyItems: [KeyItem] = []
        let keyTime = { (text: String) in GeneratedSummary.seconds(fromTimecode: text) }

        func kind(
            truth: [(text: String, at: Double?, mustFind: Bool)], candidates: [(text: String, at: Double?)],
            name: String, owners: [String]? = nil
        ) -> (KindScore, [SummaryMatcher.Pair]) {
            let pairs = matcher.match(
                truth: truth.map { ($0.text, $0.at) }, candidates: candidates
            )
            var result = KindScore()
            result.truth = truth.count
            result.mustFind = truth.filter(\.mustFind).count
            result.given = candidates.count
            result.found = pairs.count
            result.foundMustFind = pairs.filter { truth[$0.truth].mustFind }.count
            for pair in pairs {
                scores.timesNearChecked += 1
                if SummaryMatcher.isNear(truth[pair.truth].at, candidates[pair.candidate].at) { scores.timesNear += 1 }
            }
            let used = Set(pairs.map(\.candidate))
            for (index, item) in candidates.enumerated() where !used.contains(index) {
                unmatched.append(.init(kind: name, text: item.text, owner: owners?[index]))
            }
            for (index, key) in truth.enumerated() {
                let pair = pairs.first { $0.truth == index }
                keyItems.append(
                    KeyItem(
                        kind: name, key: key.text, mustFind: key.mustFind,
                        model: pair.map { candidates[$0.candidate].text }, similarity: pair?.similarity
                    ))
            }
            return (result, pairs)
        }

        let actions = summary.actionItems
        let (actionScore, actionPairs) = kind(
            truth: truth.actionItems.map { ($0.task, keyTime($0.at), $0.mustFind) },
            candidates: actions.map { ($0.task, $0.at) }, name: "action item", owners: actions.map(\.owner)
        )
        scores.actions = actionScore
        for pair in actionPairs {
            scores.ownerChecked += 1
            if SummaryMatcher.sameOwner(truth.actionItems[pair.truth].owner, actions[pair.candidate].owner) {
                scores.ownerRight += 1
            }
        }
        // Read into a constant first: `kind` writes to `scores` too, and the
        // two writes may not overlap.
        let decided = kind(
            truth: truth.decisions.map { ($0.text, keyTime($0.at), $0.mustFind) },
            candidates: summary.decisions.map { ($0.text, $0.at) }, name: "decision"
        ).0
        scores.decisions = decided
        let open = kind(
            truth: truth.openQuestions.map { ($0.text, keyTime($0.at), $0.mustFind) },
            candidates: summary.openQuestions.map { ($0.text, $0.at) }, name: "open question"
        ).0
        scores.questions = open

        // Times: every time the model gave, on any item or topic, should be a
        // line start it copied from the transcript.
        let starts = meeting.lineStarts
        let times =
            summary.topics.map(\.at) + actions.map(\.at) + summary.decisions.map(\.at)
            + summary.openQuestions.map(\.at)
        scores.timesGiven = times.count
        scores.timesOnLines = times.filter { $0.map(starts.contains) ?? false }.count

        // A key topic is covered when a model topic starts inside it.
        scores.keyTopics = truth.topics.count
        for topic in truth.topics {
            guard let start = keyTime(topic.start), let end = keyTime(topic.end) else { continue }
            if summary.topics.contains(where: { $0.at.map { $0 >= start - 30 && $0 <= end + 30 } ?? false }) {
                scores.topicsCovered += 1
            }
        }
        return (scores, unmatched, keyItems)
    }

    /// The closest pairs under the threshold across every answer, so the
    /// threshold can be checked by reading them.
    private static func nearMisses(runs: [Run], cases: [SummaryCase], matcher: SummaryMatcher) -> String {
        var lines: [String] = ["Closest unmatched pairs, similarity first. Threshold \(SummaryMatcher.threshold)."]
        for run in runs {
            guard let summary = run.answer.summary, let meeting = cases.first(where: { $0.meeting == run.meeting })
            else { continue }
            let truth =
                meeting.truth.actionItems.map(\.task) + meeting.truth.decisions.map(\.text)
                + meeting.truth.openQuestions.map(\.text)
            let candidates =
                summary.actionItems.map(\.task) + summary.decisions.map(\.text)
                + summary.openQuestions.map(\.text)
            let matched = matcher.match(truth: truth.map { ($0, nil) }, candidates: candidates.map { ($0, nil) })
            for miss in matcher.nearMisses(truth: truth, candidates: candidates, matched: matched, limit: 5) {
                lines.append(
                    String(
                        format: "%.2f  %@ %@ run %d\n      key:   %@\n      model: %@",
                        miss.similarity, run.model, run.meeting, run.run, miss.truth, miss.candidate))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
