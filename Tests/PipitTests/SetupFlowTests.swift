import Foundation
import PipitCore
import PipitLocalAI
import PipitServices
import PipitUI
import PipitTestSupport
import Testing

/// What first-run setup refuses to finish without.
///
/// Every rule here is one a user hits on a fresh machine exactly once, where a
/// regression is invisible until someone reinstalls and records a meeting that
/// captures nothing.
@Suite("SetupFlow")
struct SetupFlowTests {
    /// A snapshot with the three blocking permissions granted and nothing else
    /// arranged, so each test spoils exactly the thing it is about.
    private static func ready(
        settings: AppSettings = AppSettings(),
        cloudKeyVerified: Bool = false
    ) -> SetupSnapshot {
        var snapshot = SetupSnapshot(settings: settings, cloudKeyVerified: cloudKeyVerified)
        snapshot.permissions = [
            .microphone: .granted, .screenRecording: .granted, .accessibility: .granted,
        ]
        snapshot.installedUnits = snapshot.requiredUnits
        return snapshot
    }

    @Test("all three detection permissions block finishing")
    func allThreeDetectionPermissionsBlockFinishing() async throws {
        // Microphone alone was the required set, so a user could press
        // Done having granted nothing else and get a recorder that never
        // notices a meeting.
        #expect(SetupFlow.canFinish(Self.ready()), "the baseline finishes")

        for kind in [PermissionKind.microphone, .screenRecording, .accessibility] {
            var snapshot = Self.ready()
            snapshot.permissions[kind] = .denied
            #expect(!SetupFlow.canFinish(snapshot), "\(kind.rawValue) denied must block Done")
            #expect(kind.isRequired, "\(kind.rawValue) is a required permission")
        }
    }

    @Test("calendar and notifications never block finishing")
    func calendarAndNotificationsNeverBlockFinishing() async throws {
        var snapshot = Self.ready()
        snapshot.permissions[.calendar] = .denied
        snapshot.permissions[.notifications] = .denied
        #expect(SetupFlow.canFinish(snapshot))
        #expect(!PermissionKind.calendar.isRequired)
        #expect(!PermissionKind.notifications.isRequired)
    }

    @Test("a granted-but-not-effective permission does not count as granted")
    func aGrantedButNotEffectivePermissionDoesNotCountAsGranted() async throws {
        // The state an unsigned rebuild produces: the toggle reads on and
        // the running binary has no access. Treating it as granted let
        // setup finish onto a build that could not read a window title.
        var snapshot = Self.ready()
        snapshot.permissions[.accessibility] = .grantedButNotEffective
        #expect(!SetupFlow.canFinish(snapshot))
    }

