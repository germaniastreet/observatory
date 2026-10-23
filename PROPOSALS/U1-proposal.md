# U1 proposal — Finish & land Stage 0 validation

**Author:** Claude (Xcode assistant chat) · **Date:** 2026-10-22

## What's already done (verified by reading current code, not re-derived)
- `ObservatoryTests/FixtureReplayHarness.swift` + `AudioFixtureReplayTests.swift` already implement E1 (duration-slice test), E2 (lifecycle instrumentation), E3 (chunked ≤55s replay matching production's rollover). Their results are the fidelity numbers already recorded in PLAN.md (9–19% on-device vs 70% floor; chunking helps 9–29× but doesn't clear the floor).
- Remaining queue per PLAN.md: **E4** (device asset check), **E5** (gain-normalization A/B), **E6** (live-tap feed), **E7** (fixture re-record) — then the live on-device smoke test, then a user-approved commit.

## Scope (files touched this unit)
- `ObservatoryTests/FixtureReplayHarness.swift` — add an E6 live-tap replay path.
- `ObservatoryTests/AudioFixtureReplayTests.swift` — add E5 and E6 diagnostic tests (same pattern as E1–E3: numeric-only print output, no transcript text).
- Possibly new files under `ObservatoryTests/Fixtures/` — loudnorm'd copies of the three fixtures for E5 only (new files, not modifications to the read-only baselines per D-10).
- Doc updates at exit: `PLAN.md`, `Observatory/STABILIZATION_AND_EXPRESSION_PLAN.md` (Status line), `VERSION_HISTORY.txt`, `DECISIONS.md` if a decision changes.

**Explicitly out of scope for U1:** any production capture change in `SpeechRecognitionManager.swift` (e.g. touching `.measurement` mode). D-04 and PLAN.md U2 already gate that behind E5 evidence *and* a user/product decision — U1 isolates evidence, it doesn't act on it.

## Plan, with the gates CONVENTIONS.md requires
1. **E4 — device asset check.** This is a Settings-app check on your physical device (Dictation enabled; Siri en-US asset fully downloaded), not a code change. I can't see your device's Settings app state — please check and report back, or tell me to proceed without it (E4 is a confound-elimination step, not required to get E5/E6 results).
2. **E5 — gain-normalization A/B.** Needs `ffmpeg` (`loudnorm` filter); it's not installed on this Mac (`which ffmpeg` found nothing). I'd like to `brew install ffmpeg` — a reversible, local dev-tool install — unless you'd rather run that yourself. Once available, I generate loudnorm'd copies of the three fixtures as new test resources and add a diagnostic test running `FixtureReplayHarness.replayChunked` against them, printing word-count fidelity vs. the existing ground truth.
3. **E6 — live-tap feed.** Pure code: a harness variant that feeds one ~55s chunk through a real `AVAudioEngine` (`AVAudioPlayerNode` → `installTap` → request) instead of the paced manual-append loop, to rule out a feed-style artifact. No external tool needed.
4. **Running either on the physical device** (build+install+run the test target) needs your explicit per-action approval per CONVENTIONS.md — I'll ask before that step, separately from asking to write the code.
5. **E7 (fixture re-record)** and the **live on-device smoke test** (rollover + interruption) both require you physically operating the device — I'll hand you exact steps when we get there rather than attempting them myself.
6. Once E4–E7 results are in: update STABILIZATION plan Status, PLAN.md, VERSION_HISTORY.txt, and ask for approval to commit the in-flight changes (the already-uncommitted Stage 0 work plus whatever E5/E6 add).

## Open questions for you before I start editing
- OK to `brew install ffmpeg` for E5, or would you rather install it / skip E5's real-audio run and only review the code?
- OK to proceed with E6 (live-tap) code now, in parallel with sorting out E5?
- Any update on E4 (Dictation/Siri asset state) from your device's Settings app?

---

## Second pass (2026-10-22): E8–E10 proposal, per Hermes's re-sequencing after the ChatGPT review

E4–E6 ran (results and caveats are in PLAN.md). Per director update, the ChatGPT review (`PROPOSALS/U1-chatgpt-review-brief.md`) moved E8 (callback/aggregation audit), E9 (short-passage control), and E10 (controls & metric hygiene) ahead of E7. This section proposes the harness/test changes for those three, to be reviewed before I write any of it. The Swift 6 `feedingTask` sendability warning is already fixed (wrapped in a lock-protected `FeedingTaskBox`, same pattern as `LiveTapRequestBox`) — mechanical, no design question, done ahead of this proposal rather than gated behind it.

### E8 — raw callback/aggregation audit
**Goal:** from one device run, tell apart "the recognizer's own result stream never had the early audio" from "a later callback replaced/dropped what an earlier one already showed" — distinct from "our `SpeechTranscriptTimingMapper` dropped it after a correct raw result."

