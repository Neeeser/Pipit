# Speech engines and the first synthetic meeting

Run on an Apple M5 Max with 48 GB at commit `d7f304b`, finished 2026-11-22.
`provenance.json` has the package versions, model revisions and input
checksums.

## Questions

1. Is Pipit's Whisper set up well, and would a different Whisper size do
   better than Large v3 Turbo?
2. Do newer speech models transcribe meeting audio better than Parakeet?
3. Does a meeting voiced by Gemini text to speech make a useful benchmark case,
   in particular for more than eight speakers?

In short: no Whisper size or decode setting tried beat Pipit's Turbo, and the
two largest rows did not transcribe normally. Qwen3-ASR scored lowest on every
track type, and Parakeet is within 0.1 points of Nemotron on the AMI far end.
The synthetic meeting is a useful case for more than eight speakers, because
it showed that Pipit's speaker separation fails on a nine-voice far end when
Nemotron 3 reports fewer than its eight slots. It does not rank engines
reliably or predict their error on real calls.

## Whisper sizes and decode settings

The four six-minute AMI `laptop` call cases (`EN2002a`, `EN2002b`, `EN2002d`,
`IS1009a`) through the full pipeline, re-scored with the meeting audit's
normaliser so number and acronym style does not count as an error. Three more
runs of Turbo's own setting (`turbo-repeat-from-*`) scored 33.1% to 33.8%
against 33.4% for the Turbo run. The four-case mean moved by up to 0.4 points.
On single cases it moved by up to 3.5 points, because `EN2002b` and `EN2002d`
came out the same in every repeat and the other two cases did not. The repeats
are Turbo output that stands in for a size run (inferred from the run names, the
two rounds of size runs in the run log, and their word counts).

| Engine | cpWER |
| --- | ---: |
| Parakeet | 28.8% |
| Whisper Large v3 Turbo, 632 MB (Pipit's) | 33.4% |
| Distil Large v3 (labelled `whisper-distil-large-v3-turbo` in the run files) | 34.2% |
| Small.en | 37.8% |
| Large v3, 3.0 GB | 56.2% |
| Medium.en | 62.6% |

In WhisperKit's Core ML folder names, `_turbo` marks a build of the model, not
OpenAI's Turbo model. `openai_whisper-large-v3_turbo` is Large v3 (32 decoder
layers, `openai/whisper-large-v3`), `distil-whisper_distil-large-v3_turbo` is
Distil Large v3 (2 layers), and Pipit's
`openai_whisper-large-v3-v20240930_turbo_632MB` is the Turbo model (4 layers).
The two rows above are labelled by what the folders hold, which the run labels
`whisper-large-v3` and `whisper-distil-large-v3-turbo` also say.
`provenance.json` lists the variant behind each run label. Every Whisper run in `whisper-runs.json` records
`whisperkit-large-v3-turbo` as its transcription model, whatever variant ran,
because the temporary patch did not change the identifier.

The last two rows mostly show missing output, not model quality. Against 5,314
reference words over the four cases, Medium.en wrote 2,285 words and Large v3
2,700, where Pipit's Turbo wrote 4,064 (`hypothesisWords`). The cause is
not known. Forcing English raised Large v3 from 56.2% to 38.6%, which
points at language detection, but the stored runs do not show
it. Medium.en is English-only, so that cannot explain its rows. Of the sizes
that transcribed normally, Small.en and Distil Large v3 scored no better than
Pipit's Turbo, so this run does not show a size that does better than Turbo.

None of the seven decode settings tried on Turbo beat Pipit's current ones by
more than the 0.4-point noise, and forcing English made Turbo worse (38.7%). Of
two settings tried on Large v3, forcing English made it much better
(38.6%). One Parakeet setting, more audio context for the encoder, scored
28.6%, 0.2 points from Parakeet's 28.8%; Parakeet's own repeat noise was not
measured. These runs used a temporary local patch to choose the variant and
decode options, which was not kept, so they cannot be rerun. Their stored
transcripts can be re-scored: `Benchmarks/engines/rescore_whisper_runs.py`
reproduces the 76 stored `cpwer_plain` and `cpwer_audit` scores to the last
digit. It does not check `bench_tcpwer`, which needs meeteval with the
bench's collar, and DER cannot be re-scored because no diarizer intervals are
stored.
`whisper-runs.json` holds every run and its re-scored numbers.

## Engines on single tracks

