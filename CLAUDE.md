# Pipit development notes

Pipit is a Swift 6 macOS menu-bar application that records meetings and stores
the results as files on disk.

## Commands

Use the repository scripts. They configure the SDK and repair known Command
Line Tools problems. `scripts/test.sh` wraps `swift test --no-parallel`.
`spm-env.sh` is Bash-only and must not be sourced from zsh.

```sh
./scripts/build.sh debug
./scripts/test.sh
./scripts/test.sh --filter Name
./scripts/bundle-app.sh debug
./scripts/lint.sh
./scripts/format.sh
xcodegen generate
```

`scripts/lint.sh` checks formatting and SwiftLint rules without changing files.
`scripts/format.sh` rewrites the sources in place to satisfy that check.
`xcodegen generate` rewrites `Pipit.xcodeproj` after an edit to `project.yml`,
and CI fails on a project that does not match.

Run the browser sensor checks after changing `extension/`:

```sh
(cd extension && npm test && npm run build)
```

Before finishing a change, run `./scripts/lint.sh`, `./scripts/test.sh`, and
`(cd extension && npm test)`.

Run `./scripts/check-offline.sh` after changing model installation or code that
constructs `PipitRuntime`, `SetupModel`, or `LocalModelManager`.

## Modules

| Module | Responsibility |
| --- | --- |
| `PipitCore` | Pure models, policy, storage layout, and transcript assembly |
| `PipitAudio` | Capture, process taps, audio files, import, and mixdown |
| `PipitDetection` | Accessibility, window, process, and browser evidence |
| `PipitIntegrations` | OpenAI, Keychain, EventKit, notifications, and permissions |
| `PipitLocalAI` | On-device speech models and model installation |
| `PipitSpeakers` | Voice profiles and speaker resolution |
| `PipitServices` | Runtime wiring, meeting storage, and processing pipeline |
| `PipitUI` | Menu bar, setup, settings, meetings window, and people |

`PipitServices` also holds `EchoMeasurement`, which nothing in the application
calls. It measures what `MicrophoneCleaner` does to a recording and is run from
`pipit-eval echo`. It ships in the app binary rather than living in the tool
because the test target cannot link an executable target, and because it shares
`EchoCancellationPass` with the cleaner so that a measurement describes the pass
that ships rather than a second copy of it.

## Pull requests and release notes

Merged pull request titles become the release notes. The label decides
whether a change is announced, and the title decides how it reads.

`feature` and `fix` are for changes a person using Pipit notices. Recording,
detection, transcription, diarization, speaker names, the meetings window,
settings, the menu bar, permissions, and updates all qualify. Everything
about how the app is built, tested, signed, packaged, or released takes `ci`
or `chore` and never reaches the notes, however much work it was. `docs`,
`dependencies`, and `skip-changelog` stay out as well.

Write a `feature` or `fix` title as the symptom the person had, not the
mechanism that changed. "Pick up a speaker who only talks near the end of a
call" rather than "Widen the diarization interval match window". "Stop the
menu bar item crashing after a recording is deleted" rather than "Guard the
nil meeting in MenuBarController". A file, a type, or a function name
belongs in the body.

The notes on the release page are one or two lines saying what the release
is. The generated list carries the changes. Signing, notarization, and how
to install a disk image are implied by a macOS release and are not written
out.

## Project constraints

- Never write a Core Audio device property. Pipit reads the microphone and taps
  process output. It must not change input gain, sample rate, the default
  device, or anything else another application captures, and it must not run the
  microphone through the voice-processing unit. `AudioObjectSetPropertyData` and
  the voice-processing unit stay out of the app. `AudioUnitSetProperty` on
  Pipit's own audio unit is process-local and allowed.
- Treat source audio, manifests, raw model output, and imported originals as
  immutable after they are written.
- Keep meeting content out of logs. Log identifiers, counts, durations, states,
  and typed error categories.
- Store API keys in Keychain. Never commit keys, recordings, or benchmark audio.
- Keep voice profiles under Application Support and out of meeting folders.
- Never put a real person's name, voice, or anything said on a recorded call
  into the repository. This covers commit messages, pull requests, code and test
  comments, docs, fixtures, and test data. Describe the bug with the mechanism
  and synthetic examples instead.
- Speech dependencies are pinned to measured versions. A version change requires
  benchmark evaluation.
- An imported recording is dated from what the recorder wrote: the container's
  creation date, then a timestamp in the filename, then the file's date on this
  Mac. The manifest still owns how long the audio runs.

## References

- [Contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Benchmarks](Benchmarks/README.md)
- [Verification](docs/VERIFICATION.md)
- [Releasing](docs/RELEASING.md)
