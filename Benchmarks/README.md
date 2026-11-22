# Pipit benchmarks

`pipit-eval bench` runs a complete Pipit processing pipeline and compares its
meeting output with published reference transcripts. The benchmark covers
transcription, speaker separation, attribution, chunking, and transcript
assembly together.

`pipit-eval summaries` scores the summary and notes a language model writes
from a transcript. See [Summary evaluation](#summary-evaluation).

`Benchmarks/audit/audit.py` audits Pipit's transcripts of your own recorded
meetings against on-device reference transcribers, with nothing leaving the Mac
by default. See [Meeting audit](audit/README.md).

## Repository data

| Path | Contents |
| --- | --- |
| `ground-truth/*.json` | Reference speakers, turns, words, and word timings |
| `manifest.json` | Corpus files, checksums, partitions, windows, and suite rosters |
| `baselines.json` | Recorded results keyed by engine, diarizer, and case |
| `summaries/transcripts/*.txt` | Full AMI meeting transcripts in the form Pipit sends a model |
| `summaries/truth/*.json` | Answer keys: action items, decisions, open questions, and topics |
| `summaries/human/*.json` | The summaries the AMI annotators wrote, kept for comparison |

Audio is downloaded into `~/Library/Caches/pipit-bench`. The repository contains
no recordings. CI rejects committed audio files.

## Suites

| Suite | Cases | Purpose |
| --- | ---: | --- |
| `ami-core` | 14 | Regression coverage across AMI excerpts and full meetings |
| `ami-excerpts` | 12 | Faster AMI accuracy checks without full-meeting chunking |
| `ami-long` | 2 | Full meetings and chunk seams |
| `ami-single` | 1 | One real case for benchmark runner checks |
| `ami-overlap` | 6 | AMI meetings with 38% to 46% overlapped speech |
| `icsi` | 4 | Six to nine speakers with 28% to 39% overlap |
| `notsofar` | 5 | Recent office meetings with 4% to 46% overlap |
| `deciding` | 14 | Held-out cases used to compare engines |
| `calls` | 30 | Simulated two-track calls: a microphone track with laptop-speaker echo and a far-end track, aligned or not |

Use `deciding` when ranking one engine against another. Some `ami-core` and
`ami-overlap` cases appear in published training data for local models. Those
suites can detect a regression in one fixed configuration, but they cannot
support a fair model ranking. `manifest.json` records each case as `ami-train`,
`ami-dev`, `ami-eval`, `excluded`, or `clean`. Tests restrict `deciding` to
`ami-eval` and `clean` cases.

## Simulated calls

Every other suite imports one recording as a file on the microphone track.
That skips what a real call goes through: the echo canceller, the speech
evidence and the rule that the microphone track belongs to the local person.
The `calls` suite imports two tracks as a generic call, so those stages run.

The generator in `Benchmarks/calls/` builds each case from the per-person
headset channels of five held-out AMI meetings (`ami-eval` or `clean`):

- One participant is the local person, chosen from `calls.seed` in
  `manifest.json`. Everyone else is the far end.
- Each headset channel is gated to its owner's reference speech: it is silent
  more than 0.25 s from the owner's words, and a pause shorter than 0.6 s is
  kept. A headset also hears the other people in the room, at 7 dB to 32 dB
  below its owner when they speak alone in these meetings, so the local
  channel is muted as well wherever another participant has a word and the
  local person has none within 0.1 s. That margin keeps word edges that the
  corpus alignment places slightly off; at 0.05 s about half as much
  others-only speech would stay. The mute never touches the local person's
  annotated words, so other voices that overlap those words stay: across the
  five meetings, 34 s to 135 s of other participants' speech falls under the
  local person's words, against 2.7 s to 6.2 s left where they speak alone
  (7.3 s to 17.6 s before the mute). A least-squares subtraction of the other
  headsets from the local one, fitted on half of each meeting, took at most
  4 dB off the other voices in the other half, so the generator does not
  subtract. `case.json` records these seconds under `localChannel`, and
  generation exits with an error if the mute silenced a sample of the local
  person's words or a case has no such record. The far-end track is the sum of
  the other participants, passed through an Opus voice-call round trip.
- The microphone track is the local channel plus the far-end track played
  through a simulated laptop speaker: a high-pass and soft clip, a playback
  delay, and a synthetic room impulse response.
- Each variant fixes the echo level by the correlation Pipit's own measure
  (`EchoCancellationPass.measureAlignment`) reads between the two tracks:
  `headphones` adds no echo, `laptop` targets 0.69 and `laptop-strong` targets
  0.89. Those two numbers are the median and the 90th percentile of the same
  measure over real calls recorded on laptop speakers; the recordings are kept
  outside the repository, so the targets cannot be rechecked from here. The
  generator searches the echo gain until its copy of that measure lands within
  0.002 of the target. It then reads the 16-bit files it wrote, records that
  correlation and the echo power against the local voice (`echoToLocalVoiceDB`)
  in `case.json`, and exits with an error when the stored correlation is more
  than 0.003 from the target (the search tolerance of 0.002 plus room for the
  rounding that 16-bit storage adds) or more than 0.01% of a track's samples sit at
  full scale.
- `laptop-meet` has the `laptop` audio and also writes `sensors.raw.json`, the
  record a browser reader would keep on a Google Meet call, and the bench runs
  it as a Meet meeting. The generator replays the extension's speaking tracker
  on the reference turns: a 500 ms poll, the newest voice taking the floor, a
  1.5 s hold, so one person holds the floor at a time, a turn ends at the first
  poll that names someone else, and a brief interjection does not take the floor
  from a long turn. The record lists every far-end speaker under the reference speaker's name,
  writes the local person's tile as "You" with the self flag, the way the
  extension does for an English-locale client, and has no mute state, like the
  real ones. The poll and hold times
  and the share of dropped far-end turns are the `sensors` numbers of that
  variant in `manifest.json`. The poll and hold are the extension's own
  constants; the dropped share is chosen, not measured.
- `laptop-far-end-late` and `laptop-far-end-dropouts` put the two tracks out
  of line. Both reach the `laptop` echo level, so a difference from `laptop`
  comes from the alignment.
  - In `laptop-far-end-late` the far end begins 1.12 s after the microphone,
    and the bench imports it at that start time, the way a capture stamps a
    track that opened late. A far-end track opens on the first audio the call
    app plays, so nothing is played before then and the microphone holds no
    echo there. Far-end words in those 1.12 s are lost with it.
  - In `laptop-far-end-dropouts` the microphone is the `laptop` one, byte for
    byte. The far-end file loses whole capture buffers (one to four buffers of
    512 frames at 48 kHz) at random moments, 13 ms of audio per minute, with
    nothing in their place, so it slides earlier against the microphone as the
    call goes on: 85 ms to 117 ms by the end of a six-minute window and 395 ms
    by the end of the 30-minute one. The pipeline is not told about the losses,
    as in the app.
  - `case.json` records the start, every loss, and the correlation Pipit's
    measure reads on the file as recorded (`farEnd.correlationAsRecorded`). The
    echo target is checked against what the speakers played.

  The numbers come from `Benchmarks/calls/measure_alignment.py`, run over 197
  meetings recorded on one Mac. It reads each meeting's `raw/manifest.jsonl`,
  where every segment records its first frame's host time and its frame count,
  and stops at the first pause. The recordings stay outside the repository; the
  script prints only counts and percentiles.
  - Start offset: the far end started a median 0.04 s after the microphone, and
    1.12 s is the 90th percentile of the absolute offset (the largest was
    64 s). Of the 20 offsets over a second, 14 had the far end starting later,
    the direction the variant takes. A microphone that starts later is not
    simulated.
  - Steady clock drift between the two tracks was negligible on that Mac: at
    most 2.5 parts per million, 6 ms over a whole meeting. A microphone on its
    own clock, such as a USB one, can drift where these did not, and no
    variant models that.
  - Lost buffers do move the tracks apart. The capture pads a gap only from
    50 ms up, so shorter losses on the far end leave the rest of the track
    early. In 81 of the 197 meetings the far end slid earlier this way, and
    13 ms per minute is the 95th percentile of that rate. The sizes and their
    weights are the counts of steps under 50 ms seen between segments, rounded
    to the nearest one to four buffers; each sits within 5.2 ms of a whole
    number of buffers. The 11 steps that round to five buffers (48 ms to 50 ms)
    are left out, since one loss that long would have been padded. A step
    between two segments can add up several losses inside one 30 s segment, so
    the variant's single losses may run larger than real ones while the rate
    stays the same.
- `--attribution` on `bench` and `reprocess` chooses how a meeting client's
  speaker record and the diarizer share the far end: `current` (the app),
  `diarizer-names` (the record only names clusters), `sensor-first` (turns
  label words before clusters do) and `strict-names` (`current` with the
  narrower rule for which participant a cluster is that the app used before:
  half of the whole cluster). The app always runs `current`. Only
  `bench` and `reprocess` accept the flag, and `reprocess` refuses a mode other
  than `current` on a meeting in the app's own archive. Each bench row records
  the mode, how many far-end words sit under a speaker with no name, and, on a
  call case, how many far-end content words sit under the right display name, a
  wrong one or none (`farEndNames`). Those counts take the words of the
  transcript that match a far-end reference word within three seconds, and
  compare the speaker's display name with the reference speaker's name, which is
  what the simulated record uses.
- Scoring method. The scorer counts a speaker per person, as the app shows it:
  when a case's speaker map names several keys with one display name, they are
  one speaker, and two people who share a name are also one. Rows from this
  scorer carry `"speakerGrouping": "display-name"`. Rows without that field
  were scored per speaker key, so on a case where the speaker map names its
  speakers their speaker count, cpWER and attribution are not comparable with
  rows that have it. Compare only rows with the same `speakerGrouping`, and
  re-run a baseline before gating on it.

Build and run it:

```sh
scripts/fetch-bench-audio.sh calls
Benchmarks/calls/generate.py          # writes ~/Library/Caches/pipit-bench/calls/<case>/
scripts/eval.sh bench --suite calls --engine parakeet --diarizer local --out calls.json
Benchmarks/calls/measure_alignment.py ~/Documents/Pipit/Meetings   # recheck the start offset and loss figures
```

`generate.py --verify` also runs `pipit-eval aec` on each case and compares its
`alignmentCorrelation` with the generator's number. The generator is
deterministic for one ffmpeg, libopus and SciPy build. The case audio is not
checksum-pinned, because those libraries can differ between machines; the
headset inputs are. Run the Python tests from the repository root (they need
ffmpeg for the codec cases and skip those without it):

```sh
uv run --with numpy --with scipy --with soundfile python -m unittest discover -s Benchmarks/calls
```

Two numbers are added for each call case, both per minute of the scored
window. They follow `Benchmarks/aec/metrics.py`:

| Metric | Meaning |
| --- | --- |
| `farEndWordsUnderLocalPerMinute` | Transcript words labelled as the local person that match a far-end reference word within 3 seconds and match none of the local person's own. Words under 3 letters and common function words (articles, pronouns, "yeah", "okay" and similar) are skipped, so this count leaves those out. A transcript word is not paired with a reference word, so one word can count against several |
| `localWordsLostPerMinute` | The local person's reference words that no transcript word accounts for. A transcript word accounts for at most one reference word: it has the same text, starts within 3 seconds, and carries any label. Every word is counted, function words included, so a mislabelled word is not lost here |

The table groups cases by variant and prints the correlation the cleaner
measured before cleaning (blank when it left the track alone), the correlation
the generator recorded for the case, and the echo power against the local voice
in dB. A `*` after a variant marks simulated sensors.

How far to trust the suite: it holds five meetings from two speaker groups in
six variants, and the variants share each meeting's audio. Use it to catch a
regression in a fixed configuration, not to rank engines or models.

`localWordsLost` is mostly recognition error, not speech the pipeline dropped.
It counts any reference word whose text is not written within 3 seconds, so
hesitations (um, uh, mm), cut-off fragments, spelled-out letters, numbers the
engine writes as digits and ordinary misrecognitions all count. On the
headphone variant, which has no echo, the same engine run directly on the
unprocessed microphone file loses 9.8% of the local person's words across the
five meetings; the pipeline's 12.3% adds the canceller, the audio codec and the
rule that removes runs of echo words from the transcript. Read the figure as a difference between runs, not as the
share of the person's speech that is missing.

What stays different from a real call: the local voice is a close-talk headset
with no room sound, and even the `headphones` variant's microphone still
carries the other participants' voices where they overlap the local person's
words, which a headset on a real call would not pick up; the
tracks are aligned to the sample before the echo delay except in the two
misaligned variants, which model a late start and lost far-end buffers but no
steady clock drift (none was measured on the one Mac), no loss on the microphone
track and no microphone that starts after the far end;
there is no packet loss in the codec and no gain control; every meeting has
four participants; and the local person's share of speech is fixed by the
meeting, so reaching a very high echo correlation takes a louder echo than a
real call would have. Baselines for this suite are not in `baselines.json`.

## Smoke check

The smoke fixture uses local `say` voices. It checks command wiring and
transcript assembly without a corpus download:

```sh
scripts/make-bench-smoke.sh /tmp/pipit-bench-smoke
scripts/eval.sh bench \
  --truth /tmp/pipit-bench-smoke/smoke.json \
  --engine parakeet
```

The fixture has alternating speakers and no overlap. Use a real suite to test
overlap handling, chunk seams, or accuracy.

## Run a suite

Download the required audio, then run the benchmark:

```sh
scripts/fetch-bench-audio.sh deciding

scripts/eval.sh bench \
  --suite deciding \
  --engine parakeet \
  --diarizer local \
  --out /tmp/parakeet.json \
  --repeats 3 \
  --keep-scratch
```

Useful options include:

- `--diarizer local` runs what the app ships for a finished meeting: Nemotron 3
  Diarization, with the offline VBx diarizer when all eight Nemotron speaker
  slots fill. `--diarizer vbx` runs the VBx diarizer alone, the previous
  behavior. `nemotron3` runs Nemotron with no fallback.
- `--engine parakeet-ultra` runs Parakeet Ultra, a post-trained Parakeet TDT v3
  that FluidAudio loads as `AsrModelVersion.ultra`. It is a bench candidate and
  the app does not offer it. The install is 603 MiB.
- `--repeats N` runs each configuration several times and compares the mean.
- `--resume` continues an output file and skips completed runs.
- `--keep-scratch` preserves meeting folders, raw model output, and transcripts.
- `--baseline Benchmarks/baselines.json` enables the regression gate.
- `--allow-missing-baseline` permits exploratory cases without recorded results.

The output file is updated after each case. A stopped campaign can resume
without repeating completed model calls.

## Metrics

| Metric | Meaning |
| --- | --- |
| `wer` | Word error rate over the serialized transcript |
| `werNoFiller` | WER after removing hesitation sounds and truncated reference words |
| `werConversational` | WER after also removing conversational backchannels |
| `cpWer` | Per-speaker WER after the best one-to-one speaker assignment |
| `tcpWer` | Per-speaker WER with a five-second word timing constraint |
| `attribution` | Word ownership under a strict one-to-one speaker mapping |
| `der` | Diarization error after split clusters are merged by reference speaker |
| `derStrict` | Diarization error under the strict speaker mapping |
| `repeatedNgrams` | Repeated 8-word passages that indicate loops or bad chunk seams |
| `rtfx` | Processing speed relative to recording duration |

Use `tcpWer` as the main result for overlap-heavy suites. It charges missed
overlapped words, words assigned to the wrong speaker, and timing errors in one
measure.

Serialized WER has an ordering floor because simultaneous speakers must be
written in one sequence. The report includes `orderingFloorWer`, speech
coverage, attribution coverage, overlap ratio, and words per minute so each
result carries its main qualifiers.

DER can exceed 100%. False alarm duration has no upper bound relative to the
reference speech duration.

## Baseline gate

Create or update baselines from a complete output file:

```sh
python3 scripts/build-bench-baselines.py /tmp/parakeet.json \
  --out Benchmarks/baselines.json
```

A gated case needs a matching baseline entry. Default tolerances use absolute
percentage points:

| Metric | Allowed regression |
| --- | ---: |
| `werNoFiller` | 1.5 points higher |
| `attribution` | 1.0 point lower |
| `der` | 2.0 points higher |
| `tcpWer` | 2.0 points higher |

Repeated 8-grams use a fixed budget from the baseline. A case may not produce
more repeated passages than its recorded result. Improvements do not fail the
gate.

For repeated runs, numeric comparisons use the mean. The repeated 8-gram check
uses the worst run.

## Summary evaluation

`pipit-eval summaries` sends each meeting in `summaries/transcripts` through the
client the app would use for a model, with the app's summary prompt, and scores
the answer against `summaries/truth`:

```sh
scripts/eval.sh summaries \
  --model ollama:qwen3.5:4b \
  --model openai:gpt-6-luna \
  --repeats 3
```

`--instructions FILE` scores a draft of the prompt without rebuilding. A model
is `provider:model` with provider `openai`, `openrouter` or `ollama`,
`custom:<base url>|<model>` for any chat completions server, or
`apple:on-device` and `apple:private-cloud` for Apple's Foundation Models on
macOS 27. The Private Cloud Compute model answers only in a build that holds
Apple's entitlement for it. OpenAI and
OpenRouter keys come from `OPENAI_API_KEY` and `OPENROUTER_API_KEY`, or from
the keys Pipit stores in the keychain.

Each answer key lists every action item, decision, and open question in its
meeting with the line it rests on. A model wrote the keys from the transcripts
alone, and they were then checked by hand against the transcripts. Items the
AMI annotators also listed carry `must_find`. The annotators' own summaries
list far fewer items, a median of two action items per meeting, so they set a
floor rather than the key.

Scoring has two parts:

- Matching. A sentence embedding model proposes which of a model's items say
  the same thing as a key item of the same kind, and the pairing is one to
  one. The default is `hindsight-ai/hs-embed-1`, run on this Mac by
  `scripts/embed-texts.py` through `uv`; `--embedder ollama:<model>` names a
  model Ollama serves instead. Embeddings find items about the same subject
  but cannot tell a decision from its opposite, so when there is a judge it
  confirms each proposed pair and only confirmed pairs count. Each run in
  `runs.json` lists the key items found and missed, the pairs the judge
  rejected, and the items that matched nothing.
- A judge, `openai:gpt-6-luna` unless `--judge` names another, and none with
  `--no-judge`. Besides confirming pairs it checks the overview, whether each
  note is true to the transcript, whether the notes cover each key topic, and
  whether items that matched nothing were said or made up. Every result
  records the judge and the version of its instructions. Compare scores only
  when both match.

The command prints three tables: what each model found, the judge's grades,
and reliability. Answers, verdicts, and embeddings are kept in the output
folder, `bench-scratch/summaries/<time>` unless `--out` names one. A rerun with
the same `--out` only asks for what is new.

Rebuild the transcripts and human summaries from the pinned annotations:

```sh
scripts/fetch-bench-audio.sh --annotations ami
python3 scripts/build-summary-transcripts.py \
  --annotations ~/Library/Caches/pipit-bench/ami_public_manual_1.6.2.zip \
  ES2004a ES2004b ES2004c ES2004d IS1009b IS1009c IS1009d TS3003b TS3003c TS3003d
```

## Data provenance

`scripts/fetch-bench-audio.sh` downloads recordings and annotation archives at
pinned revisions and verifies their SHA-256 checksums. The benchmark cuts
excerpt windows with AVFoundation.

Ground truth comes from these sources:

- [AMI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/corpus/), manual
  annotations version 1.6.2
- [ICSI Meeting Corpus](https://groups.inf.ed.ac.uk/ami/icsi/), core NXT
  annotations version 1.0
- [NOTSOFAR-1](https://huggingface.co/datasets/microsoft/NOTSOFAR), evaluation
  release `240825.1_eval_full_with_GT`

The derived word text, timings, and speaker identifiers, and the summary
transcripts, human summaries, and answer keys derived from AMI, are
distributed under the source corpora's Creative Commons Attribution 4.0
licenses. The recordings
remain in the local cache and are not redistributed.

Regenerate the committed truth with `scripts/build-bench-truth.py`. The script
reads pinned annotation data and selects windows deterministically. Review the
resulting diff and run the benchmark tests before replacing ground truth.

## Scorer validation

The Swift cpWER and tcpWER implementations are checked against MeetEval with:

```sh
scripts/check-scorer-against-meeteval.py \
  --truth Benchmarks/ground-truth/ES2002b.json \
  --scratch /tmp/ES2002b-parakeet-local \
  --out /tmp/parakeet.json
```

Scorer tests also cover exact transcripts, known deletion rates, shuffled
speaker labels, split clusters, filler handling, timing collars, and baseline
failures.
