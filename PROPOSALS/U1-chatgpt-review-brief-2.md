# Review brief #2 for ChatGPT — U1 root-cause findings (E8–E10), 2026-10-22

You are again the independent reviewer for the Observatory iOS project (three-agent workflow: Claude writes code, Hermes verifies against artifacts, ChatGPT advises; you have no disk access). This brief is self-contained — it supersedes brief #1, whose recommendations (E8 callback audit, E9 short-passage control, E10 controls/hygiene) were adopted and executed on-device. Your job: critique the reasoning and evidence below. Do not write code.

## Context recap (verified state)
- Observatory records spoken reflections and transcribes them ON-DEVICE only (`SFSpeechRecognizer`, `requiresOnDeviceRecognition = true`, binding decision D-04; no external services). Production feeds audio via `AVAudioEngine` input tap into `SFSpeechAudioBufferRecognitionRequest`, rolling the request over roughly every minute (request swapped, engine never restarted).
- Validation replays three read-only fixture recordings (solo 91.1s/149 real words; multi-a 167.5s/288; multi-b 95.7s/192) through a test harness sharing the live timing-mapper code path. Pass floor: 70% word fidelity. All device runs below: physical iPhone 16 Pro, iOS 27.0.1, user-approved, 3 trials each with zero run-to-run variance.
- Prior results: full-file on-device replay ≈ total failure (1–3 words); chunked ≤55s replay 9–19% with words only from each chunk's TAIL; server recognition on the same files: 261/182 words (server path is fine). Loudness normalization (E5) lifted multi-b to 43% but nothing passed. Feed-style (manual append loop vs real engine tap, E6) and session category (E10c) ruled out as causes; re-encoding ruled out (E10a); flat per-fixture gain (E10b, peaks ≤ −1.5 dBFS) recovered most of loudnorm's benefit for multi-a/multi-b but solo stayed flat at 28/149 regardless of level.

## The new root-cause claim (E8, verified from raw bundle logs by Hermes)
The harness logged EVERY recognition callback (partial + final) directly off `result.bestTranscription` — segment count, transcript character count (never text, for privacy), min/max segment offsets — BEFORE any Observatory aggregation or timing-mapping code ran.

Observed pattern, deterministic across all 3 trials per fixture: within one continuous request, the recognizer's partial results repeatedly RESET mid-stream. Representative excerpt (multi-a, trial 1, 55s chunk fed):

```
callback #45: elapsed=19.7s, transcriptLength=211, segmentCount=33, segmentOffsets=0.9-19.0s
callback #46: elapsed=19.9s, transcriptLength=4,   segmentCount=1,  segmentOffsets=0.0-0.0s   <- RESET
callback #78: elapsed=31.9s, transcriptLength=144, segmentCount=22, segmentOffsets=19.0-28.9s
callback #79: elapsed=40.1s, transcriptLength=1,   segmentCount=1,  segmentOffsets=0.0-0.0s   <- RESET
callback #90: elapsed=46.1s, transcriptLength=49,  segmentCount=10, segmentOffsets=38.2-42.6s
callback #91: elapsed=48.3s, transcriptLength=2,   segmentCount=1,  segmentOffsets=0.0-0.0s   <- RESET
callback #105: elapsed=57.1s, isFinal=true, transcriptLength=52, segmentCount=10, segmentOffsets=49.9-54.6s
FINAL result: words=10, coveredOffsets=49.9-54.6s of 55.0s fed
```

