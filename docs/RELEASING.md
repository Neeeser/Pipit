# Releasing Pipit

A release is a pull request. `scripts/prepare-release.sh` opens one that raises
the version and adds the version's notes to `CHANGELOG.md`. Once it merges and
CI passes on `main`, the release workflow signs and notarizes the application,
creates ZIP and DMG archives, writes SHA-256 checksums, tags the merged commit,
and drafts a GitHub release.

## Version numbers

A bundle carries two numbers. `CFBundleShortVersionString` is what a person
reads, and `CFBundleVersion` is what Sparkle compares. `scripts/app-version.sh`
computes both, and every build route stamps what it prints.
`scripts/bundle-app.sh` writes them into the copied plist, and a run script
phase in `Pipit.xcodeproj` writes them into the bundle Xcode builds.

`CFBundleVersion` is `git rev-list --count HEAD`, the number of commits behind
the checkout. It rises with every commit, so any two checkouts are ordered. Both
workflows check out with `fetch-depth: 0`, because the default shallow checkout
holds one commit and would number every build 1.

`CFBundleShortVersionString` is the contents of `VERSION` when `PIPIT_RELEASE=1`
is set, which the release workflow does on its build step. Every other build
reads `<VERSION>-dev.<short sha>`, such as `0.1.0-dev.2b410e6`. A dirty working
tree adds nothing, so the sha names the commit the build started from.

Sparkle orders by the build number, so a dev build made after the last release
sees no update, and one made before it is offered that release.

`MARKETING_VERSION` in `project.yml` is a fallback that the stamping phase
replaces. `scripts/bump-version.sh --apply` still keeps it in step with
`VERSION`.

Both build routes also stamp `PipitGitCommit`, the full commit the build
started from, which `scripts/app-version.sh` prints on its third line. A
release reads plain `VERSION`, so this key is what names its source. In the
release job it is the commit the release pull request's merge put on `main`,
which is also the commit the tag names.

## Requirements

The release repository needs these GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password for the exported certificate |
| `APPLE_ID` | Apple ID used by the notary service |
| `APPLE_TEAM_ID` | Apple Developer team identifier |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password for notarization |
| `AMO_JWT_ISSUER` | Mozilla add-on API key, from the AMO credentials page |
| `AMO_JWT_SECRET` | Mozilla add-on API secret for the same key |
| `SPARKLE_PRIVATE_KEY` | Base64 EdDSA private key that signs each update archive |

The workflow falls back to ad-hoc signing when the certificate is absent. Do
not publish an ad-hoc signed build. Gatekeeper will reject it on another Mac.

For local builds, `scripts/make-signing-identity.sh` creates a self-signed
"Pipit Development" certificate that `scripts/bundle-app.sh` picks up by name.
macOS ties permission grants to the signature, so an ad-hoc build loses
Microphone, Accessibility and Screen & System Audio Recording on every
reinstall, and a recording made before they are granted again captures a
silent far end. The local certificate keeps the grants across rebuilds.

The AMO credentials come from
<https://addons.mozilla.org/en-US/developers/addon/api/key/>. A release without
them ships an app that has no signed add-on, and Firefox users then load a
temporary add-on that Firefox drops when it quits.

## Labels

The pull request list on each GitHub release, and the draft that
`scripts/prepare-release.sh` writes into `CHANGELOG.md`, come from merged pull
request titles grouped by label, as `.github/release.yml` maps them. A fork
recreates the labels with:

```sh
gh label create breaking --color B60205 --description "Changes behaviour or storage in a way an existing install notices." --force
gh label create feature --color 0E8A16 --description "Adds a capability a user can see." --force
gh label create fix --color D73A4A --description "Corrects a defect a person using the app hit." --force
gh label create docs --color 0075CA --description "Changes documentation only." --force
gh label create ci --color 5319E7 --description "Changes workflows, scripts, or the build itself." --force
gh label create chore --color FBCA04 --description "Maintenance, packaging, or build work the app does not show." --force
gh label create dependencies --color 0366D6 --description "Updates a dependency." --force
gh label create skip-changelog --color E4E669 --description "Keeps this pull request out of the release notes." --force
```

`--force` updates a label that already exists, which is how `dependencies`
keeps working for Dependabot. `.github/workflows/pr-labels.yml` fails a pull
request until one of these labels is on it.

A fix for a change that has not been released yet takes `skip-changelog`,
since nobody using Pipit had the bug. A fix to a feature added in the same
release is part of that feature.

## Cut the release

On an up-to-date `main`, run:

```sh
./scripts/prepare-release.sh minor
```

