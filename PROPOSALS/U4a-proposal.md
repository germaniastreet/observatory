# U4a proposal — Acoustic-expression observation prototype, transcript-independent (PROPOSAL-ONLY phase)

**Author:** Claude (Xcode assistant chat) · **Revision 2, 2026-10-24** (R1 dated 2026-10-24) · **Status:** revised after ChatGPT review (APPROVE WITH CHANGES, not implementation-ready); going to **director verification against the review**, not another ChatGPT round, per director ruling (e)
**Phase:** Proposal only. No code in this phase; the only file touched is this one.
**Implementation scope when approved:** `ObservatoryTests/` only (new files), plus the already-approved `project.pbxproj` test-resource edit. **No production-target file.**

---

## 0. Change log — Revision 1 → Revision 2

Every review point, and what changed. Review items are numbered by the question they came from. Nothing is silently dropped; the three places I push back or qualify are marked **[partial]** with reasons.

### Q1 — architecture and evidence claims

| # | Review point | Change |
|---|---|---|
| R1.1 | M1/M4 are *proposed checks*, not validation evidence already obtained; "validated detector" overstates | §2 now calls Channel A an **experimental estimator undergoing verification**. Every "validated" claim is gone; M1/M4 are described as checks whose results are unknown. The Q1 deviation argument no longer claims validation — it claims a *verification plan*, which is a weaker and correct claim |
| R1.2 | Withdraw "Channel-B coverage is bounded by E8's word-recovery percentage" — unmeasured | Withdrawn in §2 and §8. E8 is a recognition-**output** defect; whether result-level acoustic arrays cover the same proportion of audio is **unknown and is what M5 measures**. The old §3.3/§2 wording ("coverage bounded by E8") is deleted wherever it appeared |

### Q2 — code/data boundary

| # | Review point | Change |
|---|---|---|
| R2.1 | Search range, peak-strength floor, smoothing, octave-jump limits are consequential measurement parameters → versioned **estimator configuration as data**, distinct from observation-selection rules, values + hash in the report | New §4.4: `U4aEstimatorConfig.json`, separate file and separate schema from the rules library, SHA-256 + full inline values recorded in every report. §7 now covers only observation-selection rules |
| R2.2 | A6-vs-§5 contradiction: A6 called the peak-strength floor rule-data, §5 put it in code | Resolved — it is **estimator configuration** (§4.4), neither code constant nor observation rule. Both tables updated |
| R2.3 | Out-of-range periodic speech must not silently become "unvoiced" | §4.3: a periodicity peak at the search-range rail raises `searchRangeRail(.low/.high)`, the frame is reported `periodicityOutOfRange` — **not** `unvoiced` — its F0 is `nil`, and rail-hit counts are a reported statistic. A widened-range diagnostic pass (40–600 Hz, config-selectable) runs on request to quantify what the operational range excludes |
| R2.4 | Octave-jump rejection must not silently erase genuine abrupt pitch change | §4.3: rejection **never substitutes a value**. The frame's F0 becomes `nil` with flag `octaveJumpRejected`, the raw pre-smoothing candidate is retained in the per-frame diagnostic series, and rejection/octave-error rates are reported with every F0 result (M1 requirement R6.6). An "abrupt legitimate pitch change" synthetic case tests exactly this failure mode |

### Q3 — splice / discontinuity evidence

| # | Review point | Change |
|---|---|---|
| R3.1 | `.incomplete` does not universally mean spliced | §6.1 enumerates the patterns (`truncatedTail`, `truncatedHead`, `internalJoin`, `multipleJoins`, `unknownPattern`) and defaults to `unknownPattern`. U6b's *reported recovery* establishes a join **for that recording**; the enum never does |
| R3.2 | The two duration calculations are algebraically dependent — not independent corroboration | Withdrawn, with the algebra shown explicitly in §6.2 so the error is visible rather than quietly removed |
| R3.3 | Recognition-restart timestamps ≠ capture-resumption timestamps | §6.2 states the assumption chain and bounds it; `recognitionContinuityGaps` is demoted to a **weak upper-bound witness**, never a resumption time |
| R3.4 | Silence runs / noise-floor steps are candidate evidence; a splice can be seamless, and near-silence can occur without a splice | §6.3 relabels both as *candidate* evidence with false-positive and false-negative modes named; the seamless-splice control (R6.9) exists to demonstrate the false-negative case |
| R3.5 | Missing wall time is unobserved behavior, not an established pause | Fixed. The R1 sentence claiming a splice "erases a 32.6 s pause that really happened" is deleted; §6 now says the wall-time gap is **unobserved** and no behavioral claim attaches to it |
| R3.6 | Specify the disagreement policy; exclude everywhere the join plausibly is; abstain even if little audio remains; do not manufacture safe spans for M2 | New §6.4 is an explicit decision table. Unbounded evidence ⇒ the **whole file** is one unresolved region and temporal measurements abstain. §9's M2 is restructured (R6.7) so abstention cannot be punished |
| R3.7 | `nil` completeness = unknown provenance, not complete | §6.1: `nil` gets its own handling — analyzed, but every measurement carries `completenessUnknown`, and join-sensitive measurements get the unknown-provenance guard |
| R3.8 | Establish the coordinate system of `missingAudioIntervals` before subtracting | **Done, by reading the writer** (`SpeechRecognitionManager.recordLoss`, lines 432–439). Finding in §6.5: the bounds are written-frame-derived seconds, but the lost frames were *never written* — so the interval is **not a subtractable span in file coordinates**; it is a **join at `start` with a known missing duration**. R1's "subtract missing intervals" rule was wrong and is replaced |
| R3.9 | Production should persist capture-discontinuity events at recovery: writer-owned sample offsets, monotonic capture times either side, reason, uncertainty, clock identity, multiple events; callback timestamps insufficient; prospective recording should precede production use of splice-sensitive measurements | §6.6 expands the U4 recommendation to exactly this shape, including the sequencing condition |
| R3.10 | CAF duration from frame count, not file bytes (Hermes Finding 3) | §6.2's table now uses `AVAudioFile.length ÷ sampleRate`; the byte arithmetic is kept only as a footnote showing why it was ~0.02 s off |

### Q4 — Channel-B units

| # | Review point | Change |
|---|---|---|
| R4.1 | Raw units; preserve the documented description and access path | §8.6, unchanged in substance, now also records the access path per value |
| R4.2 | A fitted relationship is an empirical mapping for the tested API/device/OS/config, not Apple's definition; fit only independently aligned frames; report residuals and sample coverage; hold out material; Channel A's errors limit the comparison | §8.6 rewritten accordingly, including a held-out split and an explicit statement that Channel A's own error floor bounds what the comparison can show |

### Q5 — Channel B path, alignment, coverage

| # | Review point | Change |
|---|---|---|
| R5.1 | Result-level `speechRecognitionMetadata.voiceAnalytics` primary; deprecated segment-level only as optional compatibility diagnostic, separately reported, never merged | §8.1 |
| R5.2 | Specify result handling: chunk identity, partial-vs-final, revisions, dedup, failures; callbacks must not inflate coverage | §8.3 — finals only for coverage, union-of-intervals accumulation, superseded-final counting, per-chunk outcome record |
| R5.3 | Specify input mapping: the actual source sample interval per request, incl. resampling and inserted audio | §8.2 |
| R5.4 | Specify feature mapping: array length, frame duration, temporal origin, gaps, alignment uncertainty — and note that `frameDuration` + values do **not** establish origin | §8.4, including the undetectable-internal-gap limitation stated as a hard cap on alignment certainty |
| R5.5 | Verify alignment with controlled leading-silence/offset variants; never infer from word timestamps, callback arrival, or the offset that maximizes agreement | §8.5 — the leading-silence ladder (0/5/10/20 s) with a pre-registered prediction and three named banned inference sources |
| R5.6 | If alignment cannot be established: B5 and frame-wise comparison are unavailable; report descriptive array statistics | §8.5 outcome O-B2, and M5 |
| R5.7 | Define B5 per feature as `duration(V ∩ Bₖ)/duration(V)`; overlaps once; exclude unanchored; report numerator/denominator/uncertainty/A-voicing coverage; zero denominator ⇒ `nil`; established absence with positive denominator ⇒ legitimate zero | §8.7, verbatim adoption |
| R5.8 | M5 must allow "unmeasurable because alignment is unresolved" | §9, M5 outcomes O-B1/O-B2/O-B3 |

