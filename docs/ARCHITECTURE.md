# Architecture

Pipit runs as one macOS process with separate modules for detection, capture,
storage, speech processing, and interface code. A small native host relays
browser events to the application.

## Modules

```text
PipitApp
└── PipitUI
    └── PipitServices
        ├── PipitDetection
        ├── PipitIntegrations
        ├── PipitLocalAI
        ├── PipitSpeakers
        ├── PipitAudio
        └── PipitCore

pipit-nativehost    browser event relay
pipit-cli           command line tool for people and agents
pipit-eval          benchmark and diagnostic tool
```

`Package.swift` owns those modules and the test suite. `Pipit.xcodeproj` is a
shell over the same package, generated from `project.yml`. It builds the app
bundle and the native host, and links the modules as package products.

`PipitCore` imports Foundation and contains decisions that do not require I/O.
It owns session policy, manifests, storage models, chunk planning, transcript
assembly, and recovery decisions.

The other modules own external resources and state. `PipitAudio` owns audio
devices and files. `PipitDetection` collects meeting evidence. Integrations own
system and network APIs. `PipitLocalAI` owns on-device speech models.
`PipitSpeakers` owns the local voice database. `PipitServices` connects those
modules to the application lifecycle.

## Meeting detection

Detection adapters report evidence from accessibility controls, window titles,
audio process state, and the browser sensor. They do not start or stop capture.
`SessionController` combines the evidence and owns the recording lifecycle.

```text
idle -> candidate -> recording -> reconnecting -> ended
          |                            |
          └-> discard                  └-> append another recording
```

A candidate starts both audio sources into a 15-second memory ring. Confirmation
creates the meeting directory and flushes the ring to disk. An abandoned
candidate leaves no files. Manual recordings ignore provider evidence.

When a call disconnects, Pipit closes the current recording and waits for a
rejoin. A rejoin creates another immutable recording under the same logical
meeting. Linking and separating recordings changes metadata and does not rewrite
audio.

## Audio capture

Pipit records two sources against the same host clock:

```text
microphone       -> AVAudioEngine -> SegmentWriter(mic)
meeting process  -> CoreAudio tap -> SegmentWriter(system)
```

The streams stay separate during capture. Pipit aligns and mixes them after the
meeting using the host timestamps stored with each segment.

Audio callbacks copy buffers onto a private serial queue. File creation,
manifest writes, device rebuilds, and teardown run on the capture control queue.
Audio callbacks perform no file I/O.

The microphone and process tap use different health policies. Missing microphone
buffers indicate a failed input. A process tap may remain silent while its
application produces no audio. Pipit rebuilds the tap when the application
reports output and callbacks stop arriving, and when the callbacks keep arriving
carrying nothing but zero samples. Silence that survives that rebuild is
reported to the user.

Each track is written against the capture clock. When a source stops delivering,
the writer fills the missing time with silence, up to a bound, so the audio after
the hole is not placed early against the other track. That covers a stall that
began while the session waited out a reconnect: the engine holds the rebuild it
saw while no writer existed and reports it when the memory ring is flushed.

Capture writes 30-second CAF segments and appends lifecycle records to
`raw/manifest.jsonl`. Each segment records its own sample rate and frame count.
Recovery reads the manifest and file lengths, adopts complete audio after a
crash, and resumes the meeting from its last durable state.

## Storage

The default meeting root is
`~/Documents/Pipit/Meetings/YYYY/MM/<meeting>/`. Users can change it in
Settings.

```text
meeting/
├── transcript.md
├── recording.m4a
├── notes.md
├── summary.md
└── raw/
    ├── manifest.jsonl
    ├── audio/
    ├── api/
    ├── alignments/
    ├── metadata.json
    ├── transcript.raw.json
    ├── diarization.raw.json
    ├── sensors.raw.json
    ├── speakers.map.json
    └── transcript.json
```

Source audio, manifest entries, raw model output, and imported originals are
immutable. Titles, notes, speaker mappings, and meeting metadata are mutable.
Markdown, summaries, and the mixed recording are derived files and can be
regenerated.

`recording.m4a` is aligned to the same timeline as `transcript.json`, so the
Meetings window plays it and follows the transcript word by word.
`PlaybackTimeline` lays the mixdowns of a call recorded in parts end to end and
maps a playback position to a recording, a turn, and a word.

Completed source tracks are compacted from CAF segments into AAC after Pipit
verifies their decoded duration. Segment deletion starts only after the archive
and metadata are durable. An interrupted compaction resumes during startup.

