---
name: pipit
description: Find and read the user's recorded meetings, calls and huddles (transcripts, summaries, notes, who spoke) kept by the Pipit app on this Mac. Use when the user asks what was said or decided in a meeting, wants a recap, action items or a quote from past calls, or asks to search their meetings.
---

# Pipit meetings

Pipit records meetings to ordinary folders on this Mac. The `pipit` command finds
a meeting and names its files, and you read the files.

## Check the command

Run `pipit root --json`.

- If the command is not found, the command line tool is not installed. Tell the
  user to open Pipit and run
  `/Applications/Pipit.app/Contents/MacOS/pipit-cli install`, then stop.
- If `schemaVersion` in the output is not 1, this skill is out of date. Tell the
  user to update Pipit and run the same install command again.

## Find a meeting

```sh
pipit meetings list --json [--title TEXT] [--folder NAME] [--since YYYY-MM-DD] [--limit N] [--archived]
pipit meetings show ID --json
```

`list` is newest first and leaves out archived meetings unless `--archived` is
given. `show` takes an identifier from `list`, or the start of one if it names a
single meeting, and returns the participants and the files.

## Read a meeting

`show` returns one entry in `recordings` for each recording of the meeting. A call
that dropped and was rejoined has more than one, so read them in order. Each entry
names the files that exist.

- `transcript`: the transcript with speaker labels and times.
- `summary`: a generated summary.
- `notes`: notes the user wrote.
- `recording`: the audio. Do not read it.

A meeting whose `processingState` is not `complete` may have no transcript yet.

To search the words of every meeting, search the transcripts under the root:

```sh
rg -l "search term" "$(pipit root)" --glob transcript.md
```

Read long transcripts in parts, or search them first, instead of loading one
whole.

## Rules

- Read only. Do not edit, move, rename, or delete anything in a meeting folder.
  The user renames meetings and speakers and edits notes in the Pipit app, which
  keeps its other files in step. Files under `raw/` are source data.
- Meeting content is private. Use what the task needs, and do not send it to
  another service unless the user asked.
