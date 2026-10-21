# Diagnostics

Pipit keeps a small log of what it did, so a bug on someone's Mac can be
investigated without their meetings. This document is the contract between the
app, the diagnostic bundle, and the report service on the website
(`Neeeser/pipit-website`). Change it together with both sides.

## Principles

- Collected and kept on this Mac. Nothing is sent unless the person presses
  **Send**, or has turned on **Share diagnostics automatically**, which is off
  by default.
- An allowlist, not redaction. Every field below is an enum, a number, a
  boolean, a version, or a random identifier. Free text never enters an event:
  no titles, names, transcripts, notes, paths, URLs, device names, model names a
  person typed, or error descriptions.
- No account, install, or device identifier. Identifiers are random and scoped
  to one launch, one recording, one processing attempt, or one report.
- Diagnostics never interrupt recording or processing. Every write is best
  effort, bounded, and off the audio threads. A failure is counted, not thrown.

What diagnostics do not promise:

- **Durability.** Events are appended as they happen without an fsync per
  line. They survive Pipit crashing, except events still queued in memory at
  that moment. The last seconds can be lost on power loss or a kernel panic.
  Pipit fsyncs at session start and stop, after a failure event, and on a
  clean exit. Rotation deletes the oldest data first.
- **Unlinkability.** Reports carry no identifier that follows a Mac, but they
  are not anonymous. The hosting provider sees the sender's IP address. The
  hardware model, OS build, app build, and settings together can single out
  one Mac, especially while Pipit has few users. Automatic uploads from one Mac
  can be linked to each other. A note or contact address identifies the
  sender. Timestamps show when Pipit was used. Product copy says "no account or
  device identifier", never "anonymous".

## Files on this Mac

All under `~/Library/Logs/Pipit/`, outside meeting folders and away from voice
profiles:

| Path | Contents | Limit |
| --- | --- | --- |
| `events/events-YYYY-MM-DD.ndjson` | App events, one JSON object per line | 2 MB per file, then `events-YYYY-MM-DD.1.ndjson`, `.2`; 14 days or 10 MB in total, oldest first |
| `events/nativehost-YYYY-MM-DD.ndjson` | Events from `pipit-nativehost` | 256 KB per day, 14 days |
| `state/launch.json` | The current launch record (below) | One file |
| `state/automatic-sharing.json` | Automatic sharing's cut-off, next daily report, and crashes to send (Automatic sharing) | One file, deleted when sharing is turned off |
| `state/crash-offers.json` | Crash incidents already offered to the person (Crash prompt) | 50 newest |
| `crashes/<incident>.json` | Reduced crash summaries, each with its pid and launch time | 10 newest, 90 days |
| `outbox/<reportID>.json.gz` | The exact body of a report waiting to be confirmed | Until confirmed, at most 7 days |
| `outbox/<reportID>.state.json` | That report's kind, times, attempts, and next attempt (Report service) | With its body |
| `sent.json` | Receipts of sent reports, no secrets (Report service) | Until the person removes them |

The Safari extension is sandboxed and writes
`<app group container>/Diagnostics/safari-extension.ndjson`, capped at 64 KB,
which the app reads into bundles.

Deletion secrets live in the Keychain: service
`com.pipit.app.report-deletion`, account = report ID.

**Clear Diagnostics** deletes `events/`, `state/` (except the current launch),
`crashes/`, and `outbox/` with the deletion secrets of the reports in it.
Deleting `state/` restarts automatic sharing's cut-off from that moment and
forgets which crashes were offered; the crashes are deleted with it. It keeps
`sent.json` and the deletion secrets of sent reports unless the person also
chooses **Clear and Forget Sent Reports**.

## Event lines

```json
{"v":1,"t":"2026-10-21T03:18:16.123Z","launch":"9F1C…","session":"…","job":"…","kind":"processing.stage_failed","p":{"stage":"transcribing","attempt":2,"code":"processing.rate_limited","retryable":true}}
```