Voice profiles are stored separately at
`~/Library/Application Support/Pipit/Speakers/voices.sqlite`. Meeting folders
and exports contain no voice vectors. A recording made by reading the enrolment
script aloud is kept beside it, under
`~/Library/Application Support/Pipit/VoiceEnrollment/<identity>/`, and is deleted
when that person's learned voice is forgotten or they are deleted.

## Speech processing

```text
finalizing -> audio_safe -> transcribing -> diarizing
           -> resolving_speakers -> enriching -> complete
```

`audio_safe` marks the point where the recording is durable. Network work starts
only after this state. Each later stage records its state and can resume after a
failure.

`transcribing` begins by subtracting the far end from the microphone. A call
taken on speakers puts the far end back into the microphone through the air.
Pipit records that far end separately through the process tap, and that
recording is the reference an echo canceller needs. The canceller is two stages:
LocalVQE's adaptive filter, which lines the far end up on its own and removes
the linear part of the echo path, then DTLN-aec, a network trained on speech
that removes the distortion a loud laptop speaker adds. Both are vendored, the
filter as C++ under `Sources/CLocalVQE` and the network as Swift over
Accelerate in `PipitAudio`, with their model files as resources of that module.
`Benchmarks/aec` is the harness that chose them. It scores a canceller by the
far-end words a transcript would put under the user's name and the user's own
words it would lose. Measured on 10 October 2026, this pair leaked 0.18 words
per minute on clips with a nonlinear far end, as a loud laptop speaker
produces, and kept 76.6% of the near-end words, where the WebRTC canceller
that shipped before it kept 60.4%. On real-device recordings the pair leaked
0.56 words per minute and kept 92.8% (WebRTC: 0.85 and 98.3%), and on 65
recorded meetings the two scored the same. The far end is handed to the
canceller 10 ms early, because the tap's timestamps can run a few milliseconds
behind the microphone's and no canceller models an echo that arrives before its
reference.

The far end is lined up with the microphone once per run of the recording. A
call that dropped and was rejoined holds several runs under one manifest, and
each run opens writers of its own. A source that stalled around the rejoin lost
a different amount of audio on each track, so the far end can sit seconds from
where it sat in the run before: on one 59 minute call it had to move +1.76 s onto
the microphone's clock before the rejoin and -1.46 s after. Each run is placed from
its own host times, then measured. The loudness envelopes of that run's
microphone and far end are compared, and the measured offset replaces the
manifest's when the peak is clear, beats the manifest's offset by a margin and is
larger than the filter absorbs on its own. A run too short to measure keeps the
manifest's offset, and a run in which the far end recorded nothing is handed to
the canceller as silence. The canceller runs once, in order, over the whole
microphone and is given the far end at each run's own offset. The cleaned file
stays one file on the microphone's clock.

The result is written to `raw/audio/mic.cleaned.m4a`, and every stage from
transcription onward reads it in place of the recording, which is the segment
chain before compaction and `mic.m4a` after it. The recording itself is never
written to. The cleaned file is kept unless the pass measurably took the user's
own speech down. Before cleaning, Silero voice activity detection runs over the
raw microphone. The judged windows are the quarter-second windows where that
detector marks speech, the microphone is above its floor (its quietest twentieth
plus 10 dB), and the far end was quiet in the window and for the second before
it. The second after the far end is left out because the room's reverberant tail
of the echo is still arriving and the canceller is right to remove it. Quiet room
noise is left out because the speech network stage suppresses it by design.
Over the judged windows the level must not have dropped more than 2 dB at the
median, and no more than one window in ten may have dropped by more than 10 dB.
Where no detector is installed the speech requirement is dropped and the level
floor and the one-second tail pick the windows alone. Four cases keep the
microphone exactly as it was captured: a pass that damaged the user's own windows, a meeting whose far-end track holds nothing, a
meeting whose far end played for under ten seconds or an imported single-track
recording, and a meeting whose cleaning pass failed.

The record of a cleaned meeting holds what happened to the far end, measured
on the audio: the median drop over the windows it was playing in, and how well
the microphone's loudness envelope followed the far end's before and after the
pass, averaged over the runs with each weighted by the audio it was measured on.
A cleaned track whose envelope still follows the far end holds the
speakers, and the meeting shows a line saying so, because the transcript may
then show the other side's words as the user's. The assembler also drops a
microphone line that is mostly the far end's own words said at the same
moment, which is what such a track produces.

The pass runs once per meeting and records what it decided, whatever it decided.
A pass that failed is never retried. If the disk fills during it, that meeting is
never cleaned, and the user keeps the transcript they would have had before the
cleaner existed. Retrying instead would repeat a full decode and encode of the
whole meeting on every resumed run of a machine that cannot write the file.

