import Foundation
import PipitCore

/// What a model is asked, independent of how the request is sent.
///
/// The instructions and the shape of the answer are the product's, not a
/// provider's: OpenAI's responses endpoint, a chat completions server and
/// Ollama all receive the same words and the same schema, and differ only in
/// the envelope they are wrapped in.
struct LanguageModelPrompt {
    var instructions: String
    var userContent: String
    var schemaName: String
    var schema: [String: Any]
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

    /// Nil when the request asks for nothing.
    static func enrichment(_ request: EnrichmentRequest) -> LanguageModelPrompt? {
        var properties: [String: Any] = [:]
        var required: [String] = []
        if request.wantsTitle {
            properties["title"] = ["type": "string"]
            required.append("title")
        }
        if request.wantsDescription {
            properties["description"] = ["type": "string"]
            required.append("description")
        }
        if request.wantsSummary {
            properties["summary"] = ["type": "string"]
            required.append("summary")
        }
        if request.wantsNotes {
            properties["notes"] = ["type": "string"]
            required.append("notes")
        }
        let asksAboutFolders = !request.folders.isEmpty
        if asksAboutFolders {
            properties["folder_candidates"] = [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "properties": [
                        "folder": ["type": "string"],
                        "confidence": ["type": "number"],
                        "why": ["type": "string"],
                        "quote": ["type": "string"],
                        "at_seconds": ["type": "number"],
                    ],
                    "required": ["folder", "confidence", "why", "quote", "at_seconds"],
                ],
            ]
            required.append("folder_candidates")
        }
        guard !required.isEmpty else { return nil }

        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "properties": properties,
            "required": required,
        ]
        var instructions = """
            You summarise meeting transcripts. Write plainly and specifically: state \
            what was decided, who owns what, and what happens next. The title is a \
            short noun phrase naming the meeting, under eight words, with no trailing \
            punctuation. The summary is a few short paragraphs. Notes are bullet points \
            of decisions and action items. Never invent participants, dates or figures \
            that are not in the transcript.
            """
        if asksAboutFolders {
            instructions += """
                \n\nYou also decide whether this meeting belongs in one of the user's \
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
        }
        var context =
            "Provider: \(request.provider.displayName). Duration: \(Int(request.durationSeconds / 60)) minutes."
        if asksAboutFolders {
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
                "\nThe text below is not a transcript. It is the summary and notes written for each of "
                + "\(count) consecutive parts of one meeting, in order. Combine them into one result for "
                + "the whole meeting, repeat nothing, and keep what mattered."
        }
        let label: String
        if case .partNotes = request.source { label = "Notes by part" } else { label = "Transcript" }

        return LanguageModelPrompt(
            instructions: instructions,
            userContent: "\(context)\n\n\(label):\n\(request.transcript)",
            schemaName: "meeting_enrichment",
            schema: schema
        )
    }

    /// A valid JSON object can still omit the requested output. Retry that
    /// answer instead of marking an empty enrichment as successful.
    static func acceptsEnrichment(_ object: [String: Any], for request: EnrichmentRequest) -> Bool {
        let fields = [
            ("title", request.wantsTitle), ("description", request.wantsDescription),
            ("summary", request.wantsSummary), ("notes", request.wantsNotes),
        ]
        guard fields.allSatisfy({ key, wanted in !wanted || object[key] is String }) else { return false }
        return request.folders.isEmpty || object["folder_candidates"] is [[String: Any]]
    }

    static func enrichment(from object: [String: Any]) -> MeetingEnrichment {
        MeetingEnrichment(
            title: object["title"] as? String,
            summary: object["summary"] as? String,
            description: object["description"] as? String,
            notes: object["notes"] as? String,
            folderCandidates: folderCandidates(from: object["folder_candidates"])
        )
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