    @Test("cloud needs a verified key, local needs nothing")
    func cloudNeedsAVerifiedKeyLocalNeedsNothing() async throws {
        var cloud = AppSettings()
        cloud.processing.transcription = .openAI
        cloud.processing.diarization = .openAI

        #expect(
            !(SetupFlow.isSatisfied(.backend, in: Self.ready(settings: cloud))),
            "an unverified key leaves the backend step undone"
        )
        #expect(
            SetupFlow.isSatisfied(
                .backend, in: Self.ready(settings: cloud, cloudKeyVerified: true)
            )
        )
        #expect(
            SetupFlow.isSatisfied(.backend, in: Self.ready()),
            "the local default needs no key at all"
        )
    }

    @Test("the cloud path still requires local model units")
    func theCloudPathStillRequiresLocalModelUnits() async throws {
        // The diarizer is required in every configuration because voice
        // memory embeds a cloud diarizer's intervals with local models,
        // and gpt-transcribe returns no timings so it needs the aligner.
        var cloud = AppSettings()
        cloud.processing.transcription = .openAI
        cloud.processing.diarization = .openAI
        #expect(
            !LocalModelUnit.required(for: cloud).contains(.ctcAligner),
            "the default cloud model reports its own timings and needs no aligner"
        )
        cloud.models.transcription = "gpt-transcribe"
        let units = LocalModelUnit.required(for: cloud)
        #expect(units.contains(.diarizer), "the diarizer is always required")
        #expect(units.contains(.ctcAligner), "gpt-transcribe returns text, so timings are local")
        #expect(!units.contains(.cohere), "and no local transcription engine")

        var local = AppSettings()
        local.processing.localTranscriptionModel = .cohere
        let localUnits = LocalModelUnit.required(for: local)
        #expect(localUnits.contains(.cohere))
        #expect(localUnits.contains(.diarizer))
    }

    @Test("models already on disk satisfy the step with no download")
    func modelsAlreadyOnDiskSatisfyTheStepWithNoDownload() async throws {
        var snapshot = Self.ready()
        #expect(snapshot.missingUnits.isEmpty)
        #expect(!snapshot.isDownloadingModels)
        #expect(
            SetupFlow.isSatisfied(.models, in: snapshot),
            "a reinstall onto existing models downloads nothing"
        )

        snapshot.installedUnits = []
        #expect(!SetupFlow.isSatisfied(.models, in: snapshot))
        #expect(!SetupFlow.canFinish(snapshot))
    }

    @Test("a running download unblocks the models step")
    func aRunningDownloadUnblocksTheModelsStep() async throws {
        // Recording works while models arrive and meetings queue until
        // they do, so holding the user at this step for 2.1 GB buys
        // nothing.
        var snapshot = Self.ready()
        snapshot.installedUnits = []
        snapshot.isDownloadingModels = true
        #expect(SetupFlow.isSatisfied(.models, in: snapshot))
        #expect(SetupFlow.canFinish(snapshot))
    }

    @Test("setup opens on Finish only when there is nothing left to do")
    func setupOpensOnFinishOnlyWhenThereIsNothingLeftToDo() async throws {
        #expect(
            SetupFlow.openingStep(for: Self.ready()) == .finish,
            "a reinstall that kept everything opens at the end"
        )
        var finished = AppSettings()
        finished.hasCompletedOnboarding = true
        #expect(
            SetupFlow.openingStep(for: Self.ready(settings: finished)) == .finish,
            "and so does a returning user with nothing broken"
        )

        var fresh = SetupSnapshot()
        fresh.permissions = [:]
        #expect(SetupFlow.openingStep(for: fresh) == .welcome)

        // The backend step is satisfied by its own local default, so
        // resuming at the first unsatisfied step would skip the
        // local-or-cloud choice without ever showing it.
        #expect(SetupFlow.isSatisfied(.backend, in: fresh))
    }

    @Test("a revoked required permission reopens setup at the next launch")
    func aRevokedRequiredPermissionReopensSetupAtTheNextLaunch() async throws {
        // Without this a user whose microphone grant was dropped by an OS
        // update carries on with a menu bar icon that looks exactly the
        // same as always, and finds out at the end of a meeting that
        // recorded nothing.
        var settings = AppSettings()
        settings.hasCompletedOnboarding = true
        var snapshot = Self.ready(settings: settings)
        #expect(!SetupFlow.shouldOpenAtLaunch(snapshot), "nothing is wrong, so nothing opens")

        for kind in [PermissionKind.microphone, .screenRecording, .accessibility] {
            var revoked = snapshot
            revoked.permissions[kind] = .denied
            #expect(
                SetupFlow.shouldOpenAtLaunch(revoked),
                "\(kind.rawValue) revoked must bring setup back"
            )
            #expect(
                SetupFlow.openingStep(for: revoked) == SetupStepID.allCases.first { $0.permission == kind },
                "and open on the permission that broke, not on Welcome"
            )
        }

        // An optional permission is not worth a window on every launch.
        snapshot.permissions[.calendar] = .denied
        snapshot.permissions[.notifications] = .denied
        #expect(!SetupFlow.shouldOpenAtLaunch(snapshot))
    }

    @Test("the rail marks required steps red until done and optional steps by what was chosen")
    func theRailMarksRequiredStepsRedUntilDoneAndOptionalStepsByWhatW() async throws {
        var snapshot = Self.ready()
        snapshot.permissions[.microphone] = .denied
        var marks = Dictionary(
            uniqueKeysWithValues: SetupFlow.steps(for: snapshot).map { ($0.id, $0.mark) }
        )
        #expect(marks[.microphone] == .missing, "required and not done is a red X")
        #expect(marks[.screenRecording] == .done)
        #expect(marks[.backend] == .done)
        #expect(marks[.welcome] == .notVisited, "a page never continued past has no mark")
        #expect(marks[.optionalPermissions] == .notVisited)
        #expect(marks[.firefox] == .notVisited)
        #expect(marks[.finish] == .notVisited)

        // Continuing past an optional page with its offer left off is
        // a choice, and the rail keeps it as one.
        snapshot.settings.setupStepsVisited = [
            SetupStepID.welcome.rawValue, SetupStepID.optionalPermissions.rawValue,
            SetupStepID.firefox.rawValue,
        ]
        snapshot.permissions[.calendar] = .granted
        marks = Dictionary(
            uniqueKeysWithValues: SetupFlow.steps(for: snapshot).map { ($0.id, $0.mark) }
        )
        #expect(marks[.welcome] == .done, "welcome has nothing to switch on")
        #expect(
            marks[.optionalPermissions] == .skipped,
            "one of the two on is not everything on the page"
        )
        #expect(marks[.firefox] == .skipped)

        snapshot.permissions[.notifications] = .granted
        snapshot.nativeHostInstalled = true
        snapshot.settings.hasCompletedOnboarding = true
        marks = Dictionary(
            uniqueKeysWithValues: SetupFlow.steps(for: snapshot).map { ($0.id, $0.mark) }
        )
        #expect(marks[.optionalPermissions] == .done)
        #expect(marks[.firefox] == .done)
        #expect(marks[.finish] == .done)

        // A setup finished by a build that kept no visited list still
        // counts Welcome as seen.
        var finished = Self.ready()
        finished.settings.hasCompletedOnboarding = true
        #expect(SetupFlow.mark(for: .welcome, in: finished) == .done)
        #expect(SetupFlow.mark(for: .optionalPermissions, in: finished) == .notVisited)
    }

    @Test("a returning user opens on the first step that needs work, models included")
    func aReturningUserOpensOnTheFirstStepThatNeedsWorkModelsIncluded() async throws {
        var finished = AppSettings()
        finished.hasCompletedOnboarding = true
        var snapshot = Self.ready(settings: finished)
        snapshot.installedUnits = []
        #expect(SetupFlow.firstMissingStep(in: snapshot) == .models)
        #expect(SetupFlow.openingStep(for: snapshot) == .models)

        snapshot.permissions[.accessibility] = .grantedButNotEffective
        snapshot.installedUnits = snapshot.requiredUnits
        #expect(SetupFlow.openingStep(for: snapshot) == .accessibility)
    }

    @Test("the steps a person continued past survive a settings round trip")
    func theStepsAPersonContinuedPastSurviveASettingsRoundTrip() async throws {
        var settings = AppSettings()
        settings.setupStepsVisited = ["welcome", "firefox"]
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.setupStepsVisited == ["welcome", "firefox"])
        // A file written before the key existed reads as nothing visited.
        let bare = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(bare.setupStepsVisited == [])
    }

    @Test("setup that was never finished always opens")
    func setupThatWasNeverFinishedAlwaysOpens() async throws {
        var snapshot = Self.ready()
        #expect(!snapshot.settings.hasCompletedOnboarding)
        #expect(
            SetupFlow.shouldOpenAtLaunch(snapshot),
            "every permission granted still leaves the choices unmade"
        )

        // And a missing model does not, on its own, reopen anything: it
        // is repaired in Settings and costs no recording.
        var finished = AppSettings()
        finished.hasCompletedOnboarding = true
        snapshot = Self.ready(settings: finished)
        snapshot.installedUnits = []
        #expect(!SetupFlow.isSatisfied(.models, in: snapshot))
        #expect(!SetupFlow.shouldOpenAtLaunch(snapshot))
    }

    @Test("the step order runs welcome to finish with no gaps")
    func theStepOrderRunsWelcomeToFinishWithNoGaps() async throws {
        var id = SetupStepID.welcome
        var walked: [SetupStepID] = [id]
        while let next = SetupFlow.step(after: id) {
            id = next
            walked.append(id)
        }
        #expect(walked == SetupStepID.allCases)
        #expect(id == .finish)
        #expect(SetupFlow.step(after: .finish) == nil)
        #expect(SetupFlow.step(before: .welcome) == nil)
        #expect(SetupFlow.step(before: .finish) == .firefox)
    }

    @Test("only the panes with an application list accept a dropped app")
    func onlyThePanesWithAnApplicationListAcceptADroppedApp() async throws {
        // Dragging Pipit in is the fast route for the two panes that
        // hold a list. The others are granted by a system prompt and have
        // nothing to drop onto, so offering a drag chip there would be a
        // control that does nothing.
        #expect(PermissionKind.accessibility.acceptsDroppedApplication)
        #expect(PermissionKind.screenRecording.acceptsDroppedApplication)
        #expect(!PermissionKind.microphone.acceptsDroppedApplication)
        #expect(!PermissionKind.calendar.acceptsDroppedApplication)
        #expect(!PermissionKind.notifications.acceptsDroppedApplication)

        #expect(!PermissionKind.accessibility.isGrantedByPrompt)
        #expect(PermissionKind.microphone.isGrantedByPrompt)
    }

    @Test("the Speech models step offers the engine choice at the settings default")
    func theSpeechModelsStepOffersTheEngineChoiceAtTheSettingsDefault() async throws {
        // The step showed whatever the settings default happened to be
        // and no way to change it, so a fresh install committed to an
        // engine nobody had been shown.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let model = await MainActor.run { makeSetupModel(root: root, requested: nil) }
        await MainActor.run {
            // Every case is offered, retired, or a bench candidate,
            // so an engine cannot go missing from the picker by
            // accident. Cohere and Whisper retired on the 2026-08-24
            // deciding run; Canary never earned a place; Apple is
            // offered where the OS has it.
            let unoffered: Set<LocalTranscriptionModel> =
                AppleSpeechTranscriptionBackend.isAvailable
                ? [.canary, .cohere, .whisper]
                : [.canary, .cohere, .whisper, .apple]
            #expect(
                Set(LocalTranscriptionModel.offered).union(unoffered) == Set(LocalTranscriptionModel.allCases),
                "every engine is offered, retired, or a named bench candidate"
            )
            #expect(
                Set(LocalTranscriptionModel.offered).isDisjoint(with: unoffered),
                "retired engines and candidates stay out of the picker"
            )
            #expect(
                LocalTranscriptionModel.offered.first == LocalTranscriptionModel.preferred,
                "and the fresh-install default is offered first"
            )
            // A stored choice that left the offered list keeps its
            // row: hiding it would show a picker with nothing
            // selected, one click from a download nobody asked for.
            #expect(
                LocalTranscriptionModel.pickerRows(selected: .cohere).last == LocalTranscriptionModel.cohere,
                "an unoffered selection still has its row"
            )
            #expect(
                LocalTranscriptionModel.pickerRows(selected: .parakeet) == LocalTranscriptionModel.offered,
                "an offered selection adds nothing"
            )
            #expect(model.localModel == AppSettings().processing.localTranscriptionModel)
            #expect(model.localModel == LocalTranscriptionModel.preferred)
            #expect(
                model.runtime.settings.processing.usesLocalTranscription,
                "the default backend is local, which is what shows the picker"
            )
        }
    }

    @Test("choosing Cohere in setup downloads Cohere and keeps the choice")
    func choosingCohereInSetupDownloadsCohereAndKeepsTheChoice() async throws {
        // Picking a model is the consent for its download. The wizard
        // wrote the setting and started the install as two unordered
        // tasks, so the install could fetch the engine the user had
        // just moved away from.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let requested = RequestedUnits()
        let model = await MainActor.run { makeSetupModel(root: root, requested: requested) }
        await model.chooseLocalModel(.cohere)

        #expect(
            await requested.all == [[.cohere, .ctcAligner, .diarizer, .voiceActivity]],
            "the download is for the chosen engine, with the aligner it needs"
        )
        await MainActor.run {
            #expect(model.localModel == .cohere, "and the step shows what was picked")
            model.finish()
        }
        #expect(
            SettingsStore(directory: root).load().processing.localTranscriptionModel == .cohere,
            "finishing setup leaves the engine the user saw selected"
        )
    }

    @Test("leaving the choice alone downloads only what the default needs")
    func leavingTheChoiceAloneDownloadsOnlyWhatTheDefaultNeeds() async throws {
        // Nothing in setup may reach for the 2.1 GB engine on its own.
        // On macOS 26 the default is Apple and the download is the
        // shared 22 MB; before it, Parakeet's 460 MB.
        let root = try TestPaths.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let requested = RequestedUnits()
        let model = await MainActor.run { makeSetupModel(root: root, requested: requested) }
        await model.startModelDownload()

        var defaults = AppSettings()
        defaults.processing.transcription = .local
        #expect(await requested.all == [LocalModelUnit.required(for: defaults)])
        await MainActor.run { model.finish() }
        #expect(
            SettingsStore(directory: root).load().processing.localTranscriptionModel == LocalTranscriptionModel.preferred,
            "and finishing setup stores the engine nobody touched"
        )
    }

    @Test("the illustrated pane names match the panes macOS 27 actually opens")
    func theIllustratedPaneNamesMatchThePanesMacOS27ActuallyOpens() async throws {
        // Checked against the panes themselves. Accessibility is the one
        // that moved: its privacy pane is called Device Control and Data
        // Access now, while the Accessibility item in the sidebar is the
        // unrelated VoiceOver and Zoom one. Naming the picture after the
        // sidebar item sends people somewhere with no Pipit row in it.
        #expect(PermissionKind.accessibility.paneTitle == "Device Control and Data Access")
        #expect(PermissionKind.screenRecording.paneTitle == "Screen & System Audio Recording")
        for kind in PermissionKind.allCases {
            #expect(!kind.paneCaption.isEmpty, "\(kind.rawValue) has no caption")
        }
    }

    @Test("every settings deep link names a pane System Settings still has")
    func everySettingsDeepLinkNamesAPaneSystemSettingsStillHas() async throws {
        // The com.apple.preference.security pane has not existed since
        // System Settings replaced System Preferences; opening it lands
        // on the Settings root with nothing to switch on.
        for kind in PermissionKind.allCases {
            let url = try #require(kind.settingsURL, "\(kind.rawValue) has no pane")
            #expect(url.scheme == "x-apple.systempreferences")
            #expect(
                !url.absoluteString.contains("com.apple.preference.security"),
                "\(kind.rawValue) still points at the pre-Ventura pane"
            )
        }
    }
}

/// The unit sets an install was asked for, in the order they were asked.
private actor RequestedUnits {
    private(set) var all: [Set<LocalModelUnit>] = []
    func record(_ units: Set<LocalModelUnit>) { all.append(units) }
}

@MainActor
private func makeSetupModel(root: URL, requested: RequestedUnits?) -> SetupModel {
    SetupModel(
        runtime: PipitRuntime(settingsDirectory: root),
        // Setup on the local default asks the keychain nothing, and a real
        // install here would fetch gigabytes to answer a question about which
        // units were named.
        keyPresence: { false },
        install: { _, units in await requested?.record(units) }
    )
}