A person can run it again on a finished call (Remove echo in the meeting
header), for a meeting recorded before the current canceller or cleaned under
an older rule. `ProcessingPipeline.redoMicrophone` refuses a one-track
recording, a meeting that is not finished, and one with no far end recorded.
Otherwise it copies the files it will replace to
`Application Support/Pipit/Backups/<meeting>/<time>/`, sets
`microphoneRedoRequestedAt`, moves the meeting back to `transcribing`, and runs
that stage as a microphone-only pass: drop the microphone's raw chunks,
alignments and `speech.json`, clean the recording again (the cleaner reads the
recording, never its own output), transcribe the microphone, then assemble the
transcript and markdown again and rebuild the mixdown. The far end's words, the
diarization runs, every cluster name, the local user's name, titles, notes and
the summary are not touched. Corrections and line cuts on microphone lines are
removed, because they are anchored to the old words and chunks. Corrections on
the far end's lines stay. The marker is cleared in the same write that marks
the meeting complete, so a crash or a failure leaves the old transcript
readable and the launch sweep or Retry finishes the pass. Voice profiles are
not re-learned, and enrolments that came from a removed correction are not
retracted.

The alignment is per run and the decision is not: one decision covers the whole
meeting. The median is taken over every window where the far end was playing,
whichever run it fell in, and the cleaned file is kept or thrown away entire. A
call that starts on speakers and moves to headphones half way through keeps the
cleaned track across the headphone stretch. Plugging in headphones mid-call is
ordinary. Deciding per window rather than per meeting is not built.

A cleaned meeting keeps a third audio file. `mic.cleaned.m4a` sits beside the
two archived tracks at the same 48 kbps mono, so a cleaned meeting costs about
50% more archived audio than one left as recorded. Settings reports the total
under Storage, which walks the meeting folders and counts every file in them.

Local processing uses Apple SpeechAnalyzer on supported macOS versions or
Parakeet through FluidAudio. Speaker separation runs locally unless the selected
cloud model returns words and speakers together. Voice matching stays local for
every configuration.

Long recordings are divided into overlapping chunks when a backend requires it.
Completed chunks are written as they arrive. Transcript assembly places both
tracks on one timeline, removes repeated overlap text, and assigns words to
speaker intervals.

Pipit runs one processing job at a time. A queued job waits between stages while
capture is active. Capture keeps priority over speech work.

Optional enrichment reads the canonical transcript and can produce a title,
summary, notes, and textual speaker suggestions. An enrichment failure leaves
the recording and transcript available for retry.

## Speaker identity

Diarization writes immutable speaker intervals. `speakers.map.json` adds mutable
cluster mappings, line corrections, and transcript boundaries above that raw
output. Re-analysis appends another diarization run and keeps the previous run.

`sensors.raw.json` records what the meeting client itself said: the roster keyed
by the platform's own identifier, who was seen unmuted, and who held the floor
when. Mute state is kept as a record of what the client reported and is not
consulted when deciding who spoke, because holding the floor settles that and a
tile whose overlay never resolved would otherwise outrank it.
It is immutable like the diarization beside it, because it is evidence about a
recording rather than a conclusion about one.

Three things read it. Word attribution assigns each transcribed word on the
remote track to the sensor turn covering it, keyed on the platform's own
participant identifier, and the diarizer attributes only the words no turn
covers: gaps in the readings, overlap, and every meeting recorded without a
readable client. Voice enrollment embeds each participant's turns cut to the
solo speech the diarizer heard inside them, so voice memory learns a
known-identity voice without waiting for a confirmation. Cluster naming matches
a diarization cluster to whoever's turns dominate it, which carries the name
onto the stretches the sensor did not see.

Sensor names sit at an origin above a voice match and below the microphone
track, so a person's own correction always wins. The sensor never sets the
diarizer's speaker count and never moves a boundary.

The far-end track never holds the local user, so a participant who is the local
user is marked and kept out of word attribution and cluster naming. The meeting
client's own flag is used where it is authoritative. Otherwise the participant
the microphone heard speaking is marked, and so is any participant whose name is
the local user's name or one of their aliases. The marking is applied each time
the record is read; `sensors.raw.json` keeps what the client said.

A confident voice outranks a client name that names somebody else. After voice
matching, a cluster that resolved to a named person at the high band is compared
with the name the client put on it. If the client's name belongs to another
known person, or to nobody the voice's person could be, the cluster and the
participant's `sensor_` key take the voice's person. If the name is another
spelling of the same person ("Firstname Lastname" for a stored "Firstname L"),
the speaker shows the stored name and the client's spelling is added to that
person's aliases. A client name that equals a stored name or alias, ignoring
case and diacritics, links to that person even without a voice match, and no new
person is made from it. Where no voice match is confident the client's name
names the speaker as before. Names a person set or confirmed are never touched.