### Q6 — measurement and acceptance definitions

| # | Review point | Change |
|---|---|---|
| R6.1 | **Largest defect:** unvoiced ≠ pause. A9/A11/A13 are wrong as written | §3.1 replaced with a four-state frame classification (`voiced` / `activeAperiodic` / `inactive` / `unknown`). A9 is now **silence-gap candidates**, A11 is **active-audio time** (phonation is a narrower, voiced-only quantity now reported separately), A13's denominator is active-audio time and the metric is renamed |
| R6.2 | M1 conflates VAD and voicing; a noise burst must not be a periodic-voicing positive control | §9 M1 splits activity tests from periodicity tests; a level-matched noise burst is now a **negative** control for voicing and a **positive** control for activity |
| R6.3 | Low level ≠ low SNR; validate the 10th-percentile floor on known mixtures and changing backgrounds; rename A4 | A4 is now `levelAboveFloorProxy` (dB), explicitly not SNR; M1 gains a floor-estimator validation case (known mixtures, mid-file floor steps, mic-mute-like digital silence); §12's non-failure outcome no longer concludes "SNR-limited" from amplitude |
| R6.4 | A8: don't import the correction factor; label outputs detected-nucleus/estimated-syllable rate; the original study *did* cover spontaneous speech; our adaptation needs its own checks | §3.2 and §4.3 corrected — including the R1 mis-framing about read speech. No correction factor. Outputs renamed |
| R6.5 | Coverage must be metric-specific: domain coverage, eligible-frame coverage, estimation success among eligible; absolute contributing seconds; unknown ≠ silence; overlapping frames must not multiply elapsed time | §5.2's coverage model rebuilt with four separate quantities, hop-slot accounting so overlapping analysis frames cannot multiply elapsed time, and `unknownSeconds` as its own term |
| R6.6 | Specify full estimator support: centers, rounding, edges, filter context, smoothing, guards, state reset at joins, span-scoped floor/baseline; add boundary/missing-fundamental/abrupt-change/periodic-confound tests; report rejection and octave-error rates alongside accuracy | New §4.1–§4.3, and M1 expanded |
| R6.7 | M2 cannot both require every metric valid everywhere and allow an SNR-limited success | §9 M2 defines **O-A1 full demonstration** and **O-A2 evidence-supported limitation**, with the evidence O-A2 must carry to count as a pass |
| R6.8 | Verify rule firing with a controlled positive case; don't require a real fixture to fire an uncalibrated rule; no threshold tuning | Adopted, reinforced by director ruling (d). §9 M2 |
| R6.9 | A synthetic splice isn't a negative recording; require abstention across the join while allowing valid observations in safe spans; add a seamless-splice control | §9 M3 splits negative controls from join controls and adds the seamless case |
| R6.10 | A skipped session test cannot satisfy exit evidence | §12 exit criterion 2, aligned with director ruling (c): `OBSERVATORY_U4A_SESSION_BACKUP_DIR` **will be set** for exit runs; skip-not-fail remains only for other machines |
| R6.11 | 5 s windows and plausibility bands are preregistered exploratory settings, not validation; define minimum usable duration and boundary-event counting | §3.2 and §9 M2 — labelled exploratory; `minimumUsableWindowSeconds` added; boundary-event counting rule (half-open intervals, event assigned by nucleus time, boundary-straddling pauses clipped and flagged) specified |
| R6.12 | Schema: non-finite `log10(0)` without inventing a floor; finite values required; explicit nulls; bounded counts; legitimate-zero tests; quality flags alongside one primary validity reason; `.valid` = passes prototype gates | §5.1 and §5.3 rewritten |
| R6.13 | Remove the unexplained A5 "confidence 0–1" | Removed. The periodicity peak-strength value is reported as a named diagnostic series, not as a confidence |
| R6.14 | `.reducedArticulationUnsupported` belongs in a capability/status record, not the observation stream | Moved to a `CapabilityStatus` record in the report header |
| R6.15 | Record speaker mixture honestly, not as insufficient baseline; a global semitone reference isn't mathematically required for within-window spread | §5.4: new `multiSpeakerMixture` status (its own reason, not `insufficientBaseline`); within-window F0 spread is now computed window-locally and is available on multi-speaker sources, while span-median-referenced A7 is not |
| R6.16 | Determinism only for a pinned environment + canonical payload; record environment differences separately | §12 criterion 5 rewritten; cross-architecture bit-identity explicitly not claimed |
| R6.17 | String fields are not structurally leak-proof: constrained fields, sanitized errors, explicit checks | §5.5: closed enums, an identifier charset/length constraint, error reasons as enum codes (never raw `localizedDescription`), and a scanning test |
| R6.18 | `SpeechDetector` accepted as a reported local SDK finding; need not expand U4a | Q6 is **void** per director ruling (a) and is deleted, not deferred. No cross-check from that family is proposed |

### Director rulings applied

(a) Q6 deleted, not resurrected. (b) Q5a (pbxproj resource) and Q5b (backup-dir env var) are approved and now appear as settled items in §10, not questions. (c) exit runs set the env var; §12 requires executed session tests. (d) behavioral milestone unchanged in spirit — real measurements from real recordings; non-firing of uncalibrated rules on real fixtures is an honest finding; no post-hoc threshold changes; firing machinery verified by controlled positive case. (e) this revision goes to director verification.

### Where I push back or qualify

- **[partial] R6.3, on what "validate the floor estimator" can mean here.** I adopt the validation cases in full. But I want it on record that a synthetic known-mixture test validates the floor estimator *against synthetic mixtures only*. On real reflection audio there is no independent measurement of the true noise floor, so the floor estimate on fixtures remains an unverified estimate no matter how the synthetic cases come out. §4.2 says so, and the report carries `noiseFloorUnverifiedOnRealAudio` on every real-source measurement that depends on it. I would rather name that permanent limit than let synthetic passes imply real-audio validity.
- **[partial] R6.16, on determinism.** I adopt pinned-environment scoping. I am *not* weakening the within-environment requirement: on one machine, same OS/SDK/arch/build, the canonical payload must be byte-identical across runs. That is cheap to enforce and catches real defects (map iteration order, uninitialized padding, time leaking into results). Only the cross-environment claim is dropped.
- **[scope note, for the director, not a disagreement]** The review's requirements roughly double Channel B's work — the alignment ladder is a designed experiment with its own controls and its own device time, on top of the coverage arm. §13 asks the director whether U4a should split into **U4a-1 (Channel A, simulator)** and **U4a-2 (Channel B, device)** as two units under D-14's one-unit-one-thread rule. I have written the proposal so either answer works; the default if the director says nothing is to keep it as one unit.

---

## 1. What this unit has to answer

PLAN.md's one-liner commits the product to being a **measurement-grade instrument for aural behavior**, built to SaMD quality. Every unit so far pursued *transcripts*, and every unit found that path defective: E8 (recognizer-side result replacement, 9–19% word recovery from finals), U6/U6b (capture-lifecycle outages). One fact survived all of it:

> **The audio survives when the transcript does not.** The U6b session (`9D4F101A…`) persisted 54 words of ~3 minutes of speech over 149.4 s of real speech-level audio. The Oct-22 incident session (`A6699F43…`) persisted **4 words** over 156.6 s of audio, 110+ s of which Hermes's energy forensics found contains speech-level energy.

