# Changelog

What changed in each release, written for the person updating Pipit. Each
section becomes the top of its GitHub release and the notes in the app's
update window. The [releases page](https://github.com/Neeeser/Pipit/releases)
adds the list of merged pull requests and their authors below it, and holds the
notes for releases before 0.1.9. See [docs/RELEASING.md](docs/RELEASING.md) for
how a section gets written.

## 0.1.13

Pipit tells speakers apart more accurately and shows its progress while it processes a meeting.

### New
- Pipit separates speakers more accurately once you install the new speaker model from Settings.
- Unnamed speakers are numbered in the order they first talk.
- Pipit shows each step and a progress bar while it processes a meeting.

### Fixes
- The browser add-on cards no longer say an installed add-on is missing.
- A Google Meet participant no longer shows up as two speakers.
- Pipit now names Google Meet speakers when people talk over each other.
- Your words are no longer dropped when you repeat what the other side just said.
- Settings no longer asks you to re-download models that are already current.
- Settings no longer shows a disk as full when it has free space.

## 0.1.12

Pipit can now use Apple Intelligence to write meeting summaries, and it uses much less CPU and memory.

### New
- Pipit can now use Apple Intelligence to write meeting summaries.

### Fixes
- Pipit uses far less CPU and memory while it sits idle.
- Separating speakers uses far less memory.
- Your own voice is no longer filed under another speaker's name.
- Pipit keeps the speaker names you gave when you re-analyze a meeting.
- Browser calls keep recording when you switch tabs.
- Call audio comes back within a few seconds after a silence, instead of about 20.
- Merged meetings stay in one folder with one transcript.
- The arrow on a speaker's chip steps through that speaker's lines in merged meetings.
- Meetings filter labels no longer get cut off in a narrow sidebar.

## 0.1.11

Pipit has a new look, shows a live transcript during calls, and can now trim and merge recordings.

### New
- Pipit's windows have a new Mac look, and a wide Meetings window shows the summary beside the transcript.
- Pipit can now show a live transcript during a call.
- Summaries are now one page: an overview, a topic timeline with your notes, and action items that jump to their moment.
- You can now trim the start or end of a meeting.
- You can now merge a meeting recorded in pieces into one.
- The player can show speaker lanes with a time ruler and each person's talk time.

### Fixes
- Slack huddles now start recording on their own.
- A Slack huddle keeps its name when you switch conversations.
- A Slack huddle is named after the person you talked to.
- Browser calls keep recording while you work in another tab.
- The browser extension reconnects after an update.
- A meeting that keeps failing is no longer retried at every launch.

## 0.1.10

The Firefox add-on no longer keeps disconnecting, and About Pipit has a new look.

### New
- About Pipit now shows the version and build, with links to the website, source code and privacy page.

### Fixes
- The Firefox add-on no longer disconnects and reconnects every few seconds.

## 0.1.9

Pipit can now play back meetings with the transcript following along, and you can choose which AI writes your summaries.

### New
- You can now play a meeting's recording while the transcript follows along.
- You can now choose which AI writes your summaries and notes, including local models through Ollama.
- Meetings in Safari, Chrome, Edge, Brave and Arc now get their name and length automatically.
- You can now report a problem from inside Pipit and see what it sends first.