It takes `patch`, `minor`, `major`, or an exact version such as `1.0.0`, and
needs `gh` and `xcodegen`. It creates the branch `release/<version>` and writes
the version into `VERSION`, `MARKETING_VERSION` in `project.yml`, and the
`Pipit.xcodeproj` it regenerates. It adds a `## <version>` section to the top of
`CHANGELOG.md`, drafted from the titles of the pull requests merged since the
last tag and grouped under `### New`, `### Fixes` and `### Breaking changes`.
Then it pushes the branch and opens a pull request titled `Release <version>`
with the `chore` label.

The script runs under your own `gh` login. A pull request opened from Actions
with `GITHUB_TOKEN` starts no workflows, so its required checks would never run.

### Write the notes

Rewrite the section in the release pull request. It is what a person reads in
the update window.

- Open with one or two lines saying what the release is.
- Say what the person can now do, in their words. "Play a meeting's recording
  and follow along in the transcript as it plays", not the mechanism the pull
  request changed.
- List a fix only when it corrects something a person had in an earlier
  release. A fix to a feature new in this release is part of that feature.
- Use `###` headings for the groups. The update window shows each one as a list
  title, and a `##` heading would end the section.

### Merge

Squash-merge the pull request once CI passes. The release workflow starts when
CI finishes on `main`. Its first job reads `VERSION` on the commit CI tested and
stops when the tag `v<version>` already exists, which is the case for every
merge that is not a release. Otherwise it checks that `CHANGELOG.md` has notes
for the version and starts the macOS build. CI has already tested that commit,
so the build skips the test suite.

The tag goes on the merged commit only after the signing, the notarization and
the packaging have succeeded, so a failed build leaves no tag behind. Fix the
cause and re-run the failed jobs from the Actions page. A failure after the tag
is pushed leaves the tag on the remote. Delete it and re-run:

```sh
git push origin :refs/tags/v1.2.0
```

A version below 1.0.0 is always a pre-release, which puts the appcast item on
the beta channel. A 0.x build reads that channel whatever its beta setting
says, so every 0.x install receives every 0.x release. From 1.0.0 on, tick "Set
as a pre-release" on the draft before publishing to send a release to the beta
channel only. The appcast workflow reads the flag from the published release.

Check the scripts locally at any time:

```sh
./scripts/bump-version.sh minor
./scripts/bump-version.sh --self-test
./scripts/release-notes.sh --self-test
```

### Tag by hand instead

A pushed `v*.*.*` tag also starts the workflow, which is the fallback when the
release pull request route is unavailable. The tag must name a commit on
`main` whose `VERSION` matches it and whose `CHANGELOG.md` has notes for it. A
commit without a passing CI run is tested before packaging.

```sh
git switch main
git pull --ff-only
git tag v1.2.0
git push origin v1.2.0
```

The workflow creates these artifacts:

```text
Pipit-1.2.0.zip
Pipit.dmg
Pipit-1.2.0.sha256
Pipit-1.2.0-dSYMs.zip
```

## Debug symbols

`scripts/archive-dsyms.sh` writes a dSYM for each executable in the bundle
and zips them as `Pipit-<version>-dSYMs.zip`, which the release carries. A
crash report names frames by binary UUID and offset, and only dSYMs with the
same UUIDs resolve them. A later rebuild of the same commit matches only if it
comes out byte for byte the same, which nothing here guarantees.
The script fails when a dSYM's UUIDs differ from the bundled binary's, or when
`atos` cannot resolve a function of the app target and one of PipitCore to a Swift line. CI runs
it on every pull request.

To symbolicate a frame from a crash report, take the load address of `Pipit`
from the report's binary images and the frame's address:

```sh
unzip Pipit-1.2.0-dSYMs.zip
dwarfdump --uuid dSYMs/Pipit.dSYM   # must match the report's UUID for Pipit
atos -arch arm64 -o dSYMs/Pipit.dSYM/Contents/Resources/DWARF/Pipit \
  -l <load address> <frame address>
```

The release job builds, tests, notarizes and packages within a 120-minute
budget. The `swift test` step alone takes around half an hour because it
rebuilds every dependency in debug.

## Review the draft

The workflow opens the release as a draft. Its body is the version's section of
`CHANGELOG.md`, a hidden marker, and the pull request list GitHub generates
from the merged titles, grouped by label, with each author credited. The update
window shows only the part before the marker. Check the draft and publish it.
Publishing is what runs the appcast workflow. A correction after publishing
goes into both `CHANGELOG.md` and the release body.

## Local release build

Use the same scripts when testing credentials locally:

```sh
PIPIT_SIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" \
  ./scripts/bundle-app.sh release

APPLE_ID="name@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_PASSWORD="app-password" \
  ./scripts/notarize.sh dist/Pipit.app

./scripts/package.sh 1.2.0
```

`scripts/package.sh` needs `create-dmg` on the path, which `brew install create-dmg` provides.

`scripts/package.sh` preserves the application signature in both archives.

