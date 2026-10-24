# U5 proposal — Transcript accumulation prototype (TEST-ONLY phase)

**Author:** Claude (Xcode assistant chat) · **Date:** 2026-10-24 · **Status:** awaiting director review
**Scope of this phase:** `ObservatoryTests/` only. No edits to `SpeechRecognitionManager.swift`, `Models.swift`, or any app-target file. One non-test edit is requested and flagged for approval (Q2: a single `.gitignore` line).

## 1. What this unit has to answer

E8 established that, on this device/OS/request configuration, `SFSpeechRecognitionResult.bestTranscription` is **replacement-not-cumulative across internal utterance boundaries** inside one continuous request. Production (`SpeechRecognitionManager.handleRecognition`, line 1044–1052) *replaces* `currentSegmentUtterances` wholesale on every callback and only appends to `sealedUtterances` at a generation seal — so every mid-request reset silently discards content the recognizer already emitted.

The question U5 answers is narrow and must stay narrow:

> **How much of what the recognizer actually emitted does the current collection strategy throw away, and can it be recovered correctly — with honest timing — rather than merely in larger quantity?**

It does **not** answer whether on-device recognition is good enough for the product. That is U2, and per PLAN.md's reframing it can only be decided on the residual gap *after* this unit measures the recoverable part. A word-count increase is not a result here; an alignment-verified, timing-verified increase with bounded duplication is.

## 2. Architecture: three separable layers

The single most important structural decision in this proposal is that the algorithm is a **pure function over a recorded callback trace**, not something welded to a live recognizer.

| Layer | Contents | Where it runs | Why separated |
|---|---|---|---|
| **Evidence** | `RecognitionTrace` — every callback's full hypothesis (segments, raw timestamps/durations, `isFinal`, arrival elapsed), per request, with that request's file-start anchor | Device (captured during replay) | Capture once; the recognizer is the only part needing a device |
| **Algorithm** | `TranscriptAccumulator` — deterministic state machine, trace in → spans + diagnostics out. No AVFoundation, no Speech-framework calls, no I/O | Simulator *and* device | Lets every controlled case be a fast, deterministic simulator test; lets rival algorithms be scored on the **same** trace |
| **Evaluation** | Reference alignment, duplicate/omission counting, independent energy-based timing checks, fingerprinted reporting | Simulator + device | Scoring is itself testable, and comparisons are paired rather than run-to-run |

Two consequences worth stating plainly, because they answer the weakest parts of the E5/E9/E10 evidence:

1. **Paired comparison removes run-to-run variance as a confound.** Today's algorithm (final-only collection), the accumulator, and the explicitly-unapproved drop-and-concatenate are all run over *one* captured trace. Any difference is attributable to the algorithm, not to a different device run. PLAN.md's process note (§7, back-to-back device runs producing untrustworthy numbers) stops applying to the algorithm comparison entirely — it only applies to trace capture.
2. **Drop-and-concatenate is included as a measured negative control, not as a candidate.** Its duplicate count on the repeated-phrase cases is the evidence for why it is wrong, rather than an assertion that it is.

## 3. The state machine

### 3.1 Inputs

```swift
struct HypothesisSegment {
    let text: String              // from formattedString via substringRange (production's rule)
    let rawTimestamp: TimeInterval
    let rawDuration: TimeInterval
    let confidence: Float
}

struct HypothesisSnapshot {
    let callbackIndex: Int
    let arrivalElapsed: TimeInterval   // DIAGNOSTIC ONLY — never used as a timing source (see §3.6)
    let isFinal: Bool
    let segments: [HypothesisSegment]
    let formattedString: String
}
```

### 3.2 Timing materialization (D-07 at the segment level)

```
isMaterialized(segment, index) ==  rawDuration > 0 && (rawTimestamp > 0 || index == 0)
```

`rawDuration > 0` is required because a partial's segments routinely arrive with `timestamp == 0, duration == 0` before timing materializes; `index == 0` is allowed because a genuine first segment of a request legitimately sits at timestamp 0.0.

