import AppKit
import EventKit
import Foundation
import UniformTypeIdentifiers
import PipitAudio
import PipitCore
import PipitIntegrations
import PipitServices
import PipitUI
import SwiftUI
import Testing

/// Builds each window's view tree and forces a layout pass.
///
/// This is not a pixel test. It catches the failures that otherwise only appear
/// when a user opens a panel: a view that traps on a nil, a binding that reads a
/// meeting that no longer exists, a model that crashes on an empty archive.
@Suite("UI")
struct UITests {
    @Test("every panel builds and lays out")
    func everyPanelBuildsAndLaysOut() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        await MainActor.run {
            NSApplication.shared.setActivationPolicy(.prohibited)

            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = root.appendingPathComponent("Meetings").path
            runtime.update(settings: settings)

            // Every setup step, on a machine with no permissions granted
            // and no models on disk. Rendered one at a time because the
            // wizard only builds the step it is showing, so a trap in a
            // later step would otherwise never be reached here.
            let setup = SetupModel(runtime: runtime, install: { _, _ in })
            for step in SetupStepID.allCases {
                setup.jump(to: step)
                ViewFixtures.render(SetupWizardView(model: setup, onFinish: {}))
            }
            // Settings, including the tabs that read live audio state.
            ViewFixtures.render(SettingsView(model: SettingsModel(runtime: runtime)))
            // Nothing is asserted here. Reaching this line means the panels
            // built without trapping.
        }
        try? FileManager.default.removeItem(at: root)
    }

    @Test("the reading script covers the sounds it claims to")
    func theReadingScriptCoversTheSoundsItClaimsTo() async throws {
        await MainActor.run {
            // The Harvard sentences, IEEE 297-1969: phonetically balanced,
            // ten to a list. A duplicate or a truncated line means somebody
            // edited the standard set by hand, which is the one thing that
            // makes it stop being the standard set.
            let sentences = VoiceEnrollmentScript.allSentences
            #expect(sentences.count == 30, "three lists of ten")
            #expect(Set(sentences).count == 30, "no sentence twice")
            #expect(
                sentences.allSatisfy { $0.hasSuffix(".") && $0.count > 20 },
                "every line is a whole sentence"
            )
            #expect(VoiceEnrollmentScript.lists.allSatisfy { $0.sentences.count == 10 })
            // Enough words that somebody reading quickly still reaches the
            // bar: the reading is refused below 45 seconds of speech, and
            // 200 words a minute is a fast reader.
            let words = sentences.joined(separator: " ").split(separator: " ").count
            #expect(
                Double(words) / 200 * 60 >= VoiceEnrollmentModel.targetSeconds,
                "\(words) words is \(Int(Double(words) / 200 * 60))s at a fast pace, under the \(Int(VoiceEnrollmentModel.targetSeconds))s target"
            )
            #expect(!VoiceEnrollmentScript.prompts.isEmpty)
        }
    }

    @Test("the people window builds with somebody on screen")
    func thePeopleWindowBuildsWithSomebodyOnScreen() async throws {
        try await Self.peopleWindowBuilds()
    }

    @Test("the dragged application is offered as a file URL")
    func theDraggedApplicationIsOfferedAsAFileURL() async throws {
        // The drag adds Pipit to the Accessibility and Screen Recording
        // lists, which is the fast route into panes that have no prompt.
        // Built with NSItemProvider(contentsOf:) it registered nothing
        // usable, because that wants a readable file and an application is
        // a directory: the drag picked up, dropped, and did nothing.
        let bundle = URL(fileURLWithPath: "/Applications/Safari.app")
        let provider = ApplicationIdentity.dragItemProvider(for: bundle)
        #expect(
            provider.registeredTypeIdentifiers.contains(UTType.fileURL.identifier),
            "a drop target that takes files sees nothing without public.file-url: \(provider.registeredTypeIdentifiers)"
        )
        #expect(provider.suggestedName == "Safari.app")

        let loaded: URL? = await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url)
            }
        }
        #expect(loaded == bundle, "and it resolves back to the bundle")
    }

    @Test("calendar access is believed over EventKit's own status")
    func calendarAccessIsBelievedOverEventKitSOwnStatus() async throws {
        // Observed on macOS 27: requestFullAccessToEvents called back with
        // granted = true, System Settings listed Pipit under Calendars
        // with Full Access, and EKEventStore.authorizationStatus went on
        // reporting notDetermined for the rest of the process's life. The
        // wizard step never went green, and events(around:) returned
        // nothing, so a meeting recorded in that session got no calendar
        // title and no attendees.
        #expect(
            PermissionsService.calendarState(reported: .notDetermined, canReadCalendars: true) == .granted,
            "a store that can read calendars settles it"
        )
        #expect(
            PermissionsService.calendarState(reported: .notDetermined, canReadCalendars: false) == .notDetermined,
            "and one that cannot has genuinely not been asked"
        )

        // A refusal is a refusal. The probe never overrides it, or a
        // denied permission would read as granted off an empty answer.
        #expect(
            PermissionsService.calendarState(reported: .denied, canReadCalendars: true) == .denied
        )
        #expect(
            PermissionsService.calendarState(reported: .writeOnly, canReadCalendars: true) == .denied,
            "write-only cannot read the events the matcher needs"
        )
        #expect(
            PermissionsService.calendarState(reported: .fullAccess, canReadCalendars: false) == .granted,
            "and the supported answer is trusted when it is positive"
        )
    }

    @Test("setup moves to whichever side of System Settings has room")
    func setupMovesToWhicheverSideOfSystemSettingsHasRoom() async throws {
        // The wizard floats, so it stays readable while the user works in
        // System Settings. Floating also puts it on top of the pane it is
        // describing, which is worse than sinking was.
        let screen = CGRect(x: 0, y: 0, width: 1_800, height: 1_100)
        let size = CGSize(width: 760, height: 580)

        // Settings on the left, so the wizard goes right.
        let left = CGRect(x: 0, y: 0, width: 740, height: 1_100)
        let placedRight = SetupWindowPlacement.frame(
            for: size, avoiding: left, within: screen
        )
        #expect(!placedRight.intersects(left), "must not cover the pane")
        #expect(placedRight.maxX <= screen.maxX, "and must stay on screen")

        // Settings on the right, so the wizard goes left.
        let right = CGRect(x: 1_060, y: 0, width: 740, height: 1_100)
        let placedLeft = SetupWindowPlacement.frame(
            for: size, avoiding: right, within: screen
        )
        #expect(!placedLeft.intersects(right))
        #expect(placedLeft.minX >= screen.minX)

        // A screen too narrow to hold both: staying on screen wins over
        // not overlapping, since a window pushed off the display cannot
        // be read at all.
        let narrow = CGRect(x: 0, y: 0, width: 1_000, height: 1_100)
        let middle = CGRect(x: 130, y: 0, width: 740, height: 1_100)
        let squeezed = SetupWindowPlacement.frame(
            for: size, avoiding: middle, within: narrow
        )
        #expect(squeezed.minX >= narrow.minX, "left edge stays on screen")
        #expect(squeezed.maxX <= narrow.maxX, "and so does the right edge")
    }

    @Test("window-server rectangles are flipped into AppKit coordinates")
    func windowServerRectanglesAreFlippedIntoAppKitCoordinates() async throws {
        // The window list measures from the top left of the primary
        // display and AppKit from the bottom left. Skipping the flip put
        // the wizard off the bottom of the screen on any tall display.
        let measured: (x: CGFloat, maxY: CGFloat, screenTop: CGFloat)? = await MainActor.run {
            guard let primary = NSScreen.screens.first else { return nil }
            let topOfScreen = CGRect(x: 10, y: 0, width: 300, height: 200)
            let flipped = SetupWindowPlacement.flipped(topOfScreen)
            return (flipped.minX, flipped.maxY, primary.frame.maxY)
        }
        guard let measured else {
            Issue.record("no screen")
            return
        }
        #expect(measured.x == 10, "x is unchanged")
        #expect(
            measured.maxY == measured.screenTop,
            "a window at the top in window-server coordinates is at the top in AppKit"
        )
    }

    @Test("setup never touches the keychain on the local path")
    func setupNeverTouchesTheKeychainOnTheLocalPath() async throws {
        // Asking whether a key is stored can raise the keychain password
        // prompt: a login-keychain item enforces its access control on the
        // search as well as on the read, so a build re-signed since the
        // item was created is no longer trusted by it. Asked from begin(),
        // that dialog appeared over the wizard on every open, for every
        // user, including everyone who stays on the local default and has
        // no key at all.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let lookups = Counter()
        let model = await MainActor.run {
            SetupModel(
                runtime: PipitRuntime(settingsDirectory: root),
                keyPresence: { await lookups.bump(); return true },
                // Choosing a backend starts the download for that
                // choice. With the real one this test fetched the
                // aligner from HuggingFace to answer a question about
                // the keychain.
                install: { _, _ in }
            )
        }

        await model.lookUpStoredKeyIfNeeded()
        #expect(await lookups.value == 0, "the local default must never ask the keychain anything")

        await MainActor.run { model.chooseBackend(.openAI) }
        await model.lookUpStoredKeyIfNeeded()
        #expect(await lookups.value == 1, "choosing cloud is what asks")

        await model.lookUpStoredKeyIfNeeded()
        #expect(await lookups.value == 1, "and it is asked once, not per redraw")
    }

    @Test("the meetings window handles a meeting with nothing processed yet")
    func theMeetingsWindowHandlesAMeetingWithNothingProcessedYet() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = MeetingRepository(root: root.appendingPathComponent("Meetings"))
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "Engineering huddle", timestampFallback: "f"),
            now: started
        )

        await MainActor.run {
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = root.appendingPathComponent("Meetings").path
            runtime.update(settings: settings)

            let window = MeetingsWindowModel(runtime: runtime)
            window.show(meetingID: created.metadata.id)
            guard let model = window.detail else {
                Issue.record("the window opened no meeting")
                return
            }
            #expect(model.title == "Engineering huddle")
            #expect(model.transcript == nil, "nothing has been transcribed yet")
            ViewFixtures.render(MeetingsWindowView(model: window), size: NSSize(width: 1_120, height: 720))

            // Editing the title while processing has not started must stick.
            model.title = "Q3 planning"
            model.save()
            #expect(
                repository.findMeeting(id: created.metadata.id)?.metadata.displayTitle == "Q3 planning"
            )
        }
    }

    @Test("reconciling the login item does nothing when it already matches")
    func reconcilingTheLoginItemDoesNothingWhenItAlreadyMatches() async throws {
        // The setting was stored, shown and read by nothing, so the
        // toggle did nothing. Registration itself is a call into
        // launchd and is verified by hand; what is testable is that an
        // unchanged state asks for no work, which matters because
        // registering an already-registered item throws and this runs
        // on every settings change.
        #expect(LoginItem.action(wanted: true, isRegistered: true) == nil)
        #expect(LoginItem.action(wanted: false, isRegistered: false) == nil)
        #expect(LoginItem.action(wanted: true, isRegistered: false) == .register)
        #expect(LoginItem.action(wanted: false, isRegistered: true) == .unregister)
    }

    @Test("a speaker who never speaks is not offered for naming")
    func aSpeakerWhoNeverSpeaksIsNotOfferedForNaming() async throws {
        // A cloud-diarized meeting listed eleven speakers, six of them
        // showing 0s: labels the diarizer emitted that own no words.
        // There is nothing a user can do with those rows.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Meetings")
        let repository = MeetingRepository(root: archive)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .inPerson, provider: .unknown, startedAt: started,
            titles: TitleCandidates(provider: "Workshop", timestampFallback: "f"),
            now: started
        )
        func utterance(key: String, start: Double, end: Double) -> Utterance {
            Utterance(
                id: Utterance.identifier(
                    chunkID: "mic_chunk_001", track: .mic, start: start, end: end
                ),
                start: start, end: end, track: .mic,
                rawSpeakerLabel: key, speakerKey: key, text: "Morning.",
                chunkID: "mic_chunk_001", model: "test"
            )
        }
        try created.store.writeCanonicalTranscript(CanonicalTranscript(
            generatedAt: started,
            utterances: [
                utterance(key: "mic_chunk_001_speaker_00", start: 0, end: 6),
                utterance(key: "mic_chunk_001_speaker_01", start: 7, end: 7),
            ]
        ))

        let model = await MainActor.run { () -> MeetingReviewModel in
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = archive.path
            runtime.update(settings: settings)
            return MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
        }
        await model.reloadSpeakers()
        await MainActor.run {
            #expect(model.speakerRows.count == 1, "the silent cluster is not a row")
            #expect(model.speakerRows[0].clusterID == "mic_chunk_001_speaker_00")
            // Hidden for display only. The transcript still holds it.
            #expect(model.transcript?.speakerKeys.count == 2)
        }
    }

    @Test("closing the panel does not overwrite a note added elsewhere")
    func closingThePanelDoesNotOverwriteANoteAddedElsewhere() async throws {
        // The menu bar appends a quick note straight to the file. The
        // panel holds whatever it read when it opened, and writes the
        // whole file on close, so an unconditional write threw the
        // appended note away.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Meetings")
        let repository = MeetingRepository(root: archive)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "Standup", timestampFallback: "f"),
            now: started
        )

        await MainActor.run {
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = archive.path
            runtime.update(settings: settings)
            let model = MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
            #expect(model.notes == "")

            try? created.store.appendNote("ship on Friday", at: started)
            model.saveNotes()
            #expect(
                created.store.readNotes().contains("ship on Friday"),
                "the panel typed nothing, so it writes nothing"
            )

            // What the user did type still saves.
            model.notes = "my own note"
            model.saveNotes()
            #expect(created.store.readNotes() == "my own note")
        }
    }

    @Test("typing a title or a note reaches disk without closing the panel")
    func typingATitleOrANoteReachesDiskWithoutClosingThePanel() async throws {
        // Both were written only when the panel closed, under a card
        // that says editing is saved immediately, and the title only
        // when Return was pressed. onDisappear does not run on
        // termination, so quitting with the panel open lost everything
        // typed into it.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Meetings")
        let repository = MeetingRepository(root: archive)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let created = try repository.createMeeting(
            source: .manual, provider: .unknown, startedAt: started,
            titles: TitleCandidates(timestampFallback: "Manual"), now: started
        )

        let model = await MainActor.run { () -> MeetingReviewModel in
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = archive.path
            runtime.update(settings: settings)
            let model = MeetingReviewModel(runtime: runtime, meetingID: created.metadata.id)
            model.titleBinding().wrappedValue = "Frankfurt cutover"
            model.notesBinding().wrappedValue = "Chris owns the runbook"
            return model
        }
        _ = model

        var savedNotes = ""
        var savedTitle: String?
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            savedNotes = created.store.readNotes()
            savedTitle = (try? created.store.readMetadata())?.titles.human
            if !savedNotes.isEmpty, savedTitle != nil { break }
        }
        #expect(savedNotes == "Chris owns the runbook")
        #expect(savedTitle == "Frankfurt cutover")
    }

    @Test("the panel resolves the archive once, not on every render")
    func thePanelResolvesTheArchiveOnceNotOnEveryRender() async throws {
        // The panel body reads the processing fraction beside the
        // meeting's own paths, so anything computed there runs on every
        // tick. Local diarization reports hundreds of times in a few
        // seconds, and `findMeeting` walks the archive root, every year
        // and month directory below it, and decodes a metadata.json,
        // all on the actor that arms the next recording.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Meetings")
        let repository = MeetingRepository(root: archive)
        let started = Date(timeIntervalSince1970: 1_787_070_000)
        let earlier = try repository.createMeeting(
            source: .slackHuddle, provider: .slack, startedAt: started,
            titles: TitleCandidates(provider: "Standup", timestampFallback: "f"),
            now: started
        )
        let later = try repository.createMeeting(
            source: .slackHuddle, provider: .slack,
            startedAt: started.addingTimeInterval(900),
            titles: TitleCandidates(provider: "Standup", timestampFallback: "f"),
            now: started.addingTimeInterval(900)
        )
        var metadata = later.metadata
        metadata.possibleContinuationOf = earlier.metadata.id
        metadata.possibleContinuationReason = "same meeting, 15 minutes later"
        try later.store.writeMetadata(metadata)

        await MainActor.run {
            let runtime = PipitRuntime(settingsDirectory: root)
            var settings = runtime.settings
            settings.storageRootPath = archive.path
            runtime.update(settings: settings)

            let model = MeetingReviewModel(runtime: runtime, meetingID: metadata.id)
            #expect(model.directory != nil, "the reload resolved where it lives")
            #expect(model.continuationSuggestion?.title == "Standup")

            // With the archive gone, anything still walking it answers
            // nil. Both of these were computed properties reached from
            // the body, so this is the read the progress tick paid for.
            try? FileManager.default.removeItem(at: archive)
            #expect(
                model.directory != nil,
                "the panel's paths come from the last read, not from a fresh archive walk"
            )
            #expect(
                model.continuationSuggestion?.title == "Standup",
                "and so does the continuation it offers"
            )
        }
    }

    @Test("menu-bar state reads correctly in each phase")
    func menuBarStateReadsCorrectlyInEachPhase() async throws {
        var status = RuntimeStatus()
        #expect(!status.isRecording)
        #expect(status.displayHealth == .idle)

        status.sessionState = .recording
        status.startedAt = Date().addingTimeInterval(-125)
        status.health = CaptureHealthSnapshot(mic: .healthy, remote: .idleButBound)
        #expect(status.isRecording)
        #expect(status.displayHealth == .healthy)
        #expect(
            abs((status.elapsed(now: Date())) - 125) <= 2,
            "expected \(125) ± \(2), got \((status.elapsed(now: Date())))"
        )
        #expect(Format.duration(125) == "02:05")

        // A failing required source is never displayed as healthy.
        status.health = CaptureHealthSnapshot(mic: .failed, remote: .healthy)
        #expect(status.displayHealth == .failed)

        // The reconnect window is not recording: segments are closed and
        // capture waits in memory, so the menu shows a distinct state.
        status.sessionState = .reconnecting
        #expect(!status.isRecording)
        #expect(status.isInReconnectWindow)
        #expect(status.hasActiveSession)

        status.sessionState = .idle
        #expect(status.displayHealth == .idle, "an idle session shows no health")
    }

    @Test("the Firefox card reads the connection and what the build carries")
    func theFirefoxCardReadsTheConnectionAndWhatTheBuildCarries() async throws {
        #expect(
            FirefoxAddOnState(
                connection: .fresh, isInProfile: true, hasBundledAddOn: true
            ) == .reporting
        )
        #expect(
            FirefoxAddOnState(
                connection: .stale, isInProfile: true, hasBundledAddOn: true
            ) == .installed,
            "a held connection with no meeting on screen is installed and idle"
        )
        #expect(
            FirefoxAddOnState(
                connection: .stale, isInProfile: false, hasBundledAddOn: false
            ) == .installed,
            "a temporary add-on is on no profile's disk and still installed"
        )
        #expect(
            FirefoxAddOnState(
                connection: .disconnected, isInProfile: true, hasBundledAddOn: true
            ) == .connecting,
            "restarting Pipit drops the connection of an add-on that is still there"
        )
        #expect(
            FirefoxAddOnState(
                connection: .absent, isInProfile: false, hasBundledAddOn: true
            ) == .missing,
            "nothing installed, and this build has one to offer"
        )
        #expect(
            FirefoxAddOnState(
                connection: .absent, isInProfile: false, hasBundledAddOn: false
            ) == .unavailable,
            "nothing installed, and there is nothing to install"
        )
        #expect(FirefoxAddOnState.connecting.isInstalled)
        #expect(!FirefoxAddOnState.missing.isInstalled)
    }

    @Test("the add-on warning is for one that was dropped, not one never installed")
    func theAddOnWarningIsForOneThatWasDroppedNotOneNeverInstalled() async throws {
        var status = RuntimeStatus()
        status.isFirefoxRunning = true
        status.sensorConnection = .absent
        #expect(
            !status.sensorNeedsAttention,
            "a machine that never had the add-on is not missing anything"
        )

        status.firefoxSensorHasConnected = true
        #expect(
            status.sensorNeedsAttention,
            "it worked before and Firefox is open, so it was dropped"
        )

        status.sensorConnection = .stale
        #expect(
            !status.sensorNeedsAttention,
            "a held connection with no meeting on screen is the ordinary state"
        )

        status.sensorConnection = .fresh
        #expect(!status.sensorNeedsAttention)

        status.sensorConnection = .disconnected
        #expect(status.sensorNeedsAttention, "the transport dropped")

        status.firefoxAddOnInProfile = true
        #expect(
            !status.sensorNeedsAttention,
            "an add-on still in the profile is between connections, not gone"
        )
        status.firefoxAddOnInProfile = false

        status.isFirefoxRunning = false
        #expect(!status.sensorNeedsAttention, "nothing to fix while Firefox is closed")
    }

    @Test("menu-bar icons identify the Pipit state")
    func menuBarIconsIdentifyThePipitState() async throws {
        await MainActor.run {
            var status = RuntimeStatus()
            #expect(MenuBarController.iconAssetName(for: status) == "pipit-idle")

            status.sessionState = .recording
            status.health = CaptureHealthSnapshot(mic: .healthy, remote: .idleButBound)
            #expect(MenuBarController.iconAssetName(for: status) == "pipit-recording")
            #expect(
                MenuBarController.iconTintColor(for: status) == nil,
                "recording follows the menu bar's light-on-dark template colour"
            )

            status.health = CaptureHealthSnapshot(mic: .failed, remote: .healthy)
            #expect(MenuBarController.iconAssetName(for: status) == "pipit-warning")

            status.sessionState = .reconnecting
            #expect(MenuBarController.iconAssetName(for: status) == "pipit-paused")

            status.sessionState = .idle
            status.detectionPaused = true
            #expect(MenuBarController.iconAssetName(for: status) == "pipit-paused")
        }
    }

    @Test("a missing grant turns the whole icon red until the grant is seen")
    func aMissingGrantTurnsTheWholeIconRedUntilTheGrantIsSeen() async throws {
        await MainActor.run {
            var status = RuntimeStatus()
            #expect(!MenuBarController.iconIsRed(for: status))

            status.permissionNotice = PermissionNotice(missing: [.microphone])
            #expect(MenuBarController.iconIsRed(for: status))
            #expect(
                MenuBarController.iconTintColor(for: status) == nil,
                "the red is baked into the image, not tinted"
            )
            #expect(
                !MenuBarController.iconIsBadged(for: status),
                "no hole is cut through the bird for the mark"
            )

            // Red outranks the reconnect orange, and stays on through a
            // recording whose far end is missing.
            status.sessionState = .reconnecting
            status.permissionNotice = PermissionNotice(missing: [.screenRecording])
            #expect(MenuBarController.iconIsRed(for: status))
            #expect(MenuBarController.iconTintColor(for: status) == nil)

            status.permissionNotice = nil
            #expect(!MenuBarController.iconIsRed(for: status))
            #expect(MenuBarController.iconTintColor(for: status) == .systemOrange)
        }
    }

    @Test("settings survive a round trip through disk")
    func settingsSurviveARoundTripThroughDisk() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)
        #expect(store.load().localUserName == "Me", "defaults apply to a fresh install")

        var settings = AppSettings()
        settings.localUserName = "Andrew"
        settings.providers.zoom = ProviderPolicy(autoStart: .never, autoStop: false)
        settings.enrichment.generateSummary = false
        settings.alwaysRecordApplications = ["com.example.videochat"]
        try store.save(settings)

        let reloaded = SettingsStore(directory: root).load()
        #expect(reloaded.localUserName == "Andrew")
        #expect(reloaded.providers.zoom.autoStart == .never)
        #expect(!reloaded.enrichment.generateSummary)
        #expect(reloaded.alwaysRecordApplications == ["com.example.videochat"])
        // The API key is never in settings; it lives in the keychain.
        let raw = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!raw.contains("apiKey"))
        #expect(!raw.lowercased().contains("sk-"))
    }

    @Test("the Dock icon is off unless a settings file asks for it")
    func theDockIconIsOffUnlessASettingsFileAsksForIt() async throws {
        // A menu-bar utility that takes a Dock slot on upgrade is a
        // visible change nobody asked for, so an absent key reads as
        // off rather than as the platform default for an app.
        let older = #"{"version": 3, "localUserName": "Andrew"}"#
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(older.utf8))
        #expect(!settings.showsDockIcon)
        #expect(settings.localUserName == "Andrew", "the fields beside it are untouched")
        #expect(!AppSettings().showsDockIcon, "and a fresh install is menu bar only")

        let chosen = #"{"version": 3, "showsDockIcon": true}"#
        let enabled = try JSONDecoder().decode(AppSettings.self, from: Data(chosen.utf8))
        #expect(enabled.showsDockIcon)
    }

    @Test("a settings file from an older build keeps its values when a field is added")
    func aSettingsFileFromAnOlderBuildKeepsItsValuesWhenAFieldIsAdded() async throws {
        // Synthesized Codable throws on a missing key, and load() falls
        // back to defaults, so adding one field silently reset every
        // setting a user had chosen.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)

        var settings = AppSettings()
        settings.localUserName = "Andrew"
        settings.hasCompletedOnboarding = true
        try store.save(settings)

        // Strip a field, as if the file were written before it existed.
        var object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: store.url)
        ) as! [String: Any]
        object.removeValue(forKey: "firefoxSensorHasConnected")
        try JSONSerialization.data(withJSONObject: object).write(to: store.url)

        let reloaded = store.load()
        #expect(reloaded.localUserName == "Andrew", "existing values must survive")
        #expect(reloaded.hasCompletedOnboarding, "onboarding must not reappear")
        #expect(!reloaded.firefoxSensorHasConnected, "the missing field takes its default")
    }

    @Test("a settings file from a build that had the echo-cancellation toggle still loads")
    func aSettingsFileFromABuildThatHadTheEchoCancellationToggleStill() async throws {
        // The toggle was removed with the voice-processing unit behind it,
        // which ducked every other application's output for as long as
        // the microphone ran. Every settings file written before that
        // carries the key, on either value, and a file that stopped
        // loading would reset everything the user had chosen.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = SettingsStore(directory: root)

        var settings = AppSettings()
        settings.localUserName = "Andrew"
        settings.hasCompletedOnboarding = true
        try store.save(settings)
        for stale in [true, false] {
            var object = try JSONSerialization.jsonObject(
                with: Data(contentsOf: store.url)
            ) as! [String: Any]
            object["echoCancellation"] = stale
            try JSONSerialization.data(withJSONObject: object).write(to: store.url)

            let reloaded = store.load()
            #expect(reloaded.localUserName == "Andrew", "the key is ignored, not fatal")
            #expect(reloaded.hasCompletedOnboarding)
        }
    }

    @Test("every menu row draws in a colour that is readable on a dark menu")
    func everyMenuRowDrawsInAColourThatIsReadableOnADarkMenu() async throws {
        // An attributed menu title with no foreground colour draws in
        // black, and a disabled row draws in the system's disabled grey.
        // Both are unreadable on a dark menu, which is where the menu bar
        // lives most of the time.
        await MainActor.run {
            let item = MenuBarController.informationItem("  Recording")
            guard let attributed = item.attributedTitle else {
                Issue.record("an informational row needs an explicit colour")
                return
            }
            var found = false
            attributed.enumerateAttribute(
                .foregroundColor, in: NSRange(location: 0, length: attributed.length)
            ) { value, _, _ in
                found = value is NSColor
            }
            #expect(found, "no foreground colour on \(attributed.string)")
            #expect(!item.isEnabled, "an informational row is not clickable")

            let heading = MenuBarController.informationItem("Processing", emphasis: true)
            let colour = heading.attributedTitle?.attribute(
                .foregroundColor, at: 0, effectiveRange: nil
            ) as? NSColor
            #expect(colour == NSColor.labelColor, "a heading uses the primary label colour")
        }
    }

    @Test("permission checks never trap outside an app bundle")
    func permissionChecksNeverTrapOutsideAnAppBundle() async throws {
        // Reading notification permission through UserNotifications raises
        // an uncatchable Objective-C exception when the process has no
        // bundle identifier, which killed the whole test run when an
        // onboarding view refreshed itself in the background.
        #expect(!NotificationSupport.isAvailable, "the test runner is not an app bundle")
        let statuses = await PermissionsService().allStatuses()
        #expect(statuses.count == PermissionKind.allCases.count)
        #expect(statuses.first { $0.kind == .notifications }?.state == .notDetermined)
        NotificationService().registerCategories()
        NotificationService().recordingStarted(provider: .slack, title: "Standup")
    }

    @Test("processing state maps to something a person can read")
    func processingStateMapsToSomethingAPersonCanRead() async throws {
        #expect(ProcessingState.transcribing.displayName == "Transcribing")
        #expect(ProcessingState.failed.displayName == "Needs attention")
        #expect(ProcessingState.complete.displayName == "Complete")
        // Every failure message reassures about the recording.
        for error: ProcessingError in [
            .missingAPIKey, .authenticationFailed, .rateLimited(retryAfter: nil),
            .serverError(status: 500), .transport(reason: "offline"),
        ] {
            #expect(
                error.userMessage.contains("recording is safe")
                    || error.userMessage.contains("Your recording"),
                "\(error.logSafeDescription) does not reassure: \(error.userMessage)"
            )
        }
    }

    /// The people window with a person selected, their meetings loaded, and the
    /// sheet that records a reading.
    ///
    /// The detail pane draws rows built from the archive rather than from the
    /// identity alone, so an empty archive, a missing mixdown and a person with
    /// no meetings all reach it.
    @MainActor
    private static func peopleWindowBuilds() async throws {
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = RuntimeFixtures.makeRuntime(root: root)
        let store = try #require(runtime.speakerStore)
        await runtime.ensureLocalUserIdentity()
        let me = try #require(try await store.localUser())
        _ = try await PeopleFixtures.makeAppearance(
            store: store, identityID: me.id, root: root, title: "Weekly sync",
            at: Date(timeIntervalSince1970: 1_787_900_000), turns: [(0, 30)]
        )

        let model = PeopleDirectoryModel(runtime: runtime)
        await model.reload()
        model.select(me.id, extending: false)
        ViewFixtures.render(PeopleDirectoryView(model: model), size: NSSize(width: 900, height: 600))

        // The list is loaded in the background, so the pane is drawn again once
        // it is there. Both states have to build.
        for _ in 0..<100 where model.appearances.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!model.appearances.isEmpty, "the person's meetings reached the pane")
        ViewFixtures.render(PeopleDirectoryView(model: model), size: NSSize(width: 900, height: 600))

        ViewFixtures.render(
            VoiceEnrollmentView(model: VoiceEnrollmentModel(runtime: runtime), onClose: {}),
            size: NSSize(width: 520, height: 520)
        )

        peoplePickerBuilds(model.entries)
    }

    /// Every state the picker popover reaches: nobody in the directory yet, a
    /// full list, a query that narrows it, and a query that matches nobody,
    /// which is the state that offers to create the person typed.
    @MainActor
    private static func peoplePickerBuilds(_ entries: [SpeakerDirectoryEntry]) {
        let picker = PeoplePickerModel()
        func build(_ people: [SpeakerDirectoryEntry]) -> some View {
            PeoplePickerView(
                people: people,
                context: people.first.map { [$0.id: PeoplePickerContext.onAChip] } ?? [:],
                model: picker,
                leaveUnnamedTitle: "Leave unnamed",
                onPick: { _ in },
                onNewPerson: { _ in }
            )
        }
        ViewFixtures.render(build([]), size: NSSize(width: 300, height: 200))
        ViewFixtures.render(build(entries), size: NSSize(width: 300, height: 400))
        picker.query = "an"
        ViewFixtures.render(build(entries), size: NSSize(width: 300, height: 400))
        picker.query = "nobody by this name"
        ViewFixtures.render(build(entries), size: NSSize(width: 300, height: 200))
    }
}

/// Counts calls from a `@Sendable` closure.
private actor Counter {
    private(set) var value = 0
    func bump() { value += 1 }
}
