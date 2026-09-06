# Releasing Pipit

Pipit releases are built from version tags. The release workflow tests the
project, signs and notarizes the application, creates ZIP and DMG archives,
writes SHA-256 checksums, and drafts a GitHub release.

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

## Prepare the release

Start from an up-to-date `main` branch with a clean working tree. Update
`VERSION` and run the application and extension tests:

```sh
printf '1.2.0\n' > VERSION
./scripts/test.sh
(cd extension && npm test)
git add VERSION
git commit -m "chore: release 1.2.0"
```

Push the version commit through the normal pull request process. After it lands
on `main`, create and push the matching tag:

```sh
git switch main
git pull --ff-only
git tag v1.2.0
git push origin v1.2.0
```

The tag starts `.github/workflows/release.yml`. The workflow creates these
artifacts:

```text
Pipit-1.2.0.zip
Pipit-1.2.0.dmg
Pipit-1.2.0.sha256
```

A release started from the Actions tab has a pre-release checkbox. Ticking it
marks the GitHub release as a pre-release and puts the appcast item on the beta
channel. A version below 1.0.0 goes on the beta channel either way.

The release job builds, tests, notarizes and packages within a 120-minute
budget. The `swift test` step alone takes around half an hour because it
rebuilds every dependency in debug.

## Review the draft

The workflow creates a draft GitHub release. Before publishing it:

1. Confirm that the test, signing, notarization, and packaging steps passed.
2. Compare the ZIP and DMG checksums with `Pipit-1.2.0.sha256`.
3. Install the DMG on a Mac that did not build it.
4. Confirm that Gatekeeper accepts the application.
5. Complete setup and record a short meeting.
6. Review the generated release notes and publish the draft.

Publishing the draft starts `.github/workflows/appcast.yml`. It downloads
`Pipit-1.2.0.zip` from the published release, runs `scripts/make-appcast.sh`,
and commits `appcast.xml` to `gh-pages`. The feed serves the new version once
the Pages deployment for that commit finishes. A draft that is never published, or is discarded, leaves the feed
untouched. Re-run the workflow from the Actions tab with the tag as its input
if the appcast needs rebuilding.

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

The application bundle includes the browser sensor and native host. Firefox
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
