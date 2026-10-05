---
paths:
  - "Sources/PipitUI/**"
  - "extension/**"
---

## Product copy

UI text is written for the person using the app. It says what a thing is,
what it does, or what to do next, and nothing else.

- Say what the app does for the person, never how it does it. A user does
  not care about tracks, prejoin screens, relays, backoffs, or which model
  computes timings. "Pipit records your meetings and saves the transcript
  and notes as files." Mechanism belongs in code comments and docs.
- Write what the app does and why it needs the grant. Leave out what it does
  not do.
- Never turn a rule you were given into reassurance in the UI. A rule
  explains a bug to you. It is not copy.
- No reassurance claims that read as marketing. "Nothing leaves your Mac",
  "never uploaded", "stays private" are cut. State the plain fact instead:
  "Processing runs on this Mac."
- Leave the interface to show where the person is. Copy does not describe the
  screen or how long setup takes.
- One line per permission or setup item: verb, object, reason. "Reads
  window titles to tell which meeting is on screen."
- A status line says what the person gets, not what the plumbing is doing.
  "Meeting detection in Firefox is on", not "connected and reporting within
  the freshness window".
- Labels over sentences. "Optional" as an eyebrow, not "Optional, and both
  make Pipit better". "Beta updates" with a switch, not a paragraph.
- A caption exists only when the control's label leaves a real question.
- Name the general capability, not today's list of providers, unless the
  line is specifically about one. "Your meetings", not "Slack huddles and
  Meet and Zoom calls", so the copy does not need rewriting when support
  widens.
- Read every line as a first-time user. If it answers a question they did
  not ask, delete it.