| Key | Meaning |
| --- | --- |
| `v` | Line schema version, 1 |
| `t` | UTC time, milliseconds |
| `launch` | Random UUID, new each process launch |
| `session` | Random UUID of the recording session, when the event belongs to one. Also written into that meeting's `session_start` manifest event, so the meeting can be found on this Mac. A report never carries the meeting ID, which contains a title slug. |
| `job` | Random UUID of one processing attempt |
| `kind` | Event name, below |
| `p` | Payload: only the keys listed for the kind |
| `n` | How many events the line stands for, when identical events within 60 s were merged. The first of a burst is written on its own at once and the repeats as one line with `n` when the window closes, so a count is the sum of `n`, with a line that has none counting once |

Payload values are enum raw values, integers, finite doubles, booleans, or
version strings matching `^[0-9A-Za-z.+-]{1,32}$`. Two strings have their own
patterns: `hardware` is a model identifier such as `Mac15,3`, matching
`^[A-Za-z0-9,]{1,32}$`, and `commit` is 7 to 40 lowercase hex digits or
`unknown`. Anything that came from outside Pipit (an add-on's version, an
NSError domain) is checked against its pattern and replaced with `invalid` when
it does not match.

### Kinds (schema 1)

| Kind | Payload |
| --- | --- |
| `app.launched` | `version`, `build`, `commit`, `os`, `osBuild`, `hardware`, `arch` |
| `app.terminated` | (none) |
| `app.previous_exit` | `class` (see Exit classes), `previousLaunch` |
| `permission.state` | `permission` (`microphone`, `system_audio`, `accessibility`, `calendar`, `notifications`), `state` (`granted`, `denied`, `not_determined`, `restricted`) |
| `detection.meeting` | `source` (`MeetingSource`), `evidence` (`browser_addon`, `window_title`, `accessibility`, `process_audio`, `slack`), `browser` (`BrowserKind`, optional) |
| `session.started` | `source`, `trigger` (`auto`, `manual`, `import`, `reconnect`), `segmentSeconds` |
| `session.stopped` | `trigger` (`auto`, `manual`, `quit`, `error`), `seconds`, `segments` |
| `capture.bound` | `track` (`mic`, `remote`), `transport` (`built_in`, `usb`, `bluetooth`, `aggregate`, `virtual`, `other`), `sampleRate`, `channels`, `targets` (remote only) |
| `capture.restarted` | `track`, `reason` (manifest `capture_restart` reason), `count` |
| `capture.health` | `track`, `state` (manifest `source_health` state) |
| `capture.warning` | `code` (`CaptureWarning.dedupKey`) |
| `processing.stage_started` | `stage` (`ProcessingState`), `attempt` |
| `processing.stage_finished` | `stage`, `attempt`, `seconds` |
| `processing.stage_failed` | `stage`, `attempt`, `code` (DiagnosticCode), `retryable` |
| `model.install_started` | `unit` (`LocalModelUnit`) |
| `model.install_finished` | `unit`, `bytes`, `seconds` |
| `model.install_failed` | `unit`, `code` |
| `update.checked` | `outcome` (`up_to_date`, `available`, `failed`), `code` (when failed) |
| `browser.addon_connected` | `browser`, `addonVersion`, `hostVersion`, `protocol` |
| `browser.addon_disconnected` | `browser`, `reason` (`silence`, `closed`, `error`) |
| `browser.connection_rejected` | `browser` (optional), `reason` (`peer_verification`, `capacity`, `protocol`) |
| `browser.message_unparsable` | `browser` |
| `nativehost.started` | `browser` |
| `nativehost.app_unreachable` | `code` |
| `nativehost.exited` | `reason` (`browser_closed`, `app_closed`, `error`), `relayed` |
| `diagnostics.dropped` | `count` (events lost to a full queue or a failed write) |
| `report.sent` | `kind` (`user`, `crash`, `automatic`), `bytes`, `outcome` (`accepted`, `replayed`, `rejected`, `failed`), `status` (HTTP status, when there was one) |

A new kind is added here first, then to the `DiagnosticEvent` enum, with a test
that encodes it.

## DiagnosticCode

A stable string naming a failure category: `<area>.<case>[.<detail>]`, where
detail is a number or a token. Examples:

