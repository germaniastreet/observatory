# DECISIONS.md — settled choices
**Don't re-litigate these in chat.** If new evidence contradicts an entry, amend it here explicitly (with date + rationale) rather than silently diverging in code. Deepest product-level rules live in `Observatory/PROJECT_CONSTRAINTS.md` (binding, v0.2); this log records concrete decisions made under them.

## Product & scope
- **D-01 (2026-08): App renamed WayReally → Observatory.** Xcode project, entitlements paths, and docs all migrated; stray `second/` paths fixed (`ad29322`, `bdf515c`).
- **D-02 (2026-10): The product is about expression, not just words.** Prolonged sounds, compressed/accelerated delivery, reduced articulation, and change in expression are the signal; words are context. Stretching may *accompany* uncertainty but never *establishes* an emotion.
- **D-03: Observation / interpretation / self-report are three distinct, separately-persisted layers.** Nothing infers felt emotion from deliberate test speech; nothing asserts an emotion from a single acoustic cue. Interpretations are tentative, non-exclusive (`alternativeExplanations`), and support user correction.
- **D-04: No external audio/ML services; recordings stay on-device — now code-enforced** (2026-10-21, uncommitted): `requiresOnDeviceRecognition = true` in `SpeechRecognitionManager.swift`. Known consequence: Apple's on-device recognizer loses fidelity on quiet/multi-speaker audio (measured: 9–19% word recovery vs 70%+ server-side; prime suspect is capture gain — `.measurement` mode disables system AGC). Whether to add an explicit opt-in server-based mode with its own consent flow is an open **user/product decision** (PLAN.md U2), not an agent decision.

## Speech pipeline (Stage 0, implemented 2026-10-15)
- **D-05: Frame accounting counts successful writes only.** `capturedFrames` / `enqueuedFrames` / `writtenFrames` are distinct; downstream offset math uses `writtenFrames` and a per-recording fixed sample rate (piecewise segments if the rate ever changes mid-recording).
- **D-06: Generation-tagged recognition lifecycle.** Monotonic `requestGeneration`, single-rollover guard, rapid-restart guard, lock-unified `endAndClear` (closes the append/endAudio race). Audio engine is never stopped/restarted at segment boundaries — only the recognition request is swapped (`CurrentRequestBox`).
- **D-07: `nil` means unavailable, never `0`.** Optional word `audioStart/audioEnd` with backward-compatible legacy decode; unavailable features are marked unavailable, not defaulted to neutral values.
- **D-08: Typed diarization results.** `DiarizationResult.segments` replaced RTTM text parsing; word-level speaker matching by overlap duration; honest `Speaker.overlap/.unknown` instead of defaulting to `.user`; raw segments + filtering decisions persisted for audit.
- **D-09: Reliability gates analysis.** `audioRecordingReliable == false` or `missingAudioIntervals` gates BOTH diarization and (future) acoustic-feature extraction; `stop()` awaits writer drain before anything opens the file.
- **D-10: Fixture validation method.** The three saved fixtures (`fixture-solo.caf`, `fixture-multi-a.caf`, `fixture-multi-b.caf`) are read-only baselines. Re-diarizing saved session JSON cannot validate Stage 0 (original timing was already discarded) — validation re-transcribes each `.caf` through a test-only replay harness sharing the live code path (`SpeechTranscriptTimingMapper`), then diarizes that output.
- **D-11: Speaker labels never guess identity.** Diarization ("who spoke when") is separate from identification ("is this Chris?"); labels stay "Speaker 1/2/3" without enrollment or explicit user confirmation (constraints §8).
- **D-12: SpeakerKit pinned to 1.0.0** (Pyannote v4 on-device).

## Process
- **D-13: Three-agent split.** Claude implements (Xcode assistant), ChatGPT reviews plans pre-implementation, Hermes directs and verifies against artifacts and never edits code. Device builds/installs/tests and commits require explicit per-action user approval; git via Xcode GUI only.
- **D-14 (2026-10-22): One unit of work = one fresh chat thread.** Durable context lives in PLAN.md / CONVENTIONS.md / DECISIONS.md, not in chat history. Exit protocol at the end of every unit (see CONVENTIONS.md).
- **D-15: Plans get independent review before execution.** STABILIZATION_AND_EXPRESSION_PLAN.md went through two ChatGPT review revisions before approval; the same applies to future multi-file plans.
- **D-16: Thresholds are data, not Swift constants.** Acoustic/detection thresholds go through the SignalLibrary rule pattern (`SignalRuleMatchType` numeric case), per constraints §7. Hard-coded rules are temporary prototypes requiring a documented migration path.

## Explicitly out of scope (as of 2026-10-15 plan)
Perceptual ground-truth annotation at scale; further diarization-threshold retuning; full async `AVAudioSession` migration; SpeechAnalyzer/SpeechTranscriber A/B migration; any external audio/ML service.
