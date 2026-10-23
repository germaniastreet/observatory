# Review brief for ChatGPT — U1 (Stage 0 fidelity investigation), 2026-10-22

You are the independent reviewer in a three-agent workflow on "Observatory," a personal iOS app. Claude (Xcode assistant) writes code; Hermes (director) verifies claims against real artifacts; ChatGPT (you) gives second-opinion reviews. You have no disk access — everything you need is below. Your job is to critique reasoning and evidence, NOT to write code. Numbers marked "verified" were extracted by Hermes directly from xcresult bundles / ffmpeg measurements, not from Claude's summaries.

## Project context (condensed)
- Core loop: record spoken reflections → on-device transcription (Apple Speech framework, `SFSpeechRecognizer`) → speaker diarization (SpeakerKit/Pyannote, on-device) → acoustic-expression observation → bounded interpretation.
- Binding decision D-04: NO external audio/ML services; `requiresOnDeviceRecognition = true` is code-enforced (uncommitted). Known consequence: Apple's on-device recognizer shows severe fidelity loss on the test fixtures. Server recognition on the same files: 261/182 words with 2 speakers found. Whether to ever add an opt-in server mode is a user/product decision (unit U2), not an agent decision.
- Validation method (D-10): three read-only fixture recordings (`fixture-solo.caf` 91.1s/149 real words, `fixture-multi-a.caf` 167.5s/288 words, `fixture-multi-b.caf` 95.7s/192 words) are re-transcribed through a test-only replay harness sharing the live timing-mapping code path, then diarized. Pass floor: 70% word fidelity.
- Production capture config: `AVAudioSession` category `.record`, mode `.measurement` (disables system AGC/DSP), audio fed to the recognition request via `AVAudioEngine` input tap, ~1-minute segment rollover that swaps the recognition request without restarting the engine.
- Fixture provenance caveat: fixtures were recorded ~1 hour BEFORE the `.measurement` tuning was committed; E7 (re-record under current config) is queued to address this.

## Experiment results (all device runs on physical iPhone 16 Pro, iOS 27.0.1; user-approved)
**Baseline (2026-10-21, verified):** on-device full-file replay: multi-a 3 words, multi-b 1 word (near-total failure, no errors raised). Server path same files: 261/182 words.

**E1–E3 (verified earlier):**
- E1 duration-slice + E2 lifecycle instrumentation: finalization happens, but content is missing rather than errored.
- E3 chunked replay (≤55s chunks, matching production rollover) improved on-device counts 9–29×: multi-a 27/288 (9%), solo 28/149 (19%), multi-b 29/192 (15%). But within each chunk, recognized words came only from the chunk's TAIL (e.g. multi-a's first 0–55s chunk yielded words only from offsets ≥49.9s). So ~2/3+ of each chunk is silently dropped.
- Solo fixture (single speaker, no overlap) fails too → NOT overlap-specific.
- Measured fixture levels (ffmpeg volumedetect): mean −37.4 dB (multi-a), −38.1 dB (multi-b), −46.5 dB (solo); peaks −13.5 to −20.2 dBFS. Quiet audio is the documented failure mode of the on-device recognizer.

**E4 device-asset check (user-performed, reported):** Dictation enabled; Siri language en-US with no download indicator; offline (Airplane Mode) dictation into Notes worked. → On-device speech assets are present and functional. Ruled out.

**E5 gain-normalization A/B (2026-10-22, verified raw prints):** loudnorm'd copies (`loudnorm=I=-16:TP=-1.5:LRA=11`, resampled back to originals' 48kHz/mono/pcm_f32le so sample rate is not a second variable; measured post-normalization means −16.9 to −18.7 dB) replayed via the same chunked path:
- multi-a: 43/288 words (9%→15%), 2 speakers, timing assertions pass, coveredOffsets 87.6–165.5s of 167.5s
- multi-b: 83/192 (15%→43%, biggest jump), 2 speakers, 9 unknown-attribution words, coveredOffsets 34.8–95.7s of 95.7s
- solo: 28/149 (19%→19%, unchanged), 1 speaker, coveredOffsets 54.0–91.2s of 91.1s
- All three still fail the 70% floor. Conclusion drawn: signal level is a contributing factor but not sufficient alone.

