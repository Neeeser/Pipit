# Pipit development notes

Pipit is a Swift 6 macOS menu-bar application that records meetings and stores
the results as files on disk.

## Commands

Use the repository scripts. They configure the SDK and repair known Command
Line Tools problems. `scripts/test.sh` wraps `swift test --no-parallel`.
`scripts/spm-env.sh` is Bash-only and must not be sourced from zsh.

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

Before finishing a change, run `./scripts/lint.sh` and `./scripts/test.sh`.
After changing `extension/`, also run
`(cd extension && npm run lint && npm test && npm run build)`.

Run `./scripts/check-offline.sh` after changing model installation or code that
constructs `PipitRuntime`, `SetupModel`, or `LocalModelManager`.

## Modules

| Module | Responsibility |
| --- | --- |
| `PipitCore` | Pure models, policy, storage layout, and transcript assembly |
| `PipitAudio` | Capture, process taps, audio files, import, mixdown, and the echo canceller |
| `PipitDetection` | Accessibility, window, process, and browser evidence |
| `PipitIntegrations` | OpenAI, Keychain, EventKit, notifications, and permissions |
| `PipitLocalAI` | On-device speech models and model installation |
| `PipitSpeakers` | Voice profiles and speaker resolution |
| `PipitServices` | Runtime wiring, meeting storage, and processing pipeline |
| `PipitUI` | Menu bar, setup, settings, meetings window, and people |
| `PipitApp` | Application entry point |
| `PipitNativeHost` | Browser native-messaging host (`pipit-nativehost`) |
| `PipitBench` | Benchmark ground truth, scoring, and suite manifest |
| `PipitEval` | Developer evaluation tool (`pipit-eval`), not bundled in the app |

`CLocalVQE` is vendored C++ (LocalVQE and ggml) that `PipitAudio` links; see
`Sources/CLocalVQE/UPDATING.md` before touching it. `Benchmarks/aec` is the
echo canceller bake-off, and `Sources/PipitAudio/Resources/EchoModels` holds
the model files the pass ships with, produced by `Benchmarks/aec/export_dtln.py`.

## Pull requests and release notes

Merged pull request titles become the release notes, grouped by label
(`breaking`, `feature`, `fix`). Use those labels only for changes a person using
Pipit notices. Build, test, signing, and release work takes `ci` or `chore`.
Title a `feature` or `fix` by the symptom the person had ("Pick up a speaker who
only talks near the end of a call"). Put file and type names in the body.
The release page note is one or two lines saying what the release is.
`CONTRIBUTING.md` and `.github/release.yml` list every accepted label.

## Project constraints

- Never write a Core Audio device property. Pipit reads the microphone and taps
  process output. It must not change input gain, sample rate, the default
  device, or anything else another application captures.
  `AudioObjectSetPropertyData` stays out of the app. `AudioUnitSetProperty` on
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

## References

- [Contributing](CONTRIBUTING.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Benchmarks](Benchmarks/README.md)
- [Verification](docs/VERIFICATION.md)
- [Releasing](docs/RELEASING.md)
- [Product copy rules](.claude/rules/product-copy.md), loaded when editing UI or extension sources