**Design:** add an optional `onCallback` hook to the existing `replay(audioURL:...)` (not `replayChunked` — one chunk, one request, matching E3/E6's ~55s chunk size via the existing `frameRange` parameter):
```swift
struct RecognitionCallbackLogEntry {
    let callbackIndex: Int
    let elapsedSeconds: TimeInterval
    let isFinal: Bool
    let transcriptLength: Int      // character count only, never the text — SECURITY.md
    let segmentCount: Int
    let minSegmentOffset: TimeInterval?
    let maxSegmentOffset: TimeInterval?
}
```
`runSingleRequest`'s result loop already sees every callback (partial and final) before it breaks on `isFinal` — it just currently discards all but the last one. I'll thread an `onCallback: ((RecognitionCallbackLogEntry) -> Void)?` parameter down from `replay` through to that loop, computed directly from `result.bestTranscription.segments`/`formattedString.count` — i.e. before `SpeechTranscriptTimingMapper` ever runs. This answers the question in one pass: if `minSegmentOffset` is low (near 0s) on an early callback but the *final* callback's own `minSegmentOffset` is ~50s, that's the recognizer itself superseding/dropping early content — nothing to do with our mapping layer, since the log never touches it.

**Test:** `diagnosticCallbackAudit` (E8) — runs all three fixtures' first ~55s chunk through `replay(frameRange:)` with `onCallback` collecting a log, prints every entry plus the existing final-result fields for cross-check.

### E9 — short-passage control
**Goal:** per ChatGPT's suggested experiment — isolate duration/position dependence from content, using a passage known to be clearly audible.

**Design:** reuse a 10–15s slice of `fixture-solo-loudnorm.caf` (already normalized, so level isn't a second variable here) as "the passage." Three arms, fresh request each:
- `.alone` — just the passage (`frameRange`, existing `replay`).
- `.start` — passage + synthesized trailing silence, totaling ~55s.
- `.end` — synthesized leading silence + passage, totaling ~55s.

Silence is generated in-process as zeroed `AVAudioPCMBuffer`s in `targetFormat` and fed via a new small `appendSilence(duration:to:targetFormat:)` helper — no new fixture files needed for this one. New function `replayPassagePositionControl(audioURL:passageRange:totalDuration:position:...)`, following `replayLiveTap`'s precedent of a self-contained stream/timeout/cancellation block rather than threading a third variant through `runSingleRequest`.

**Test:** `diagnosticShortPassageControl` (E9) — all three arms on the solo-loudnorm passage, prints word count / coveredOffsets per arm. `.alone` is the control that should recover ~all the passage's words if duration/position is the driver, not content.

### E10 — controls & metric hygiene
- **(a) identity-conversion control:** new `fixture-*-identity.caf` (ffmpeg re-encode through the exact same pcm_f32le/48kHz round-trip as E5, but no `loudnorm` filter) — isolates "did merely re-encoding change anything" from "did the gain change matter." 3 new files.
- **(b) fixed digital-gain control:** new `fixture-*-gain20db.caf` (`ffmpeg -af volume=20dB`, flat linear gain, no dynamics compression) as an alternative to `loudnorm`'s compression — isolates gain from loudnorm's other processing. 3 new files.
- **(c) E6 session-category control:** add a `sessionCategory: AVAudioSession.Category = .record` parameter to `replayChunked` (default unchanged, so E3/E5 are untouched) so the manual-feed path can also be run under `.playAndRecord`, matching E6's arm exactly — isolates the feed mechanism from the category change ChatGPT flagged.
- **(d) repeat trials:** no new harness code — the E8/E9/E10 tests each loop 3x and print every run, to show run-to-run variance rather than a single sample.
- **Metric-hygiene doc fix:** strengthen the existing `FixtureCase.groundTruthWordCount` / `minimumWordFidelity` doc comments to state explicitly that this ratio is an *upper-bound* proxy (raw count, not alignment-verified WER) and that `coveredOffsets` is a min–max range, not proof of continuous coverage — matching PLAN.md's new caveats. No behavior change, comment-only.

All six new fixture files are new, under `ObservatoryTests/Fixtures/`, never touching the three read-only baselines (D-10) — same approach as E5's loudnorm copies.

### Scope / sequencing
This is `FixtureReplayHarness.swift` + `AudioFixtureReplayTests.swift` (already in scope) + 6 new fixture files. No production code touched. Device runs (building/running E8/E9/E10 on-device) still need your separate per-action approval, same as E5/E6 — I'll write and build-check the code first, then ask.

**Question for you:** proceed with writing E8–E10 as scoped above, or trim anything (e.g. skip E10b's extra gain arm if E10a/c already feel sufficient)?