- `processing.rate_limited`, `processing.server_error.503`
- `processing.audio_unreadable`
- `language_model.unreachable`, `language_model.model_not_found`
- `model.install.network`, `model.install.disk_full`
- `net.NSURLErrorDomain.-1009`
- `error.<domain>.<code>` for an error with no mapping, where the domain matches
  `^[A-Za-z0-9_.]{1,64}$` or is replaced with `other`

Typed errors map to codes at the boundary that catches them. The mapping is
exhaustive over each error enum, so a new case cannot compile without a code.

## Exit classes

`state/launch.json` describes this launch:

```json
{
  "launch": "random UUID, the launch of this launch's event lines",
  "pid": 4242,
  "startedAt": "2026-10-21T03:10:00.123Z",
  "bootSession": "kern.bootsessionuuid",
  "binaryUUID": "LC_UUID of the main executable, lowercase",
  "version": "0.1.8",
  "clean": false
}
```

`startedAt` is the kernel's start time for the process, UTC with
milliseconds, because that is what a crash report's `procLaunch` gives.
`bootSession` and `binaryUUID` are left out when they cannot be read. The file
is written atomically at launch, and a clean exit rewrites it with
`"clean": true`, only when it still holds that launch's record. At the next
launch, Pipit reads the record before writing its own and classifies the
previous launch:

| Class | Evidence | Crash prompt |
| --- | --- | --- |
| `crash` | A Pipit crash report that matches the record (below), whatever `clean` says | Yes |
| `hang` | A Pipit hang report that matches the record. Not produced yet: hang reports are not read | No, listed in diagnostics |
| `clean` | `clean` is true and no report matches | No |
| `system_restart` | The boot session UUID changed and no report matches | No |
| `unclean_unknown` | Same boot, or a boot session that could not be read, and no report: force quit, `kill -9`, debugger, or a report not yet written | No, listed in diagnostics |

The rows are checked in this order. A matching crash report wins over
`clean`: a crash in a teardown handler after `clean` was written is still a
crash.

A report matches the record when all of these hold:

- it is the app's own (`process` is `app`), not the native host's, the
  command line's, or the Safari extension's;
- its `pid` is the record's `pid`;
- its `procLaunch` is at most 120 seconds before the record's `startedAt` and
  at most 2 seconds after it. A report without `procLaunch` matches only when
  it was captured after `startedAt`;
- when both the report and the record name the executable's UUID, they are
  the same.

When two reports match, the one launched nearest `startedAt` is the launch's.

ReportCrash can write a report after Pipit has relaunched. Pipit scans again
2 minutes after launch and upgrades `unclean_unknown` to `crash`, or to `hang`
for a hang report, when a matching report appears. Every other class stands.

## Crash summaries

Read from `~/Library/Logs/DiagnosticReports/<executable>-*.ips`, where the
executable is `Pipit`, `pipit-nativehost`, `pipit-cli`, or
`PipitSafariExtension`. The first line of an `.ips` is a JSON header; the rest
is the report. Only `bug_type` 309, a crash, is read. Hang and spin reports
carry other bug types in a layout Apple does not document and are not read
yet. A report marked `isNonFatal` or `isSimulated` is ignored, since the
process did not end. A report is Pipit's when its bundle identifier is one of
`com.pipit.app`, `com.pipit.nativehost`, `com.pipit.cli`, and
`com.pipit.app.safari-extension`, or, when it names no bundle identifier, when
its process name is one of the four executables. A report that is not JSON, is
cut short, or lacks a pid, an incident identifier, or a time is skipped.

A summary keeps:

```json
{
  "incident": "UUID from the report, lowercase",
  "class": "crash",
  "process": "app",
  "occurredAt": "2026-10-21T03:18:16Z",
  "app": {"version": "0.1.8", "build": 812},
  "os": "15.6.1",
  "osBuild": "24G90",
  "exceptionType": "EXC_BAD_ACCESS",
  "signal": "SIGSEGV",
  "termination": "SIGNAL.11",
  "faultingThread": 0,
  "frames": [{"image": 0, "offset": 123456}],
  "images": [
    {"name": "Pipit", "uuid": "…", "arch": "arm64", "base": 4295000064},
    {"name": "other", "arch": "arm64", "base": 7000000000}
  ]
}
```