U4a starts measuring the channel that survived:

> **Can we produce honest, unit-bearing, validity-scoped acoustic measurements directly from recordings already on disk — with no dependency on transcript content or diarization — and show real measurements from real recordings as an artifact rather than a claim?**

It does not answer whether those measurements mean anything about emotion or state (Stage 2), does not touch attribution (U3) or the recognizer (U5), and ships nothing into the app.

---

## 2. Two channels, and what is and isn't claimed about them

`SFVoiceAnalytics` is reachable only through recognition results — in the installed SDK via `SFSpeechRecognitionResult.speechRecognitionMetadata.voiceAnalytics` (result level, iOS 14+), with `SFTranscriptionSegment.voiceAnalytics` deprecated ("moved to SFSpeechRecognitionMetadata"), and documented as available when the system sends `isFinal`. There is therefore **no transcript-free path to it**, which is U4a's defining constraint.

| Channel | Source | Transcript dependency | Runs on | Status |
|---|---|---|---|---|
| **A (primary)** | DSP directly on the saved `.caf` via `AVAudioFile` + Accelerate; never opens a recognizer | None | **Simulator** and device | **Experimental estimator undergoing verification.** Not validated. M1/M4 are checks whose outcomes are unknown |
| **B (secondary)** | Result-level `SFVoiceAnalytics` through a replay recognition pass | Requires recognition | Device only | Two questions, both open: *can its frame arrays be anchored to file time at all*, and *if so, how much A-detected voiced audio do they cover* |

**Withdrawn from Revision 1 (R1.2):** the claim that Channel B's coverage is bounded by E8's word-recovery percentage. E8 established a recognition-**output** defect. Whether result-level acoustic arrays cover a similar proportion of audio is **not established by it** and is exactly what M5 measures.

**Deviation from the STABILIZATION plan**, stated plainly for the director's record: the plan says pitch comes from `SFVoiceAnalytics` and forbids a separate pitch tracker "unless that API proves insufficient at implementation time… not silently worked around with an unvalidated DIY detector." The insufficiency is structural (above) and director-verified against the SDK. What Revision 2 no longer claims is that M1/M4 make the estimator *validated*. They are a **verification plan**: synthetic accuracy plus selected invariances, which if passed establish exactly that and nothing about reliable F0, nucleus counts, or behavioral measurement on spontaneous speech. The plan's "unvalidated" objection is answered by making the estimator's limits measured and published, not by asserting it is validated.

Channel A running on the **simulator** (the fixtures are already test-bundle resources) means the entire primary measurement set needs **zero device approvals**.

---

## 3. The observation set (item a)

### 3.1 Frame classification — speech activity, periodic voicing, and silence are three different things

Revision 1's single `voicing` decision conflated them and made pause/phonation/articulation-rate definitions wrong (R6.1). Replaced by two independent detectors over a shared frame grid (§4.1), producing a four-state classification:

| Detector | Basis | Output |
|---|---|---|
| **Activity** | `levelAboveFloorProxy` (A4) with two-threshold hysteresis and a minimum run length | `active` / `inactive` |
| **Periodicity** | NCCF peak strength over the configured search range | `periodic` / `aperiodic` / `periodicityOutOfRange` (rail hit, R2.3) |

| Frame state | Definition | What it is **not** |
|---|---|---|
| `voiced` | `active ∧ periodic` | not "speech" — unvoiced speech is excluded by construction |
| `activeAperiodic` | `active ∧ ¬periodic` | **not a pause.** Could be unvoiced speech (fricatives, stops, whispering), could be noise. U4a cannot distinguish these and does not claim to |
| `inactive` | `¬active` | **not established silence from this speaker** — could be room tone, a breath below threshold, another person's distant speech, or an OS mic-mute span |
| `unknown` | Outside the analysis domain, inside a guard band, estimator failure, saturated, or filter-settling | **never counted as silence** (R6.5) |

Everything downstream is defined on these four states, and every reported quantity names which states it used.

### 3.2 Measurements

Frame geometry, rounding, and edge handling are specified in §4.1; estimator parameters are configuration data (§4.4).

**Frame level (10 ms hop slots):**

| # | Quantity | Unit | Frame | Notes |
|---|---|---|---|---|
| A1 | Short-time level | **dBFS** (20·log₁₀ RMS) | 25 ms | Zero-energy frames are non-finite — see §5.3, no invented floor |
| A2 | Clipping fraction | ratio 0–1 | 25 ms | \|sample\| ≥ 0.999 |
| A3 | Estimated noise floor | dBFS | **per analyzable span** | 10th percentile of A1 within the span. A heuristic whose error is measured on synthetics (M1) and **unverifiable on real audio** (§4.2) |
| A4 | **Level above estimated floor** (`levelAboveFloorProxy`) | dB | 25 ms | A1 − A3. **Explicitly not SNR** (R6.3): flat gain moves signal and floor together; the floor estimate may select mic-mute samples or speech energy depending on the recording |
| A5a | Activity state | enum | 25 ms | §3.1 |
| A5b | Periodicity state | enum | 40 ms | §3.1; peak-strength values are reported as a diagnostic series, **not** as a confidence (R6.13) |
| A6 | **F0** | **Hz** | 40 ms | NCCF + parabolic interpolation within the configured range; `nil` when not `voiced`, when rejected (R2.4), or at a rail (R2.3). Never 0 |
| A7 | F0 relative to span median | semitones | derived | Requires a span-scoped single-speaker baseline (§5.4) |
| A8 | **Detected nucleus events** | event list (time, peak dB) | envelope, 10 ms | Band-limited envelope peak picking with a dip threshold, minimum inter-nucleus interval, and a periodicity constraint. **Our adaptation of the De Jong–Wempe approach, not that method as published** — no correction factor is imported, and the published method's own reported misses (principally unstressed syllables) are not assumed to transfer to our implementation (R6.4) |

**Window level** — default **5 s / 1 s hop**, declared **preregistered exploratory settings, not validated geometry** (R6.11). Windows shorter than `minimumUsableWindowSeconds` after domain clipping are not emitted. Events are assigned to windows by their own time, on half-open intervals `[start, end)`; a silence-gap candidate straddling a window edge is clipped to the window and flagged `boundaryClipped`.

| # | Quantity | Unit | Definition | States used |
|---|---|---|---|---|
| A9 | **Silence-gap candidates** | s (start, end, duration) | Maximal `inactive` runs ≥ `minimumGapSeconds` containing **no** `unknown` frame; a run interrupted by `unknown` is reported as `indeterminateGap` instead | `inactive`, `unknown` |
| A10 | Silence-gap ratio | ratio | A9 total ÷ window classified duration | — |
| A11 | **Active-audio time** | s | Duration of `active` frames (`voiced` + `activeAperiodic`). Renamed from R1's "phonation time", which was wrong | `active` |
| A11b | Voiced time | s | Duration of `voiced` frames — the narrower quantity that *is* phonation-like | `voiced` |
| A12 | **Detected nucleus rate** | nuclei/s | A8 count ÷ window classified duration | all |
| A13 | **Estimated syllable rate per active second** | nuclei/s | A8 count ÷ A11. Reported under that name — never "articulation rate in syllables per second" without the estimated/detected qualifier (R6.4) | `active` |
| A14 | Window level | dBFS | Median A1 over `active` frames | `active` |
| A15 | Level variability | dB | IQR of A1 over `active` frames | `active` |
| A16 | Window F0 median | Hz | Median A6 over `voiced` frames | `voiced` |
| A17 | **Within-window F0 spread** | semitones | `12·log₂(p95 ÷ p05)` of A6 **within the window** — a ratio, needing **no global reference** (R6.15), so it is available on multi-speaker sources | `voiced` |
| A18 | Deltas vs span baseline | dB / semitones / nuclei·s⁻¹ | A14, A16, A12, A13 minus their span baseline (§5.4) | — |

