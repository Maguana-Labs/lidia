# Live speech-to-text: engine choice and the skipped-words bug (Nov 2026)

## The problem

The owner recorded the same speech with LidIA and Granola side by side, on one microphone
(system audio off). LidIA's live transcript was lowercase, had no punctuation, dropped word
fragments mid-word ("wor on", "te you", "se eight", "lyd", "applicat") and labelled every
line "Others". Granola's was clean sentences with punctuation and numerals.

## Root causes

1. **Cut words: a stitching bug, not the model.** The Parakeet EOU streaming model calls
   back with the whole utterance so far after every 320 ms chunk. `ParakeetEngine` held the
   last word back (it may still be growing) and, when later words arrived, sent *the copy it
   had held*, not the word from the newest partial. Whenever one chunk both finished the
   held word and started the next one ("wor" → "working on"), the cut copy was sent: "wor".
   Replaying the model's own partials through the old and the fixed stitching on the
   reference audio: old 14.4% WER with 6 cut words (som, tell, it, lyd, we, kn), fixed 7.8%
   with none. Fixed in `ParakeetPartialStitcher` (STT/ParakeetEngine.swift).
2. **Lowercase, no punctuation, words for numbers: the model.** The live model is Parakeet
   EOU 120M (`parakeet-eou-streaming/320ms`), a small English model trained without
   punctuation or capitals. No stitching fixes that; a different live engine does.
3. **Odd segment cuts.** The old live view started a new bubble after any 2 s gap and the
   Parakeet live words had no times (arrival time only). Bubbles are now built from final
   phrases in arrival order, one paragraph per run of a speaker (`LiveTranscriptBubbles`).
4. **"Others" on the owner's own voice.** Screen Recording permission was off, so capture
   fell back to the mic only, the transcriber then left words unlabelled (`isLocalSpeaker
   == nil`), and the live view showed anything not explicitly local as "Others". After the
   meeting, the single-track batch path ran diarization and then a "who is local" vote over
   labels that were all nil, so every speaker became remote ("Them") as well. Now the mic is
   always "You" (as in Granola), system audio is "Others", and diarization numbers several
   remote voices ("Speaker 2", "Speaker 3"), or, with the mic only, other voices in the room
   (`SpeakerAttribution`).

## Method

`Tests/LidIATests/LiveSTTHarnessTests.swift` (opt-in) runs each engine on a recording and
scores it against a reference transcript:

```
LIDIA_WER_AUDIO=…/mic.pcm LIDIA_WER_REF=…/reference.txt LIDIA_WER_OUT=/tmp/wer \
  [LIDIA_WER_REALTIME=1] [LIDIA_WER_ENGINES=eou,analyzer,analyzer-fast,tdt-batch] \
  swift test --filter liveSTTHarness
```

- Audio: LidIA's raw mic track of the 10:20 session (134.6 s, 16 kHz), fed in 100 ms
  chunks through the same engine code the app uses.
- Reference: Granola's transcript of the same speech (90 words). Granola started ~41 s
  later, so words before its first and after its last word are not counted (free ends).
  Granola isn't perfect ground truth ("Lydia" for LidIA, "in the" vs "and the"); every
  engine is scored against the same text.
- Normalisation: lowercase, punctuation removed, 0–99 spelled out ("10" = "ten").
- Latency (real-time feed only): words are aligned to the batch Parakeet transcript, whose
  word end times say when each word was spoken. *First seen* is when the word first showed
  (in the volatile guess at its final position, or final); *final* is when it stopped
  changing.

## Results

| Engine | WER | Sub | Del | Ins | Cut words | . ? ! per 100 words | , per 100 words | Digits | First seen p50 / p90 | Final p50 / p90 |
|---|---|---|---|---|---|---|---|---|---|---|
| Parakeet EOU 120M live, old stitching (shipped) | 14.4% | 8 | 4 | 1 | 6 | 0 | 0 | no | 0.9 / 1.5 s | 0.9 / 1.5 s |
| Parakeet EOU 120M live, fixed stitching | 7.8% | 2 | 4 | 1 | 0 | 0 | 0 | no | 0.5 / 0.9 s | 0.9 / 1.6 s |
| Apple SpeechAnalyzer live | **4.4%** | 3 | 0 | 1 | 0 | 7.2 | 17.4 | yes | 2.4 / 9.1 s | 6.4 / 18.4 s |
| **Apple SpeechAnalyzer live, `fastResults` (new default)** | 5.6% | 4 | 0 | 1 | 0 | 6.0 | 18.0 | yes | **0.5 / 0.9 s** | 6.2 / 15.8 s |
| Parakeet TDT 0.6B v3, whole file after the meeting | 5.6% | 3 | 0 | 2 | 0 | 3.0 | 8.4 | partly | – | – |

Processing time for the whole 134.6 s file fed as fast as possible: SpeechAnalyzer 2.8–3.3 s,
Parakeet EOU 15.3 s, Parakeet TDT batch 31.8 s (including model load).

Excerpts (same stretch of speech):

- Granola: "I'm going to send a test: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10. And then I will do some
  more tests."
- Old live: "i'm going to send a test one two three four five six seven eight nine ten and
  then i will do som more tests and tell you all of this … happening on lyd right"
- SpeechAnalyzer: "I'm going to send a test, one, two, three, four, five, six, seven, eight,
  nine, 10, and then I will do some more tests, and I'm telling you all of this while
  transcription is happening on granola, but it's also happening on Lydia, right, on the
  application that we're working on."
- Parakeet TDT batch: "I'm going to set a test one, 2, three, four, five, 6, 7, 8, 9, 10 and
  then I will do some more tests and I'm telling you all of this while transcription is
  happening on granola but it's also happening on Lydia, right on the application"

## Decision

- **Live: Apple SpeechAnalyzer + SpeechTranscriber with `fastResults`** (macOS 26, on
  device, no Speech Recognition permission needed, model is a macOS system asset). Lowest
  error of the live engines, real sentences with punctuation and capitals, and a volatile
  guess that shows words 0.5 s after they're spoken and refines in place. `fastResults`
  costs one word on this sample (5.6% vs 4.4%) and cuts the first-seen latency from 2.4 s
  to 0.5 s; for a live view that's the better trade. Custom vocabulary and attendee names go
  in as contextual strings.
- **Fallback: Parakeet EOU with the fixed stitching**, when SpeechAnalyzer doesn't support
  the language, while macOS downloads the speech model, or if it fails mid-meeting.
- **After the meeting: keep the live transcript** when it came from SpeechAnalyzer. The
  Parakeet TDT batch pass scored the same WER (5.6%) with less punctuation, would replace
  the text the user just watched, and takes ~30 s. It still runs when the live transcript
  came from the Parakeet live model (lowercase, untimed) or is empty.
- Diarization still runs after the meeting on the system track (or the mic, when it's the
  only track) to number remote voices.

Settings keep the same choice ("Parakeet TDT (Recommended)" is now shown as "On-device
(Recommended)") so existing users get the new live engine without changing anything.

## Caveats

- One 90-word sample from one speaker. Differences of one or two words (1–2 points) are
  within noise; the formatting and latency differences aren't. Re-run the harness on more
  recordings (a call with system audio, a non-English meeting) when they're available.
- SpeechAnalyzer finalizes at pauses, so the final text of a long run-on sentence can lag
  15 s; the volatile guess covers that on screen.
- The mic track was resampled from 48 kHz by plain decimation (no anti-aliasing filter) in
  `MeetingAudioRecorder`/`AudioResampler`; every engine here heard the same aliased audio.
