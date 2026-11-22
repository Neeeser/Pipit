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

## Whisper sizes and decode settings

The four six-minute AMI `laptop` call cases (`EN2002a`, `EN2002b`, `EN2002d`,
`IS1009a`) through the full pipeline, re-scored with the meeting audit's
normaliser so number and acronym style does not count as an error. A repeat of
the same run moved by up to 0.5 points.

| Engine | cpWER |
| --- | ---: |
| Parakeet | 28.8% |
| Whisper Large v3 Turbo, 632 MB (Pipit's) | 33.4% |
| Distil Large v3 Turbo | 34.2% |
| Small.en | 37.8% |
| Large v3 | 56.2% |
| Medium.en | 62.6% |

None of the seven decode settings tried on Turbo beat Pipit's current ones by
more than the noise, and forcing English made Turbo worse (38.7%). Of two
settings tried on Large v3, forcing English made it much better (38.6%). One
Parakeet setting, more audio context for the encoder, scored 28.6%, within the
noise of Parakeet's 28.8%. These runs used a temporary local patch to choose
the variant and decode options, so they cannot be rerun from the recorded
commit alone. `whisper-runs.json` holds every run and its re-scored numbers.

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

| Case | Engine | tcpWER | Speakers found, of 10 | DER | Local words lost, of 928 |
| --- | --- | ---: | ---: | ---: | ---: |
| Headphones call | Parakeet | 42.0% | 8 | 22.8% | 72 |
| Laptop call | Parakeet | 41.5% | 8 | 28.5% | 50 |
| Headphones call | Whisper | 46.5% | 9 | 19.8% | 116 |
| Laptop call | Whisper | 47.3% | 9 | 22.0% | 137 |
| In person | Parakeet | 23.5% | 10 | 10.0% | |
| In person | Whisper | 29.2% | 11 | 11.3% | |

On the calls, Parakeet's words are about 16% wrong (Whisper's 20%) while tcpWER
is above 40%: most of the error is words credited to the wrong person. Only
seven speakers were found on the far-end track, which has nine; Whisper's runs
count one more because some far-end words were left with no speaker. The in-person recording of the same
meeting separates all ten. `pipeline-synthetic.json` has the full reports and
`pipeline-transcripts.json.gz` the transcripts.

### The same voices in other layouts

Run the same day after the generator fixes listed under Limits. Each row lays
the same ten voice files out on the timeline with a seed (no new speech
requests) and runs Parakeet through the pipeline. The two groups differ only
in how the splitter trims a line's edges: the second drops lone noise frames
in the pauses, which shortened three of 125 lines by 0.3 to 1.1 s.
`pipeline-layouts.json` has the full reports.

| Generator | Seed | Case | tcpWER | Word error | Speakers found, of 10 | DER |
| --- | --- | --- | ---: | ---: | ---: | ---: |
| Used for the pilot | 20261122 | Headphones call | 42.0% | 15.8% | 8 | 22.8% |
| Used for the pilot | 20261122 | Laptop call | 41.5% | 15.8% | 8 | 28.5% |
| Before the noise-frame change | 20261122 | Headphones call | 17.3% | 16.8% | 10 | 9.8% |
| Before the noise-frame change | 20261122 | Laptop call | 16.5% | 14.9% | 10 | 10.3% |
| Before the noise-frame change | 1 | Headphones call | 17.3% | 14.5% | 10 | 9.8% |
| Before the noise-frame change | 2 | Headphones call | 46.4% | 15.1% | 8 | 23.2% |
| Before the noise-frame change | 3 | Headphones call | 17.9% | 15.5% | 10 | 20.0% |
| Current | 20261122 | Headphones call | 39.5% | 16.2% | 9 | 20.4% |
| Current | 20261122 | Laptop call | 38.3% | 15.0% | 9 | 19.7% |
| Current | 1 | Headphones call | 38.3% | 15.0% | 9 | 19.0% |
| Current | 2 | Headphones call | 15.1% | 15.9% | 11 | 8.7% |
| Current | 3 | Headphones call | 29.2% | 16.2% | 9 | 16.9% |

The word error stays between 14.5% and 16.8% in every run; the speaker count
and tcpWER do not. With seed 20261122 the count went from 10 speakers to 9, and
with seed 2 from 8 to 11, after three lines changed by 0.3 to 1.1 s. On this ten-person meeting, whether
Pipit's speaker separation tells the far-end voices apart depends on small
details of timing, so a single run of one meeting says little about how often
it fails. More meetings, and several layouts of each, are needed to measure it.

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
  microphone, leaving out Granite 2B's repetition failure. The synthetic
  meeting ranks engines; it does not predict their error on real calls.
- Parakeet placed the cuts between lines in nine of the ten Gemini voice
  files (the tenth split at its silences), though the reference words come
  from the script. This may favour Parakeet slightly.
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