- Final results of the 55s chunks: multi-a 10 words (offsets 49.9–54.6s), multi-b 2 words (53.5–54.3s), solo 3 words (54.1–55.1s). Only the LAST utterance survives into the final result.
- Reset frequency (Hermes's recount from the raw log): segmentCount drops in 30/318 callbacks (multi-a), 33/336 (multi-b), 21/345 (solo); counting any segmentCount-or-transcriptLength drop: 39/45/27. (Claude's originally reported tallies did not reproduce from the artifacts and were corrected by Hermes — flagged for transparency.)
- Notable detail: just BEFORE each reset, one partial result carries materialized segment timestamps covering the completed span (e.g. #45 → 0.9–19.0s, #78 → 19.0–28.9s, #90 → 38.2–42.6s). Between resets, partials show segmentOffsets 0.0–0.0s (timestamps not yet materialized). So each completed utterance's content+timing DOES appear in at least one partial before being discarded.
- **Conclusion drawn:** on this OS/device, `SFSpeechRecognitionResult.bestTranscription` behaves with REPLACEMENT, not cumulative, semantics across internal utterance boundaries within a single request: when the recognizer starts a new utterance (after an internal pause), it discards the prior utterance's recognized content from subsequent results. Any consumer that trusts only the final result — as Observatory's production code does — receives only the last utterance of each ~1-minute request. This is recognizer-side behavior observed upstream of all Observatory code, not a harness or mapping defect.

## E9 corroboration (short-passage position control, verified raw prints)
A clearly-audible 12s passage (from multi-b-loudnorm 36–48s; solo-loudnorm 38–50s secondary) replayed with fresh requests, padded with synthesized silence to 55s where applicable:
- multi-b passage: alone=28 words (coveredOffsets 0.0–11.8s), start-of-55s=29 (0.0–11.7s), end-of-55s=37 (43.0–55.0s) — full recovery in every position.
- solo passage: alone=20, start=20, end=18 — full recovery.
- No early finalization from silence padding (firstFinal arrived after endAudio in all arms).
**Conclusion drawn:** duration/position alone cause no loss; loss occurs when NEW SPEECH follows a pause (triggering the E8 reset). Silence padding is benign.

## The candidate production fix (proposed in PLAN.md, NOT yet implemented, needs its own proposal/review)
Production could accumulate transcript content itself across each reset event — e.g. detect segmentCount/transcriptLength drops between consecutive partials, snapshot the pre-reset partial's segments (which carry materialized timestamps per the E8 detail above), and concatenate snapshots + the final result's segments in offset order, instead of trusting only the final result. Alternatives not yet evaluated: rotating requests proactively at detected utterance boundaries; consuming partials continuously; `taskHint`/request-configuration changes; Apple's newer SpeechAnalyzer/SpeechTranscriber API (currently OUT OF SCOPE per the decisions log — changing that is a user decision).

## Questions for you
1. **Does the raw callback evidence establish the replacement-semantics diagnosis**, or is there a plausible alternative explanation we haven't excluded (e.g. an artifact of `shouldReportPartialResults=true` + `addsPunctuation=true` configuration, bestTranscription vs alternatives, or the harness's break-on-first-final loop interacting with the stream)?
2. **Is the accumulate-across-resets fix sound?** Assess specifically: duplicate/overlapping content between a pre-reset snapshot and the post-reset stream; ordering and timestamp consistency for downstream diarization (word-level speaker matching by overlap duration); segments lost if a reset occurs before timestamps materialize (the 0.0–0.0s partials); and whether the pre-reset timestamped partial (#45-style) is guaranteed or merely observed.
3. **Server-path implication:** server recognition on the same files yielded 261/182 words through the SAME harness result-collection code. Does that cleanly imply the replacement behavior is on-device-specific, or could server results simply contain everything in one final because server-side utterance segmentation differs?
4. **Does this change the U2 privacy/fidelity framing?** (U2 = user decision on what the app does given on-device fidelity limits: documented limitation, capture-side fixes, and/or opt-in server mode with consent.)
5. **Is E7 (fixture re-record under current capture config) still worth running** now that the root cause is recognizer-side result replacement, not capture config? What would it still be able to tell us?
6. **Confidence check:** Claude's E8 tallies didn't reproduce from artifacts (Hermes recounted and corrected them). Does anything ELSE above smell miscounted, over-claimed, or under-controlled? What additional evidence would you require before approving the accumulate-fix proposal for implementation?

Answer as a numbered list matching the questions. Be blunt; "insufficient evidence" is an acceptable answer.

ChatGPT Reply: 
1. **Strong evidence for replacement behavior in this tested configuration; insufficient evidence for a universal API rule or complete root cause.** Early content appears in raw callbacks and disappears from later ones before Observatory processes it. That substantially supports the diagnosis and explains why collecting only the final result loses content. A break-on-first-final loop cannot explain resets that occurred before that final.

   However, segment-count and character-count drops alone cannot distinguish a new utterance from ordinary hypothesis revision. The logs also do not establish that *every* completed utterance appears intact before replacement. Attribute the behavior to **this on-device request configuration on this device/OS**, pending configuration controls and production confirmation. Punctuation, partial reporting, and alternative hypotheses remain possible modifiers. Similar disappearance-after-pause behavior has been reported on Apple’s developer forum, but that is corroborating experience, not an API guarantee. [Developer report](https://developer.apple.com/forums/thread/762952?page=2)

2. **Accumulation is a sound direction; “snapshot on any count/length drop, then concatenate” is not yet a sound production algorithm.**

   - **Duplicates and revisions:** A shorter hypothesis can correct earlier text without beginning a new utterance. Committing the previous version could preserve mistakes and duplicate overlapping speech. Conversely, replacement with equal or greater counts would evade this detector.
   - **Ordering and diarization:** Establish that timestamps remain request-relative across resets. Validate individual start times **and durations** against known audio boundaries; nonzero timestamps and sorted output do not establish accurate word-to-speaker overlap. Apple defines timestamps relative to the processed audio stream, but that definition does not guarantee provisional values are stable. [Timestamp documentation](https://developer.apple.com/documentation/speech/sftranscriptionsegment/timestamp)
   - **Missing timing:** A reset before usable timing appears must produce an explicit unresolved span, or trigger a defined recovery path. Assigning zero-offset words to speakers would manufacture certainty.
   - **Snapshot guarantee:** The pre-reset timestamped partial is **observed, not guaranteed**. The proposal needs separate retained state for the latest hypothesis and latest usable timed hypothesis, plus rules for reconciling them and the final result.

   Require a defined state machine for revisions, replacements, overlap, missing timing, and final reconciliation before production implementation.

3. **It establishes a difference between the tested local and server paths, not clean on-device exclusivity.** Different server-side segmentation could indeed yield one cumulative final while local processing emits replacement hypotheses. That explanation is compatible with the observations.

   The shared collector helps localize the discrepancy, but its final-only assumption can work for one backend and fail for another. Compare callback histories under matched settings to characterize that difference. Also, “server path is fine” remains too strong: 261/182 output words establish output volume, not transcription accuracy or timing quality.

4. **Yes—U2 should now be framed around an unresolved collection defect before an inherent privacy/fidelity tradeoff.** The earlier final-only measurements substantially undercount what the local recognizer produced during processing. They no longer establish the achievable accuracy of a correctly collected local transcript.

   This does **not** establish that accumulation will pass 70%: missing, incorrect, duplicated, and mistimed words may remain. Validate recovered local output first, then present the residual quality gap to the user. Gain remains a separate possible contributor. D-04 stays binding; neither server use nor changing recognizer scope follows automatically from this diagnosis.

5. **E7 remains worthwhile as a production-representativeness check, not as the next root-cause discriminator.** Current recordings can establish whether the symptom occurs under today’s capture configuration and whether recovered transcripts have acceptable accuracy, timing, and speaker attribution. Paired with the smoke test, they can expose rollover and interruption losses.

   Re-recording cannot isolate the effect of capture configuration because speech delivery and recording conditions also change. First validate reconstruction on the existing fixtures, then run E7 against that baseline. Preserve the original fixtures as regression cases.

6. **The corrected tallies are a reporting failure caught by independent verification, not grounds to discard E8. Several other claims still need tightening:**

   - **“Full recovery” in E9 is unsupported by counts alone.** The identical passage producing 28 versus 37 words needs alignment: additional words could be correct recovery, repetition, or insertion.
   - **E9 does not isolate “new speech after a pause” as the trigger.** Add matched speech–pause–speech and continuous-speech controls, varying pause duration. Silence padding only shows that those padded examples retained early content.
   - **“Timestamps materialized” does not mean “timestamps accurate.”** Zero is also a legitimate initial timestamp; validity needs more than a nonzero check.
   - **“Ruled out” is too broad for E6/E10.** The brief summarizes those controls without enough detail to assess their matching or coverage.
   - **Reset tallies need explicit definitions and denominators.** Separate ordinary revisions from replacement events, and distinguish the representative chunk from whole-fixture callback totals.

   **Before approving implementation**, I would require a concrete algorithm proposal and a test-only reconstruction demonstrating reference-aligned accuracy, duplicate/omission counts, and independently checked timing on all three fixtures. Add controlled repeated phrases, ordinary hypothesis shortening, missing-timestamp resets, and rollover-boundary cases. Privacy-preserving text fingerprints can help establish content continuity without logging transcript text.

   **Verdict: approve further prototyping of accumulation; do not yet approve the proposed drop-and-concatenate heuristic as the production fix.**