**Stated ambiguity, not papered over:** a *post-reset* hypothesis whose first segment reads `timestamp == 0.0, duration > 0` is indistinguishable by value alone from a request-start segment. That ambiguity is the reason for arm E11d (§6) and for the rule in §3.6 — the prototype detects and reports the reset timing mode rather than assuming it.

A hypothesis is classified `.fullyTimed` / `.partiallyTimed(throughIndex:)` / `.untimed`. Both of the trackers the review asked for are maintained per request:

```swift
var latestHypothesis: HypothesisSnapshot?        // most recent, whatever its timing state
var latestTimedHypothesis: HypothesisSnapshot?   // most recent with ANY materialized segment,
                                                 // retained with its materialized prefix length
```

`latestTimedHypothesis` is never assumed to exist and never assumed to cover the whole pre-reset utterance — both are *observed* behaviours per E8's caveats, so both are handled as failure modes (§3.5).

### 3.3 Classification of a new snapshot `H` against the active hypothesis `P`

Tokens are normalized words (case-folded, punctuation stripped, index-mapped back to their source segments). Let `cpl = commonPrefixLength(P.tokens, H.tokens)`.

| # | Class | Condition | Action |
|---|---|---|---|
| 1 | `.initial` | `P == nil` | `H` becomes active |
| 2 | `.identical` | `cpl == P.count == H.count` | No content change; upgrade timing if `H` is more materialized |
| 3 | `.growth` | `cpl == P.count && H.count > P.count` | Ordinary extension; `H` replaces `P` as active |
| 4 | `.revisionShortening` | `cpl == H.count && H.count < P.count` | Same utterance, tail **retracted**. `H` replaces `P`; the retracted tail is **discarded, never committed**. Counted (`retractedTailEvents`, with token count) |
| 5 | `.revisionInPlace` | Not a replacement by the §3.4 test, tokens differ past `cpl` | Same utterance, tail rewritten; `H` replaces `P` |
| 6 | `.utteranceReplacement` | §3.4 test fires | Commit `P` (§3.5); `H` starts a new utterance |
| 7 | `.overlap` | Replacement by timing, but `P`'s suffix matches `H`'s prefix (≥ 2 tokens) | Commit `P` **minus** the overlapping suffix; `H` continues. Counted (`overlapStitches`) |
| 8 | `.ambiguousBoundary` | Audio spans overlap, no token overlap found | Commit `P` in full, record an `UnresolvedSpan(.ambiguousBoundary)`. **Never silently merged** |

### 3.4 Replacement test — timing first, text only as fallback

This is the part most likely to be wrong if done by a tuned ratio, so it is deliberately structural:

- **Both `P` and `H` have materialized timing** → replacement iff `H.firstOffset ≥ P.lastOffsetEnd − overlapTolerance` **and** `cpl < P.count`. Rationale: a revision's hypothesis still begins at the *same utterance's* start, so `H.firstOffset ≈ P.firstOffset`, nowhere near `P`'s end. No ratio needed.
- **Timing unavailable on either side** → replacement iff `cpl == 0` **and** `H.tokens.first != P.tokens.first`. A mid-utterance revision essentially never rewrites token 0 after normalization; a reset essentially always does.
- **`cpl == 0` but `H.count ≥ P.count`** (a full rewrite that is not a collapse) → classified `.ambiguousBoundary`, counted as `lowConfidenceClassifications`, never silently treated as either.

Every classification records which evidence class decided it (`.timing` or `.textOnly`), and the report breaks the histogram down by evidence class — so a reviewer can see exactly how many decisions rested on text alone. Prototype tolerances live in one `AccumulationTuning` struct with per-constant rationale; **D-16 note:** these are prototype constants, and the production port must migrate them to the SignalLibrary rule pattern (or justify in writing why recognizer-lifecycle tolerances are not product thresholds). That migration path is part of the production proposal, not deferred silently.