### 3.3 What the prototype may emit

Test-local mirrors of the Stage 1 kinds the STABILIZATION plan reserves: `.pitchContourShift`, `.intensityShift`, `.acceleratedDeliveryCandidate`.

`.reducedArticulationUnsupported` is **not an observation** (R6.14) — it moves to a `CapabilityStatus` record in the report header, alongside every other "we cannot measure this" statement, so the observation stream contains only things that were measured.

`.prolongedSoundCandidate` stays excluded: the plan defines it via syllable counts from recognized text, which is transcript-dependent by construction.

**No observation carries an emotional or state label, a probability, or a severity.**

---

## 4. Estimator specification and configuration

### 4.1 Frame geometry — exact, integer, and shared only in hop

At 48 kHz: hop = **480 samples** (10 ms), A1/A5a frame = **1200 samples** (25 ms), A6/A5b frame = **1920 samples** (40 ms). All integer; no floating accumulation of frame positions (index × hop, computed in samples).

- **Centers.** Frame *i* of any length is centered at sample `spanStartSample + i·hop + hop/2`. Different frame lengths therefore **share centers, not extents** — this is what makes 25 ms and 40 ms measurements co-locatable, and the review is right that a shared hop alone does not (R6.6). Every measurement records its own frame length in `AnalysisWindow`.
- **Edges.** A frame is computed only if its **entire extent** lies inside the analyzable span. No zero-padding, no reflection, no partial-frame compensation. This yields an automatic guard of `frameLength/2` at every span edge — including both sides of every join.
- **Filter context.** The A8 band-pass runs per span with state reset at span start; the first `filterSettlingMs` of each span is `unknown`, not measured.
- **Smoothing.** Median smoothing never crosses a span boundary; frames with incomplete smoothing support at a span edge are `unknown`.
- **State reset at joins (R6.6).** Hysteresis state, filter state, smoothing history, noise floor (A3), and baselines (§5.4) are **all span-scoped**. Nothing carries across a join or an unresolved region.

### 4.2 The noise-floor estimator is itself a measured component

A3 is a 10th-percentile heuristic. M1 validates it against synthetic mixtures with a known floor, mid-file floor steps, and mic-mute-like digital-silence regions, reporting the error in dB per case. **On real audio there is no independent floor measurement**, so every real-source measurement depending on A3 carries the quality flag `noiseFloorUnverifiedOnRealAudio`. Synthetic passes do not transfer to the fixtures, and the report says so next to the numbers.

### 4.3 F0 estimator behaviour at its limits

| Situation | Behaviour | Reported as |
|---|---|---|
| Periodicity peak at the low or high rail of the search range | F0 `nil`, frame state `periodicityOutOfRange` — **never `unvoiced`** (R2.3) | `searchRangeRail(.low/.high)` count per span |
| Candidate rejected by the octave-jump limit | F0 `nil`; **no substituted value** (R2.4); raw candidate retained in the diagnostic series | `octaveJumpRejected` count and rate per span |
| Missing fundamental (energy only at harmonics) | Whatever the NCCF does — measured, not assumed, by an M1 case | accuracy + rejection rates for that case |
| Periodic non-speech (hum, tone, music) | Will likely be called `voiced`. U4a **cannot** exclude it | `periodicNonSpeechPossible` is a known limitation in `CapabilityStatus` |

Rejection rate and octave-error rate are reported **alongside** accuracy in every M1 result, so abstention cannot hide a failing estimator (R6.6).

### 4.4 Estimator configuration is versioned data, not code (R2.1/R2.2)

A second JSON file, **separate in both file and schema from the observation-selection rules** (§7), because these parameters determine *which voices and behaviors become measurable* rather than *which measurements get reported as observations*:

```jsonc
// U4aEstimatorConfig.json
{
  "configID": "u4a.estimator.default",
  "configVersion": "0.1.0",
  "frameGeometry":  { "hopMs": 10, "levelFrameMs": 25, "pitchFrameMs": 40 },
  "noiseFloor":     { "method": "percentile", "percentile": 10, "minSpanSecondsForFloor": 3.0 },
  "activity":       { "onsetAboveFloorDb": 8.0, "offsetAboveFloorDb": 5.0, "minActiveRunMs": 50, "minInactiveRunMs": 100 },
  "periodicity":    { "searchMinHz": 60, "searchMaxHz": 400, "peakStrengthFloor": 0.45,
                      "diagnosticWidenedRange": { "minHz": 40, "maxHz": 600, "enabled": true } },
  "f0Smoothing":    { "medianWidthFrames": 3, "maxOctaveJumpSemitonesPerFrame": 9.0 },
  "nuclei":         { "bandLowHz": 70, "bandHighHz": 4000, "dipDb": 2.0,
                      "minInterNucleusMs": 100, "filterSettlingMs": 30, "requirePeriodicFrame": true },
  "joins":          { "guardSeconds": 1.0 },
  "windows":        { "windowSeconds": 5.0, "hopSeconds": 1.0, "minimumUsableWindowSeconds": 2.0 }
}
```

The config's **full inline values and its SHA-256** are recorded in every report's manifest. Only the NCCF implementation itself, the parabolic interpolation, and the percentile/IQR arithmetic remain in code, versioned by `estimatorVersion`.

---

## 5. Measurement semantics (item b)

### 5.1 A measurement is a record

```swift
struct AcousticMeasurement: Codable {
    let metric: MetricID            // closed enum, e.g. .f0WindowMedian
    let value: Double?              // nil == unavailable, never 0-as-unknown (D-07); always finite when present
    let unit: Unit                  // closed enum: .dBFS, .dB, .hertz, .semitones, .nucleiPerSecond,
                                    //              .seconds, .ratio, .count, .rawUnspecifiedLog
    let window: AnalysisWindow      // spanID, start, end (file-relative s), frameSamples, hopSamples
    let estimator: EstimatorID      // closed enum
    let estimatorVersion: String
    let configID: String            // §4.4
    let configSHA256: String
    let coverage: Coverage          // §5.2
    let status: MeasurementStatus   // §5.3
    let baseline: BaselineRef?
    let provenanceID: ProvenanceID
}
```

### 5.2 Coverage is metric-specific (R6.5)

One ratio cannot describe both "how much of the window exists" and "how much of it this metric could use." Four quantities, all reported:

```swift
struct Coverage: Codable {
    let nominalWindowSeconds: Double
    let domainSeconds: Double        // window ∩ analysis domain, after guards
    let unknownSeconds: Double       // NEVER folded into silence or into domain
    let eligibleSeconds: Double      // frames meeting THIS metric's eligibility predicate
    let estimatedSeconds: Double     // eligible frames where the estimator returned a finite value
    let eligibleFrames: Int
    let estimatedFrames: Int
    var domainFraction: Double       { domainSeconds / nominalWindowSeconds }
    var eligibleFraction: Double     { eligibleSeconds / max(domainSeconds, ε) }
    var estimationSuccess: Double    { estimatedSeconds / max(eligibleSeconds, ε) }
}
```

- **Eligibility is per metric**: F0 metrics → `voiced` frames; level metrics → `active` frames; gap metrics → all classified frames. A window full of legitimate pauses is therefore no longer rejected for "low coverage" the way Revision 1's single 80% rule would have rejected it.
- **Elapsed-time accounting uses hop slots** (10 ms each, non-overlapping), never frame extents, so overlapping 25/40 ms analysis frames cannot multiply elapsed-time coverage.
- Rule gates (§7) name *which* of these they test.

### 5.3 Status: one primary reason, plus non-exclusive quality flags (R6.12)

