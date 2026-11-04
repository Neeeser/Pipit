import Foundation

/// What a language model wrote about a meeting, as structure rather than prose.
///
/// The model is asked for the meeting one topic at a time, with each topic's
/// decisions, action items and open questions inside it. Small models find the
/// items next to the talk that produced them and miss them when asked for one
/// list at the end, so the meeting-wide lists are collected from the topics
/// here instead of asked for separately.
public struct GeneratedSummary: Codable, Sendable, Equatable {
    /// A decision or an open question, at the moment it was said.
    public struct Item: Codable, Sendable, Equatable {
        public var text: String
        /// Seconds from the start of the meeting, or nil when the model gave
        /// no time that lands inside it.
        public var at: Double?

        public init(text: String, at: Double? = nil) {
            self.text = text
            self.at = at
        }
    }

    public struct ActionItem: Codable, Sendable, Equatable {
        public var task: String
        /// Empty when nobody in particular took it.
        public var owner: String
        /// When it is due, in the words the model used. Empty when no deadline
        /// was said.
        public var due: String
        public var at: Double?

        public init(task: String, owner: String = "", due: String = "", at: Double? = nil) {
            self.task = task
            self.owner = owner
            self.due = due
            self.at = at
        }
    }

    public struct Topic: Codable, Sendable, Equatable {
        public var title: String
        public var at: Double?
        public var points: [String]
        public var decisions: [Item]
        public var actionItems: [ActionItem]
        public var openQuestions: [Item]

        public init(
            title: String, at: Double? = nil, points: [String] = [], decisions: [Item] = [],
            actionItems: [ActionItem] = [], openQuestions: [Item] = []
        ) {
            self.title = title
            self.at = at
            self.points = points
            self.decisions = decisions
            self.actionItems = actionItems
            self.openQuestions = openQuestions
        }
    }

    public var overview: String
    public var topics: [Topic]

    public init(overview: String = "", topics: [Topic] = []) {
        self.overview = overview
        self.topics = topics
    }

    public var actionItems: [ActionItem] { topics.flatMap(\.actionItems) }
    public var decisions: [Item] { topics.flatMap(\.decisions) }
    public var openQuestions: [Item] { topics.flatMap(\.openQuestions) }

    public var isEmpty: Bool { overview.isEmpty && topics.isEmpty }

    // MARK: - times

    /// Seconds for a time as a transcript line writes it: "mm:ss" or
    /// "h:mm:ss", with or without the brackets around it.
    ///
    /// Models copy the bracket along with the time often enough that refusing
    /// it would throw away a correct answer.
    public static func seconds(fromTimecode text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] \t\n"))
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0
        for (index, part) in parts.enumerated() {
            guard let value = Int(part), value >= 0 else { return nil }
            // Minutes and seconds after the first field roll over at sixty; a
            // time that breaks that was not copied from a transcript line.
            if index > 0, value >= 60 { return nil }
            total = total * 60 + value
        }
        return Double(total)
    }

    // MARK: - markdown

    /// The Summary tab's half of `summary.md`: the overview, then the
    /// meeting-wide lists.
    public var summaryMarkdown: String {
        var sections: [String] = []
        if !overview.isEmpty { sections.append(overview) }
        let actions = actionItems.map { item -> String in
            var line = "- \(item.task)"
            var details: [String] = []
            if !item.owner.isEmpty { details.append(item.owner) }
            if !item.due.isEmpty { details.append("due \(item.due)") }
            if !details.isEmpty { line += " (\(details.joined(separator: ", ")))" }
            return line + Self.stamp(item.at)
        }
        if !actions.isEmpty { sections.append("### Action items\n\n" + actions.joined(separator: "\n")) }
        let decided = decisions.map { "- \($0.text)" + Self.stamp($0.at) }
        if !decided.isEmpty { sections.append("### Decisions\n\n" + decided.joined(separator: "\n")) }
        let open = openQuestions.map { "- \($0.text)" + Self.stamp($0.at) }
        if !open.isEmpty { sections.append("### Open questions\n\n" + open.joined(separator: "\n")) }
        return sections.joined(separator: "\n\n")
    }

    /// The Notes tab's half of `summary.md`: one section per topic.
    public var notesMarkdown: String {
        topics.map { topic in
            let heading = "### \(topic.title)" + Self.stamp(topic.at)
            let points = topic.points.map { "- \($0)" }
            return ([heading] + (points.isEmpty ? [] : [points.joined(separator: "\n")]))
                .joined(separator: "\n\n")
        }
        .joined(separator: "\n\n")
    }

    private static func stamp(_ seconds: Double?) -> String {
        guard let seconds else { return "" }
        let whole = Int(seconds)
        let text =
            whole >= 3_600
            ? String(format: "%d:%02d:%02d", whole / 3_600, whole % 3_600 / 60, whole % 60)
            : String(format: "%02d:%02d", whole / 60, whole % 60)
        return " [\(text)]"
    }
}

/// `raw/summary.json`: the structure, and the `summary.md` text written from
/// it, so a reader can tell whether the markdown has been edited since.
struct StructuredSummaryFile: Codable {
    var markdown: String
    var summary: GeneratedSummary
}
