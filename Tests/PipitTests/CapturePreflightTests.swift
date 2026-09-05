import Foundation
import PipitCore
import Testing

@Suite("CapturePreflight")
struct CapturePreflightTests {
    @Test("a call recorded without the system audio grant is warned about before capture")
    func aCallRecordedWithoutTheSystemAudioGrantIsWarnedAboutBeforeCa() async throws {
        // Seven recordings on this Mac lost their far end to a tap created
        // without the grant. The tap reports healthy, so the answer has to
        // come from the grant itself, before anything is armed.
        for state in [PermissionState.denied, .notDetermined, .grantedButNotEffective] {
            #expect(
                RecordingPreflight.warnings(capturesRemote: true, systemAudio: state) == [.systemAudioPermissionMissing],
                "\(state.rawValue) means silence from the tap"
            )
        }
    }

    @Test("a granted tap and a recording with no far end raise nothing")
    func aGrantedTapAndARecordingWithNoFarEndRaiseNothing() async throws {
        #expect(RecordingPreflight.warnings(capturesRemote: true, systemAudio: .granted) == [])
        // An in-person or imported recording never opens a tap, so the
        // grant is not its business.
        #expect(RecordingPreflight.warnings(capturesRemote: false, systemAudio: .denied) == [])
    }

    @Test("no microphone grant refuses the recording, no system audio grant lets it run with a warning")
    func noMicrophoneGrantRefusesTheRecordingNoSystemAudioGrantLetsIt() async throws {
        #expect(RecordingPreflight.decide(capturesRemote: true, microphone: .denied, systemAudio: .granted) == RecordingPreflight.Decision.refuse(.microphonePermissionMissing))
        #expect(RecordingPreflight.decide(capturesRemote: false, microphone: .notDetermined, systemAudio: .denied) == RecordingPreflight.Decision.refuse(.microphonePermissionMissing))
        #expect(RecordingPreflight.decide(capturesRemote: true, microphone: .granted, systemAudio: .denied) == RecordingPreflight.Decision.proceed([.systemAudioPermissionMissing]))
        #expect(RecordingPreflight.decide(capturesRemote: true, microphone: .granted, systemAudio: .granted) == RecordingPreflight.Decision.proceed([]))
        #expect(RecordingPreflight.decide(capturesRemote: false, microphone: .granted, systemAudio: .denied) == RecordingPreflight.Decision.proceed([]))
        #expect(CaptureWarning.message(forKey: "microphone_permission_missing") == CaptureWarning.microphonePermissionMissing.message)
    }

    @Test("one missing grant is offered from the panel, two send the person into Setup")
    func oneMissingGrantIsOfferedFromThePanelTwoSendThePersonIntoSetu() async throws {
        let refused = PermissionNotice(missing: [.microphone])
        #expect(refused?.single == .microphone)
        #expect(refused?.recordingContinues == false)
        #expect(refused?.title == "Pipit can't record this meeting")
        #expect(refused?.menuTitle == "Microphone permission missing…")
        #expect(refused?.warnings == [.microphonePermissionMissing])

        let farEnd = PermissionNotice(missing: [.screenRecording])
        #expect(farEnd?.single == .screenRecording)
        #expect(farEnd?.recordingContinues == true)
        #expect(farEnd?.title == "Pipit can't record the other people in this meeting")

        // Given out of order, kept in Setup order, and too many for one
        // panel to grant.
        let both = PermissionNotice(missing: [.screenRecording, .microphone])
        #expect(both?.missing == [.microphone, .screenRecording])
        #expect(both?.single == nil)
        #expect(both?.menuTitle == "Permissions missing…")
        #expect(both?.recordingContinues == false)
        #expect(both?.body.contains("Setup") == true)

        #expect(PermissionNotice(missing: []) == nil)
    }

    @Test("the notice clears when every grant it names is seen, not one of them")
    func theNoticeClearsWhenEveryGrantItNamesIsSeenNotOneOfThem() async throws {
        let notice = PermissionNotice(missing: [.microphone, .screenRecording])!
        let mic = PermissionStatus(kind: PermissionKind.microphone, state: .granted)
        #expect(!notice.isResolved(by: [mic]))
        #expect(
            !notice.isResolved(by: [mic, PermissionStatus(kind: .screenRecording, state: .grantedButNotEffective)]),
            "System Settings showing it on is not the tap being able to use it"
        )
        #expect(notice.isResolved(by: [mic, PermissionStatus(kind: .screenRecording, state: .granted)]))
    }

    @Test("the icon is red while any required grant is known to be missing, on evidence only")
    func theIconIsRedWhileAnyRequiredGrantIsKnownToBeMissingOnEvidenc() async throws {
        #expect(PermissionNotice.missingRequired(in: [:]) == nil, "nothing probed yet is not a problem")
        #expect(
            PermissionNotice.missingRequired(in: [
                .microphone: .granted, .screenRecording: .granted, .accessibility: .granted,
                .calendar: .denied, .notifications: .denied,
            ]) == nil,
            "the optional grants never colour the icon"
        )
        let one = PermissionNotice.missingRequired(in: [.microphone: .granted, .accessibility: .denied])
        #expect(one?.missing == [.accessibility])
        #expect(one?.recordingContinues == true, "the microphone still records without it")
        let two = PermissionNotice.missingRequired(in: [
            .microphone: .notDetermined, .screenRecording: .grantedButNotEffective, .accessibility: .granted,
        ])
        #expect(two?.missing == [.microphone, .screenRecording])
        #expect(two?.menuTitle == "Permissions missing…")
    }

    @Test("a manual start always gets the notice, a detected call once a minute")
    func aManualStartAlwaysGetsTheNoticeADetectedCallOnceAMinute() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let justNow = now.addingTimeInterval(-1)
        // The person pressed the button one second after the last notice
        // and is waiting for a reaction. This was the second press that
        // saw nothing.
        #expect(PermissionPromptPolicy.shouldPrompt(isManual: true, lastPromptedAt: justNow, now: now))
        #expect(PermissionPromptPolicy.shouldPrompt(isManual: false, lastPromptedAt: nil, now: now))
        #expect(!PermissionPromptPolicy.shouldPrompt(isManual: false, lastPromptedAt: justNow, now: now))
        #expect(PermissionPromptPolicy.shouldPrompt(
            isManual: false, lastPromptedAt: now.addingTimeInterval(-60), now: now
        ))
    }

    @Test("a warning stored by key reads back as its message")
    func aWarningStoredByKeyReadsBackAsItsMessage() async throws {
        let key = CaptureWarning.systemAudioPermissionMissing.dedupKey
        #expect(CaptureWarning.message(forKey: key) == CaptureWarning.systemAudioPermissionMissing.message)
        #expect(CaptureWarning.message(forKey: "remote_silent_while_producing") == CaptureWarning.remoteSilentWhileProducing(seconds: 0).message)
        #expect(CaptureWarning.message(forKey: "permission_revoked_mic") == CaptureWarning.permissionRevoked(track: .mic).message)
        // What older builds wrote is free text and is shown as it was.
        #expect(CaptureWarning.message(forKey: "capture ended in state degraded") == "capture ended in state degraded")
    }
}