```swift
struct MeasurementStatus: Codable {
    let primary: PrimaryStatus
    let flags: [QualityFlag]       // non-exclusive, may accompany .valid
}

enum PrimaryStatus: Codable {
    /// "Passes this prototype's operational gates" — NOT clinically or perceptually validated.
    case valid
    case unavailable(UnavailableReason)
}

enum UnavailableReason: Codable {
    case noAudio, outsideAnalysisDomain, insideUnresolvedRegion, insideJoinGuard
    case insufficientEligibleSeconds(eligible: Double, required: Double)
    case lowEstimationSuccess(success: Double, required: Double)
    case nonFiniteInput(NonFiniteCause)     // e.g. .zeroEnergyFrame → log10(0)
    case saturated(clippedFraction: Double)
    case insufficientBaseline(observedSeconds: Double, required: Double)
    case multiSpeakerMixture                 // its own reason, NOT disguised as insufficient baseline (R6.15)
    case alignmentUnresolved                 // Channel B
    case estimatorFailed(EstimatorFailureCode)   // enum code, never a raw error string (R6.17)
}

enum QualityFlag: Codable {
    case clippingPresent, nearJoinGuard, filterSettling
    case octaveJumpRejectionsPresent, searchRangeRailHits
    case noiseFloorUnverifiedOnRealAudio, noiseFloorStepDetected
    case completenessUnknown, multiSpeakerSource, boundaryClipped
    case sparseEligibility, periodicNonSpeechPossible
}
```

Hard schema rules, test-enforced:

1. `value != nil ⟺ primary == .valid`.
2. **Every encoded number is finite.** `log10(0)` from a digital-silence frame never becomes a magic floor like −120 dBFS and never becomes `0`; the frame's value is `nil` with `.nonFiniteInput(.zeroEnergyFrame)`. A JSON scan rejects `NaN`/`Infinity`/non-numeric literals anywhere.
3. **Explicit nulls.** `value: null` is emitted; keys are never omitted (an omitted key invites a consumer default).
4. **Legitimate zeros are representable and tested**: zero detected nuclei in a window, `coverage = 0.0`, `0 dB` delta, and B5 `= 0.0` are all real values that must encode as `0`, with `.valid`, and are covered by their own tests so rule 1 is not implemented as "nil out anything zero."
5. Counts are bounded and non-negative; `estimatedFrames ≤ eligibleFrames`.

### 5.4 Baselines, and the multi-speaker case

Span-scoped, within-session only. A baseline needs `minimumBaselineVoicedSeconds` of `voiced` frames **inside the same analyzable span**; otherwise `.insufficientBaseline`.

For `fixture-multi-a`/`-b` there is no diarization, so a span baseline mixes speakers. That is recorded as **`.multiSpeakerMixture`** — its own reason with `multiSpeakerSource` flagged on every measurement from that source (R6.15), never disguised as insufficient duration. Span-median-referenced A7/A18-pitch are withheld on those sources; **A17 (within-window spread) is still reported**, because a ratio inside one window needs no global reference.

### 5.5 Provenance, and structural protection against text leakage (R6.17)

```swift
struct CaptureProvenance: Codable {
    let sourceID: SourceID           // closed enum of known fixtures + an opaque session UUID
    let fileSHA256: String           // 64 hex chars, pattern-checked
    let sampleRate: Double
    let channelCount: Int
    let sampleFormat: SampleFormat   // closed enum
    let fileDurationSeconds: Double  // AVAudioFile.length ÷ sampleRate — frame count, never file bytes (R3.10)
    let captureConfiguration: CaptureConfiguration  // .measurementModeConfirmed | .unverifiedPreTuning | .unknown
    let postProcessing: PostProcessing              // .none | .identityReencode | .flatGain(db:) | .loudnorm
    let completeness: CompletenessRecord            // §6.1
}
```

- **Amplitude-domain metrics are refused on `-loudnorm`/`-gain` variants** except inside the M4 invariance control.
- **Intensity is dBFS, never loudness or SPL.** No calibrated microphone exists in this project.
- Leak protection is not left to discipline: all string-typed report fields are either closed enums, fixed-pattern identifiers (`^[A-Za-z0-9._:-]{1,64}$`), or the rules file's own authored `rationale` text. Error reasons are **enum codes**, never interpolated `localizedDescription`. Channel B never reads `formattedString` or segment substrings. A test scans every encoded string against the allowed set/pattern and fails on anything else.

---

## 6. Analysis domain, joins, and what the evidence can actually establish

### 6.1 Completeness is provenance, not a conclusion (R3.1/R3.7)

```swift
struct CompletenessRecord: Codable {
    let recorded: RecordedCompleteness   // .complete | .incomplete(endpointAudioSeconds: Double?) | .unknownLegacy
    let pattern: DiscontinuityPattern    // .none | .truncatedTail | .truncatedHead
                                         // | .internalJoin | .multipleJoins | .unknownPattern
    let patternEvidence: [EvidenceItem]  // each source kept separate, never fused into one number
}
```

- `.incomplete` **does not mean spliced.** It is consistent with a truncated tail, a truncated head, one internal join, several, or something unobserved. `pattern` defaults to `.unknownPattern` and is only narrowed by named evidence. For U6b, the *reported recovery* is what argues for an internal join in that recording — the enum never argues for it.
- `.unknownLegacy` (`nil` in the record) is **unknown provenance, not confirmed complete** (R3.7): the source is analyzed, every measurement carries `completenessUnknown`, and join-sensitive measurements get the same guard treatment as an unresolved region.

### 6.2 The U6b worked example, corrected

| Fact | Value | Source |
|---|---|---|
| `startedAt` → `endedAt` | 18:56:06Z → 18:59:08Z = **182 s** wall | session JSON |
| Audio duration | `AVAudioFile.length ÷ 48000` ≈ **149.4 s** | the file itself (R3.10 — R1 divided *file* bytes by 4·48000, ~0.02 s long because of the CAF header) |
| `captureCompleteness` | `.incomplete(endpointAudioSeconds: 149.4)` | session JSON |
| `recognitionContinuityGaps` | T+46 s, T+48 s, T+65 s | session JSON |
| `audioRecordingReliable` / `missingAudioIntervals` | `true` / `[]` | session JSON — no write ever failed |

**Withdrawn (R3.2):** Revision 1 claimed two independent arithmetics agreeing to 0.2 s. They are the same equation. With `resume = 65 s` assumed: `preOutage = 149.4 − (182 − 65) = 32.4 s`, and `missing = 182 − 149.4 = 32.6 s` is that identity rearranged. Agreement here is algebra, not corroboration.

**Assumption chain, each link uncertain (R3.3):**

1. The successful **recognition** restart at T+65 s is not the **capture** resumption time. Capture resumption is whenever the engine/tap/writer actually resumed, which the record does not contain; the recognition timestamp is at best a weak upper-bound witness.
2. Capture is assumed to have run continuously from resumption to `endedAt`. Not established.
3. `endedAt` is assumed to be when the last frame was written. Not established.

Under those assumptions the join lies near file offset ≈32 s, and PLAN.md's record of post-recovery words at file-time 54.1/54.5 s is inconsistent with it — but those timestamps come from the recognizer, which the U6b run itself showed producing backward-stepping offsets. **Two unreliable sources disagree; neither is promoted.** The honest statement is that the join's location is bounded only weakly, and §6.4 says what to do about that.

**Also withdrawn (R3.5):** Revision 1's claim that a splice "erases a 32.6 s pause that really happened." The missing wall time is **unobserved behavior**. Nothing is known about what the person did in it.

### 6.3 Two evidence sources, both candidate-grade (R3.4)

| Source | Produces | False positives | False negatives |
|---|---|---|---|
| **Lifecycle** | An interval from the session record under §6.2's assumptions | Wrong if any assumption fails | Silent about joins the record never captured |
| **Signal** | Near-digital-silence runs (Hermes measured −87 to −90 dBFS for mic-mute spans vs −42 to −56 dBFS speech in these recordings) and noise-floor steps | Genuine near-silence and genuine background changes occur **without** a splice | A splice can be **seamless** — same room, same gain, no detectable signature |