`process` is `app`, `nativehost`, `cli`, or `safari_extension`.
`exceptionType`, `signal`, `termination` (`<namespace>.<code>`), and
`faultingThread` are left out when the report has none. A missing version, OS,
OS build, or architecture is `unknown`, and a missing build is 0.

Only the faulting thread's frames, at most 128 from the top, and only the
images those frames name, in the report's order; a frame's `image` indexes the
summary's `images`. A frame without an image index or offset in range is
dropped. An image outside the Pipit bundle, `/System/`, and `/usr/lib/` is
named `other` and carries no `uuid`: no dSYM of ours resolves it, and its UUID
says what someone has installed. Every other string passes the token rule
(Report format) or is replaced with `invalid`, and UUIDs are lowercase.
Dropped: `crashReporterKey`, `asi`, `lastExceptionBacktrace`, exception
reason, message, and subtype, thread names and queues, register state, VM
regions, `procPath`, parent process, and symbol names. Frames are
symbolicated by us with the release dSYMs (`docs/RELEASING.md`).

`crashes/<incident>.json` wraps the summary with what matches it to a launch
record on this Mac; `launchedAt` and `binaryUUID` are left out when the report
has none. Only `summary` goes into a report:

```json
{
  "pid": 4242,
  "launchedAt": "2026-10-21T03:10:00.123Z",
  "binaryUUID": "LC_UUID of the crashed executable, lowercase",
  "summary": {}
}
```

## Report format (schema 1)

A report is one JSON document, gzip-compressed, sent as the request body.

```json
{
  "schemaVersion": 1,
  "reportID": "random UUID, equal to the Idempotency-Key header",
  "kind": "user",
  "createdAt": "2026-10-21T03:18:16Z",
  "deletionSecretHash": "base64url(SHA-256(UTF-8 deletion secret)), 43 chars",
  "app": {"version": "0.1.8", "build": 812, "commit": "40 hex or unknown", "channel": "release", "configuration": "release"},
  "system": {"os": "15.6.1", "osBuild": "24G90", "hardware": "Mac15,3", "arch": "arm64", "memoryGB": 16, "cpuCores": 8, "freeDisk": "20-100GB", "language": "en"},
  "summary": {
    "settings": {},
    "permissions": {},
    "models": [],
    "browserAddOns": [],
    "storage": {},
    "recentFailures": [],
    "diagnostics": {"eventsDropped": 0, "oldestEvent": "…", "eventsIncluded": 1524, "eventsOmitted": 0}
  },
  "events": [],
  "crashes": [],
  "note": "only for kind user, at most 4000 characters",
  "contact": "only for kind user, at most 254 characters"
}
```

`kind` is `user` (Report a Problem), `crash` (sent from the crash prompt), or
`automatic` (the daily upload). `note` and `contact` are the only free text and
are rejected on any other kind.

**Token rule.** Except `note` and `contact`, every string anywhere in the
report must match `^[A-Za-z0-9_.,:+#=-]{0,64}$`: no spaces, slashes, `@`, or
quotes. The server rejects a report that breaks it. This is a second line of
defence: a title, a name, a path, a URL, or an email address cannot pass it.

**Limits.** Compressed body at most 1,048,576 bytes. Decompressed at most
8 MB. At most 20,000 events, 10 crashes, 128 frames per crash. When the events
do not fit, the newest that fit are sent and `summary.diagnostics.eventsOmitted`
says how many were left out; the preview shows the same.

The fixture `Tests/Fixtures/Diagnostics/report-v1.json` is a
synthetic valid report. The website's tests validate the same file, so a change
to the format breaks one side's tests until both agree.

## Report service

Hosted by the website project on Vercel, storing into its Neon Postgres
database. Base URL: `https://pipit-website.vercel.app`.

