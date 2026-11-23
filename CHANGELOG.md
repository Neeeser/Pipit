# Changelog

What changed in each release, written for the person updating Pipit. Each
section becomes the top of its GitHub release and the notes in the app's
update window. The [releases page](https://github.com/Neeeser/Pipit/releases)
adds the list of merged pull requests and their authors below it, and holds the
notes for releases before 0.1.9. See [docs/RELEASING.md](docs/RELEASING.md) for
how a section gets written.

## 0.1.13

<!-- One or two lines on what this release is, then rewrite the items below for the person updating. Cut fixes to things that were never released. -->

### New
- Count and separate speakers more accurately in finished meetings
- Install the new speaker model from Settings with one Update button
- Separate speakers in recordings longer than three hours with the new speaker model
- Show each processing step and a steady progress bar while a meeting is processed
- Number unnamed speakers in the order they first talk

### Fixes
- Stop the browser add-on cards saying an installed add-on is missing after Pipit starts
- Stop showing one Meet participant as both a named and an unnamed speaker
- Keep your words when you repeat what the other side just said
- Stop asking to re-download models that are already current after an update
- Name Google Meet speakers on calls where people talk over each other
- Show the real free disk space in Settings when the disk reports none

## 0.1.12

Summaries can now be written by Apple Intelligence, and Pipit uses much less CPU and memory.

### New
- Write meeting summaries with Apple Intelligence on this Mac, with nothing to install.

### Fixes
- Pipit uses far less CPU and memory while it sits idle.
- Separating speakers uses far less memory.
- Your own voice is no longer filed under another speaker's name when it reaches your microphone.
- Speaker names you gave are kept when you re-analyze a meeting.
- A browser call keeps recording when you switch to another tab, including Zoom in the browser, and when its page stops showing the meeting's name.
- Call audio comes back within a few seconds after it goes silent, instead of about 20.
- A merged meeting stays in one folder with one transcript, and the arrow on a speaker's chip steps through that speaker's lines.
- The Meetings filter labels stay whole at the narrowest sidebar width on newer macOS.

## 0.1.11

A redesigned Meetings window, a live transcript during calls, and trimming and merging for your recordings.

### New
- The Meetings, People, Settings and Setup windows have a new Mac look, with the summary beside the transcript when the window is wide.
- See what's being said during a call in a live transcript window.
- The summary is one page: an overview, a timeline of topics with your notes, and action items that jump to their moment.
- Trim the start or end of a meeting from the player.
- Merge meetings that were recorded in pieces into one.
- Open speaker lanes across the full player, with a time ruler and each person's talk time.

### Fixes
- Slack huddles start recording on their own, and keep their name when you switch conversations.
- A Slack huddle is named after the person you talked to, not the channel left open.
- A browser call keeps recording while you work in another tab, and the browser extension reconnects after an update.
- A meeting that keeps failing is no longer retried at every launch.

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