Both are reported separately, with their own intervals and their own confidences. Neither is ever fused into a single "the splice is here."

### 6.4 Disagreement policy (R3.6) — the decision table

Let **L** be the lifecycle interval (if any) and **S** the set of signal-candidate intervals (if any).

| Case | Unresolved region | Consequence |
|---|---|---|
| Both present, overlapping | `L ∪ S`, plus `joins.guardSeconds` either side | Domain splits around it; spans either side are analyzable |
| Both present, **disjoint** | `L ∪ S` — **both**, each guarded. No tie-break, no preference, no midpoint | Possibly three spans; all of them may be short, and that is an acceptable outcome |
| Only one present | That one, guarded | As above |
| Neither present, but completeness is `.incomplete` or `.unknownLegacy` | **The whole file** | Every join-sensitive measurement (A9, A10, A12, A13, A18, all cross-window trends) is `.insideUnresolvedRegion`. Frame-local measurements (A1, A6, A16, A17 within a window) may still be reported, each flagged |
| `.complete` with no write losses | None | Single span |

Three rules that are not negotiable within this unit:

- **Abstention beats fabrication even when little audio remains.** If the policy leaves a 20 s file with no analyzable temporal span, the report says so. It does not widen guards downward or pick the "more likely" join to recover coverage.
- **No safe spans are manufactured to satisfy M2.** M2's restructured outcomes (§9) make abstention a reportable success, which removes the incentive that would otherwise exist.
- **No wall-clock mapping** on anything but `.complete`-with-no-losses sources, and **no cross-span trend statements** ever.

### 6.5 `missingAudioIntervals` — coordinate system established (R3.8)

Established by reading the writer rather than assuming, as the review required. In `SpeechRecognitionManager.AudioFileWriter.recordLoss` (lines 432–439):

```swift
let start = audioSecondsLocked(for: writtenFrames)
let end   = audioSecondsLocked(for: writtenFrames + frameCount)
missingAudioIntervals.append(AudioInterval(start: start, end: end))
```

`audioSecondsLocked` converts **written-frame counts** to seconds. So `start` is a genuine file-relative offset: the point just after the last successfully written frame. But the lost frames were **never written**, so `end` is *not* a file coordinate — nothing in the file occupies `[start, end)`. Everything after `start` is later audio sitting earlier than it otherwise would.

**Consequence: Revision 1's "subtract `missingAudioIntervals` from the file timeline" was wrong.** A write loss is **another join** — at a known file offset `start`, with a known missing duration `end − start`. Correct handling:

- Treat each interval as `DiscontinuityPattern.internalJoin` at `start`, with `missingSeconds` known (a rare case where it *is* known).
- Apply the standard guard around `start`; **never remove `[start, end)` from the file**, which would delete real audio.
- Until a test confirms this reading against a constructed loss case, **any source with a non-empty `missingAudioIntervals` is excluded from U4a analysis entirely.** All sources this unit uses have empty intervals, so nothing is lost by the conservative rule.

### 6.6 Recommendation for U4 (production) — record discontinuities prospectively (R3.9)

Reconstructing a join after the fact is what §6.2 shows to be unreliable. At recovery time the information actually exists. Recommended for U4, not built here:

```swift
struct CaptureDiscontinuityEvent: Codable {   // ReflectionSession carries [CaptureDiscontinuityEvent]
    let writerSampleOffset: Int64        // writer-owned, authoritative: frames written when capture ceased
    let sampleRateAtOffset: Double
    let lastCaptureTime: UInt64          // monotonic clock before the gap
    let firstCaptureTimeAfter: UInt64?   // monotonic clock after resumption; nil if never resumed
    let clockID: ClockIdentity           // which clock these are on — comparisons across clocks are invalid
    let reason: DiscontinuityReason      // .interruptionBegan | .engineRestart | .writeLoss | .unknown
    let uncertaintySeconds: Double?      // nil when exact (write loss), set when bounded
}
```

Multiple events per session must be supported — U6b produced a failed restart, a fast retry, and a successful retry in one session. A recognizer callback timestamp is **not** acceptable as the offset source. **Sequencing condition:** production use of join-sensitive measurements should wait until this record exists, rather than shipping reconstruction-based scoping.

---

## 7. Observation-selection rules as SignalLibrary data (item c)

Distinct from §4.4's estimator configuration: these decide **which measurements are reported as observations**, and they are the D-16 thresholds.

```jsonc
// U4aAcousticRules.json — shaped as a SignalLibrary so U4 can import it as data
{
  "id": "observatory.voice.acoustic.prototype",
  "version": "0.1.0",
  "domain": "Voice",
  "authorType": "Observatory",
  "calibrationStatus": "uncalibrated-prototype",
  "rules": [{
    "id": "u4a.intensityShift.rise",
    "matchType": "numericThreshold",
    "eventKind": "intensityShift",
    "eventCategory": "Voice",
    "confidence": "low",
    "numeric": {
      "metric": "level.windowMedian.deltaFromSpanBaseline",
      "unit": "dB", "comparison": "greaterThanOrEqual", "threshold": 6.0,
      "gates": {                      // names the specific coverage quantities (§5.2)
        "minDomainFraction": 0.9,
        "minEligibleSeconds": 1.5,
        "minEstimationSuccess": 0.7,
        "minBaselineVoicedSeconds": 20.0,
        "requireNoFlags": ["clippingPresent", "insideUnresolvedRegion"]
      },
      "rationale": "6 dB ≈ a doubling of amplitude; a deliberately large, round, UNCALIBRATED default — not validated against perception or any reference annotation."
    }
  }]
}
```

Also rule data (today hardcoded in `SilenceTracker`, `SpeechRecognitionManager.swift:223/234`): the silence threshold — re-expressed as dB above the estimated floor rather than absolute RMS 0.02 — `minimumGapSeconds` (today 1.5 s) and the resume debounce (0.3 s).

**Migration to production (U4):** additive `SignalRuleMatchType.numericThreshold`; additive optional `SignalDetectionRule.numeric` (existing persisted libraries decode unchanged); a sibling `AcousticRuleEvaluator` over `[AcousticMeasurement]` rather than contorting the text matcher; the JSON enters via `SignalLibraryRegistry.importJSON` as data.

---

## 8. Channel B specification (Q5)

### 8.1 Access path (R5.1)

**Primary:** `SFSpeechRecognitionResult.speechRecognitionMetadata?.voiceAnalytics` — result level, one `SFVoiceAnalytics` per result.
**Optional compatibility diagnostic:** the deprecated `SFTranscriptionSegment.voiceAnalytics`, collected under a separate report key, reported separately, **never merged** with the primary path and never used for B5.

### 8.2 Input mapping (R5.3)

Per request, recorded before any result arrives:

`requestID`, `sourceID`, **exact fed source sample range** `[startSample, endSample)` in source-file coordinates, source sample rate, the format actually submitted and whether resampling occurred (with the ratio), every inserted silence region (offset + duration, as its own interval, excluded from source-mapped coverage), and feed order. **Chunk identity = (sourceID, requestIndex, fedSampleRange).**

### 8.3 Result handling (R5.2)

- **Coverage counts finals only.** Partials are logged with `(callbackIndex, isFinal)` for audit but never contribute; their analytics may be revised.
- **Revisions:** the last final per `requestID` wins; superseded finals are counted and reported.
- **Deduplication:** coverage accumulates as a **union of intervals** in source-file coordinates. Overlapping chunk boundaries are counted once. Durations are never summed.
- **Failures:** a request that errors (including `kAFAssistantErrorDomain 1110`) contributes **no** coverage and is recorded as `chunkOutcome: .failed(code)`. Because the audio was still fed, B5 is reported **twice** — over the whole eligible domain, and over only successfully-processed fed intervals — both labelled, so a failure cannot masquerade as low coverage or be hidden by excluding it.