Each engine transcribed the same 11 tracks (105 minutes), scored on words alone
with no speaker labels, using the audit's normaliser on each track as one text
(normalising word by word would split spoken numbers that engines write as
digits). Error is pooled over the
tracks of each type. Speed is audio seconds per processing second. For Pipit's
two engines it includes starting `pipit-eval` and loading the model for every
track, which the mlx-audio engines' numbers leave out, so it understates them.
Peak memory is the largest over all tracks; Qwen3-ASR and Nemotron read each
track whole, so their peak comes from the 19-minute synthetic tracks.

| Engine | AMI far end | AMI local mic | Synthetic far end | Synthetic local mic | Synthetic in person | Speed | Peak memory |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Qwen3-ASR 1.7B, 8-bit | 25.4% | 9.2% | 6.7% | 1.8% | 8.3% | 20x | 12.5 GB |
| Nemotron 3.5 Transcribe 30B-A4B, NVFP4 | 28.9% | 10.1% | 9.6% | 3.9% | 13.6% | 13x | 24.6 GB |
| Parakeet TDT v3 (Pipit) | 28.8% | 14.2% | 8.8% | 2.8% | 10.3% | 141x | not measured |
| Whisper Large v3 Turbo (Pipit) | 32.0% | 18.6% | 11.8% | 9.0% | 12.6% | 22x | not measured |
| Granite Speech 5.0 470M TurboCTC | 34.8% | 11.2% | 9.0% | 4.3% | 10.8% | 518x | 1.9 GB |
| Granite Speech 5.0 2B | 29.1% | 68.5% | 8.9% | 525% | 10.6% | 12x | 12.7 GB |

Granite 2B fell into repeating the same words on one microphone track in each
set. The mlx-audio engines ran through `Benchmarks/engines/run_mlx_engine.py`
and Pipit's through `pipit-eval asr`. `engine-scores.json` has each track and
`engine-transcripts.json.gz` each transcript.

## Pipit's pipeline on the synthetic meeting

`SYN001` is a 19-minute, 10-person meeting written and voiced by Gemini
(`Benchmarks/synthetic`), rendered as a headphones call, a laptop-speaker call
and an in-person room recording. 6.7% of its speech overlaps.

The call recordings carry the local microphone and the far-end track
separately, and Pipit diarizes the far end, which holds nine of the ten
voices. Pipit diarizes with Nemotron 3, which tracks up to eight speakers
(`LocalSpeechStack.nemotron3SpeakerSlots`). When Nemotron 3 reports eight
clusters, every slot is full and Pipit discards its answer and runs the offline
clusterer, which has no such limit (`LocalDiarizationBackend`). When it reports
fewer, Pipit keeps its answer. Each run's `diarizationBackends` names the
diarizer whose result was scored, and the tables below show it. The stored runs
have no `diarizerReason` field, so that a clusterer run came from a full set of
eight slots is inferred from the backend name and the code, not recorded.

| Case | Engine | Diarizer | tcpWER | Speakers found, of 10 | DER | Local words lost, of 928 |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Headphones call | Parakeet | Nemotron 3 | 42.0% | 8 | 22.8% | 72 |
| Laptop call | Parakeet | Nemotron 3 | 41.5% | 8 | 28.5% | 50 |
| Headphones call | Whisper | Nemotron 3 | 46.5% | 8 | 19.8% | 116 |
| Laptop call | Whisper | Nemotron 3 | 47.3% | 8 | 22.0% | 137 |
| In person | Parakeet | Offline clusterer | 23.5% | 10 | 10.0% | |
| In person | Whisper | Offline clusterer | 29.2% | 10 | 11.3% | |

Speakers found counts the clusters that match a person. Some Whisper runs also
keep a bucket of far-end words that got no speaker; the stored
`hypothesisSpeakers` counts that bucket, so it reads one higher.

On the calls, Parakeet's words are about 16% wrong (Whisper's 20%) while tcpWER
is above 40%: most of the error is words credited to the wrong person. In all
four call runs Nemotron 3 found seven clusters on the far-end track, which has
nine voices, and Pipit kept that answer. S05 and S10 had no cluster of their
own. The in-person runs used the offline clusterer and found all ten. That
comparison is between two diarizers, so it does not show that an in-person
recording separates speakers better than a call: the layout runs below put five
call recordings of the same voices through the clusterer, and their tcpWER
(15.1% to 17.9%) is lower than the in-person runs' (23.5% and 29.2%).
`pipeline-synthetic.json` has the full reports and `pipeline-transcripts.json.gz`
the transcripts.

