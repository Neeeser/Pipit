import CryptoKit
import Foundation
import PipitCore
import PipitIntegrations

/// `pipit-eval summaries`: scores the summary and notes each model writes for
/// public meetings against a hand-checked answer key.
///
/// Every model goes through the client the app would use for it, with the
/// app's prompt or a draft passed with `--instructions`, so a score is a score
/// for what a person would see. Answers, embeddings and verdicts are kept in
/// the output folder and reused, so adding a model or a repeat only runs what
/// is new.
enum SummaryEvalCommand {
    struct Options {
        var models: [String] = []
        var judge: String? = "openai:gpt-6-luna"
        var embedder = "local:hindsight-ai/hs-embed-1"
        var meetings: [String] = []
        var repeats = 3
        var instructions: URL?
        var contextTokens = ContextWindow.defaultTokens
        var benchmarks = URL(fileURLWithPath: "Benchmarks/summaries", isDirectory: true)
        var out: URL?
    }

    /// A key item and a model item proposed as the same, by index into each
    /// kind's lists.
    struct Pair: Codable, Sendable {
        var truth: Int
        var candidate: Int
        var similarity: Double
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
        /// Pairs the embeddings proposed, and how many the judge confirmed.
        var proposed = 0
        var confirmed = 0
        /// Items the model listed that matched nothing in the key and that the
        /// judge found were never said.
        var invented = 0
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
        var keyItems: [KeyItem] = []
        /// What the model listed that matched nothing in the key.
        var unmatched: [SummaryJudge.Item] = []
        /// Proposed pairs the judge said were not the same, for checking it.
        var rejectedPairs: [SummaryJudge.ProposedPair] = []
        var judgeModel: String?
        var judgeVersion: Int?
        var verdict: SummaryJudge.Verdict?
        var judgeError: String?
    }