A cluster split evenly between two people is named for neither, a timeline
covering too little of the diarized speech names nobody, which is what
disagreeing clocks look like, and a floor nobody confirmed ends at the last
reading that saw it rather than running to the end of the call. A sensor that reports nothing leaves
naming exactly as it was before, which is by voice alone.

One identity is the person using this Mac, flagged in the store and named in
Settings from that row. The microphone track of a remote call is theirs by
construction, so it is written into `speaker_occurrence` under the `local` key
with no vector: every count of the meetings a person was in reads that table,
and the track it covers produces no diarization cluster of its own. Taking a
name off that track writes the row back with nobody behind it.

Their profile can also be built without a meeting. Reading a short script aloud
is embedded as one speaker and enrolled directly, which is what makes an
in-person or imported recording recognisable as them: neither carries a
microphone track whose speaker is known in advance.

Named people and recurring unnamed voices share one identity store. A confirmed
speaker name can add meeting audio to a profile. Automatic recognition reads the
profiles and never trains them. Human corrections take precedence over automatic
matches.

Line corrections use positions on the meeting timeline. They remain attached to
the corrected audio when transcript assembly or speaker re-analysis changes line
and cluster identifiers.

A cluster identifier is only meaningful inside one recording. A call that dropped
and was rejoined is two recordings under one row, and both number their speakers
from zero, so every correction names the recording it belongs to.

## Reading the archive

The meetings window lists every recording, grouped by when and searched by title,
notes, speaker name, and transcript text. The transcripts are read once in the
background, so search covers titles immediately and words a moment later.

Selecting a meeting opens the same controls that used to appear only when a
meeting finished. Naming a speaker rewrites `speakers.map.json` and re-renders
`transcript.md` for the recording it belongs to.

Right-clicking a row archives it or moves it to the Trash. Archiving writes
`archivedAt` into `metadata.json` and moves the row to the Archived filter,
where it is put back from. Every file stays where it is.

Moving to the Trash asks first, then hands every folder the conversation was
recorded in to the Finder's Trash, both halves of a rejoined call included, and
drops that meeting's rows from `speaker_occurrence` so it stops counting towards
how many meetings a voice has been heard in. The confirmed voice material stays.
Putting a folder back from the Trash puts the meeting back in the list, and a
job still running for it carries on with the restored folder. The occurrences do
not come back, because only a processing stage writes them.

The meeting being recorded is refused. A folder that will not move leaves the
recording the conversation started with in place, so its row still reaches what
is left, and an archive on a volume with no Trash is reported as the volume
rather than as a fault on one meeting.

An imported recording is filed under the date the recorder wrote rather than the
date the file was copied. Pipit reads the container's creation date, then a
timestamp in the filename, then the file's date on this Mac, and refuses anything
before 1990 or more than a day ahead. `metadata.json` records which of the three
it used. The manifest remains the authority on how long the audio runs.

## Command line and agent skill

`pipit-cli` ships in `Pipit.app/Contents/MacOS` and links only `PipitCore`. It
reads the archive the same way the application does and loads no speech model.
`pipit root`, `pipit meetings list`, and `pipit meetings show` print the
meetings folder chosen in Settings, the meetings in it, and the files of one
meeting. `--json` output carries a `schemaVersion`, and a change that is not
additive raises it.

The file is named `pipit-cli` because `pipit` would collide with the `Pipit`
executable on a case-insensitive volume. `pipit-cli install` links the name
`pipit` into `~/.local/bin` and copies the skill from `Contents/Resources/skills`
into the skills folder of each agent found in the home directory
(`~/.claude/skills` and `~/.agents/skills`). It replaces a skill folder only when
its `SKILL.md` is named `pipit`, and refuses to link from a disk image.

Settings has an Agents page that does the same through `AgentInstaller`, the one
type both the tool and the page call. Each row reads Installed, Update available
(the installed copy differs from the one in the app), or Not installed, and
Remove deletes only a link to a `pipit-cli` or a skill folder named `pipit`.
`pipit-cli uninstall` does the same from a terminal.

`skills/pipit/SKILL.md` is the skill. It tells an agent to run `pipit` and read
the files it names, and it leaves the archive layout to the command so a layout
change does not leave installed skills pointing at old paths. The same folder is
discoverable from the repository by skill installers.

## Browser sensor

```text
content script -> browser background -> pipit-nativehost -> Unix socket -> Pipit
```

The sensor reports provider, meeting state, URL, and audible-tab state. Native
detection continues when the extension disconnects.

Pipit accepts sensor connections only from its bundled native host when a browser
launched that host. Sensor evidence is combined with native evidence and cannot
end a recording by disappearing on its own.