| Request | Response |
| --- | --- |
| `POST /api/reports` with `Content-Type: application/vnd.pipit.report+json`, `Content-Encoding: gzip`, `Idempotency-Key: <reportID>` | `201 {reportID, receivedAt, expiresAt}`; `200` with the same body for a replay of the same ID and contents; `409` for the same ID with different contents; `400 {error}` for an invalid report; `413` too large; `415` wrong type; `429` rate limited; `503` daily cap or storage full |
| `GET /api/reports/<id>` with `Authorization: Bearer <deletion secret>` | `200 {reportID, receivedAt, expiresAt}` or `404` |
| `DELETE /api/reports/<id>` with `Authorization: Bearer <deletion secret>` | `204` or `404` (unknown ID and wrong secret look the same) |
| `GET /api/cron/expire-reports` with `Authorization: Bearer <CRON_SECRET>` | `200 {deleted}`; Vercel Cron calls it daily |

`/reports/delete` on the website takes a deletion code and deletes the report.

**Idempotency.** The app creates the report ID and the deletion secret (32
random bytes, base64url) before the first attempt, stores the secret in the
Keychain and the exact body in `outbox/`, and retries with the same ID and body.
The server inserts with `ON CONFLICT (id) DO NOTHING` and compares the stored
body hash and deletion hash; equal is a replay, different is `409`.

The secret is 32 bytes from `SecRandomCopyBytes`, written as canonical
base64url (43 characters, no padding). `deletionSecretHash` is
base64url(SHA-256(UTF-8 of that string)). The Keychain account is the report
ID in lowercase, and the report ID is a lowercase UUID everywhere the app
writes it.

**Deletion code.** Shown in Settings as `<reportID>.<deletion secret>` with
**Copy Deletion Code**. It works on the website from any Mac. **Delete from
Server** sends the `DELETE`; on `204` or `404` the receipt and the Keychain
item are removed.

**The app's requests.** The base URL is the Info.plist key
`PipitReportServiceURL`, or `https://pipit-website.vercel.app` when the key is
missing, empty, or not an http or https URL. Every request carries
`User-Agent: Pipit/<version>` and nothing the table above does not name. The
session is ephemeral, with no cookie store, cache, or credential store. A
request waits 30 seconds for an answer and a transfer at most 60. Log lines
name the report ID, the compressed size, and the status, never a body, a
secret, a note, or a contact.

**Outbox.** `outbox/<reportID>.json.gz` is written before the first attempt
and never rewritten; `<reportID>.state.json` beside it holds:

```json
{
  "reportID": "lowercase UUID",
  "kind": "user",
  "createdAt": "the report's createdAt",
  "queuedAt": "2026-10-21T03:18:16.000Z",
  "automatic": false,
  "bytes": 48213,
  "attempts": 1,
  "nextAttemptAt": "2026-10-21T03:19:01.000Z"
}
```

`automatic` marks a report automatic sharing queued; a report the person
sent, from Report a Problem or the crash prompt, is false. What an attempt
does with the report:

| Answer | The report | `report.sent` outcome |
| --- | --- | --- |
| `201`, or `200` with this report's receipt | Moves to `sent.json` | `accepted`, `replayed` |
| `409`, `400`, `413`, `415`, any other `4xx` | Dropped with its secret | `rejected` |
| `429`, `5xx`, no answer, or a `2xx` without this report's receipt | Kept for another attempt | `failed` |

A wait doubles from 60 seconds to at most 6 hours, its upper half jittered,
and is never shorter than `Retry-After` (seconds or an HTTP date, capped at 6
hours). A pass over the outbox stops at the first report that fails, since
the next would meet the same limit. A report still unconfirmed 7 days after it
was queued is dropped with its secret. A report that would break the token
rule or the limits is refused before it is sent.

`sent.json` is `{"receipts": [...]}`, newest first, each
`{reportID, kind, sentAt, receivedAt, expiresAt, bytes}`: `sentAt` is when the
Mac had the answer and the other two times are the service's.

**Server-side storage.**