    /// The judge for a run, with the name its verdicts are filed under.
    struct Judging: Sendable {
        var label: String
        var slug: String
        var judge: SummaryJudge
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
        guard let embedder = SummaryEmbedder(options.embedder) else {
            note("summaries: --embedder is local:<hugging face model> or ollama:<model>")
            return 2
        }
        let meetings = options.meetings.isEmpty ? SummaryCase.available(in: options.benchmarks) : options.meetings
        guard let cases = try? meetings.map({ try SummaryCase.load(meeting: $0, from: options.benchmarks) }),
            !cases.isEmpty
        else {
            note("summaries: cannot read the meetings in \(options.benchmarks.path)")
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

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let out = options.out ?? URL(fileURLWithPath: "bench-scratch/summaries/\(stamp)", isDirectory: true)
        let matcher = SummaryMatcher(
            embedder: embedder, cache: out.appendingPathComponent("embeddings/\(embedder.slug).json")
        )
        print(
            "summaries: \(cases.count) meetings, \(options.repeats) runs each, prompt "
                + (options.instructions?.lastPathComponent ?? "built-in"))
        print(
            "matching:  \(embedder.label) proposes pairs at similarity \(SummaryMatcher.threshold) or more"
                + (judgeModel == nil ? "" : ", the judge confirms them"))
        print("judge:     \(judgeModel.map { "\($0.label), instructions version \(SummaryJudge.version)" } ?? "none")")
        print("output:    \(out.path)")

        // Every answer first, so all the text is embedded in one pass.
        var runs: [Run] = []
        for model in models {
            let summarizer = model.summarizer(contextTokens: options.contextTokens)
            for meeting in cases {
                for index in 1...options.repeats {
                    let answer = await answer(
                        model: model, summarizer: summarizer, meeting: meeting, run: index,
                        instructions: override, out: out
                    )
                    let status =
                        answer.error.map { "failed: \($0.prefix(80))" }
                        ?? String(format: "%.0fs, %d topics", answer.seconds, answer.summary?.topics.count ?? 0)
                    print("  \(model.label)  \(meeting.meeting) run \(index): \(status)")
                    runs.append(Run(model: model.label, meeting: meeting.meeting, run: index, answer: answer))
                }
            }
        }
        do {
            let texts = runs.compactMap(\.answer.summary).flatMap(texts(of:)) + cases.flatMap { texts(of: $0.truth) }
            try await matcher.prepare(texts)
        } catch {
            note("summaries: \(error.localizedDescription)")
            return 1
        }

        let judge = judgeModel.map {
            Judging(
                label: $0.label, slug: $0.slug,
                judge: SummaryJudge(client: $0.structured(contextTokens: options.contextTokens), model: $0.model))
        }
        runs = await gradeAll(runs, cases: cases, matcher: matcher, judge: judge, out: out)

        let report = SummaryReport(runs: runs, models: models.map(\.label), judge: judgeModel?.label)
        print("")
        print(report.text)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(runs).write(to: out.appendingPathComponent("runs.json"))
            try report.text.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
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

    // MARK: - grading

    /// Grades every run, a few at a time: each one waits on the judge, and the
    /// judge's provider answers several requests at once.
    private static func gradeAll(
        _ runs: [Run], cases: [SummaryCase], matcher: SummaryMatcher, judge: Judging?, out: URL
    ) async -> [Run] {
        var graded = runs
        await withTaskGroup(of: (Int, Run).self) { group in
            var next = 0
            func start() {
                guard next < runs.count else { return }
                let index = next
                let record = runs[index]
                let meeting = cases.first { $0.meeting == record.meeting }
                next += 1
                group.addTask {
                    guard let meeting else { return (index, record) }
                    return (index, await grade(record, meeting: meeting, matcher: matcher, judge: judge, out: out))
                }
            }
            for _ in 0..<6 { start() }
            for await (index, record) in group {
                graded[index] = record
                start()
            }
        }
        return graded
    }

    /// Scores one answer: the embeddings propose pairs, the judge confirms
    /// them and grades the writing, and the confirmed pairs are counted.
    private static func grade(
        _ record: Run, meeting: SummaryCase, matcher: SummaryMatcher, judge: Judging?, out: URL
    ) async -> Run {
        var record = record
        guard let summary = record.answer.summary else { return record }
        let lists = Lists(summary: summary, truth: meeting.truth)
        let proposals = lists.kinds.map { kind in
            matcher.proposals(
                truth: kind.truth.map { ($0.text, $0.at) }, candidates: kind.model.map { ($0.text, $0.at) })
        }
        let proposed = zip(lists.kinds, proposals).flatMap { kind, pairs in
            pairs.map {
                SummaryJudge.ProposedPair(
                    kind: kind.name, key: kind.truth[$0.truth].text, model: kind.model[$0.candidate].text)
            }
        }

        if let judge {
            record.judgeModel = judge.label
            record.judgeVersion = SummaryJudge.version
            let content = SummaryJudge.content(meeting: meeting, summary: summary, pairs: proposed, items: lists.items)
            let digest = SHA256.hash(data: Data(content.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
            let file = out.appendingPathComponent(
                "verdicts/\(judge.slug)-v\(SummaryJudge.version)/\(record.model.replacingOccurrences(of: ":", with: "_"))/"
                    + "\(meeting.meeting).\(record.run).\(digest).json")
            if let data = try? Data(contentsOf: file),
                let cached = try? JSONDecoder().decode(SummaryJudge.Verdict.self, from: data)
            {
                record.verdict = cached
            } else {
                do {
                    let verdict = try await judge.judge.judge(content: content)
                    save(verdict, to: file)
                    record.verdict = verdict
                } catch {
                    record.judgeError = String(describing: error)
                }
            }
        }

        // With a verdict only the pairs it confirmed count; without one, every
        // proposal does.
        var number = 0
        let accepted = proposals.map { pairs in
            pairs.filter { _ in
                number += 1
                guard let verdict = record.verdict else { return true }
                return SummaryJudge.Verdict.answer(verdict.pairs, number) ?? false
            }
        }
        let scored = score(
            lists: lists, accepted: accepted, meeting: meeting, summary: summary, verdict: record.verdict)
        record.scores = scored.scores
        record.scores?.proposed = proposed.count
        record.scores?.confirmed = accepted.map(\.count).reduce(0, +)
        record.keyItems = scored.keyItems
        record.unmatched = scored.unmatched
        let acceptedKeys = Set(
            zip(lists.kinds, accepted).flatMap { kind, pairs in
                pairs.map { "\(kind.name)|\(kind.truth[$0.truth].text)|\(kind.model[$0.candidate].text)" }
            })
        record.rejectedPairs = proposed.filter { !acceptedKeys.contains("\($0.kind)|\($0.key)|\($0.model)") }
        return record
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

    /// The key's items and the model's, side by side for each kind, and every
    /// model item in one numbered list for the judge.
    struct Lists {
        struct Entry {
            var text: String
            var at: Double?
            var mustFind = false
            var owner: String?
        }

        struct Kind {
            var name: String
            var truth: [Entry]
            var model: [Entry]
        }

        var kinds: [Kind]

        init(summary: GeneratedSummary, truth: SummaryTruth) {
            let time = { (text: String) in GeneratedSummary.seconds(fromTimecode: text) }
            kinds = [
                Kind(
                    name: "action item",
                    truth: truth.actionItems.map {
                        Entry(text: $0.task, at: time($0.at), mustFind: $0.mustFind, owner: $0.owner)
                    },
                    model: summary.actionItems.map { Entry(text: $0.task, at: $0.at, owner: $0.owner) }),
                Kind(
                    name: "decision",
                    truth: truth.decisions.map { Entry(text: $0.text, at: time($0.at), mustFind: $0.mustFind) },
                    model: summary.decisions.map { Entry(text: $0.text, at: $0.at) }),
                Kind(
                    name: "open question",
                    truth: truth.openQuestions.map { Entry(text: $0.text, at: time($0.at), mustFind: $0.mustFind) },
                    model: summary.openQuestions.map { Entry(text: $0.text, at: $0.at) }),
            ]
        }

        var items: [SummaryJudge.Item] {
            kinds.flatMap { kind in
                kind.model.map { SummaryJudge.Item(kind: kind.name, text: $0.text, owner: $0.owner) }
            }
        }
    }

    private static func texts(of summary: GeneratedSummary) -> [String] {
        summary.actionItems.map(\.task) + summary.decisions.map(\.text) + summary.openQuestions.map(\.text)
    }

    private static func texts(of truth: SummaryTruth) -> [String] {
        truth.actionItems.map(\.task) + truth.decisions.map(\.text) + truth.openQuestions.map(\.text)
    }

    static func score(
        lists: Lists, accepted: [[Pair]], meeting: SummaryCase, summary: GeneratedSummary,
        verdict: SummaryJudge.Verdict?
    ) -> (scores: Scores, keyItems: [KeyItem], unmatched: [SummaryJudge.Item]) {
        var scores = Scores()
        var keyItems: [KeyItem] = []
        var unmatched: [SummaryJudge.Item] = []
        var itemNumber = 0
        for (kind, proposals) in zip(lists.kinds, accepted) {
            let pairs = SummaryMatcher.assign(proposals)
            var result = KindScore()
            result.truth = kind.truth.count
            result.mustFind = kind.truth.filter(\.mustFind).count
            result.given = kind.model.count
            result.found = pairs.count
            result.foundMustFind = pairs.filter { kind.truth[$0.truth].mustFind }.count
            for pair in pairs {
                let key = kind.truth[pair.truth]
                let item = kind.model[pair.candidate]
                scores.timesNearChecked += 1
                if SummaryMatcher.isNear(key.at, item.at) { scores.timesNear += 1 }
                if let keyOwner = key.owner, let owner = item.owner {
                    scores.ownerChecked += 1
                    if SummaryMatcher.sameOwner(keyOwner, owner) { scores.ownerRight += 1 }
                }
            }
            let used = Set(pairs.map(\.candidate))
            for (index, item) in kind.model.enumerated() {
                itemNumber += 1
                guard !used.contains(index) else { continue }
                unmatched.append(SummaryJudge.Item(kind: kind.name, text: item.text, owner: item.owner))
                if let verdict, SummaryJudge.Verdict.answer(verdict.items, itemNumber) == false { scores.invented += 1 }
            }
            for (index, key) in kind.truth.enumerated() {
                let pair = pairs.first { $0.truth == index }
                keyItems.append(
                    KeyItem(
                        kind: kind.name, key: key.text, mustFind: key.mustFind,
                        model: pair.map { kind.model[$0.candidate].text }, similarity: pair?.similarity))
            }
            switch kind.name {
            case "action item": scores.actions = result
            case "decision": scores.decisions = result
            default: scores.questions = result
            }
        }

        // Every time the model gave, on any item or topic, should be a line
        // start it copied from the transcript.
        let starts = meeting.lineStarts
        let times =
            summary.topics.map(\.at) + summary.actionItems.map(\.at) + summary.decisions.map(\.at)
            + summary.openQuestions.map(\.at)
        scores.timesGiven = times.count
        scores.timesOnLines = times.filter { $0.map(starts.contains) ?? false }.count

        // A key topic is covered when a model topic starts inside it.
        scores.keyTopics = meeting.truth.topics.count
        for topic in meeting.truth.topics {
            guard let start = GeneratedSummary.seconds(fromTimecode: topic.start),
                let end = GeneratedSummary.seconds(fromTimecode: topic.end)
            else { continue }
            if summary.topics.contains(where: { $0.at.map { $0 >= start - 30 && $0 <= end + 30 } ?? false }) {
                scores.topicsCovered += 1
            }
        }
        return (scores, keyItems, unmatched)
    }
}