### 8.4 Feature mapping (R5.4)

Per feature *k* per result: `acousticFeatureValuePerFrame.count`, `frameDuration`, derived nominal span `count × frameDuration`, and value statistics.

**`frameDuration` and the values do not establish the array's origin in the source file.** Candidate anchors, enumerated rather than assumed:

| Anchor | Hypothesis | Status |
|---|---|---|
| **(a)** | Origin = start of the fed interval | The hypothesis §8.5 tests |
| **(b)** | Origin = result/segment timing (`speechStartTimestamp`, segment timestamps) | **Disallowed as a primary source** — recognizer timing is demonstrably unreliable here (E8; U6b backward steps). Recorded as a diagnostic only |
| **(c)** | Origin unknown or arrays non-contiguous | The outcome if (a) fails |

**Hard limitation, stated rather than discovered later:** an internal gap inside a feature array is undetectable from the array alone. Even a successful alignment test therefore bounds alignment certainty to "consistent with contiguity," never "contiguous."

### 8.5 Alignment verification (R5.5) — a designed experiment with a pre-registered prediction

Controlled inputs where the answer is known by construction, built with the harness's existing silence-padding machinery (the E9 passage-position precedent): one audible passage, fed with leading silence of **0 / 5 / 10 / 20 s**, held otherwise identical.

**Pre-registered prediction under anchor (a):** the voiced region within each feature array shifts by exactly the inserted leading silence (within one `frameDuration`), and `count × frameDuration` tracks the fed duration.

| Outcome | Condition | Consequence |
|---|---|---|
| **O-B1 — alignment supported** | Offset tracks inserted silence across all four variants within one `frameDuration`, and array duration tracks fed duration | Anchor (a) is adopted **for this device/OS/SDK/configuration only**, with the measured residual carried as `alignmentUncertaintySeconds` on every Channel-B measurement |
| **O-B2 — alignment unresolved** | Offsets do not track, or arrays are shorter than fed audio with unknown placement | **B5 and all frame-wise A/B comparison are `.alignmentUnresolved`** (R5.6). The report carries descriptive statistics only: array counts, `frameDuration`, value distributions, finite/non-finite fractions, exact-zero fractions per feature |

**Banned as alignment evidence:** word timestamps; callback arrival time; whichever offset maximizes A/B agreement. Writing them down here is what keeps them out later.

### 8.6 Pitch units (Q4 / R4.1, R4.2)

`SFVoiceAnalytics.pitch` is documented as "expressed as a logarithm" with unspecified base and reference. It is reported in **raw units** (`.rawUnspecifiedLog`) with its documented description and access path, and is never converted to Hz.

If alignment reaches O-B1, the A6↔B2 relationship is fitted **only on independently aligned `voiced` frames**, with: residuals, sample coverage, a held-out split (fit on two fixtures, test on the third), and an explicit statement that **Channel A's own error bounds what the comparison can establish.** A clean fit is an **empirical mapping for this API/device/OS/configuration** — never proof of Apple's unit definition.

### 8.7 B5 — coverage, defined per feature (R5.7)

Let **V** = union of Channel-A `voiced` intervals inside the eligible analysis domain; **Bₖ** = union of independently anchored, usable intervals for feature *k* (value present and finite; unanchored intervals excluded).

> **Coverageₖ = duration(V ∩ Bₖ) ÷ duration(V)**

Overlaps counted once. Reported with: numerator, denominator, `alignmentUncertaintySeconds`, and Channel-A voicing coverage alongside the ratio. `duration(V) == 0` ⇒ **`nil`**. Positive denominator with established zero overlap ⇒ **legitimate `0.0`**.

This is **coverage of A-detected voiced audio** — not independently known coverage of all human speech in the recording. The report states that next to every B5 value. Per-feature exact-zero fractions are reported separately, because a `0.0` in a feature array may encode "unvoiced" and the documentation does not say.

---

## 9. Acceptance: milestones with artifact evidence (item d)

**The artifact.** Every run emits `U4aMeasurementReport.json` via Swift Testing `Attachment.record(_:named:)`, extractable from the `.xcresult` bundle the way Hermes extracted E8's callback log. Contents: run manifest (device/OS/build/arch, estimator IDs + versions, **estimator config inline + SHA-256**, rules library id/version/`calibrationStatus`), `CapabilityStatus` (including `.reducedArticulationUnsupported`), per-source `CaptureProvenance`, the `AnalysisDomain` with every evidence item and unresolved region, every `AcousticMeasurement` with coverage and status, and every observation with the rule id that selected it. `[u4a]`-tagged summary lines are printed too, matching the `[E8]`/`[E10]` convention.

| ID | Milestone | Where | Outcome definition |
|---|---|---|---|
| **M1** | **Estimator checks against known answers.** (i) **Activity**: speech-like noise bursts and digital silence at known boundaries — boundaries within ±30 ms. (ii) **Periodicity**: level-matched noise must be `activeAperiodic`, **not** `voiced` — a noise burst is a *negative* control for voicing and a *positive* control for activity (R6.2). (iii) **F0**: tones and glottal-pulse-like stacks at 100/150/220/300 Hz; sweeps; **60 Hz and 400 Hz boundary cases**; **missing fundamental**; **abrupt legitimate pitch change**; **periodic non-speech**; at SNR 30/20/10/5 dB. (iv) **Level**: ±0.5 dB vs analytic RMS; known-dB steps. (v) **Nuclei**: known burst-train counts. (vi) **Noise floor**: known mixtures, mid-file floor steps, mic-mute-like silence | Simulator | Each case reports **accuracy together with rejection rate and octave-error rate** (R6.6), so abstention cannot hide failure. Targets (F0 ±1% clean, level ±0.5 dB, boundaries ±30 ms, exact clean nucleus counts) are **pre-registered expectations**; a miss is reported and the estimator revised — tolerances are never widened to pass |
| **M2** | **Real measurements from real recordings — the behavioral milestone** (director ruling (d)). Full Channel-A pipeline over `fixture-solo`, `fixture-multi-a`, `fixture-multi-b`, session `9D4F101A…` (`.incomplete`, 149.4 s) and session `4B9A04FD…` (clean, 73.3 s) | Simulator | **Two acceptable outcomes, both requiring the artifact** (R6.7). **O-A1 full demonstration:** for at least `fixture-solo`, valid measurements of F0, level, silence-gap and nucleus-rate metrics with their coverage quantities reported, plus the preregistered exploratory bands (voiced fraction 0.30–0.85, median F0 70–300 Hz, nucleus rate 2–8 /s) **reported, not enforced** — an out-of-band value is a finding. **O-A2 evidence-supported limitation:** one or more metrics not obtainable, accompanied by the specific evidence — eligible seconds, estimation-success fraction, rejection and octave-error rates, level distribution relative to the estimated floor — and a statement of what would be needed. O-A2 **passes**. What fails: missing coverage reporting, silent absence, or numbers without their validity context. **Rule firing** is verified by a **controlled positive case** (a synthetic signal crossing a rule threshold by a known margin); real-fixture firing or non-firing is reported as-is, with **no post-hoc threshold changes** |
| **M3** | **Abstention, join behaviour, and schema invariants.** *Negative recordings:* digital silence; −50 dBFS white noise; the real 4096-byte header-only orphan `5FF28F05…`. *Join controls (not negative recordings — R6.9):* a synthetic splice with a known, signal-detectable join; a **seamless splice** (same source, same level, no detectable signature) | Simulator | Negative recordings: **zero** observations, explicit `.noAudio` / `.insufficientEligibleSeconds` / `.nonFiniteInput` statuses, no crash. Detectable splice: the join falls inside the reported unresolved region, windows overlapping it are unavailable, **and valid observations are still produced in the safe spans either side**. Seamless splice: demonstrates signal evidence returning **nothing**, so the unresolved region is whatever lifecycle evidence supports — or the whole file (§6.4) — which is the intended, documented behaviour. Schema scan: no non-finite number anywhere, no omitted value keys, no `.valid` with `null`, no `nil` with a `0` substitute, legitimate zeros present and correct |
| **M4** | **Invariance controls on existing assets.** base vs `-identity` vs `-gain` fixtures | Simulator | F0 medians agree within ±1% (F0 must be gain-invariant); level differs by the known applied gain (+12.0 / +15.2 / +18.7 dB, PLAN.md E10b) within ±0.5 dB. Pre-registered expectations; a miss is a reported finding about the estimator |
| **M5** | **Channel B: alignment first, coverage second.** Arm 1 = the §8.5 leading-silence ladder. Arm 2 = coverage/agreement on the three fixtures, **only if Arm 1 reaches O-B1** | **Device**, user-approved, isolated actions | **O-B1** alignment supported ⇒ per-feature B5 (§8.7) + the fitted A6↔B2 relationship with residuals and held-out test. **O-B2** alignment unresolved ⇒ B5 and frame-wise comparison reported **unavailable** with descriptive array statistics — an honest outcome, not a failure (R5.8). **O-B3** no analytics returned at all ⇒ reported as such. Any of the three passes; what fails is reporting a coverage number without established alignment |