### The same voices in other layouts

Run the same day after the generator fixes listed under Limits. Each row lays
the same ten voice files out on the timeline with a seed (no new speech
requests) and runs Parakeet through the pipeline. The first two rows are the
pilot's own Parakeet call runs again. For seeds 20261122 and 3 the "before"
rows differ from the current rows only in how the splitter trims a line's
edges: the current splitter drops lone noise frames in the pauses, which
shortened three of 125 lines by 0.3 to 1.1 s. The "before" rows for seeds 1 and 2
were evidently made by code that was not recorded: regenerating them with the splitter
before the change gives audio 0.24 s and 0.05 s longer than the stored runs'.
`pipeline-layouts.json` has the full reports.

| Generator | Seed | Case | Diarizer | tcpWER | Word error | Speakers found, of 10 | DER |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| Used for the pilot | 20261122 | Headphones call | Nemotron 3 | 42.0% | 15.8% | 8 | 22.8% |
| Used for the pilot | 20261122 | Laptop call | Nemotron 3 | 41.5% | 15.8% | 8 | 28.5% |
| Before the noise-frame change | 20261122 | Headphones call | Offline clusterer | 17.3% | 16.8% | 10 | 9.8% |
| Before the noise-frame change | 20261122 | Laptop call | Offline clusterer | 16.5% | 14.9% | 10 | 10.3% |
| Before the noise-frame change | 1 | Headphones call | Offline clusterer | 17.3% | 14.5% | 10 | 9.8% |
| Before the noise-frame change | 2 | Headphones call | Nemotron 3 | 46.4% | 15.1% | 7 | 23.2% |
| Before the noise-frame change | 3 | Headphones call | Offline clusterer | 17.9% | 15.5% | 10 | 20.0% |
| Current | 20261122 | Headphones call | Nemotron 3 | 39.5% | 16.2% | 8 | 20.4% |
| Current | 20261122 | Laptop call | Nemotron 3 | 38.3% | 15.0% | 8 | 19.7% |
| Current | 1 | Headphones call | Nemotron 3 | 38.3% | 15.0% | 8 | 19.0% |
| Current | 2 | Headphones call | Offline clusterer | 15.1% | 15.9% | 11 | 8.7% |
| Current | 3 | Headphones call | Nemotron 3 | 29.2% | 16.2% | 8 | 16.9% |

The word error stays between 14.5% and 16.8% in every run; the speaker count
and tcpWER do not, and the diarizer predicts them. Counting the pilot's
call runs and the layout rows once each, Nemotron 3 produced 9 runs with tcpWER
from 29.2% to 47.3% and 6 or 7 far-end clusters for nine voices. The offline
clusterer produced 5 call runs with tcpWER from 15.1% to 17.9% and 9 or 10
far-end clusters (seed 2 in the current generator splits S06 in two, so its 11
clusters cover 10 people). In the Nemotron 3 runs S05 never has a cluster, and
one more voice (S10, S06 or S07) is missing too, except in the one run where
two others are.

So the cause on this meeting is the diarizer and its limit, not timing or the
recording type. Nine far-end voices exceed Nemotron 3's eight slots, so it can
report at most eight clusters. When it merges two voices and reports seven, Pipit
keeps the seven and the fallback never runs. When it reports eight, the
clusterer runs and separates everyone. Which of the two a given layout lands on
changed with the layout, including after three lines moved by 0.3 to 1.1 s
(seed 20261122 went from the clusterer to Nemotron 3), and this run does not say
why. A meeting with more speakers than Nemotron 3 can hold needs a fallback that
does not wait for every slot to fill; that is a change to Pipit, not made here.

## Checking the synthetic voices

`check_audio.py` with Gemini 3.5 Flash-Lite transcribed each of the ten voices
(ten requests) and compared the transcripts with the script. Of 125 lines, 101
matched, 21 differed by one or two words, and 2 differed by more. One more, a
lone "Mm-hmm", cannot be scored, because the normaliser drops hesitation
sounds; Flash-Lite heard it as "Mhm". S08's second and third lines overlap by
1.6 s in this layout (the fault listed under Limits), so the second line's clip
ends with the first words of the third. Parakeet, run on the two lines that
differed by more, heard the same slips Flash-Lite did:

- In S03's fifth line the voice says "live at the math" for "look at the
  math", and says "Elena" so that both listeners heard another name.