**E6 live-tap feed (2026-10-22, verified raw prints):** one ~55s chunk fed through a real `AVAudioEngine` (`AVAudioPlayerNode` → `installTap` on the player node → recognition request), instead of the harness's paced manual `append()` loop. Note: this path required session category `.playAndRecord` (engine wouldn't start an output unit under `.record`; CoreAudio −10851). The chunked/manual paths remain `.record`, unchanged.
- multi-a: 9 words, coveredOffsets 50.0–53.2s of the 55s chunk, firstFinal at 54.2s, endAudio called before final result
- multi-b: 45 words, coveredOffsets 36.0–44.9s, firstFinal 54.5s
- solo: 18 words, coveredOffsets 40.3–50.5s, firstFinal 54.3s
- Conclusion drawn: the manual feed loop is NOT the cause of tail-truncation — a real engine tap truncates the same way (words only from the chunk's latter third).

## Current state
- Uncommitted working tree: Stage 0 implementation + validation harness + E5/E6 test code and loudnorm fixtures. Nothing committed pending U1 exit.
- Queue: E7 (re-record fixtures under current `.measurement` capture config) → live on-device smoke test (1-min rollover + interruption) → user-approved commit. Only after E4–E7: revisit recognizer choice. NOTE: A/B against Apple's newer `SpeechAnalyzer`/`SpeechTranscriber` API is currently listed "out of scope" in the decisions log; changing that is a user decision.
- Known minor issue: one Swift 6 sendability warning in the new E6 harness code (`feedingTask` captured var), to be fixed before commit.

## Questions for you
1. **E5 soundness:** Given the numbers (level normalized +18–28 dB, fidelity improved 0–28 points but capped well under floor, solo unchanged), is "level is a contributing factor but not sufficient" the right conclusion? Any confound in how E5 was run (loudnorm then resample-back; same chunked path)?
2. **E6 validity:** Does the live-tap design actually rule out feed-style artifacts? Consider: `.playAndRecord` was used ONLY in the live-tap path (manual/chunked paths use `.record`); tap is on the player node, not the input node; firstFinal arrives at ~54s of a 55s chunk with endAudio-before-final in all three fixtures. Is the comparison to E3 apples-to-apples?
3. **The tail-truncation pattern:** Across E3 and E6, recognized words come only from roughly the last 1/3 of each fed chunk, with finals arriving just before endAudio. Does this pattern point at a specific known behavior of `SFSpeechRecognizer` on-device (buffering/finalization semantics, `shouldReportPartialResults`, audio-format mismatch, task type `.dictation` vs `.search`, on-device model windowing)? What experiment would you run next to isolate it — before or instead of E7?
4. **Sequencing:** Is E7 (re-record fixtures under current capture config) the right next step, or does the existing evidence already justify a different priority order?
5. **U2 implications:** Does this evidence change how the privacy/fidelity tradeoff decision should be framed for the user (documented limitation vs capture-side gain fix vs opt-in server mode)? Note multi-b's 15%→43% jump from gain alone.
6. **Process/verification gaps:** Anything in the above that smells unverified, over-claimed, or missing a control?

Answer as a numbered list matching the questions. Be blunt; "insufficient evidence" is an acceptable answer.


ChatGPT Reply: 

1. **E5 supports a narrower conclusion: normalization helped two fixtures, but did not restore acceptable performance.** “Level contributes but is insufficient” is reasonable as a working hypothesis, not an isolated causal finding. `loudnorm` can change dynamics and peaks as well as overall gain; resampling back preserves the nominal format but does not make this a gain-only intervention. Add an identity-conversion control and a fixed-gain control, check clipping and frame counts, and repeat runs. Also, **recognized word count divided by reference word count is not fidelity** unless words were aligned and verified correct. Insertions, substitutions, and repetitions could inflate those percentages.

2. **E6 weakens the manual-loop hypothesis; it does not rule out feed artifacts.** A second delivery path reproducing the symptom is useful evidence, but both paths still share request handling, result collection, timing mapping, and potentially buffer assumptions. The session category changed, and a player-node tap does not exercise production microphone capture. The comparison also needs identical source slices, normalization, formats, and request settings. Use `.playAndRecord` for both arms of a controlled replay comparison, then validate production input capture separately. Crucially, the supplied results say **`endAudio` precedes the final callback**; Question 3 says the reverse. Resolve that contradiction before interpreting finalization.

3. **Insufficient evidence identifies a specific recognizer behavior.** Do not label this “on-device model windowing” yet. First audit every recognition callback: request identifier, callback time, `isFinal`, complete transcript, and raw segment timestamps—before application aggregation or timing conversion. Apple describes results as transcriptions of the current utterance and allows intermediate partial results; those semantics warrant inspecting the callback history, not assuming every callback is a complete recording transcript. [Apple recognition-result documentation](https://developer.apple.com/documentation/speech/sfspeechrecognitionresult)

   My next experiment would replay **the same clearly audible 10–15-second early passage** alone, then at the beginning and end of a longer controlled input, using fresh requests and identical settings. Log frames appended, format, pacing, `endAudio`, cancellation, and final delivery. If the isolated passage succeeds but disappears when followed by more audio, investigate result replacement, lifecycle, and duration dependence. If raw callbacks retain early words but the reported output loses them, the defect is downstream. Change partial-result reporting, task hint, or audio format individually afterward. None currently explains the evidence conclusively.

4. **Prioritize the callback/aggregation audit and short-passage control before E7.** They directly test whether “recognizer drops the beginning” is even the correct diagnosis. E7 remains necessary to establish current production behavior, but new recordings change content, delivery, microphone conditions, and capture configuration together. They cannot isolate `.measurement` as the cause. After the audit, perform E7, then the rollover/interruption smoke test with transcript completeness checked across the boundary. A commit can preserve an explicitly failed investigation; it must not imply the 70% acceptance floor passed.

5. **Frame U2 as an unresolved quality failure under the current privacy constraint.** Gain treatment is a promising intervention, particularly for multi-b, but 43% by the supplied count measure remains far below the floor, and solo did not improve. “Documented limitation” is inadequate if this prevents the core reflection workflow from working. The user’s options include continuing local investigation, reducing or deferring the feature, authorizing evaluation of another on-device recognizer, or considering opt-in server processing. The newer Apple API remains a scope decision, not an already rejected technical option. Server word counts demonstrate greater output volume; aligned accuracy measurements are still needed to establish its quality advantage precisely. D-04 remains binding until the user changes it.

6. **The main verification gaps are:**

   - **Metric validity:** Report reference-aligned errors and coverage, separately from output word counts and speaker attribution.
   - **Raw versus mapped evidence:** Timing assertions on a shared code path can pass while both paths share the same defect. Inspect raw recognizer timestamps and independently verify delivered audio.
   - **Coverage interpretation:** A minimum-to-maximum offset range does not establish continuous coverage. “Two-thirds silently dropped” needs interval-level evidence.
   - **E4 overclaim:** Offline Notes dictation makes missing assets less likely; it does not prove this app’s exact locale/model/request configuration works. “Ruled out” is too strong.
   - **Uncontrolled variability:** Repeat trials and record exact request settings, source treatment, formats, frame totals, and lifecycle events.
   - **Unsupported mechanism:** “Quiet audio is the documented failure mode” needs a specific source supporting that claim. Quietness and improvement after processing do not establish the entire mechanism.
   - **Acceptance status:** On the supplied evidence, **U1 has demonstrated failure and narrowed hypotheses; it has not demonstrated acceptable Stage 0 fidelity.**
