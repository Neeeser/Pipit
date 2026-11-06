import PipitCore
import SwiftUI

/// The people window: everyone Pipit can recognise on the left, one of them
/// on the right.
///
/// Replaces a flat list in a settings tab, which held every person and every
/// unnamed voice in one scroll with no search, no grouping and nothing that
/// could act on more than one row.
public struct PeopleDirectoryView: View {
    let model: PeopleDirectoryModel
    @FocusState private var searchFocused: Bool

    public init(model: PeopleDirectoryModel) {
        self.model = model
    }

    public var body: some View {
        // The system split view, as in the Meetings and Settings windows, so
        // the list is the standard floating sidebar.
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 240, ideal: 264, max: 360)
        } detail: {
            detail.frame(minWidth: 380).toolbarTitle("People")
        }
        .frame(minWidth: 820, minHeight: 520)
        // The search field takes the keys when the window opens, so typing
        // finds a person rather than renaming the one shown.
        .defaultFocus($searchFocused, true)
        .task {
            searchFocused = true
            await model.reload()
        }
        .alert(
            model.pendingAction?.title ?? "",
            isPresented: Binding(
                get: { model.pendingAction != nil },
                set: { if !$0 { model.pendingAction = nil } }
            )
        ) {
            // Captured here, while the alert still has one. The button's action
            // runs after the dismissal has cleared `pendingAction`, so reading
            // it back there finds nothing and the confirmation does nothing.
            let action = model.pendingAction
            Button("Cancel", role: .cancel) { model.pendingAction = nil }
            Button(action?.confirmLabel ?? "Delete", role: .destructive) {
                guard let action else { return }
                Task { await model.perform(action) }
            }
        } message: {
            Text(model.pendingAction?.message ?? "")
        }
        .sheet(
            isPresented: Binding(
                get: { model.organizationPrompt != nil },
                set: { if !$0 { model.organizationPrompt = nil } }
            )
        ) {
            organizationSheet
        }
        .sheet(
            isPresented: Binding(
                get: { model.enrollment != nil },
                set: { showing in
                    // Escape dismisses the sheet without pressing anything in
                    // it, and the microphone has to close either way.
                    if !showing {
                        model.enrollment?.cancel()
                        model.enrollment = nil
                    }
                }
            )
        ) {
            if let enrollment = model.enrollment {
                VoiceEnrollmentView(model: enrollment) { model.enrollment = nil }
            }
        }
        .sheet(
            isPresented: Binding(
                get: { model.lookAgain != nil },
                set: { if !$0 { model.lookAgain = nil } }
            )
        ) {
            if let state = model.lookAgain {
                LookAgainView(model: model, state: state) { model.lookAgain = nil }
            }
        }
    }

    // MARK: - sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("Search", text: model.text(\.query))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($searchFocused)
                }
                .sidebarSearchField()
                Picker(
                    "",
                    selection: Binding(
                        get: { model.filter }, set: { model.filter = $0 }
                    )
                ) {
                    ForEach(PeopleFilter.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            list
            Divider()
            footer
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if model.visibleCount == 0 {
                    Text(
                        model.entries.isEmpty
                            ? "No people"
                            : "No matches"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                }
                ForEach(model.sections) { section in
                    Text(section.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                    ForEach(section.entries) { entry in row(entry) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func row(_ entry: SpeakerDirectoryEntry) -> some View {
        let selected = model.selection.contains(entry.id)
        return HStack(spacing: 8) {
            PersonAvatar(identity: entry.identity, image: model.avatarImage(for: entry))
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.identity.resolvedName)
                        .font(.callout)
                        .lineLimit(1)
                    // The row is the person at this Mac. The section heading
                    // says so too, but a name is what a reader looks at, and
                    // scrolled past the heading the row is just another name.
                    if entry.identity.isLocalUser {
                        Text("You")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.20))
                            )
                            .foregroundStyle(Color.accentColor)
                    }
                }
                Text(rowSubtitle(entry))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            profileDot(entry.profile)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.18) : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            model.select(entry.id, extending: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu { menu(entry) }
    }

    /// What a right-click offers. The same actions the footer menu holds, on
    /// the row under the pointer. It acts on the whole selection when that row
    /// is part of it, and on that row alone otherwise.
    @ViewBuilder private func menu(_ entry: SpeakerDirectoryEntry) -> some View {
        let targets = model.contextTargets(for: entry)
        if targets.count == 1, model.canBeYou(entry) {
            // The row the microphone track built and the row Slack named are
            // one person. Merging them is what puts the mic-track voice and the
            // platform's name on one profile.
            Button("This Is Me") { Task { await model.makeYou(entry) } }
            Divider()
        }
        Button("Set Organization…") { model.beginSetOrganization(targets) }
        if targets.count == 1 {
            Button("Forget Voice…") { model.confirmForgetVoice(of: entry) }
                .disabled(targets[0].profile == .none)
        }
        if targets.count == 2 {
            Button("Merge People") { Task { await model.merge(targets) } }
        }
        Divider()
        Button(
            targets.count == 1 ? "Delete…" : "Delete \(targets.count) People…",
            role: .destructive
        ) {
            model.confirmDelete(targets)
        }
    }

    private func rowSubtitle(_ entry: SpeakerDirectoryEntry) -> String {
        entry.meetingCount == 1 ? "1 meeting" : "\(entry.meetingCount) meetings"
    }

    /// How much verified voice material stands behind this person, at a glance.
    @ViewBuilder private func profileDot(_ status: VoiceProfileStatus) -> some View {
        switch status {
        case .none:
            Circle().strokeBorder(.tertiary, lineWidth: 1).frame(width: 7, height: 7)
        case .learning:
            Circle().fill(.orange).frame(width: 7, height: 7)
        case .ready:
            Circle().fill(.green).frame(width: 7, height: 7)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text("\(model.visibleCount) of \(model.entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button("Set Organization…") { model.beginSetOrganization() }
                    .disabled(model.selection.isEmpty)
                Button("Merge People") { Task { await model.mergeSelection() } }
                    .disabled(!model.canMerge)
                // Above the deletions on purpose. The voices a purge takes are
                // the ones this offers to name, so the chance to keep one comes
                // before the way to throw it away.
                Button("Find Matches…") {
                    Task { await model.lookAgainForMatches() }
                }
                Divider()
                Button(
                    "Delete \(model.purgeCandidates.count) Unnamed "
                        + "\(model.purgeCandidates.count == 1 ? "Person" : "People") Heard Once…"
                ) {
                    model.confirmPurge()
                }
                .disabled(model.purgeCandidates.isEmpty)
                Button("Delete Selected", role: .destructive) { model.confirmDeleteSelection() }
                    .disabled(model.selection.isEmpty)
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    // MARK: - detail

    @ViewBuilder private var detail: some View {
        if model.selection.count > 1 {
            PeopleSelectionSummary(model: model)
        } else if let entry = model.focused {
            PersonDetailView(model: model, entry: entry)
        } else {
            Text("No Person Selected").font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var organizationSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                model.organizationPrompt.map {
                    $0.targets.count == 1
                        ? "Organization" : "Organization for \($0.targets.count) people"
                } ?? "Organization"
            )
            .font(.headline)
            TextField(
                "Organization",
                text: Binding(
                    get: { model.organizationPrompt?.draft ?? "" },
                    set: { model.organizationPrompt?.draft = $0 }
                )
            )
            .frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { model.organizationPrompt = nil }
                Button("Save") {
                    guard let prompt = model.organizationPrompt else { return }
                    Task { await model.commitOrganization(prompt) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
    }
}

/// What several selected people can be told to do: a count and one row of
/// buttons, centred in the pane, the same shape as several selected meetings.
struct PeopleSelectionSummary: View {
    let model: PeopleDirectoryModel

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: -10) {
                ForEach(model.selectedEntries.prefix(3)) { entry in
                    PersonAvatar(identity: entry.identity, image: model.avatarImage(for: entry), side: 44)
                        .overlay(Circle().stroke(Color(nsColor: .textBackgroundColor), lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
            Text("\(model.selection.count) people").font(.title2.weight(.semibold))
            HStack(spacing: 8) {
                Button("Merge") { Task { await model.mergeSelection() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canMerge)
                    .help(model.canMerge ? "Merge into one person" : "Select two people to merge")
                Button("Set Organization…") { model.beginSetOrganization() }
                Button("Delete…", role: .destructive) { model.confirmDeleteSelection() }
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