### 3.5 Commit — where D-07 is enforced

```swift
struct ResolvedToken { let text: String; let offset: TimeInterval?; let duration: TimeInterval? }

struct ResolvedSpan {
    let tokens: [ResolvedToken]
    let generation: Int
    let requestStartFileOffset: TimeInterval?   // production's generation anchor
    let timingSource: TimingSource              // .ownHypothesis | .latestTimedHypothesis | .none
    let sourceCallbackIndex: Int
}
```

File-relative offset = `requestStartFileOffset + rawTimestamp`, computed **only** when both exist — mirroring `AudioFileWriter.audioOffset(forGeneration:segmentTimestamp:)` so the production port is a 1:1 translation rather than a reimplementation.

Commit order of preference for the span's timing:
1. `P`'s own materialized segments.
2. For tokens `P` has but `P` never timed: `latestTimedHypothesis`'s materialized prefix, matched by token identity, **only** where the token sequences agree.
3. Anything still uncovered: `offset = nil`, plus exactly one `UnresolvedSpan`:

```swift
struct UnresolvedSpan {
    enum Reason { case timingNeverMaterialized, ambiguousBoundary, resetBeatMaterialization, orderingUnresolved }
    let reason: Reason
    let tokenCount: Int
    let textFingerprint: String        // never the text
    let neighborLowerBound: TimeInterval?   // nil unless BOTH neighbours resolved
    let neighborUpperBound: TimeInterval?
}
```

**Hard rule, test-enforced:** no code path in the accumulator may write `0` into an offset as a stand-in for "unknown." Unresolved spans are a first-class, counted, reported output; a run with resets that beat materialization is *expected* to report a nonzero unresolved count, and a report claiming zero unresolved spans on such a run is treated as a defect in the prototype, not a success.

### 3.6 What the prototype may NOT do

Re-anchoring an untimed or post-reset span from `arrivalElapsed`, buffer counts, or interpolation between neighbours is **not** in this design. That would manufacture offsets D-07 exists to forbid, and it would be invisible in every metric except an independent timing check. `arrivalElapsed` is carried in the trace for diagnosis only. See Q4 for the one circumstance under which this becomes a question worth escalating.

### 3.7 Final reconciliation

On `isFinal`, the final snapshot is classified against `P` by the same rules and committed. Then one extra pass: if the final snapshot's token sequence *contains* an already-committed span's sequence **and** their audio spans overlap, the duplicate is dropped from the final and counted (`finalOverlapDrops`). This covers the case where Apple's final result turns out to be cumulative after all — without that pass, an accumulator would double-count exactly the content it was built to preserve. A request terminated by error commits its open span with whatever timing exists plus unresolved markers, counted as `requestEndedByError`.

### 3.8 Session assembly across generations (rollover) — ordering

Per PLAN.md's U6b caveat (ii), which is hard device evidence that post-recovery words persist last in text order while carrying mid-file timestamps:

- Spans are ordered by **first resolved file-relative offset, ascending** — never by arrival or persistence order.
- A span with no resolved offset keeps its position relative to its own generation's neighbours (insertion order within generation, generations in generation order) and is flagged `orderedByFallback`, counted, and recorded as an `UnresolvedSpan(.orderingUnresolved)`. It is not silently interleaved as though its position were known.
- **Rollover-boundary de-duplication fires only on audio-time overlap AND token match.** Never on text alone. This is the rule that lets a genuinely repeated phrase survive, and it is what the controlled cases in §5 exist to verify.

## 4. Evaluation

### 4.1 Reference-aligned accuracy

Needleman–Wunsch / Levenshtein alignment over normalized tokens, reconstruction vs reference, reporting:

