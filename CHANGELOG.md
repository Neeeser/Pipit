# Changelog

What changed in each release, written for the person updating Pipit. Each
section becomes the top of its GitHub release and the notes in the app's
update window. The [releases page](https://github.com/Neeeser/Pipit/releases)
adds the list of merged pull requests and their authors below it, and holds the
notes for releases before 0.1.9. See [docs/RELEASING.md](docs/RELEASING.md) for
how a section gets written.

## 0.1.11

<!-- One or two lines on what this release is, then rewrite the items below for the person updating. Cut fixes to things that were never released. -->

### New
- Give the transcript most of the Meetings window at a quarter of the screen
- Give open speaker lanes the full width of the player, with a time ruler and talk time
- Show the meeting summary as one page: overview, a timeline with your notes, and action items with their moments
- Merge meetings that were recorded in pieces into one
- Trim the start or end of a meeting from the player bar
- Give the Meetings, Settings, People and Setup windows a native Mac look, with the summary beside the transcript in wide windows

### Fixes
- Start recording Slack huddles on their own and keep their name when you switch conversations
- Keep recording a browser call while you work in another tab, and reconnect the browser extension after an update
- Name a Slack huddle after the person you talked to, not the channel left open
- Stop a meeting that keeps failing from being retried at every launch

## 0.1.10

Fixes repeated Firefox add-on disconnections and updates About Pipit.

### New
- About Pipit shows the landscape artwork, version, build, and links to the website, source code, and privacy page.

### Fixes
- Fixes the Firefox add-on repeatedly disconnecting and reconnecting every few seconds.

## 0.1.9

Play back your meetings and follow along in the transcript, and choose which AI writes your summaries.

### New
- Play a meeting's recording and follow along in the transcript as it plays.
- Choose the AI that writes your summaries and notes, from OpenAI to a model running on your own Mac with Ollama.
- Meetings in Safari, Chrome, Edge, Brave and Arc now get their name and length automatically.
- Report a problem from inside Pipit, and preview exactly what's sent before you send it.
