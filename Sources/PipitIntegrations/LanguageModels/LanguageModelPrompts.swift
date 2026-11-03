import Foundation
import PipitCore

/// What a model is asked, independent of how the request is sent.
///
/// The instructions and the shape of the answer are the product's, not a
/// provider's: OpenAI's responses endpoint, a chat completions server and
/// Ollama all receive the same words and the same schema, and differ only in
/// the envelope they are wrapped in.
public struct LanguageModelPrompt {
    public var instructions: String
    public var userContent: String
    public var schemaName: String
    /// A JSON schema. Objects may be `[String: Any]` or, where the order of
    /// the fields matters, built with `LanguageModelPrompt.object(_:)`.
    public var schema: [String: Any]

    public init(instructions: String, userContent: String, schemaName: String, schema: [String: Any]) {
        self.instructions = instructions
        self.userContent = userContent
        self.schemaName = schemaName
        self.schema = schema
    }

    /// A strict object schema with its properties in the order given.
    public static func object(_ properties: [(String, Any)]) -> [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": OrderedJSONObject(properties),
            "required": properties.map(\.0),
        ]
    }
}

/// A client that can be asked any question with a JSON schema for the answer.
///
/// The app's own requests go through `LanguageModelBackend`. This is for the
/// developer tools, which ask questions of their own, such as the evaluation's
/// judge, through the same transport and fallbacks the app uses.
public protocol StructuredLanguageModel: Sendable {
    /// The answer as JSON object bytes.
    func structuredAnswer(_ prompt: LanguageModelPrompt, model: String) async throws -> Data
}

enum LanguageModelPrompts {
    // MARK: - speakers

