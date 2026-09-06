# Contributing to Pipit

Pipit is a Swift package that builds a macOS menu-bar application and a browser
sensor. Contributions should keep capture reliable, meeting content private,
and stored recordings readable across versions.

## Requirements

- macOS 15 or later
- Swift 6
- Xcode 26 or later
- Node.js 22 for browser sensor changes

## Build and test

Clone the repository and run the application tests:

```sh
git clone https://github.com/Neeeser/Pipit.git
cd Pipit
./scripts/build.sh debug
./scripts/test.sh
```

Build an application bundle with:

```sh
./scripts/bundle-app.sh debug
open dist/Pipit.app
```

Use the scripts instead of bare SwiftPM commands. They configure the SDK and
repair known Command Line Tools problems before Swift runs. `scripts/test.sh`
runs `swift test --no-parallel`. Running `swift test --no-parallel` directly
works when the repairs are not needed. The suite shares temporary directories
and process-wide state, so it must not run in parallel.

Xcode runs suites in parallel by default. Give a suite `.serialized` when its
own tests collide with each other. One test in `CaptureEngineHardening` depends
on a real-time watchdog and needs the whole run serial, which is why
`scripts/test.sh` passes `--no-parallel`.

## Open in Xcode

```sh
open Pipit.xcodeproj
```

Run the `Pipit` scheme to launch the menu bar app. The test navigator lists the
package's `PipitTests` suite, subject to the parallel-run caveat above.

`project.yml` is the source for the project, and `xcodegen generate` rewrites
`Pipit.xcodeproj` from it. Edit `project.yml` and regenerate rather than
changing target settings in Xcode, because CI regenerates the project and fails
on a difference. Modules and tests stay in `Package.swift`, which the project
references as a local package. In a clone whose directory is not named `Pipit`,
`xcodegen generate` renames that package reference and changes two lines in
`Pipit.xcodeproj/project.pbxproj`, and those two lines must not be committed.

The Xcode build and `scripts/bundle-app.sh` read the same `App/Info.plist` and
`App/Pipit.entitlements`. A shipped bundle takes its version from `VERSION`,
which `scripts/bundle-app.sh` stamps into the copied plist.

## Targeted checks

List or filter application tests with:

```sh
./scripts/test.sh --list
./scripts/test.sh --filter MicrophoneRecoveryCoordinatorTests
```

The filter matches the Swift type name of a suite or test, not the display
name in its `@Suite` or `@Test` label.

Run the browser sensor tests after changing `extension/`:

```sh
cd extension
npm ci
npm run lint
npm test
npm run build
```

`npm run lint` is ESLint over `shared/` and `test/`, with the same flat config
CI runs.

To try the changed extension in Firefox, load it as a temporary add-on: open
`about:debugging#/runtime/this-firefox`, choose Load Temporary Add-on, and select
`extension/dist/firefox/manifest.json`. Firefox drops a temporary add-on when it
quits, so this repeats each launch. Pipit itself only offers the signed add-on a
release build carries, because release Firefox refuses an unsigned one; see
[releasing](docs/RELEASING.md) for how that gets signed.

Run the full application and extension tests before opening a pull request:

```sh
./scripts/test.sh
(cd extension && npm test)
```

Run `./scripts/test-update.sh` after changing the updater. It builds two
versions, serves a local appcast, and checks that the older copy updates itself.

Run `./scripts/check-offline.sh` after changing model installation or code that
constructs `PipitRuntime`, `SetupModel`, or `LocalModelManager`. It fails if an
ordinary test starts a model download.

## Project structure

`PipitCore` contains deterministic logic. The audio, detection, integration,
local AI, speaker, service, and UI modules own their corresponding I/O and state.
See [the architecture guide](docs/ARCHITECTURE.md) for module boundaries and
data flow.

The browser sensor lives in `extension/`. The `pipit-nativehost` executable
relays its events to Pipit.

## Pull requests

Keep each pull request focused on one change. Add a regression test for every
bug fix and confirm that the test fails before the fix and passes after it.
Test behavior at the lowest layer that exposes the defect.

GitHub fills the description from `.github/PULL_REQUEST_TEMPLATE.md`, which asks
for the problem, the change, and the testing. New issues use the bug and feature
templates under `.github/ISSUE_TEMPLATE/`. Record a user-visible change in the
Unreleased section of [CHANGELOG.md](CHANGELOG.md). Report a security problem
privately instead, through the process in [SECURITY.md](SECURITY.md).

Do not commit recordings, API keys, benchmark audio, or meeting content. The
CI hygiene job rejects audio files and strings shaped like API keys.

Ad-hoc application builds receive new macOS permission grants after each
rebuild. A Developer ID build keeps a stable signing identity.

## Benchmarks and releases

Changes to speech models, diarization, alignment, or transcript assembly may
require the benchmark gate. See [Benchmarks](Benchmarks/README.md).

Maintainers can find the release procedure in
[docs/RELEASING.md](docs/RELEASING.md).

## License

Contributions are licensed under the [MIT License](LICENSE).