- In S03's nineteenth line the voice says "Tariq" so that both listeners heard
  "to reek".

The truth keeps the script's words for those two lines, so every engine is
charged for them. `syn001-audio-check.json` has each line's verdict and
Flash-Lite's transcripts.

A control, run by hand and not stored, showed why the check must not see the
script. Given the script, the same model called every line of S05 a match even
with two lines swapped. Without it, scoring the stored S05 transcript against
the swapped script flags the moved lines.

## Limits

- Every engine makes fewer errors on synthetic speech than on AMI: 2.7 to 3.9
  times fewer on the far end and 2.1 to 5.1 times fewer on the local
  microphone, leaving out Granite 2B's repetition failure. The gap has more than
  one cause that this run does not separate. SYN001 has 6.7% overlap and the four
  AMI cases 31%, 45%, 46% and 17%, and on the AMI far end the engines miss 18% to
  30% of the reference words (deletions), against 4.9% to 6.4% on SYN001, which is
  what a single-stream recogniser does with overlapped speech. SYN001's script
  also has 5.6% interrupts and 7.2% backchannels of its turns, where the prompt
  asked for about 12% and 15%. So easier synthetic speech and less overlap are
  not told apart, and the synthetic error does not predict error on real calls.
- The synthetic meeting does not rank the engines reliably. The order differs
  from AMI's: on the far end Granite 470M goes from last to fourth and Nemotron
  from third to fifth, and the engines within 0.2 points of each other
  (Parakeet, Granite 2B and Granite 470M at 8.8% to 9.0%) cannot be ordered.
  The local-microphone column is one text-to-speech voice and 899 reference
  words, and spelling decides part of it: `check_audio.py` counts "all right"
  and "alright" as the same word and `score.py` does not. Applying that one rule
  to both sides moves Qwen3-ASR from 1.8% to 1.1% and Granite 470M from 4.3% to
  3.7%, which ties it with Nemotron, and leaves Parakeet and Whisper where they
  were. The tables above are as `score.py` computed them.
- Parakeet placed the cuts between lines in nine of the ten Gemini voice
  files (the tenth split at its silences), though the reference words come
  from the script. Scoring is on words alone and the cuts only remove silence,
  so the effect on Parakeet is probably small, but the generator also rejects
  voice files Parakeet cannot align, and this run did not measure how much
  either matters. Parakeet's second place on the synthetic local microphone, up
  from fourth on AMI, fits an advantage and also fits easy speech.
- There is one synthetic meeting and four AMI meetings, each measured once.
- AMI is in the training data of Parakeet, Granite and Nemotron.
- The AMI call audio came from version 1 of the call generator, before the
  #191 change that mutes other participants on the local microphone. The
  synthetic cases used version 2.
- The generator that produced `SYN001` had two faults since fixed: one
  speaker's line started 1.6 s before that speaker's previous line ended
  (lines 70 and 72 of the script), and two cuts between S04's lines fell
  inside a word, so about 0.1 s of one line's audio went to the line before.
  `SYN001` is kept as measured.
- The voice audio is not in the repository. `provenance.json` has checksums
  of the ten Gemini voice files (`syntheticVoiceFiles`), the pilot's laid-out
  tracks (`syntheticTracks`) and every track the engines transcribed
  (`inputs`). The layout runs rebuild their tracks from the voice files.
- What re-scores from this folder with committed tools: the engine table's word
  error (`Benchmarks/engines/make_inputs.py` and `score.py` on
  `engine-transcripts.json.gz`) and the Whisper runs' `cpwer_plain` and
  `cpwer_audit` (`rescore_whisper_runs.py`). The pilot pipeline transcripts and
  two layout runs (seed 20261122 before the noise-frame change, with its truth
  in `syn001-layout-truth-before-noise-frame-change.json.gz`) hold the words
  and speakers for a word-based cpWER, but no committed tool computes it, and
  tcpWER needs meeteval with the bench's collar. DER cannot be re-scored: no
  diarizer intervals are stored. The other ten layout rows have scores but no
  transcripts, and the truth of their layouts is not stored; the seed and the
  voice files rebuild the layout, but only for the current generator.
- `provenance.json` lists what the record could not capture, including the
  Whisper patch and the Python versions at measurement time, and any script
  that sat in an ignored folder such as `probes/` (`provenance.py` skips ignored
  paths; its `--code` option hashes named files).
