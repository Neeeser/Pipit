import Foundation

/// The three tables a summary evaluation prints: what each model found, how
/// good its writing is by the judge, and how reliable it was.
///
/// Every share is pooled over all meetings and runs, so a meeting with more
/// items counts for more. No column is folded into a single score, so a strong
/// column cannot hide a weak one.
struct SummaryReport {
    let runs: [SummaryEvalCommand.Run]
    let models: [String]
    let judge: String?

    var text: String {
        var out: [String] = []
        out.append("What each model found, against the answer key")
        out.append(
            row([
                "model", "actions", "must-find", "as questions", "topics", "owner right",
            ]))
        for model in models {
            let scores = pooled(model)
            let tasks = runs.filter { $0.model == model }.compactMap(\.answer.summary).flatMap(\.actionItems)
            out.append(
                row([
                    model,
                    share(scores.actions.found, scores.actions.truth),
                    share(scores.actions.foundMustFind, scores.actions.mustFind),
                    share(tasks.filter(\.isQuestion).count, tasks.count),
                    share(scores.topicsCovered, scores.keyTopics),
                    share(scores.ownerRight, scores.ownerChecked),
                ]))
        }
        let all = runs.compactMap(\.scores)
        if judge != nil {
            out.append(
                "matching: the judge confirmed \(all.map(\.confirmed).reduce(0, +)) of the "
                    + "\(all.map(\.proposed).reduce(0, +)) pairs the embeddings proposed")
        }

        out.append("")
        out.append(
            "Writing quality, by the judge (\(judge ?? "no judge"), instructions version \(SummaryJudge.version))")
        out.append(row(["model", "overview", "notes true", "notes complete", "invented", "judged"]))
        for model in models {
            let verdicts = runs.filter { $0.model == model }.compactMap(\.verdict)
            let overview = verdicts.isEmpty ? nil : verdicts.map(\.overview.score).reduce(0, +) / Double(verdicts.count)
            let points = verdicts.flatMap(\.points)
            let topics = verdicts.flatMap(\.keyTopics)
            // Invented items are counted against everything the model listed,
            // matched or not, so a model that lists more is not punished for it.
            let judged = runs.filter { $0.model == model && $0.verdict != nil }.compactMap(\.scores)
            let listed = judged.reduce(0) { $0 + $1.actions.given }
            out.append(
                row([
                    model,
                    overview.map { String(format: "%.0f%%", $0 * 100) } ?? "-",
                    share(points.filter(\.yes).count, points.count),
                    share(topics.filter(\.yes).count, topics.count),
                    share(judged.map(\.invented).reduce(0, +), listed),
                    "\(verdicts.count) of \(runs.filter { $0.model == model }.count)",
                ]))
        }

        out.append("")
        out.append("Reliability")
        out.append(row(["model", "valid", "seconds each", "times on lines", "times near key", "swing"]))
        for model in models {
            let mine = runs.filter { $0.model == model }
            let valid = mine.filter { $0.answer.summary != nil }
            let seconds = valid.map(\.answer.seconds).reduce(0, +) / Double(max(valid.count, 1))
            let scores = pooled(model)
            out.append(
                row([
                    model,
                    "\(valid.count) of \(mine.count)",
                    valid.isEmpty ? "-" : String(format: "%.0f", seconds),
                    share(scores.timesOnLines, scores.timesGiven),
                    share(scores.timesNear, scores.timesNearChecked),
                    swing(model),
                ]))
        }
        out.append("")
        out.append(
            "found: share of key items the model also listed; must-find: of those the AMI annotators also listed"
        )
        out.append("as questions: share of the model's action items it flagged as a question to go and answer")
        out.append(
            "invented: items matching nothing in the key that the judge found were never said, as a share of all listed"
        )
        out.append("swing: half the spread between the best and worst run of the share of all key items found")
        return out.joined(separator: "\n")
    }

    private func pooled(_ model: String) -> SummaryEvalCommand.Scores {
        var total = SummaryEvalCommand.Scores()
        for scores in runs.filter({ $0.model == model }).compactMap(\.scores) {
            total.actions.add(scores.actions)
            total.ownerRight += scores.ownerRight
            total.ownerChecked += scores.ownerChecked
            total.timesOnLines += scores.timesOnLines
            total.timesGiven += scores.timesGiven
            total.timesNear += scores.timesNear
            total.timesNearChecked += scores.timesNearChecked
            total.topicsCovered += scores.topicsCovered
            total.keyTopics += scores.keyTopics
        }
        return total
    }

    /// How far the found share moves between runs: each run number pooled over
    /// the meetings, then half the gap between the best and the worst.
    private func swing(_ model: String) -> String {
        let byRun = Dictionary(grouping: runs.filter { $0.model == model }, by: \.run)
        let shares = byRun.values.compactMap { group -> Double? in
            var found = 0
            var truth = 0
            for scores in group.compactMap(\.scores) {
                found += scores.actions.found
                truth += scores.actions.truth
            }
            return truth == 0 ? nil : Double(found) / Double(truth)
        }
        guard shares.count > 1, let high = shares.max(), let low = shares.min() else { return "-" }
        return String(format: "±%.0f", (high - low) / 2 * 100)
    }

    private func share(_ part: Int, _ whole: Int) -> String {
        whole == 0 ? "-" : String(format: "%.0f%%", Double(part) / Double(whole) * 100)
    }

    private func row(_ cells: [String]) -> String {
        let first = cells[0].padding(toLength: 26, withPad: " ", startingAt: 0)
        return first
            + cells.dropFirst().map { $0.count >= 12 ? " " + $0 : String(repeating: " ", count: 12 - $0.count) + $0 }
            .joined()
    }
}
