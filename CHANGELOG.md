# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
A release is cut by updating `VERSION` and pushing the matching `v` tag, as
described in [docs/RELEASING.md](docs/RELEASING.md).

## [Unreleased]

### Added

- Pipit updates itself through Sparkle, checking a signed appcast once a day.
  The menu bar has a "Check for Updates…" item, and Settings has a "Receive beta
  updates" option that follows the beta channel.

### Changed

- The test suite runs on Swift Testing through `swift test`, so a contributor
  without Xcode can run it. ([#63])

### Fixed

- Deleting a folder no longer removes meetings the listing could not read, and
  filing, renaming, or deleting a folder is refused while the pipeline is
  writing into it. ([#65])
- Compaction decodes an archive end to end before it deletes the source
  segments, so a container with a corrupt payload no longer passes the check.
  ([#65])
- Identifier allocation scans meetings filed into folders, so a filed meeting
  can no longer hand its identifier to a new recording. ([#65])
- The browser relay keeps the sensor's observation time across an `await`, so an
  older event no longer arrives with a newer time. ([#65])
- A meeting is logged by its timestamp and source rather than by the identifier
  that embeds its title. ([#65])
- An import that hits a read or conversion error marks the meeting failed and
  refuses retry, instead of being marked complete. ([#65])
- A keychain lookup already in flight is awaited instead of skipped, so the
  stored API key is found on the first read after launch. ([#64])

[#63]: https://github.com/Neeeser/Pipit/pull/63
[#64]: https://github.com/Neeeser/Pipit/pull/64
[#65]: https://github.com/Neeeser/Pipit/pull/65
