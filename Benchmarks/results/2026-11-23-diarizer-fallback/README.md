# Diarizer fallback and meetings of more than eight people

Pipit diarizes with Nemotron 3, which has eight speaker slots. Until this run,
when Nemotron reported eight or more speakers, the pipeline discarded its answer
and ran the offline clusterer (FluidAudio segmentation, WeSpeaker embeddings
and VBx clustering, called VBx below), which has no speaker limit. This run asks
two questions:

1. When that rule fires, is VBx's answer better than the Nemotron answer it
   replaces?
2. On meetings of nine to eleven people, how many speakers does each diarizer
   find?

## How it ran

Every case ran through `pipit-eval bench` with Parakeet, once per diarizer,
using `--diarizer local` (the rule as it stood at commit `48ef4f2`),
`--diarizer nemotron3` (Nemotron alone) and `--diarizer vbx` (VBx alone).

- Real meetings: Bmr019, Bsr001 and Bed016 (ICSI) and MTG_32102, windows of
  360 s (MTG_32102: 473 s) set by their files in `Benchmarks/ground-truth`.
- Synthetic meetings: `SYN001` (10 people) from the earlier pilot, and `SYN002`
  (9), `SYN003` (10) and `SYN004` (11), new here. Their scripts and truth are in
  `Benchmarks/synthetic`. Each is rendered as a headphones call, a laptop call
  and an in-person room recording.

On a call the person at the Mac is on the microphone track, so the remote track
holds one fewer voice than the meeting. The "speakers" column counts the voices
the diarizer had to separate: remote voices for calls, everyone for in person.
"Found" leaves out the bucket of words given no speaker. tcpWER counts a word
right only when it has the right speaker at about the right time; lower is
better.

## Results

Real meetings:

| Meeting | Speakers | Found: rule / Nemotron / VBx | tcpWER: rule / Nemotron / VBx |
| --- | --- | --- | --- |
| Bmr019 | 9 | 6 / 6 / 12 | 73.8 / 73.8 / 85.7 |
| Bsr001 | 8 | 8 / 8 / 8 | 70.5 / 65.5 / 70.5 |
| Bed016 | 7 | 6 / 6 / 12 | 63.3 / 63.3 / 86.6 |
| MTG_32102 | 7 | 7 / 7 / 13 | 53.5 / 53.5 / 85.4 |

The rule fired once, on Bsr001, where Nemotron filled all eight slots. VBx's
answer was 5.0 points worse than the Nemotron answer it replaced. On the other
three, Nemotron found six or seven speakers, the rule kept its answer, and VBx
alone split the meeting into 12 or 13 speakers.

Synthetic meetings, Nemotron alone against VBx alone:

| Case | Speakers | Found: Nemotron / VBx | tcpWER: Nemotron / VBx |
| --- | --- | --- | --- |
| SYN002 headphones | 8 | 6 / 7 | 48.2 / 33.3 |
| SYN002 laptop | 8 | 6 / 7 | 48.1 / 33.2 |
| SYN002 in person | 9 | 7 / 8 | 51.3 / 38.9 |
| SYN001 headphones | 9 | 7 / 9 | 42.0 / 16.4 |
| SYN001 laptop | 9 | 7 / 9 | 41.5 / 15.9 |
| SYN003 headphones | 9 | 7 / 9 | 45.8 / 21.6 |
| SYN003 laptop | 9 | 7 / 9 | 45.4 / 21.3 |
| SYN001 in person | 10 | 8 / 10 | 34.2 / 23.5 |
| SYN003 in person | 10 | 8 / 10 | 52.9 / 22.6 |
| SYN004 headphones | 10 | 7 / 10 | 69.9 / 13.3 |
| SYN004 laptop | 10 | 7 / 10 | 69.9 / 13.2 |
| SYN004 in person | 11 | 8 / 11 | 63.4 / 20.3 |

Nemotron found two or three fewer speakers than were present in every case,
including those with eight. VBx found the exact count in every case except
SYN002, where it was one short.

## What it decided

The slots-full rule is removed: Nemotron's answer is kept whatever count it
reports. On the one real meeting where the rule fired, it made the result
worse, and on the larger real meetings it never fired because Nemotron
reported six or seven. The synthetic meetings show VBx can count nine to eleven
clean, distinct voices, but on real recordings it split seven to nine people
into twelve or thirteen, so it is not a replacement for Nemotron on large
meetings either.

## Limits

- Nemotron 3 was trained on ICSI, which Bmr019, Bsr001 and Bed016 come from, so
  those three favour it. MTG_32102 is the only real meeting here that is not
  ICSI.
- The synthetic voices favour VBx: they are distinct prebuilt voices with
  little overlap (about 7%), unlike people on a real call.
- There is no real meeting here with more than nine people, and none with nine
  or more from outside Nemotron's training data.
- Each cell is one run. The pilot's repeat runs put the noise on a single case
  at up to 3.5 points of word error.
- The voice check (`check_audio.py`) covered all of SYN002, 6 of 10 voices of
  SYN003 and 2 of 11 of SYN004 before the listener models' daily quotas ran
  out. In SYN002 it flagged 3 mismatched lines that were not listened to, and
  6 missing lines from one voice that Parakeet heard (251 of its 270 words), so
  the listener stopped early there. SYN005 (12 people) is
  written but only 9 of its 12 voices exist, so it was not measured.

## Files

| File | Contents |
| --- | --- |
| `diarizer-scores.json` | One row per case and diarizer: speakers, found, tcpWER, DER and its parts, backend, processing time |
| `diarizer-reports.json.gz` | The `pipit-eval bench` report of each row, keyed by file name |
| `provenance.json` | Commit, machine, package versions, the run scripts' checksums and a SHA-256 for each input audio file |

The real-meeting runs and `SYN001` ran at `48ef4f2`; `SYN002` to `SYN004` ran
with the uncommitted `synthesize.py` changes that this commit adds, which change
how voices are chosen and cut, not the diarizers.