    static func speakerResolution(_ request: SpeakerResolutionRequest) -> LanguageModelPrompt {
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "mapping": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "properties": [
                            "label": ["type": "string"],
                            "name": ["type": "string"],
                            "confidence": ["type": "number"],
                            "quote": ["type": "string"],
                            "at_seconds": ["type": "number"],
                            "expanded_from_known_names": ["type": "boolean"],
                        ],
                        // Every field is required. A model allowed to omit the
                        // quote omits it exactly when it has none, which is the
                        // case the quote exists to catch.
                        "required": [
                            "label", "name", "confidence", "quote", "at_seconds",
                            "expanded_from_known_names",
                        ],
                    ],
                ],
                "unresolved": ["type": "array", "items": ["type": "string"]],
            ],
            "required": ["mapping", "unresolved"],
        ]

        var context: [String] = []
        if let name = request.localUserName {
            context.append(
                "The local microphone track belongs to \(name), and their lines are already "
                    + "labelled with that name."
            )
        }
        if let humanContext = request.humanContext, !humanContext.isEmpty {
            context.append("Notes from the user: \(humanContext)")
        }
        if !request.nameHints.isEmpty {
            context.append(
                "Names known for this meeting, for completing a first name only: "
                    + request.nameHints.joined(separator: ", ")
            )
        }
        context.append("Labels to identify: \(request.labels.joined(separator: ", "))")

        let instructions = """
            You identify speakers in a meeting transcript. Most lines already carry \
            the speaker's real name. Only the labels listed below are unidentified, \
            and only those may be named.

            Name a label only when someone says that name out loud in the transcript. \
            The evidence is almost always one person addressing another, and that \
            person speaking next or just before. The one who answers has to be the \
            label you are naming: where the line that follows already carries a \
            name, that name belongs to them and says nothing about the label. \
            Quote the line that shows it, verbatim, with the timestamp it carries, \
            and only ever a line the label itself spoke or one right beside it. The \
            quote and the timestamp are checked against the transcript, and a \
            suggestion whose line is not where you say it is will be thrown away. A \
            guess with no line behind it is worthless here, so return the label in \
            `unresolved` instead of inventing one.

            You may complete a first name into a full name using the known names \
            given as context, and must set `expanded_from_known_names` to true when \
            you do. Never take a name from that list that nobody said. Set \
            `confidence` in [0,1]: above 0.8 when the name is said clearly and the \
            turn-taking is unambiguous, lower when either is in doubt.
            """

        return LanguageModelPrompt(
            instructions: instructions,
            userContent: "\(context.joined(separator: "\n"))\n\nTranscript:\n\(request.transcript)",
            schemaName: "speaker_map",
            schema: schema
        )
    }

    /// The suggestions in a model's answer, or nil when the answer is not the
    /// shape that was asked for.
    static func speakerSuggestions(from object: [String: Any], labels: [String]) -> [SpeakerSuggestion]? {
        guard let mapping = object["mapping"] as? [[String: Any]] else { return nil }
        let allowed = Set(labels)
        return mapping.compactMap { entry in
            guard let label = entry["label"] as? String, let name = entry["name"] as? String,
                let quote = entry["quote"] as? String
            else { return nil }
            // A label outside the set asked about is a rename of a speaker the
            // meeting already resolved, which this stage does not get to do.
            guard allowed.contains(label) else { return nil }
            let trimmed = quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
                return nil
            }
            return SpeakerSuggestion(
                label: label,
                name: name,
                confidence: (entry["confidence"] as? Double) ?? 0,
                quote: trimmed,
                atSeconds: (entry["at_seconds"] as? Double) ?? 0,
                expandedFromCalendar: (entry["expanded_from_known_names"] as? Bool) ?? false
            )
        }
    }

    // MARK: - enrichment

    /// The instructions for the summary and notes, written for the smallest
    /// model Pipit supports: a short statement of the goal, a reason with each
    /// rule, and no sample values, because a small model copies a sample into
    /// its answer.
    static let writeupInstructions = """
        You write notes on a meeting from its transcript, for a person who was there or \
        who missed it and needs to know what happened and what they have to do. Use only \
        what the transcript says, because the notes are kept as the record of the meeting. \
        Fill the fields in the order they come.

        Each transcript line starts with its time in brackets. Wherever a field is named \
        `at`, give the time of the line where that thing was said, written as the \
        transcript writes it but without the brackets, so the reader can jump to that \
        moment.

        topics: the subjects the meeting worked on, in the order they came up, each with \
        the time it started. Keep talk about one subject together even when it is \
        interrupted. points are the facts, figures, reasons and concerns someone who \
        missed it would need, one idea each. Under each topic, list what the group \
        decided, the tasks people took on or agreed to, and the questions left \
        unanswered, so each is found next to the talk that produced it. A task's owner is \
        the person who will do it, named as the transcript names them, and is empty when \
        nobody in particular took it; due is a deadline someone said for that task, and is \
        empty when nobody said one.

        overview: a few sentences on why the group met, where it landed and what happens \
        next, for someone who will read nothing else.
        """

    /// Nil when the request asks for nothing.
    static func enrichment(_ request: EnrichmentRequest) -> LanguageModelPrompt? {
        var properties: [(String, Any)] = []
        let wantsWriteup = request.wantsSummary || request.wantsNotes
        // The parts of a long meeting already gave their topics, with the
        // times they were said, so the request that combines them only writes
        // what needs the whole meeting.
        let wantsTopics = wantsWriteup && !isCombining(request)
        if wantsTopics { properties.append(("topics", ["type": "array", "items": topicSchema])) }
        if wantsWriteup { properties.append(("overview", ["type": "string"])) }
        if request.wantsTitle { properties.append(("title", ["type": "string"])) }
        if request.wantsDescription { properties.append(("description", ["type": "string"])) }
        let asksAboutFolders = !request.folders.isEmpty
        if asksAboutFolders {
            properties.append(
                (
                    "folder_candidates",
                    [
                        "type": "array",
                        "items": strictObject([
                            ("folder", ["type": "string"]), ("confidence", ["type": "number"]),
                            ("why", ["type": "string"]), ("quote", ["type": "string"]),
                            ("at_seconds", ["type": "number"]),
                        ]),
                    ]
                ))
        }
        guard !properties.isEmpty else { return nil }

        let instructions = instructions(for: request, wantsTopics: wantsTopics)
        let context = context(for: request)
        let label = isCombining(request) ? "Notes by part" : "Transcript"

        return LanguageModelPrompt(
            instructions: instructions,
            userContent: "\(context)\n\n\(label):\n\(request.transcript)",
            schemaName: "meeting_enrichment",
            schema: strictObject(properties)
        )
    }

    /// The instructions for whatever the request asks for, in the order the
    /// fields come.
    private static func instructions(for request: EnrichmentRequest, wantsTopics: Bool) -> String {
        let wantsWriteup = request.wantsSummary || request.wantsNotes
        var instructions: [String] = []
        if wantsWriteup {
            if let override = request.instructions {
                instructions.append(override)
            } else if wantsTopics {
                instructions.append(writeupInstructions)
            } else {
                instructions.append(
                    "You write the overview of a long meeting from the notes written on each of its "
                        + "parts: a few sentences on why the group met, where it landed and what "
                        + "happens next, for someone who will read nothing else."
                )
            }
        } else {
            instructions.append("You describe a meeting from its transcript, using only what it says.")
        }
        if request.wantsTitle {
            instructions.append(
                "title: a short noun phrase naming the meeting, under eight words, with no trailing "
                    + "punctuation."
            )
        }
        if request.wantsDescription {
            instructions.append("description: one sentence on what the meeting was for.")
        }
        if !request.folders.isEmpty { instructions.append(folderInstructions) }
        return instructions.joined(separator: "\n\n")
    }

    /// What the model is told about the meeting, above the text itself.
    private static func context(for request: EnrichmentRequest) -> String {
        var context =
            "Provider: \(request.provider.displayName). Duration: \(Int(request.durationSeconds / 60)) minutes."
        if let startedAt = request.startedAt {
            let day = DateFormatter()
            day.locale = Locale(identifier: "en_US_POSIX")
            day.dateFormat = "EEEE, MMMM d, yyyy"
            context += " Meeting date: \(day.string(from: startedAt))."
        }
        if !request.folders.isEmpty {
            let catalogue = request.folders.map { folder -> String in
                var line = "- \(folder.name)"
                if !folder.about.isEmpty { line += ": \(folder.about)" }
                if let rule = folder.rule, !rule.isEmpty { line += " [files: \(rule)]" }
                if !folder.recentTitles.isEmpty {
                    line += "\n  holds: \(folder.recentTitles.joined(separator: "; "))"
                }
                return line
            }.joined(separator: "\n")
            context += "\n\nThe folders that exist:\n\(catalogue)"
        }
        if !request.participants.isEmpty {
            context += "\nParticipants: \(request.participants.joined(separator: ", "))"
        }
        if let notes = request.humanNotes, !notes.isEmpty {
            context += "\nThe user's own notes (do not repeat them verbatim): \(notes)"
        }
        switch request.source {
        case .transcript:
            break
        case .part(let index, let count):
            context +=
                "\nThis is part \(index) of \(count) of one meeting. Write only about this part, "
                + "and do not guess at the rest."
        case .partNotes(let count):
            context +=
                "\nThe text below is not a transcript. It is the notes written for each of "
                + "\(count) consecutive parts of one meeting, in order."
        }
        return context
    }

    private static let folderInstructions = """
        You also decide whether this meeting belongs in one of the user's \
        existing folders. Return folder_candidates as at most two entries, best \
        first, and only for folders in the list you are given. Never invent a \
        folder name. Every entry needs a verbatim quote from the transcript and \
        the time in seconds where it appears; an entry you cannot quote for is \
        an entry to leave out. confidence runs from 0 to 1. why is one short \
        clause naming the evidence, under twelve words, with no trailing \
        punctuation.

        Return an empty array when no folder fits. That is the ordinary \
        answer, not a failure. Two examples of it. A one to one whose only \
        link to a client folder is that one person in the call also appears \
        in that folder: a person is not a topic, so return nothing. A \
        technical review of a model evaluation, where every folder is a \
        client: the subject belongs to none of them, so return nothing.
        """

    private static var topicSchema: [String: Any] {
        let item = strictObject([("text", ["type": "string"]), ("at", ["type": "string"])])
        let task = strictObject([
            ("task", ["type": "string"]), ("owner", ["type": "string"]), ("due", ["type": "string"]),
            ("at", ["type": "string"]),
        ])
        return strictObject([
            ("title", ["type": "string"]), ("at", ["type": "string"]),
            ("points", ["type": "array", "items": ["type": "string"]]),
            ("decisions", ["type": "array", "items": item]),
            ("action_items", ["type": "array", "items": task]),
            ("open_questions", ["type": "array", "items": item]),
        ])
    }

    /// An object schema whose properties are all required and that allows
    /// nothing else, which OpenAI's strict mode demands. The order is kept,
    /// because a model held to a schema writes the fields in the order given
    /// and the instructions rely on that.
    private static func strictObject(_ properties: [(String, Any)]) -> [String: Any] {
        LanguageModelPrompt.object(properties)
    }

    private static func isCombining(_ request: EnrichmentRequest) -> Bool {
        if case .partNotes = request.source { return true }
        return false
    }

    /// A valid JSON object can still omit the requested output. Retry that
    /// answer instead of marking an empty enrichment as successful.
    ///
    /// Lists inside a topic may be missing: a model answering in JSON mode
    /// rather than held to the schema drops an empty one, and an empty list is
    /// what it meant.
    static func acceptsEnrichment(_ object: [String: Any], for request: EnrichmentRequest) -> Bool {
        let wantsWriteup = request.wantsSummary || request.wantsNotes
        let fields = [
            ("title", request.wantsTitle), ("description", request.wantsDescription),
            ("overview", wantsWriteup),
        ]
        guard fields.allSatisfy({ key, wanted in !wanted || object[key] is String }) else { return false }
        if wantsWriteup, !isCombining(request), !(object["topics"] is [Any]) { return false }
        return request.folders.isEmpty || object["folder_candidates"] is [[String: Any]]
    }

    static func enrichment(from object: [String: Any], for request: EnrichmentRequest) -> MeetingEnrichment {
        var result = MeetingEnrichment(
            title: object["title"] as? String,
            description: object["description"] as? String,
            folderCandidates: folderCandidates(from: object["folder_candidates"])
        )
        guard request.wantsSummary || request.wantsNotes else { return result }
        let summary = generatedSummary(from: object, durationSeconds: request.durationSeconds)
        result.generatedSummary = summary
        if request.wantsSummary, !summary.summaryMarkdown.isEmpty { result.summary = summary.summaryMarkdown }
        if request.wantsNotes, !summary.notesMarkdown.isEmpty { result.notes = summary.notesMarkdown }
        return result
    }

    /// Reads the structure leniently, keeping what is usable from an answer
    /// that is partly wrong: an item with no text is dropped, a time that does
    /// not land inside the meeting is dropped and the item kept, and a task
    /// that is only its owner's name is dropped.
    static func generatedSummary(from object: [String: Any], durationSeconds: Double) -> GeneratedSummary {
        func text(_ value: Any?) -> String {
            ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func time(_ value: Any?) -> Double? {
            let seconds: Double?
            if let number = value as? Double {
                seconds = number
            } else if let string = value as? String {
                seconds = GeneratedSummary.seconds(fromTimecode: string)
            } else {
                seconds = nil
            }
            guard let seconds, seconds >= 0 else { return nil }
            // A little past the end, because the last line starts before the
            // recording stops and a duration rounds down.
            if durationSeconds > 0, seconds > durationSeconds + 60 { return nil }
            return seconds
        }
        func items(_ value: Any?) -> [GeneratedSummary.Item] {
            var seen = Set<String>()
            return ((value as? [[String: Any]]) ?? []).compactMap { entry in
                let body = text(entry["text"])
                guard !body.isEmpty, seen.insert(body.lowercased()).inserted else { return nil }
                return GeneratedSummary.Item(text: body, at: time(entry["at"]))
            }
        }
        let topics = ((object["topics"] as? [[String: Any]]) ?? []).compactMap { entry -> GeneratedSummary.Topic? in
            let title = text(entry["title"])
            let points = ((entry["points"] as? [Any]) ?? []).map(text).filter { !$0.isEmpty }
            var seenTasks = Set<String>()
            let actions = ((entry["action_items"] as? [[String: Any]]) ?? []).compactMap {
                task -> GeneratedSummary.ActionItem? in
                let body = text(task["task"])
                let owner = text(task["owner"])
                guard !body.isEmpty, body.lowercased() != owner.lowercased(),
                    seenTasks.insert(body.lowercased()).inserted
                else { return nil }
                return GeneratedSummary.ActionItem(
                    task: body, owner: owner, due: text(task["due"]), at: time(task["at"])
                )
            }
            let topic = GeneratedSummary.Topic(
                title: title, at: time(entry["at"]), points: points,
                decisions: items(entry["decisions"]), actionItems: actions,
                openQuestions: items(entry["open_questions"])
            )
            let isEmpty =
                title.isEmpty && points.isEmpty && topic.decisions.isEmpty && actions.isEmpty
                && topic.openQuestions.isEmpty
            return isEmpty ? nil : topic
        }
        return GeneratedSummary(overview: text(object["overview"]), topics: topics)
    }

    /// Reads the folder answers, keeping the two best and dropping anything
    /// malformed. A model that returns six is answering a different question
    /// from the one asked, and the matcher only ever looks at two.
    static func folderCandidates(from value: Any?) -> [ModelFolderCandidate] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry -> ModelFolderCandidate? in
            guard let folder = entry["folder"] as? String, !folder.isEmpty,
                let confidence = entry["confidence"] as? Double
            else { return nil }
            return ModelFolderCandidate(
                folderName: folder,
                confidence: min(max(confidence, 0), 1),
                why: (entry["why"] as? String) ?? "",
                quote: entry["quote"] as? String,
                atSeconds: entry["at_seconds"] as? Double
            )
        }
        .sorted { $0.confidence > $1.confidence }
        .prefix(2)
        .map { $0 }
    }
}