M1–M4 need **no device approval**. M5's two arms: the ladder is ~4 short feeds, the coverage arm ~6 minutes of audio at real time; with isolated actions, ≈35–45 minutes of device time (up from R1's 20–25, because the alignment experiment is new).

---

## 10. Files, and the two settled mechanics

All new, all `ObservatoryTests/`:

| File | Contents |
|---|---|
| `AcousticMeasurementSemantics.swift` | `AcousticMeasurement`, `Unit`, `Coverage`, `MeasurementStatus`, `AnalysisWindow`, `AnalysisDomain`, `CompletenessRecord`, `CaptureProvenance`, `CapabilityStatus`, report types. Pure value types |
| `AcousticEstimatorConfig.swift` | §4.4 config decoding + hashing |
| `AcousticMeasurementPrototype.swift` | Channel A: reader, frame grid, A1–A18 |
| `AcousticAnalysisDomainBuilder.swift` | §6: completeness, evidence sources, disagreement policy, join guards |
| `AcousticRulePrototype.swift` | §7 rule schema + `AcousticRuleEvaluator` |
| `U4aEstimatorConfig.json`, `U4aAcousticRules.json` | Test-bundle resources |
| `AcousticMeasurementTests.swift` | M1, M3 |
| `AcousticFixtureObservationTests.swift` | M2, M4 |
| `AcousticVoiceAnalyticsDeviceTests.swift` | M5 (both arms) |

**Untouched:** every app-target file; the read-only fixtures; `AudioFixtureReplayTests.swift`. `FixtureReplayHarness.swift` will likely need an **additive** entry point for M5 (result-level metadata + fed-interval recording + the silence ladder); existing functions and their instrumentation stay byte-identical so E1–E10 remain comparable, and the addition is flagged for approval before it is made.

**Settled per director ruling (b):** the `project.pbxproj` edit adding the two JSON resources, and `OBSERVATORY_U4A_SESSION_BACKUP_DIR` for reaching session audio that must stay outside the repo. Per ruling (c), that variable **is set for exit-evidence runs** — session tests must actually execute; skip-not-fail semantics remain only so the suite stays green on machines without the backups.

---

## 11. What this unit will not do

No transcript content, word timings, diarization, or attribution (U3). No interpretation, emotion label, probability, or severity (Stage 2). No UI, no production-target file (U4), no recognizer change (U5), no capture-side DSP change. No fixture re-recording (E7 deferred), no new dependency, no external service (D-04). No `.prolongedSoundCandidate`. No `SpeechDetector`/`SpeechAnalyzer` cross-check — director ruling (a), and the family is absent from the installed SDK. No claim of perceptual, emotional, or clinical validity.

---

## 12. Exit criteria

1. M1, M3, M4 green on simulator with **real numbers reported** — accuracy *and* rejection/octave-error rates — alongside the existing suite total (62 logic tests today).
2. M2 executed on all five sources **including both real sessions** (the env var set per ruling (c) — a skipped session test cannot satisfy exit evidence, R6.10), landing on O-A1 or O-A2 with the artifact attached and Hermes-verified from the `.xcresult`.
3. The U6b session's report shows: the completeness record, **both evidence sources separately**, the unresolved region the §6.4 policy produced, and the resulting spans — with the ≈32 s lifecycle inference and the 54.1 s recognizer timing presented as **two unreliable sources that disagree**, neither promoted.
4. Schema invariants enforced by test: finite numbers only, explicit nulls, `value != nil ⟺ .valid`, legitimate zeros present, no `0`-as-unknown, string fields within the constrained set.
5. Determinism **within a pinned environment** (same machine, OS, SDK, arch, build config): byte-identical **canonical analysis payload** (report minus manifest environment/timing fields) across repeated runs. Cross-environment bit-identity is **not** claimed; environment differences are recorded in the manifest and cross-environment comparison uses a reported tolerance.
6. M5 executed on device with user approval, landing on O-B1, O-B2 or O-B3, reported honestly.
7. The CONVENTIONS.md three-way statement: measured/tested (estimator checks, invariances, abstention) vs integration-tested-but-not-validated (real-recording measurements) vs entirely unverified (anything perceptual or clinical).
8. Exit protocol: PLAN.md, STABILIZATION Status line, `VERSION_HISTORY.txt`, and a DECISIONS entry if the director settles the §6 join semantics or the §6.6 U4 recommendation.

**Valid non-failure outcomes**, stated so they cannot be read as failures later: O-A2 (evidence-supported limitation), O-B2/O-B3 (Channel B unmeasurable or absent), and a fully-unresolved join region producing wide abstention on a real session. **Explicitly not a permitted conclusion (R6.3):** "these recordings are SNR-limited, so capture conditioning is required," on the evidence of low amplitude or failed F0 extraction alone. Low level is not low SNR; such a conclusion needs evidence this unit may not produce, and if it does not, the report says only what it measured.

---

## 13. Open items for the director (not for another review round)

**D1 — unit split.** The review's Channel-B requirements turn M5 into a designed experiment with its own controls. Under D-14's one-unit-one-thread rule, this may be two units: **U4a-1** (Channel A, simulator, M1–M4) and **U4a-2** (Channel B, device, M5). The proposal works either way; **default if unanswered: one unit**, with U4a-2 split out only if the thread grows long enough to hit CONVENTIONS.md's "finish at the next natural boundary" rule.

**D2 — device budget.** ≈35–45 minutes of isolated device actions for M5's two arms. Confirm or trim to the alignment ladder alone (coverage then waits for a later unit — but note that without the ladder, no coverage number is permitted at all).

**D3 — pre-registration.** The exploratory bands, targets, and thresholds in §4.4, §7 and §9 are fixed **by committing this revision** before any run. Changing one after seeing results is a documented amendment with a reason, never a silent edit.

---

## 14. Sequencing

1. Director verification of this revision against the review (ruling (e)) → D1–D3 answered.
2. Implement §10's Channel-A files; run M1, M3, M4 on simulator; report real numbers.
3. Run M2; attach the report; Hermes verifies it against the `.xcresult`.
4. M5 Arm 1 (alignment) on device with explicit user approval; Arm 2 only if Arm 1 reaches O-B1.
5. Honest scored report → CONVENTIONS.md exit protocol.
6. Production integration (`Models.swift` additive fields and kinds, `SignalRuleMatchType.numericThreshold`, `CaptureDiscontinuityEvent` per §6.6, `AcousticExpressionEngine.swift`, store wiring) stays **U4**, with its own proposal and review.