| Metric | Definition |
|---|---|
| `substitutions`, `deletions`, `insertions`, `wer` | Standard alignment counts (not a count ratio — explicitly replacing the `wordCount / groundTruthWordCount` upper bound the existing tests are documented as using) |
| `omissionCount` | `= deletions`, reported separately by request/generation so loss can be localized to a reset |
| `duplicateCount` | Insertion runs whose tokens repeat a contiguous reference n-gram already consumed by an adjacent alignment — i.e. the reconstruction said the same reference words twice. Reported as runs *and* tokens |
| `insertionsOther` | Insertions that are not duplicates (genuine hallucination/mis-splits), kept distinct so duplication cannot hide inside a generic insertion count |

Run for **three algorithms on the same trace**: `finalOnly` (today's production behaviour), `accumulated` (this design), `dropAndConcatenate` (negative control).

### 4.2 Independent segment-timing checks

"Nonzero ≠ accurate," so timing is checked against evidence the recognizer did not produce:

- **T1 — energy profile.** `FixtureAudioEnergyProfile` reads the `.caf` directly via `AVAudioFile` and computes 20 ms RMS frames, a per-file noise floor, and speech/silence regions with minimum-duration hysteresis. No ffmpeg, no external tool, no recognizer involvement. Reports: tokens whose `[offset, offset+duration]` overlaps a speech region; tokens landing entirely inside silence (**timing implausible**); tokens past the file end.
- **T2 — known-boundary composites.** Built in-process from existing fixtures (no new recording, fixtures stay read-only): a clearly-audible passage placed at known offsets inside synthesized silence, reusing `appendSilence`'s explicitly-zeroed buffers from the existing harness. Because everything outside the known windows is synthetic silence, *every* reconstructed token must land inside a known window — exact by construction, no reference text required.
- **T3 — ordering invariants.** Backward offset steps after assembly must be 0; a paired check asserts the `finalOnly` baseline *does* exhibit backward steps on the U6b-style trace, proving the metric detects the real anomaly rather than being vacuously satisfied.

### 4.3 Privacy-preserving fingerprints

```swift
enum TextFingerprint { static func of(_ text: String) -> String }   // first 8 hex of SHA256(processSalt ‖ normalized(text))
```

A 32-byte random salt is generated once per test process and **never logged**. Reports carry fingerprint + token count + character count; the report types have **no `String` text field at all**, so "no transcript text in logs" is structural rather than a discipline every future `print` has to remember.

**Honest limitation, stated rather than claimed away:** an unsalted short hash of a single common word is trivially reversible by dictionary attack. The per-process salt removes that, at the cost of making fingerprints incomparable across runs — which is acceptable because every comparison in this design is within a single run over a single trace. Fingerprints prevent transcript reconstruction from logs; they are not a cryptographic privacy guarantee about the fixtures themselves.

## 5. Controlled cases (simulator, deterministic, no device)

Hand-written synthetic traces, so each case is a fast unit test with an exact expected outcome.

| # | Case | Must hold |
|---|---|---|
| 1 | Repeated phrase, same tokens at 5.0 s and 30.0 s, one request | Both occurrences survive; de-dup does not fire (no audio overlap) |
| 2 | Repeated phrase straddling a rollover boundary, non-overlapping audio | Both survive |
| 3 | Genuine boundary duplicate: same tokens, *overlapping* audio spans across generations | Exactly one survives |
| 4 | Hypothesis shortening `a b c d e` → `a b c` → final `a b c` | Result is `a b c`; no `d e`; no `a b c` twice |
| 5 | Untimed reset (`P` entirely `timestamp 0 / duration 0`) | `P`'s tokens present, offsets all `nil`, exactly one `UnresolvedSpan(.timingNeverMaterialized)`, **zero** `0.0` offsets |
| 6 | Partially-timed reset: `latestTimedHypothesis` covers 3 of 5 tokens | 3 timed, 2 `nil`, unresolved span of 2 |
| 7 | Overlap stitch: `P` ends `… the red door`, `H` begins `red door was`, overlapping in time | Stitched once; no duplicated `red door` |
| 8 | Ambiguous overlap: time overlap, no token overlap | Both committed, `ambiguousBoundary` counted, unresolved span recorded |
| 9 | Cumulative final: final snapshot contains all prior content | No double-counting (`finalOverlapDrops > 0`) |
| 10 | Error-terminated request | Open span committed, `requestEndedByError` counted, nothing fabricated |
| 11 | U6b ordering anomaly: spans arriving last carrying mid-file offsets | Assembly ordered by offset, 0 backward steps; `finalOnly` baseline *does* show backward steps |
| 12 | Provenance invariant (property-style, over all synthetic traces) | Every reconstructed token traces to exactly one source callback; no token appears in two spans without an audio-overlap justification |
| 13 | Growth-only trace | Result is exactly the final hypothesis — the accumulator adds nothing on a well-behaved request |

Case 13 matters as much as the rest: the accumulator must be a no-op where there is nothing to recover.

## 6. Device arms (E11) — require user approval, run after §5 is green

Each arm is a **separate, isolated test action**, per PLAN.md's process note (§7) on contaminated back-to-back runs.

| Arm | What | Purpose |
|---|---|---|
| **E11a** | All three baseline fixtures, `replayChunkedCapturingTrace` (55 s chunks, matching production rollover), all three algorithms scored on each captured trace | The headline result: reference-aligned accuracy, duplicates, omissions, unresolved spans, timing checks |
| **E11b** | Same, `-loudnorm` variants | Separates "the algorithm recovered content" from "the content was never recognized at all" — E5 showed level matters for two fixtures and not for solo |
| **E11c** | T2 composites: known passage at two known offsets with silence padding; passage repeated | Exact timing verification and the real-audio repeated-phrase case |
| **E11d** | Reset-timing probe: single request, passage at a known 30–42 s offset after silence | **Determines, with evidence, whether post-reset timestamps stay request-relative or restart near zero.** Reported as `.requestRelativeContinues` / `.restartsAtZero` / `.indeterminate`; never assumed |

Trial counts: 3 for E11a (headline), 1 for E11b–E11d unless the director wants more. Rough device cost: the fixtures total ~4.5 minutes of audio fed at real-time pace, so E11a ≈ 15–20 min with 3 trials, all four arms ≈ 45–60 min of device time including setup. Flagged so the director can trim before approving (Q3).

## 7. Files

**New, all test-target (`ObservatoryTests/`):**
- `TranscriptAccumulationPrototype.swift` — types + `TranscriptAccumulator` + the `finalOnly` and `dropAndConcatenate` comparators. Pure; no AVFoundation/Speech calls.
- `TranscriptAccumulationScoring.swift` — alignment, duplicate/omission counting, `FixtureAudioEnergyProfile`, `TextFingerprint`, report types (text-field-free by construction).
- `TranscriptAccumulationTests.swift` — §5's cases, simulator.
- `TranscriptAccumulationDeviceTests.swift` — §6's arms.

**Extended:** `FixtureReplayHarness.swift` — adds `onSnapshot:` to `runSingleRequest` and new `replayCapturingTrace` / `replayChunkedCapturingTrace` / composite-feed entry points. **Existing functions and their existing `onCallback` instrumentation are left byte-for-byte unchanged**, so E1–E10's numbers stay directly comparable; the new entry points are purely additive.

**Not touched:** `SpeechRecognitionManager.swift`, `Models.swift`, `SpeechTranscriptTimingMapper.swift`, every other app-target file, the existing `AudioFixtureReplayTests.swift` assertions (including the 70 % fidelity floor), and the read-only fixtures themselves.

## 8. Exit criteria for this (test-only) phase

1. §5's logic tests green on simulator, reported as real counts alongside the existing suite's total — not "should pass."
2. For each of the three fixtures: reference-aligned WER with substitution/deletion/insertion breakdown, `omissionCount`, `duplicateCount`, and unresolved-span counts, for all three algorithms **on the same captured trace**.
3. `accumulated` recovers more reference tokens than `finalOnly` **without** duplication inflating the gain — target: duplicate tokens ≤ 2 % of reconstructed tokens. If missed, the number is reported as-is and the state machine is revised, not the target.
4. Zero fabricated offsets (no `0.0`-as-unknown) in any arm; every unresolved span explicitly reasoned and counted.
5. T2 composites: 100 % of reconstructed tokens inside their known windows (± one segment-duration tolerance), or the deviation reported with its magnitude.
6. E11d returns a determination of the reset timing mode backed by the composite evidence.
7. No transcript text in any emitted report (structural: report types have no text field).

**A valid, non-failure outcome** (per CONVENTIONS.md's "absence of evidence is a valid result"): if accumulation recovers little — e.g. pre-reset content genuinely absent from every snapshot in these fixtures — the honest output is "result collection is not the dominant loss; the loss is upstream of `bestTranscription`," which reframes U2 rather than failing U5. The prototype is built to be able to return that answer.

## 9. Decisions needed from the director

**Q1 — reference text source (blocking for §4.1 only; §4.2/§5 proceed regardless).** `.caf` fixtures are gitignored (`.gitignore:17`, "recordings may contain sensitive audio"), so no reference transcript exists in-repo and none should be committed.
- **(R-A, recommended)** Use the fixtures' **original live transcripts** from the device backup `completed_reflections_v1.json` — the same source PLAN.md's 288/192/149 ground-truth counts came from — placed as local-only, gitignored reference files. Available immediately; honest caveat: it is *agreement with the original capture*, which was itself produced by the pre-fix pipeline, not verified verbatim ground truth. Every WER number would be labelled as such.
- **(R-B)** User-provided verbatim transcription of the three fixtures — true ground truth, costs the user ~5 minutes of listening per fixture. Strictly better for an absolute accuracy claim; can be added later without redesign.
- **(R-C)** Reference-free only (§4.2 composites) — rigorous on timing and duplication, but cannot report WER at all, which does not satisfy review #2's "reference-aligned accuracy."

Recommendation: R-A now, labelled as agreement-not-ground-truth, with R-B as an optional upgrade. Needs a decision on **who produces the reference file** — extracting it from the backup JSON is data extraction, not code, but it is also not obviously Hermes's remit under D-13.

**Q2 — one non-test edit.** A single `.gitignore` line (`ObservatoryTests/Fixtures/*.reference.txt`) so the reference files cannot be committed by accident. Requesting explicit approval rather than treating it as in-scope.

**Q3 — device-run budget.** §6 as written is ~45–60 min of isolated device actions. Confirm, or trim (e.g. E11a+E11c only, 1 trial each, ≈ 15 min).

**Q4 — pre-stated conditional ChatGPT escalation.** Everything above is settled by review #2's criteria as embedded in PLAN.md, so no ChatGPT round is proposed now. One contingency is flagged in advance rather than decided silently: **if E11d shows post-reset timestamps restart near zero**, then "may a span be re-anchored from a non-timestamp source (arrival time, buffer counts, neighbour interpolation), or must it be unresolved?" is a D-07 semantics question of exactly the kind D-17 went to ChatGPT for (the Q3 precedent). This proposal's answer for the **test-only** phase is "mark unresolved and report," which needs no escalation and does not block U5. The escalation would only be needed before a **production** port that wanted to re-anchor. Flagging now so it is not discovered mid-implementation.

## 10. Sequencing

1. Director review of this proposal (Hermes, from disk) → Q1–Q3 answered.
2. Implement the algorithm + scoring + §5's controlled cases; run the simulator suite; report real numbers.
3. Hermes review of the logic-test evidence against the xcresult bundle.
4. Device arms (§6) on user approval, isolated actions, with the container-backup precaution the prior units used.
5. Scored report + honest verdict → **then** the production proposal for `SpeechRecognitionManager.swift`, which is a separate unit requiring its own review per PLAN.md's U5 entry.
6. CONVENTIONS.md exit protocol at the close of the unit.
