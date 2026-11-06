import AppKit
import PipitCore
import PipitServices
import SwiftUI

/// One meeting: what it was, who was in it, and what was said.
///
/// The header and the speaker strip stay put while the transcript scrolls, so
/// changing who said what is one click away from any line rather than a scroll
/// back to a card at the top.
///
/// Laid out for a window a quarter of the screen in size: the tabs share the
/// title bar line, the header is two lines, and the recording is docked at the
/// bottom, so the transcript gets most of the height.
public struct MeetingDetailView: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel
    /// Confirms a copy for two seconds, because the clipboard says nothing.
    @State private var copied = false
    @State private var confirmingMicrophoneRedo = false
    /// Whether the pane is tall enough to open the speaker lanes by default.
    @State private var roomy = false

    public init(model: MeetingsWindowModel, detail: MeetingReviewModel) {
        self.model = model
        self.detail = detail
    }

    public var body: some View {
        VStack(spacing: 0) {
            titleBar
            Divider()
            header
            // The folder can go away under an open pane: a meeting deleted in
            // the Finder, or one folded into another. Everything on screen is
            // then the last read rather than what is on disk, and nothing else
            // here says so.
            if let message = detail.errorMessage {
                noticeBar(message)
                Divider()
            }
            if let message = detail.microphoneRedoMessage {
                noticeBar(message)
                Divider()
            }
            // Every recording of the call, not only the first: a rejoined part
            // that failed has its own failure and its own Retry.
            ForEach(Array(detail.recordings.enumerated()), id: \.element.id) { index, recording in
                if let failure = recording.processing.lastFailure {
                    failureBar(
                        failure, message: recording.processing.failureMessage ?? failure.message,
                        partNumber: detail.isSplitRecording ? index + 1 : nil,
                        meetingID: recording.id, isOutOfAttempts: recording.processing.isOutOfAttempts)
                    Divider()
                }
            }
            if detail.metadata?.processing.skippedForMissingKey == true {
                missingKeyBar
                Divider()
            }
            // Under the notices rather than over them: a meeting that did not
            // finish is the more urgent thing to read. The suggested title is
            // asked on the title's own line, so the folder offer comes first
            // here, and it quotes whichever title the meeting has.
            if let folder = model.folderSuggestion(for: detail.meetingID) {
                folderSuggestionBar(folder)
                Divider()
            }
            speakerStrip
            if let receipt = model.receipt, receipt.meetingID == detail.meetingID {
                receiptBar(receipt.text)
            }
            Divider()
            content
            // Docked at the bottom, outside the tabs, so the recording keeps
            // playing and stays in reach whichever of them is open, without
            // pushing the transcript down.
            if detail.playback.hasAudio {
                Divider()
                MeetingPlayerBar(detail: detail, roomy: roomy)
            } else if isPreparingAudio {
                Divider()
                MeetingPlayerPlaceholder()
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onGeometryChange(for: Bool.self) {
            $0.size.height >= 760
        } action: {
            roomy = $0
        }
        .onDisappear { detail.playback.pause() }
        .confirmationDialog(
            "Remove echo from your side?", isPresented: $confirmingMicrophoneRedo,
            titleVisibility: .visible
        ) {
            Button("Remove echo") { detail.redoMicrophone() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Corrections and splits on your own lines are removed.")
        }
    }

    /// Whether the recording is still to be written. It is mixed when
    /// processing finishes, and a meeting that finished without one has none
    /// to wait for.
    private var isPreparingAudio: Bool {
        guard let state = detail.metadata?.processing.state else { return false }
        return state != .complete && state != .failed
    }

    /// Redoes the microphone straight away, or after asking when that would
    /// remove corrections the user made to their own lines.
    private func requestMicrophoneRedo() {
        if detail.microphoneLineEdits > 0 {
            confirmingMicrophoneRedo = true
        } else {
            detail.redoMicrophone()
        }
    }

    // MARK: - title bar

    /// The tabs and the meeting's commands, on the line the window buttons
    /// use.
    private var titleBar: some View {
        MeetingsTitleBar {
            Spacer(minLength: 0)
            Picker("", selection: Binding(get: { model.tab }, set: { model.tab = $0 })) {
                ForEach(MeetingDetailTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer(minLength: 0)
            revealButton
            copyTranscriptButton
            moreMenu
        }
    }

    /// Shows the meeting's folder in Finder. An icon rather than "Open folder",
    /// which is already the sidebar's button for the whole archive.
    private var revealButton: some View {
        Button {
            detail.reveal()
        } label: {
            Label("Show in Finder", systemImage: "folder").labelStyle(.iconOnly)
        }
        .buttonStyle(PillButtonStyle())
        .help("Show this meeting's folder in Finder")
    }

    /// The commands used now and then: rebuilding the files, and working the
    /// speakers out again.
    private var moreMenu: some View {
        Menu {
            if detail.transcript != nil {
                Button("Rebuild transcript") { model.rebuildFocusedMeeting() }
            }
            if detail.transcript != nil, detail.canRedoMicrophone {
                Button("Remove echo") { requestMicrophoneRedo() }
            }
            if detail.transcript != nil { Divider() }
            // Only where somebody is still unnamed. With nobody to name it has
            // nothing to do.
            if detail.unnamedSpeakerCount > 0 {
                Button(suggestNamesTitle) { detail.suggestSpeakerNames() }
                    .disabled(detail.isSuggestingNames)
            }
            Menu("Re-analyze speakers") { reanalyzeItems }
                .disabled(detail.isReanalyzing)
        } label: {
            Label("More actions", systemImage: "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
        .accessibilityLabel("More actions")
    }

    // MARK: - header

    /// The title, with the folder, an unfinished state and a suggested title
    /// on the same line. Where and when the meeting was is in the title's
    /// help: the sidebar row beside it already prints it, and a line of its
    /// own under the title was most of what made the top of the pane crowded.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A hidden copy of the title sets the field's width, so what
            // follows sits right after the words, and gives way when the title
            // is longer than the room left.
            HStack(spacing: 8) {
                Text(detail.title.isEmpty ? "Title" : detail.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .padding(.trailing, 6)
                    .hidden()
                    .overlay(alignment: .leading) { titleField }
                    .help(aboutMeeting)
                folderMenu
                // A finished meeting says nothing by being finished.
                if let state = detail.metadata?.processing.state, state != .complete {
                    StageBadge(state: state)
                }
                if let suggestion = detail.titleSuggestion {
                    titleSuggestionPill(suggestion)
                }
                Spacer(minLength: 0)
            }

            if let warnings = detail.metadata?.captureWarnings, !warnings.isEmpty {
                // What went wrong while this was recorded, kept with the
                // meeting. A far end that was never captured is the usual one,
                // and a transcript read without knowing that reads as a
                // recogniser failure.
                Label(
                    CaptureWarning.message(forKey: warnings[0]),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .help(warnings.map(CaptureWarning.message(forKey:)).joined(separator: "\n"))
                .padding(.top, 4)
            }

            if detail.metadata?.cleanedMic?.echoRemains == true {
                // The other side came back through the speakers into the
                // microphone and the pass could not take it all out, so some
                // of their words may be shown as the user's.
                Label(
                    "Sound from the speakers stayed in the microphone.",
                    systemImage: "speaker.wave.2.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .help("Some of the other side's words may appear under your name.")
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var titleField: some View {
        TextField("Title", text: detail.titleBinding())
            .textFieldStyle(.plain)
            .font(.title2.weight(.semibold))
            .onSubmit { detail.save() }
    }

    /// The source, the day and the length, and for an import where its date
    /// came from: what the line under the title used to print.
    private var aboutMeeting: String {
        guard let metadata = detail.metadata else { return "" }
        var lines = [
            [
                metadata.source.displayName,
                Format.day(metadata.startedAt),
                Format.shortDuration(metadata.durationSeconds),
            ].joined(separator: " · ")
        ]
        if let source = metadata.recordedDateSource {
            // Only an imported file carries this. Where the date came from
            // decides whether the position this meeting holds in a list sorted
            // by date can be trusted, so it is said either way.
            lines.append(
                source.isOriginal
                    ? "\(source.displayName): the recording carried this date."
                    : "\(source.displayName): the file said nothing about when it was recorded."
            )
        }
        if detail.isSplitRecording {
            lines.append(
                "Recorded in \(detail.recordings.count) parts, shown in order."
            )
        }
        return lines.joined(separator: "\n")
    }

    private func failureBar(
        _ failure: ProcessingFailure, message: String, partNumber: Int?, meetingID: String,
        isOutOfAttempts: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 1) {
                Text(
                    "\(partNumber.map { "Part \($0): processing" } ?? "Processing") stopped at "
                        + failure.stage.displayName.lowercased()
                )
                .font(.callout)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            // "Anyway" only where another attempt has already given the same
            // result every time. A failure waiting or Settings clears is a plain
            // Retry.
            Button(isOutOfAttempts ? "Try again anyway" : "Retry") { detail.retry(meetingID: meetingID) }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.red.opacity(0.07))
    }

    /// Says why a meeting completed with no summary.
    ///
    /// The one stage that needs the cloud is the one stage allowed to be
    /// skipped without failing the meeting, which left no trace anywhere when a
    /// stored key went missing.
    private var missingKeyBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text("No model is set up, so summary, notes and speaker suggestions were skipped")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Open Settings") { model.openSettings() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    /// Which folder this meeting is in, and the way to change it.
    ///
    /// On the line under the title, with the rest of what the meeting is. The
    /// path itself is in the help of Reveal in Finder: printed on the line it
    /// pushed everything after it off a narrow window.
    @ViewBuilder private var folderMenu: some View {
        let current = model.rows.first { $0.id == detail.meetingID }?.summary.folderName
        let tint =
            current
            .flatMap { name in model.folderRows.first { $0.name == name } }
            .map { FolderTint.color($0.folder.tintIndex) }
        Menu {
            ForEach(model.folderRows) { folder in
                Button {
                    file(in: folder.name)
                } label: {
                    if folder.name == current {
                        Label(folder.name, systemImage: "checkmark")
                    } else {
                        Text(folder.name)
                    }
                }
            }
            if !model.folderRows.isEmpty { Divider() }
            Button("New Folder…") {
                model.pendingNewFolder = NewFolderRequest(filing: [detail.meetingID])
            }
            if current != nil {
                Button("Remove from Folder") { file(in: nil) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 9))
                Text(current ?? "Not in a folder")
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
        }
        // A pill in the folder's colour, the way the sidebar tags the same
        // folder. As a borderless menu it dropped the small size and the
        // colour and drew in large white type.
        .menuStyle(.button)
        .buttonStyle(PillButtonStyle(tint: tint ?? .secondary))
        .controlSize(.small)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filing a meeting moves its folder on disk. Nothing inside it is rewritten.")
    }

    private func file(in folder: String?) {
        guard let row = model.rows.first(where: { $0.id == detail.meetingID }) else { return }
        Task { await model.file([row], in: folder) }
    }

    /// The folder this meeting was thought to belong in.
    ///
    /// The same bar as the suggested title above it, with one difference that
    /// matters: the icon says whether a model was involved. A repeat arrow means
    /// metadata matched metadata and nothing was read.
    private func folderSuggestionBar(_ suggestion: FolderSuggestion) -> some View {
        HStack(spacing: 7) {
            Image(systemName: suggestion.reason == .model ? "sparkles" : "arrow.trianglehead.2.clockwise")
                .foregroundStyle(suggestion.reason == .model ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(suggestion.reason == .model ? "Suggested folder" : "Recurring meeting")
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Text(suggestion.folderName).layoutPriority(1)
            Text(suggestion.why)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(quoteHelp(suggestion))
            Spacer(minLength: 8)
            Button("Move it") { Task { await model.acceptFolderSuggestion(for: detail.meetingID) } }
            Button("Dismiss") { model.dismissFolderSuggestion(for: detail.meetingID) }
                .buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(
            suggestion.reason == .model
                ? Color.accentColor.opacity(0.08)
                : Color.primary.opacity(0.04)
        )
    }

    private func quoteHelp(_ suggestion: FolderSuggestion) -> String {
        guard let quote = suggestion.quote, !quote.isEmpty else { return suggestion.why }
        guard let at = suggestion.atSeconds else { return "\u{201C}\(quote)\u{201D}" }
        return "\u{201C}\(quote)\u{201D} at \(Format.duration(at))"
    }

    private func noticeBar(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.08))
    }

    private func receiptBar(_ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.caption)
            Spacer(minLength: 8)
            Button("Reveal in Finder") { detail.reveal() }.buttonStyle(.link).font(.caption)
            Button("Dismiss") { model.dismissReceipt() }.buttonStyle(.link).font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - speakers

    /// The chips on one line, by talk time. The commands that act on all of
    /// them are in the More menu; a spinner says when one of them is running.
    private var speakerStrip: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if detail.speakerRows.isEmpty {
                        Text(waitingText).font(.caption).foregroundStyle(.secondary)
                    } else {
                        SpeakerChips(model: model, detail: detail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if detail.isReanalyzing || detail.isSuggestingNames {
                    ProgressView().controlSize(.small)
                        .frame(minHeight: 26)
                        .help(detail.isReanalyzing ? "Re-analyzing speakers" : "Suggesting names")
                }
            }
            // Only where there is something to propose. A meeting whose voices
            // all matched, and one where nobody was named out loud, both draw
            // nothing here rather than a line saying so.
            if !detail.speakerSuggestions.isEmpty {
                SuggestionPills(model: model, detail: detail)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var waitingText: String {
        switch detail.metadata?.processing.state {
        case .some(.complete): "Nobody was identified in this recording."
        case .some(.failed): "Processing stopped before speakers were worked out."
        default: "Speakers appear when the transcript lands. The audio is already on disk."
        }
    }

    private var suggestNamesTitle: String {
        let count = detail.unnamedSpeakerCount
        return "Suggest names for \(count) \(count == 1 ? "speaker" : "speakers")"
    }

    /// Re-clusters the audio on this Mac. Next to Suggest names in the menu,
    /// which reads the words and sends them away instead.
    @ViewBuilder private var reanalyzeItems: some View {
        Button("Run with the count Pipit picks") {
            detail.reanalyzeCount = ""
            detail.reanalyzeSpeakers()
        }
        .disabled(!detail.localModelsReady)
        Menu("Run with a set count") {
            ForEach(2...8, id: \.self) { count in
                Button("\(count) speakers") {
                    detail.reanalyzeCount = "\(count)"
                    detail.reanalyzeSpeakers()
                }
            }
        }
        .disabled(!detail.localModelsReady)
        Divider()
        Text(
            detail.localModelsReady
                ? "The words are not transcribed again. Names on whole speakers are cleared, "
                    + "because the clusters they name no longer exist. Corrections to single "
                    + "lines are kept."
                : "Runs on this Mac. Download the speech models in Settings to use it."
        )
    }

    // MARK: - content

    /// Puts `transcript.md` on the clipboard.
    ///
    /// On the title bar line, tinted, because it is the command people use the
    /// most. It copies the whole document whichever tab is open, and that line
    /// stays on screen while the transcript scrolls.
    private var copyTranscriptButton: some View {
        Button {
            guard detail.copyTranscript() else { return }
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(2))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
        }
        .buttonStyle(PillButtonStyle(prominent: true))
        .disabled(detail.transcript == nil)
        .help("Copy transcript: the whole transcript.md as it stands on disk.")
    }

    @ViewBuilder private var content: some View {
        switch model.tab {
        case .transcript: MeetingTranscriptView(model: model, detail: detail)
        // Room under the divider the tab row used to provide.
        case .summary: MeetingSummaryTab(model: model, detail: detail).contentMargins(.top, 14, for: .scrollContent)
        }
    }
}

// MARK: - title bar

extension MeetingDetailView {
    /// The generated title, offered against the name the meeting already has.
    ///
    /// A pill right after the title rather than a bar of its own, so the
    /// question costs no height and sits beside the words it would replace.
    /// The title keeps its place when the pill appears.
    func titleSuggestionPill(_ suggestion: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            // A generated title can outrun a narrow pane, and the whole point
            // is reading it before deciding.
            Text(suggestion)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 220, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .help("Suggested title: \(suggestion)")
            // Grey, so the blue is left to Copy and Follow: this is a question
            // asked once, not the pane's main command.
            Button("Use title") { detail.acceptTitleSuggestion() }
                .buttonStyle(PillButtonStyle())
                .controlSize(.mini)
                .help("Renames this meeting, and its folder, to the suggested title.")
            Button {
                detail.declineTitleSuggestion()
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Keeps the current title and stops offering this one.")
            .accessibilityLabel("Dismiss suggested title")
        }
        .font(.caption)
        .padding(.leading, 9)
        .padding(.trailing, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Suggested title")
    }
}

/// Names the model heard, under the speakers they belong to.
///
/// A recommendation rather than an answer: the pill says who it thinks a
/// speaker is and what it heard, and nothing reaches the speaker map until
/// somebody presses the tick. Written this way round because a name filled in
/// for you is only worth having when it is right, and the one place the model
/// is asked about is the one place nothing else could work it out.
struct SuggestionPills: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text("Heard in the conversation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Dismiss all") { model.dismissAllSuggestions() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            FlowRow(spacing: 6) {
                ForEach(detail.speakerSuggestions) { row in pill(row) }
            }
        }
        .padding(.top, 3)
    }

    private func pill(_ row: MeetingSuggestionRow) -> some View {
        HStack(spacing: 6) {
            SpeakerFace(name: "", side: 20)
            Text(row.speakerLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(row.suggestion.name).font(.callout.weight(.medium))
            // The band rather than the number behind it. A model's confidence
            // reads as a probability when it is shown as a percentage, and it
            // is not one.
            Text(row.suggestion.band.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Button {
                    model.acceptSuggestion(row)
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
                .help("Name \(row.speakerLabel) as \(row.suggestion.name)")

                Button {
                    model.dismissSuggestion(row)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 21, height: 21)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help("Not this. The name is not offered again.")
            }
            .padding(.leading, 2)
        }
        .padding(.leading, 3)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background { Capsule().fill(Color.accentColor.opacity(0.09)) }
        .overlay { Capsule().stroke(Color.accentColor.opacity(0.30), lineWidth: 1) }
        .help(why(row.suggestion))
    }

    /// The line that earned the guess, which is the whole case for it.
    private func why(_ suggestion: SpeakerNameSuggestion) -> String {
        let renderer = TranscriptRenderer()
        var text = "“\(suggestion.quote)” at \(renderer.timecode(suggestion.atSeconds))"
        if suggestion.expandedFromCalendar {
            text += "\nFull name from the calendar invite."
        }
        return text
    }
}

/// The round spot at the start of a speaker chip: the speaker's face, a
/// waveform while they are speaking, and the arrow to where they speak while
/// the pointer is on the chip or the walk through their turns is on.
///
/// One spot for all three, so the chip keeps its width. An arrow added at the
/// end of the chip widened it on hover, the last chip on a line wrapped to the
/// next one and out from under the pointer, and it could not be clicked.
struct SpeakerChipBadge: View {
    enum Shows {
        case face
        case speaking(Color)
        case jump(walking: Bool)
    }

    static var side: CGFloat { 20 }

    /// Empty for a voice nobody has named.
    let name: String
    var identityID: IdentityID?
    let shows: Shows
    var playing = false
    var onJump: () -> Void = {}

    var body: some View {
        Group {
            switch shows {
            case .face:
                SpeakerFace(name: name, identityID: identityID, side: Self.side)
            case .speaking(let tint):
                Image(systemName: "waveform")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.variableColor.iterative, isActive: playing)
                    .frame(width: Self.side, height: Self.side)
                    .background(Circle().fill(tint.opacity(0.18)))
                    .accessibilityLabel("Speaking")
            case .jump(let walking):
                Button(action: onJump) {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(walking ? Color.white : Color.primary)
                        .frame(width: Self.side, height: Self.side)
                        .background(
                            Circle().fill(walking ? Color.accentColor : Color.primary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
                .help(walking ? "Next turn" : "Go to where they speak")
            }
        }
        .frame(width: Self.side, height: Self.side)
    }
}

/// One chip per speaker, each a menu that renames them everywhere in the
/// meeting.
///
/// An unnamed voice is outlined rather than left to look like the rest: it is
/// the one row in the strip that is asking for something.
///
/// One line, most talk time first. The speakers that do not fit wait behind a
/// "+N" chip, which grows the strip to as many lines as it takes and becomes
/// Show less. A strip that always wrapped took a second line for a voice heard
/// for a few seconds, and the transcript lost the height.
struct SpeakerChips: View {
    let model: MeetingsWindowModel
    let detail: MeetingReviewModel
    /// The chip under the pointer, whose arrow is showing.
    @State private var hovered: String?
    @State private var showsAll = false

    var body: some View {
        let rows = detail.speakerRows
        Group {
            if showsAll {
                FlowRow(spacing: 6) {
                    ForEach(rows) { row in chip(row) }
                    moreChip(hiding: [])
                }
                .transition(.opacity)
            } else {
                // The first that fits wins: every chip, then one fewer with a
                // "+1", and so on down to a lone "+N".
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(stride(from: rows.count, through: 0, by: -1)), id: \.self) { shown in
                        HStack(spacing: 6) {
                            ForEach(rows.prefix(shown)) { row in chip(row) }
                            if shown < rows.count { moreChip(hiding: Array(rows.dropFirst(shown))) }
                        }
                    }
                }
                .transition(.opacity)
            }
        }
        .onChange(of: detail.meetingID) { showsAll = false }
    }

    /// "+N" for the speakers out of sight, outlined orange when one of them
    /// has no name yet, since the line would otherwise hide that it is asking
    /// for something. With nothing hidden it is Show less.
    private func moreChip(hiding hidden: [MeetingSpeakerRow]) -> some View {
        let unnamed = hidden.contains(where: \.isUnnamed)
        return Button {
            withAnimation(.easeOut(duration: 0.2)) { showsAll.toggle() }
        } label: {
            Text(hidden.isEmpty ? "Show less" : "+\(hidden.count)")
                .font(.callout)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(
                    Capsule().fill(unnamed ? Color.orange.opacity(0.12) : Color.primary.opacity(0.06))
                )
                .overlay {
                    if unnamed { Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1) }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(hidden.isEmpty ? "Show the speakers on one line" : hidden.map(\.displayName).joined(separator: ", "))
        .accessibilityLabel(
            hidden.isEmpty
                ? "Show fewer speakers"
                : "\(hidden.count) more \(hidden.count == 1 ? "speaker" : "speakers")"
        )
    }

    /// The face sits outside the name's button, deliberately. The talk time is
    /// in the chip's help, so the line holds more people.
    ///
    /// A macOS borderless menu draws one element of its label and drops the
    /// rest: with the avatar inside, the name disappeared and the chip read as
    /// two letters. The menu therefore carries the name alone, and the capsule
    /// around both is what makes it one control.
    private func chip(_ row: MeetingSpeakerRow) -> some View {
        let unnamed = row.isUnnamed
        let walking = detail.isWalking(row)
        let showsArrow = walking || hovered == row.id
        let speaking = isSpeaking(row)
        let tint = PersonTint.color(identity: row.identity?.id, name: row.displayName)
        return HStack(spacing: 6) {
            SpeakerChipBadge(
                name: unnamed ? "" : row.displayName,
                identityID: row.identity?.id,
                shows: showsArrow ? .jump(walking: walking) : speaking ? .speaking(tint) : .face,
                playing: detail.playback.isPlaying,
                onJump: { detail.jump(to: row) }
            )
            Button(row.displayName) { detail.beginNaming(target(row)) }
                .buttonStyle(.plain)
                .font(.callout)
                .popover(isPresented: picking(row), arrowEdge: .bottom) {
                    PeoplePickerView(
                        people: detail.knownPeople,
                        context: detail.pickerContext,
                        model: detail.picker,
                        leaveUnnamedTitle: row.isUnnamed ? nil : "Leave unnamed",
                        onPick: { person in
                            detail.cancelNaming()
                            model.assignCluster(row, to: person)
                        },
                        onNewPerson: { name in
                            detail.cancelNaming()
                            model.assignCluster(row, toNewPerson: name)
                        },
                        onLeaveUnnamed: {
                            detail.cancelNaming()
                            model.clearCluster(row)
                        }
                    )
                }
        }
        .padding(.leading, 3)
        .padding(.trailing, 8)
        .padding(.vertical, 3)
        .background {
            Capsule().fill(
                speaking
                    ? tint.opacity(0.14)
                    : unnamed ? Color.orange.opacity(0.12) : Color.primary.opacity(0.06)
            )
        }
        .overlay {
            if speaking {
                Capsule().stroke(tint, lineWidth: 1.5)
            } else if unnamed {
                Capsule().stroke(Color.orange.opacity(0.55), lineWidth: 1)
            }
        }
        .onHover { inside in hovered = inside ? row.id : (hovered == row.id ? nil : hovered) }
        .contextMenu {
            Button("Go to First Turn") { detail.jump(to: row) }
            Button("Assign to Person…") { detail.beginNaming(target(row)) }
        }
        .help(chipDetail(row))
    }

    private func target(_ row: MeetingSpeakerRow) -> SpeakerNamingTarget {
        .cluster(row.allClusterIDs, in: row.recordingID)
    }

    /// Whether the recording is on this speaker's voice right now.
    private func isSpeaking(_ row: MeetingSpeakerRow) -> Bool {
        guard let cursor = detail.playback.cursor, cursor.isSpeaking else { return false }
        return cursor.speakerName == row.displayName && cursor.recordingID == row.recordingID
    }

    private func picking(_ row: MeetingSpeakerRow) -> Binding<Bool> {
        let id = target(row).id
        return Binding(
            get: { detail.isNaming(id) },
            set: { open in if !open, detail.isNaming(id) { detail.cancelNaming() } }
        )
    }

    /// What the automatic decision was, in words rather than a number.
    ///
    /// A cosine similarity of 0.92 is not a 92% probability: genuine matches sit
    /// between 0.72 and 0.96 and so do the hardest wrong ones, so the score is
    /// kept for diagnostics and never shown as a percentage.
    private func chipDetail(_ row: MeetingSpeakerRow) -> String {
        var parts = [Format.shortDuration(row.speechSeconds)]
        switch row.origin {
        case .human: parts.append("you set this")
        case .deterministic: parts.append("your microphone track")
        case .sensor: parts.append("named by the meeting")
        case .voiceProfile: parts.append("matched a saved voice, \(row.band.displayName.lowercased())")
        case .anonymousVoice:
            parts.append(
                row.meetingCount > 1 ? "heard in \(row.meetingCount) meetings" : "heard before"
            )
        case .ai:
            if row.identity == nil { parts.append("not recognized") }
        }
        return parts.joined(separator: " · ")
    }
}

/// A row that wraps onto the next line when it runs out of width.
///
/// SwiftUI has no wrapping stack on this deployment target, and the speaker
/// strip is the one place in the app that needs one.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = layout(subviews: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in layout(subviews: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layout(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > width {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