```sql
create table diagnostic_reports (
  id uuid primary key,
  received_at timestamptz not null default now(),
  expires_at timestamptz not null,
  kind text not null check (kind in ('user', 'crash', 'automatic')),
  schema_version int not null,
  app_version text not null,
  app_build int not null,
  os_version text not null,
  hardware text not null,
  summary jsonb not null,
  note text,
  contact text,
  body_sha256 bytea not null,
  deletion_hash bytea not null
);
create table diagnostic_report_bodies (
  report_id uuid primary key references diagnostic_reports (id) on delete cascade,
  body bytea not null
);
```

The service stores no IP address and logs only the report ID, size, kind, and
outcome. Vercel processes request metadata (IP address, user agent, path) to
serve and protect the site and keeps runtime logs for one hour on the Hobby
plan; that is outside Pipit's control.

**Retention.** `expires_at` is 90 days after receipt. A daily Vercel Cron job
deletes expired reports, so a report is gone within about a day after 90 days.
Neon keeps 6 hours of history, so a deleted row can be restored for up to 6
hours after deletion. A report deleted by its sender is removed at once, with
the same 6-hour window.

**Abuse limits.** One Vercel WAF rate-limit rule on `/api/reports` (5 requests
per 10 minutes per IP), a global cap of 500 reports a day, and a refusal to
store new reports once the database passes 400 MB. The free plan's storage
limit has been reported as both 0.5 GB and 1 GB, so the threshold sits under
the lower one.

## Automatic sharing

Off by default, and off for a settings file written before the setting
existed (`sharesDiagnosticsAutomatically`). Turning it on first shows what is
sent and asks. When on:

- A crash summary is sent at the next launch after a confirmed crash.
- The events since the last confirmed upload are sent once a day.
- Nothing is sent while recording or processing, in Low Data Mode, or on an
  expensive network.
- A failed send retries with backoff and the same report ID; after 7 days the
  report is dropped.
- Turning it off stops sending and empties the outbox of the reports it
  queued.

In detail. The scheduler looks 2 to 10 minutes after launch, then every 15
minutes. A look first retries what is due in the outbox: reports the person
sent always, automatic ones only when nothing below holds them back. While the
setting is off nothing else happens, and nothing automatic is built.

- **Holds.** Recording, a meeting about to record or ending, or processing;
  no network; Low Data Mode (`isConstrained`); an expensive network
  (`isExpensive`, cellular or a hotspot). The look is skipped and the next one
  tries again.
- **Start.** The first look with the setting on writes
  `state/automatic-sharing.json`: events from that moment on, the first daily
  report 24 hours plus up to an hour later. Events collected before it was
  turned on are never sent.
- **Crash.** A `crash` found at launch, or by the rescan 2 minutes later, is
  noted in the state file and sent 1 to 5 minutes later as a `crash` report
  with the events and crash summaries from the crashed launch's start. Each
  incident is sent once.
- **Daily.** When due, and when no daily report is already queued, an
  `automatic` report with the events since `eventsSince`. When the service
  confirms it, at once or on a retry, `eventsSince` moves to that report's
  `createdAt`. The next one is due 24 hours plus up to an hour after the
  attempt, whatever its answer.
- **Off.** The state file is deleted, and every automatic report in the
  outbox is removed with its secret. One that was already attempted is also
  deleted from the service, best effort: the service may have stored it with
  its answer lost. Turning sharing on again starts from that moment.

```json
{
  "eventsSince": "2026-10-21T03:18:16.000Z",
  "nextDailyAt": "2026-10-22T03:41:02.000Z",
  "pendingCrashes": [{"incident": "lowercase UUID", "since": "…", "notedAt": "…"}],
  "sentCrashes": ["lowercase UUID, the 50 newest"]
}
```

## Crash prompt

When the previous exit is classified `crash`, at launch or by the rescan, and
automatic sharing is off, the incident is added to `state/crash-offers.json`.
If it was not there, Pipit posts one notification, "Pipit quit unexpectedly",
with **Review…**, and sets `PipitRuntime.crashReportOffer`, which the menu
uses to highlight **Report a Problem…** until the person opens it or
dismisses the offer. Review opens the report to read before sending; a
dismissed or ignored notification sends nothing. `hang`, `unclean_unknown`,
`system_restart`, and `clean` are never offered. The notification follows the
Show notifications setting; the highlight does not.