## In-app updates

Pipit checks `https://neeeser.github.io/Pipit/appcast.xml` once a day. The
release workflow writes that file with `scripts/make-appcast.sh`, which signs
each archive with an EdDSA key and commits the result to `gh-pages`.

Generate the key pair once, on the maintainer's Mac. `generate_keys` stores the
private key in the login keychain and prints the public key:

```sh
curl -fsSLO https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
tar -xJf Sparkle-2.9.6.tar.xz
./bin/generate_keys
./bin/generate_keys -x sparkle-private-key.txt
```

Put the printed public key into `App/Info.plist` under `SUPublicEDKey`, and the
one line in `sparkle-private-key.txt` into the `SPARKLE_PRIVATE_KEY` secret.
Delete the exported file afterwards. `generate_appcast` compares the public key
in the app against the public half of the private key it is given. On a mismatch
it warns, leaves `edSignature` empty and exits 0, so `scripts/make-appcast.sh`
checks the written appcast for that attribute and fails the run itself. The
release workflow also refuses to build while `App/Info.plist` still holds the
placeholder key, so an unsignable release never reaches the feed. Losing the
private key means every installed copy stops updating, so keep a backup outside
the repository.

The `gh-pages` branch has to exist before Pages can point at it. The first
published release creates it. To create it by hand instead:

```sh
git switch --orphan gh-pages
git commit --allow-empty -m "Start the update feed"
git push -u origin gh-pages
```

Then enable Pages once, under Settings > Pages: source "Deploy from a branch",
branch `gh-pages`, folder `/ (root)`.

## Install route

The disk image on the GitHub release is the install route.

## Browser extension

The application bundle includes the browser sensor and native host.

Safari's add-on ships inside the app as `Contents/PlugIns/PipitSafariExtension.appex`,
which `scripts/bundle-app.sh` assembles and signs before the app. Safari only
loads it from a Developer ID signature; a local build needs Safari's "Allow
unsigned extensions" developer setting. Both the app and the extension are
signed into the app group `<team>.com.pipit.sensor`, with the team read from
the signing certificate (`PIPIT_TEAM_ID` overrides it).

The Chrome add-on has no store listing yet. Settings copies it to
`~/Library/Application Support/Pipit/Chrome Add-on` for the browser's Load
unpacked button. Its identifier comes from the `key` in
`extension/chrome/manifest.json`; a Chrome Web Store listing gets an identifier
of its own, which has to be added to `NativeMessagingInstaller`'s allowed list.

Firefox
distribution through addons.mozilla.org uses the extension identifier
`sensor@pipit.app`. Keep that identifier aligned with
`extension/firefox/manifest.json` when publishing an updated XPI.

Release Firefox installs a signed add-on permanently and refuses an unsigned
one, so the release workflow signs the extension before assembling the app:

```sh
AMO_JWT_ISSUER=... AMO_JWT_SECRET=... ./scripts/sign-extension.sh 1.2.0
```

The channel is `unlisted`, so Mozilla signs the file and returns it rather than
publishing it on addons.mozilla.org. The signed XPI lands at
`extension/signed/pipit-sensor.xpi`, and `scripts/bundle-app.sh` copies it into
the app bundle, where Settings offers it as a one-click install.

The version argument stamps the built manifest, because AMO refuses a version
it has already signed for this add-on. Pass the release version so each tag
signs a version of its own. Mozilla reviews self-distributed add-ons after the
fact and can disable one that breaks their policies.
### Add-on updates

Firefox updates the add-on on its own. The add-on's manifest names an update
feed at `https://neeeser.github.io/Pipit/firefox/updates.json`, and Firefox
reads it about once a day. The release workflow attaches the signed add-on to
the GitHub release, and the appcast workflow adds it to the feed with
`scripts/make-addon-updates.sh` when it publishes the appcast. A signed add-on
already installed updates from the feed with no prompt.

The app tells the person to update the add-on only when the add-on is older
than the app needs. That is decided by one number, `SensorProtocol.required`
in `Sources/PipitCore/Detection/SensorCompatibility.swift`, matched by
`SENSOR_PROTOCOL` in `extension/shared/relay.js`. The add-on sends its number
in its hello. Raise both numbers together in the change that makes the app
depend on something new from the add-on, and leave them alone in every other
release. An add-on ahead of the app is not a problem: each side reads only the
fields it knows, and the Browsers page says an app update is what would use
the newer add-on.

The update window is Pipit's own, not Sparkle's. It lists the app and the
add-on as the two steps of one update, and it draws the release notes from
the GitHub release body through the API, up to the marker after the
`CHANGELOG.md` section, rather than showing the release page.
The launch after an update opens the window on its second step when the
add-on is still behind, and closes it once the add-on reconnects updated.

