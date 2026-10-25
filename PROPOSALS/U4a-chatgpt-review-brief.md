# Review brief for ChatGPT — U4a proposal (acoustic-expression observation prototype), 2026-10-24

You are the independent reviewer for Observatory (three-agent workflow: Claude writes code, Hermes verifies claims against real artifacts and directs, ChatGPT advises; you have no disk access). Self-contained brief; the full proposal text is appended verbatim at the end. This unit defines MEASUREMENT SEMANTICS for the product's core channel, so per the project's conventions (D-15) it requires your review before implementation. Critique the plan; do not write code.

## State since your last review (U6 brief #4)
- **U6 closed** (`84d0e7d`): interruption-chain recovery (state machine + watchdog), failure budget, and the honest capture-completeness record you ruled on (D-17: `captureCompleteness` enum, lifecycle-evidence-only, diarization skip). Device re-run PASSED with caveats.
- **U6b closed** (`fa7651e`): fast-backoff restart retry shrank the post-interruption dead window from 46.4s to 30.2s in a device-verified run. Two durable facts from that run matter here: (i) the saved audio file of an interrupted-then-recovered session is a **splice** — capture stopped at the interruption and resumed into the same file, so file-time is contiguous while wall-time jumped ~32s with no marker in the file; (ii) a **pre-existing timestamp-ordering anomaly** was confirmed: post-recovery words persist last in text order but carry mid-file audio timestamps (3 backward steps in the U6b transcript) — hard evidence that recognizer-side timing cannot be trusted on this device/OS.
- **Owner's product vision recorded (2026-10-24)**: Observatory is a SaMD-grade instrument measuring human behavior — aural behavior first, visual body language later — for eventual FDA review. Behavioral measurement capability leads; transcript fidelity serves it.
- **D-18 adopted (your prior reviews informed it)**: `.incomplete` sessions get coverage-scoped analysis, not blanket exclusion — every measurement from a partially-captured session must carry explicit coverage/validity metadata; consumers that cannot honestly scope partial coverage skip entirely (today: diarization).
- **Queue re-sequenced by the owner**: U4a (this unit, proposal-first) → U5 (transcript accumulation; Claude's test-only proposal is drafted and staged, review deferred until U4a closes) → U2 → U3 → U4.
- Binding decisions relevant here: **D-04** (on-device only, no external service), **D-07** (unavailable = `nil`, never `0`), **D-16** (thresholds are SignalLibrary rule data, not Swift constants), **D-17** (completeness from lifecycle evidence only; duration mismatch is corroboration, never sole basis), **D-18** (above).

## Why U4a exists (director's framing, artifact-verified)
Every Stage 0 unit found the transcript path defective: E8 proved `bestTranscription` behaves replacement-not-cumulative across internal utterance boundaries on this device/OS/request configuration (9–19% word recovery from finals); U6/U6b proved capture survives interruptions that kill transcripts. The U6b session persisted 54 words over 149.4s of real speech-level audio; the Oct-22 incident session persisted **4 words** over 156.6s of audio containing 110+ seconds of confirmed speech energy. **The audio survives when the transcript does not** — U4a starts measuring the channel that survived, with no transcript or diarization dependency.

## The proposal in brief (full text appended)
**Two channels, explicitly ranked (a deliberate deviation from the STABILIZATION plan — Q1 below):**
- **Channel A (primary):** signal processing directly on saved `.caf` files via `AVAudioFile` + Accelerate — never opens a recognizer; runs on simulator and device. Delivers: frame intensity (dBFS, 25ms/10ms), clipping fraction, noise floor (10th percentile), frame SNR proxy, voicing decision (SNR hysteresis + autocorrelation gate), F0 via normalized cross-correlation (60–400 Hz, parabolic interpolation, octave-jump rejection; `nil` when unvoiced, never 0), speaker-relative F0 in semitones, syllable-nucleus events (De Jong & Wempe envelope-peak method); then window-level (5s/1s hop, rule data): pauses, pause ratio, phonation time, speech rate, articulation rate, intensity level/variability, F0 median/range/variability, deltas vs within-span baseline.
- **Channel B (secondary, measured not relied on):** `SFVoiceAnalytics` (pitch/jitter/shimmer/voicing) harvested through the existing device replay-harness recognition pass. Its headline deliverable is ONE honest number: what fraction of A5-voiced audio it actually covers on this device (coverage bounded by E8's final-result defect), plus the measured relationship between its `pitch` (documented as "a logarithm," base/reference unspecified) and Channel A's F0 on co-covered frames. `pitch` is reported in its own raw units, never converted to Hz by assumption.
- The deviation: the STABILIZATION plan says pitch comes from `SFVoiceAnalytics` and forbids a separate pitch-tracking implementation "unless that API proves insufficient at implementation time… not silently worked around with an unvalidated DIY detector." The proposal argues insufficiency **by construction**: `SFVoiceAnalytics` is only reachable through recognition results, so it cannot satisfy U4a's defining transcript-independence constraint; and the Channel-A F0 estimator is validated against analytically-known synthetic signals (M1) and gain-invariance controls (M4) before being pointed at speech, with Channel B retained so the gap is reported with a number.

**Measurement semantics (SaMD standard):** every measurement is a record, not a number — metric ID, value (`nil` = unavailable, never 0), unit as an enum, window geometry, estimator ID + semver version, coverage (expected/analyzed/contributing frames), validity enum (`.valid`, `.insufficientCoverage`, `.lowSNR`, `.saturated`, `.outsideAnalysisDomain`, `.discontinuityAdjacent`, `.insufficientBaseline`, `.estimatorFailed`, `.noAudio`), baseline reference, and capture provenance (source ID, file SHA-256, sample rate, capture configuration — the fixtures' known-ambiguous `.measurement`-mode provenance included — and any post-processing, with amplitude-domain metrics REFUSED on loudnorm/gain variants outside the invariance control). Test-enforced invariant: `value == nil ⟺ validity != .valid`. Intensity is dBFS, never called loudness or SPL (no calibrated microphone exists).

**The splice problem (§4.3, where D-17/D-18 meet):** for `.incomplete` sessions the analysis domain is split at every **discontinuity bound** — an uncertainty REGION derived from two independent sources reported separately: (a) lifecycle bound from session-record arithmetic (U6b worked example: 182s wall, 149.4s audio, gaps at T+46/48/65s ⇒ implied splice at file ≈32.4s), and (b) signal bound from near-digital-silence runs (OS mic-mute measured at −87 to −90 dBFS vs −42 to −56 dBFS speech in these very recordings) and noise-floor steps. The proposal explicitly REFUSES to resolve a real contradiction: the derived 32.4s splice is inconsistent with the transcript's 54.1s word timing (itself suspect per the known timestamp anomaly) — neither source alone establishes the splice, matching D-17's corroboration rule. Windows overlapping a bound report `value == nil` (`.discontinuityAdjacent`); no rate/pause/delta measurement may span a join (a splice fakes an instantaneous step and erases a real 32.6s pause); no wall-clock claim attaches to `.incomplete`-session measurements; no cross-discontinuity trend statements.

**Baselines:** within-session, within-analyzable-span only, minimum voiced seconds as rule data. Because there is no diarization, baseline-dependent measurements (relative F0, F0 variability, deltas) are computed ONLY for single-speaker sources (`fixture-solo`, clean single-speaker sessions); multi-speaker fixtures get speaker-agnostic measurements with the mixture recorded as a validity defect.

**Thresholds as rule data (D-16):** a numeric rule schema (`matchType: "numericThreshold"`, metric + unit + comparison + threshold + window geometry + coverage/SNR/baseline gates + `calibrationStatus: "uncalibrated-prototype"` + rationale text) in test-local Codable types mirroring proposed production field names, loaded from a JSON test-bundle resource. Today's hardcoded `SilenceTracker` constants (RMS 0.02, min pause 1.5s, debounce 0.3s) become rule data expressed in dB-above-noise-floor rather than absolute RMS. Estimator internals (F0 search range, NCCF peak floor, octave-jump rejection) stay in code, versioned via `estimatorVersion` — the proposed code/data boundary is Q2. Migration path to production (U4): additive `SignalRuleMatchType` case + optional `numeric` field on `SignalDetectionRule` (existing persisted libraries decode unchanged) + a sibling `AcousticRuleEvaluator` (the existing text-matching engine is not contorted).

**Acceptance = five behavioral milestones with machine-readable artifact evidence** (`U4aMeasurementReport.json` attached via Swift Testing `Attachment.record`, extractable from the `.xcresult` bundle; report types structurally incapable of holding transcript text or audio samples):
- **M1** estimator correctness vs analytically-known synthetics (F0 ±1% clean, intensity ±0.5 dB, exact nucleus counts, VAD boundaries ±30 ms; degradation curves at SNR 30/20/10/5 dB; a miss revises the estimator, never silently widens the tolerance).
- **M2** the behavioral milestone: real measurements from the three fixtures + two real sessions (the `.incomplete` U6b run and a clean 73.3s session), ≥1 valid measurement each of F0/intensity/pause/articulation-rate at contributingFraction ≥0.8, ≥1 rule-fired observation on `fixture-solo` carrying full metadata, and PRE-REGISTERED plausibility bands (voiced fraction 0.30–0.85, median F0 70–300 Hz, articulation rate 2–8 syll/s) where an out-of-band value is a finding to investigate, not a test to loosen.
- **M3** abstention/D-07 invariants: zero observations from digital silence, −50 dBFS white noise, the real 4096-byte orphaned header-only recording, and a synthetic spliced file with known join (join must land inside the reported discontinuity bound); structural JSON scan for 0-as-unknown.
- **M4** invariance controls on EXISTING assets: F0 medians agree ±1% across base/identity-re-encode/flat-gain fixture variants; intensity differs by exactly the known applied gains (+12.0/+15.2/+18.7 dB) within ±0.5 dB.
- **M5** (only device cost, user-approved, isolated runs): Channel B coverage number per fixture — **any value passes, including near-zero**; the deliverable is the number and its interpretation.
M1–M4 run entirely on simulator (fixtures are already test-bundle resources). A declared valid non-failure outcome: if `.measurement`-mode levels (solo fixture mean −46.5 dBFS) leave too little SNR for reliable F0, the honest result is "transcript-independent acoustic measurement on these recordings is SNR-limited; capture-side conditioning is a prerequisite" — a real finding that reframes U2/E7, reported with numbers rather than confident garbage.

**Location:** 8 new files, all in `ObservatoryTests/`; no production-target file; existing harness/replay files untouched (one additive callback parameter only if unavoidable, flagged for approval); smoke-session audio reached via an environment variable pointing at the device-backup directory — tests skip (with recorded reason) when unset, nothing sensitive copied/committed/logged. Excluded: transcript content, attribution, UI, emotion/state labels, probabilities, severity, `.prolongedSoundCandidate` (transcript-dependent by the plan's own definition), fixture re-recording, any external service.

## Director's verification notes (Hermes, against real artifacts — not Claude's claims)
**Confirmed accurate:** the STABILIZATION-plan quotes (the "no separate pitch-tracking" line and the Stage 1 observation kinds, verbatim at lines 39/51); `.prolongedSoundCandidate`'s transcript-dependence (the plan defines it with a "syllable-count estimate from the recognized text"); the `SilenceTracker` constants (0.02 RMS, 1.5s — in `SpeechRecognitionManager.swift:223/234`); `SignalRuleMatchType` is a String-raw-value enum with `phrases: [String]` today (the additive migration is structurally sound); the entire U6b worked example in §4.3 re-verified against the device backup just now (session `9D4F101A…`: startedAt→endedAt = 182s, `captureCompleteness=.incomplete(149.4)`, `reliable=true`/`missingAudioIntervals=[]`, gaps at 18:56:52/54 and 18:57:11Z; the `.caf` on disk is 28,688,896 bytes ⇒ 149.42s at 48 kHz float mono); Swift Testing `Attachment.record(_:named:)` exists in the installed Testing framework; the fixture inventory for M4 (base + identity/gain/loudnorm variants of all three) exists on disk.

**Finding 1 — Claude's Q6 is moot as a matter of fact (director ruling, evidence below).** Q6 floated iOS 26+ `SpeechDetector` as a cheap transcript-free VAD cross-check on A5, flagged as needing a user decision because DECISIONS.md excludes the SpeechAnalyzer family. **`SpeechAnalyzer`/`SpeechDetector` do not exist in the installed iPhoneOS 27.0 SDK** (nor the simulator SDK): no framework, no tbd, no module trace anywhere in the SDK tree. The cross-check is unavailable at any scope; the question is void, not deferred. (Note the asymmetry: the proposal verified its `SFVoiceAnalytics` claims against the installed SDK — correct — but did not verify Q6's premise the same way.)

**Finding 2 — Channel B harvests from a deprecated access path as specified (new director question Q5 below).** In the installed SDK, `SFTranscriptionSegment.voiceAnalytics` is marked `NS_DEPRECATED` ("moved to SFSpeechRecognitionMetadata"); the live path is `SFSpeechRecognitionResult.speechRecognitionMetadata.voiceAnalytics` (iOS 14+), which is **result-level** (one `SFVoiceAnalytics` per recognition result ≈ per ~55s replay chunk), not segment-level. This matters for B5's definition ("seconds covered by segments carrying non-nil voiceAnalytics"): at result level, coverage semantics and the anchoring of the `SFAcousticFeature` frame grids to file time both change — and frame-grid anchoring depends on result/segment timing that E8 and the U6b timestamp anomaly have already shown to be unreliable on this device. The proposal must specify which access path(s) Channel B harvests, how the frame grid is anchored to file time, and what B5 counts, before implementation.

**Finding 3 — footnote, harmless but worth correcting.** §4.3's 149.4s derivation divides the whole-file byte count by 4/48000; CAF files carry a header, so true audio-data duration is ~0.02s shorter. At the recorded precision (149.4) nothing changes, and §4.2's provenance spec already mandates computing duration from `AVAudioFile.frameCount` — but the §4.3 table should use frameCount-derived seconds so the "two arithmetics agree to 0.2s" claim is built on data bytes, not file bytes.

**Director dispositions (for the record):** Claude's Q5a (one `project.pbxproj` edit adding the rules JSON as a test-bundle resource) and Q5b (the backup-directory environment variable with skip-not-fail semantics) are APPROVED as routine mechanical items — fixture-resource precedent exists, and the privacy design is sound; user commit approval still required at exit per convention. Claude's Q6 is ruled MOOT per Finding 1. Q1–Q4 plus director's Q5–Q6 below go to this review.

## Questions — answer as a numbered list (Q1–Q6 plus your overall verdict: approve / approve-with-changes / reject, with reasons). Be blunt.

**Q1 — Two-channel split and the deliberate deviation.** Is the Channel-A (validated DSP, transcript-free) + Channel-B (SFVoiceAnalytics coverage measured, not relied on) design accepted, including the deviation from the STABILIZATION plan's "no separate pitch-tracking" line? The insufficiency argument is structural (voiceAnalytics is only reachable through recognition results — director-verified against the SDK), and M1/M4 supply validation evidence rather than a promise. If you reject, the stated fallback is a materially smaller unit (intensity/pause/rate only, no pitch) until U5 repairs recognition — is that fallback preferable?

**Q2 — Code/rule-data boundary.** Estimator internals (F0 search range 60–400 Hz, NCCF peak-strength floor, octave-jump rejection, interpolation) stay in code under `estimatorVersion`; every gate, window, and threshold moves to rule data. Is this the right reading of D-16, or should the search range be data too?

**Q3 — Discontinuity semantics (schema question; D-17/Q3 precedent applies).** (a) Is the §4.3 treatment of an `.incomplete` session's file as spliced — bounded-uncertainty discontinuity regions from two independently-reported sources, domain splitting, `.discontinuityAdjacent` windows nilled out, no wall-clock mapping, no cross-discontinuity trends — the right measurement semantics under D-18? (b) Should the production record eventually carry an explicit discontinuity/splice-offset field on `ReflectionSession`, set from lifecycle evidence AT RECOVERY TIME when the offset is actually known rather than reconstructed after the fact (proposed for U4, not built in U4a)?

**Q4 — Channel-B unit honesty.** `SFVoiceAnalytics.pitch` is documented as "a logarithm" with unspecified base/reference. The proposal reports it in raw units and MEASURES the A6↔B2 relationship on co-covered frames instead of assuming a conversion. Confirm this is preferred over picking a plausible base; if the relationship comes back clean, the unit mapping becomes a documented finding.

**Q5 (director) — Channel-B access path and frame-grid anchoring.** Per Finding 2: which access path should Channel B harvest (result-level `speechRecognitionMetadata.voiceAnalytics`, deprecated segment-level, or both with per-path reporting)? How should the `SFAcousticFeature` frame grids be anchored to file time given that recognizer-side timing is demonstrably unreliable on this device (E8; U6b timestamp anomaly)? And what exactly should B5's coverage denominator/numerator count at result level? Specify what you would require before implementation.

**Q6 (director) — Anything missing or under-specified?** Candidates to consider: the voicing gate design (SNR hysteresis AND autocorrelation peak strength) at `.measurement`-mode levels; A8's syllable-nucleus method transferring from read speech to spontaneous reflection audio; the 5s/1s window geometry as a default; the pre-registered M2 plausibility bands; the mult…-speaker baseline exclusion rule; determinism claim (byte-identical reports modulo timestamps); the M3 orphaned-file and synthetic-splice controls; exit criterion adequacy. Flag anything else you see.

---

## Appendix — full proposal text (verbatim, `PROPOSALS/U4a-proposal.md`, 2026-10-24)

# U4a proposal — Acoustic-expression observation prototype, transcript-independent (PROPOSAL-ONLY phase)

**Author:** Claude (Xcode assistant chat) · **Date:** 2026-10-24 · **Status:** awaiting ChatGPT review (D-15), then director review
**Phase:** Proposal only. No code is written in this phase; the only file touched is this one.
**Implementation scope when approved:** `ObservatoryTests/` only (new files), plus one flagged `project.pbxproj` resource addition (Q5). **No production-target file** — not `Models.swift`, not `SignalLibraryModels.swift`, not any `*Engine.swift`, not any screen.

---

## 1. What this unit has to answer

PLAN.md's project one-liner commits the product to being a **measurement-grade instrument for aural behavior**, built to SaMD quality. Every unit so far has been about getting *transcripts* out of audio, and every unit so far has found that path defective: E8 (recognizer-side result replacement, 9–19% word recovery), U6/U6b (capture-lifecycle outages). The one thing all of that work established beyond dispute is this:

> **The audio survives when the transcript does not.** The U6b session (`9D4F101A…`) persisted 54 words of ~3 minutes of speech, but its `.caf` holds 149.4 s of real, speech-level audio. The U6 re-run (`0CA79AED…`) persisted 69 words over 142.7 s of audio. The Oct-22 incident session (`A6699F43…`) persisted **4 words** over 156.6 s of audio, 110+ s of which Hermes's energy forensics confirmed contains real speech.

U4a exists to start measuring the channel that survived. The question it answers:

> **Can we produce honest, unit-bearing, validity-scoped acoustic measurements directly from recordings this project already has on disk — with no dependency on transcript content or diarization — and can we show real measurements from real recordings as an artifact, not as a claim?**

It does **not** answer whether those measurements mean anything about emotion or state. That is Stage 2, and nothing in this unit may label one. It does not touch attribution (U3), does not touch the recognizer (U5), and does not ship anything into the app.

---

## 2. The transcript-independence problem, stated before it bites us

The STABILIZATION plan's Stage 1 names `SFVoiceAnalytics` (pitch/jitter/shimmer/voicing) as the first-choice source. Confirmed against the installed SDK documentation today, rather than assumed:

- `SFVoiceAnalytics` is reached through **`SFTranscriptionSegment.voiceAnalytics`** (and `SFSpeechRecognitionMetadata.voiceAnalytics`).
- The documentation states these results "are part of the `SFTranscriptionSegment` object and **are available when the system sends the `isFinal` flag**."

So the structural facts are:

1. There is **no way to obtain `SFVoiceAnalytics` without running a speech-recognition pass.** Its frame grids are anchored to *transcription segments*, not to the audio file.
2. On this device/OS/configuration, the final result is precisely the artifact E8 proved unreliable: final-result segment coverage on these fixtures corresponds to 9–19% of the spoken words. Whatever `SFVoiceAnalytics` coverage we get is bounded by that same defect, and is currently **unmeasured**.
3. Therefore "`SFVoiceAnalytics`-only" is not a transcript-independent design. It is a transcript-*content*-independent design that is still hostage to transcript *production*.

**Design consequence — two channels, explicitly ranked:**

| Channel | Source | Transcript dependency | Runs on | Role in U4a |
|---|---|---|---|---|
| **A (primary)** | Signal processing performed directly on the saved `.caf` via `AVAudioFile` + Accelerate | **None.** Never opens a recognizer | **Simulator** and device | The measurement set U4a delivers |
| **B (secondary, measured not relied on)** | `SFVoiceAnalytics` from a replay recognition pass through the existing `FixtureReplayHarness` | Requires a recognition pass; coverage bounded by E8 | Device only | Deliver **one honest number**: how much of the voiced audio it actually covers here — plus cross-channel agreement where it does |

Channel A running on the **simulator** is a real practical win: the three fixtures are already test-bundle resources (`AudioFixtureReplayTests.fixtureURL`), so the entire primary measurement set is developable and verifiable with **zero device-run approvals**. Device time is needed only for Channel B.

**This is a deliberate deviation from one line of the STABILIZATION plan** — the line reading "no separate pitch-tracking implementation unless that API proves insufficient at implementation time, in which case the gap is reported, not silently worked around with an unvalidated DIY detector." The argument for deviating, which reviewers should accept or reject explicitly (**Q1**):

- The API *is* insufficient for this unit by construction, not by surprise: it cannot be obtained transcript-independently, which is U4a's defining constraint.
- The detector is not "unvalidated." §6 MILESTONE-1 validates every Channel-A estimator against **synthetic signals with analytically known answers** before it is pointed at speech, and §6 MILESTONE-4 validates gain invariance against fixture variants that already exist. The plan's objection is to an unvalidated detector, and the answer is validation evidence, not a promise.
- Channel B is retained precisely so the gap is *reported with a number* rather than asserted.

---

## 3. The observation set (item a)

All Channel-A measurements are computed on the file's own timeline (file-relative seconds), in a fixed, deterministic pipeline. Frame geometry is uniform so every metric shares one frame grid and windows are directly comparable.

### 3.1 Frame grid and base measurements

| # | Quantity | Unit | Frame / hop | Estimator | `nil` when |
|---|---|---|---|---|---|
| A1 | Short-time intensity | **dBFS** (20·log₁₀ RMS, full-scale reference) | 25 ms / 10 ms | RMS over the frame | frame incomplete at file end |
| A2 | Clipping fraction | dimensionless 0–1 | per frame | \|sample\| ≥ 0.999 count ÷ frame length | — |
| A3 | Noise floor | dBFS | whole analysis segment | 10th percentile of A1 across the segment | segment shorter than the minimum (rule data) |
| A4 | Frame SNR proxy | dB | per frame | A1 − A3 | A3 unavailable |
| A5 | Voicing decision | boolean + confidence 0–1 | 25 ms / 10 ms | A4 hysteresis gate **and** autocorrelation peak-strength gate | A4 unavailable |
| A6 | Fundamental frequency **F0** | **Hz** | 40 ms / 10 ms | Normalized cross-correlation (NCCF) peak picking over 60–400 Hz, parabolic interpolation, median-of-3 smoothing with octave-jump rejection | frame unvoiced (A5 false) or peak strength below the rule-data floor — **never 0** (D-07) |
| A7 | F0, speaker-relative | **semitones re: segment median F0** | derived from A6 | 12·log₂(F0 ÷ medianF0) | A6 `nil`, or baseline insufficient |
| A8 | Syllable-nucleus events | event list (time, peak dB) | envelope, 10 ms | Intensity-peak picking on the 70–4000 Hz band envelope with a dip threshold, minimum inter-nucleus interval, and a voicing constraint (De Jong & Wempe's method, as used in phonetics for ASR-free speech-rate estimation) | SNR below gate |

### 3.2 Derived, window-level measurements

Aggregation windows are **5 s wide, 1 s hop** by default (both rule data, §5), each window carrying its own coverage and validity.

| # | Quantity | Unit | Definition |
|---|---|---|---|
| A9 | Pause events | s (start, end, duration) | Runs of A5 = false longer than `minimumPauseSeconds` (rule data; today's `SilenceTracker` hardcodes 1.5 s — see §5) |
| A10 | Pause ratio | dimensionless 0–1 | Pause time ÷ window duration |
| A11 | Phonation time | s | Window duration − pause time |
| A12 | **Speech rate** | **syllables/s** | A8 nuclei in window ÷ window duration |
| A13 | **Articulation rate** | **syllables/s** | A8 nuclei in window ÷ A11 (excludes pauses — the measure that separates "paused a lot" from "spoke slowly") |
| A14 | Window intensity level | dBFS | Median of A1 over voiced frames in the window |
| A15 | Intensity variability | dB | IQR of A1 over voiced frames |
| A16 | Window F0 median / range | Hz; semitones | Median of A6; 5th–95th-percentile spread expressed via A7 |
| A17 | F0 variability | semitones | IQR of A7 within the window |
| A18 | Deltas vs within-segment baseline | dB / semitones / syllables·s⁻¹ | A14, A16, A12, A13 minus their within-segment baseline (§4.4) |

### 3.3 Channel B (device arm only)

| # | Quantity | Unit as documented | Handling |
|---|---|---|---|
| B1 | `voicing` | probability 0–1 | Compared frame-wise against A5 where their grids overlap |
| B2 | `pitch` | "fundamental frequency … expressed as a **logarithm**" — base and reference **unspecified by the documentation** | **Reported in its own raw units and never converted to Hz by assumption.** Its relationship to A6 is *measured* on co-covered frames (regression/correlation) and reported; if the relationship is clean we gain a documented unit mapping as a finding, and if it is not, that is also the finding |
| B3 | `jitter` | % of the frame's fundamental frequency | Reported as-is; no cross-channel equivalent in U4a |
| B4 | `shimmer` | dB | Reported as-is |
| B5 | **Voice-analytics coverage** | dimensionless 0–1 | Seconds covered by segments carrying non-nil `voiceAnalytics`, ÷ seconds of A5-voiced audio. **This is Channel B's headline deliverable.** |

### 3.4 Observation kinds the prototype may emit

Mirrors, case-for-case, the `ObservationEventKind` additions the STABILIZATION plan reserves for Stage 1 — declared in a **test-local** enum because adding cases to `Models.swift` is a production edit deferred to U4:

`.pitchContourShift`, `.intensityShift`, `.acceleratedDeliveryCandidate`, plus `.reducedArticulationUnsupported` which is emitted **only** as an explicit "no validated method available" status marker, never as a detection.

`.prolongedSoundCandidate` is **excluded from U4a**: the STABILIZATION plan defines it in terms of per-word duration outliers normalized by a syllable count from recognized text — that is transcript-dependent by definition. It returns in U4 once attribution and transcript exist. Saying so here is cheaper than discovering it mid-implementation.

**No observation emitted by this unit carries an emotional or state label, a probability, or a severity.** Each is a measurement plus the rule that selected it.

---

## 4. Measurement semantics to SaMD standard (item b)

This is the part that distinguishes an instrument from a demo. The governing rule, from D-18: *a measurement presented without its validity context is the failure mode SaMD discipline forbids.*

### 4.1 Every measurement is a record, not a number

```swift
struct AcousticMeasurement: Codable {
    let metric: MetricID              // e.g. "intensity.windowMedian", stable, versioned
    let value: Double?                // nil == unavailable. NEVER 0 as a stand-in (D-07)
    let unit: Unit                    // .dBFS, .hertz, .semitonesReBaseline, .syllablesPerSecond,
                                      // .seconds, .ratio, .unspecifiedLogHz  (an enum, not a String)
    let window: AnalysisWindow        // start, end (file-relative s), frameMs, hopMs
    let estimator: EstimatorID        // e.g. "u4a.f0.nccf"
    let estimatorVersion: String      // semver; changing the algorithm changes this
    let coverage: Coverage
    let validity: Validity
    let baseline: BaselineRef?        // which baseline A18's delta was taken against, if any
    let provenance: CaptureProvenanceID
}

struct Coverage: Codable {
    let expectedFrames: Int           // frames the window geometry implies
    let analyzedFrames: Int           // frames actually inside the analysis domain (§4.3)
    let contributingFrames: Int       // frames that passed validity and fed the value
    var analyzedFraction: Double { ... }       // analyzed ÷ expected
    var contributingFraction: Double { ... }   // contributing ÷ analyzed
}

enum Validity: Codable {
    case valid
    case insufficientCoverage(contributingFraction: Double, required: Double)
    case lowSNR(frameSNRMedianDb: Double, required: Double)
    case saturated(clippedFraction: Double)
    case outsideAnalysisDomain
    case discontinuityAdjacent(bound: DiscontinuityBound)   // §4.3
    case insufficientBaseline(observedSeconds: Double, required: Double)
    case estimatorFailed(reason: String)
    case noAudio
}
```

Invariants, each one test-enforced (§6 MILESTONE-3):

1. **`value == nil` ⟺ `validity != .valid`.** A measurement can never carry a number it does not stand behind, and can never carry `.valid` with no number.
2. **No `0` is ever written where a value is unavailable** — including in the JSON encoding, which emits explicit `null`, never an omitted key that a consumer could default.
3. **Units are an enum, not prose.** The STABILIZATION plan's complaint about "burying units in prose `detail` text" is answered structurally.
4. **Every measurement names its estimator and version.** Two numbers produced by different estimator versions are never silently comparable.

### 4.2 Capture provenance is recorded with every measurement

Per the STABILIZATION plan's Stage 1 provenance requirement, and because the fixtures have a *known-ambiguous* capture configuration (PLAN.md: fixtures were recorded ~1 h before the `.measurement` tuning was committed):

```swift
struct CaptureProvenance: Codable {
    let sourceID: String              // "fixture-solo" | session UUID
    let fileSHA256: String            // reproducibility anchor; the audio itself never leaves the device/machine
    let sampleRate: Double            // 48000 observed
    let channelCount: Int
    let bitDepthDescription: String   // "pcm_f32le" observed
    let fileDurationSeconds: Double   // from frameCount ÷ sampleRate, computed, never assumed
    let captureConfiguration: CaptureConfiguration  // .measurementModeConfirmed | .unverified(note:) | .unknown
    let postProcessing: PostProcessing              // .none | .identityReencode | .flatGain(db:) | .loudnorm
}
```

Two rules follow from `postProcessing` and are enforced, not merely documented:

- **Amplitude-domain metrics (A1, A3, A4, A14, A15, A18-intensity) are refused on `-loudnorm` and `-gain` variants** except inside the §6 MILESTONE-4 invariance control, where the known transformation is the point.
- **Intensity is reported in dBFS and is never called loudness or SPL.** No microphone in this project is calibrated; absolute level is meaningless and cross-device comparison is invalid. The unit enum makes this impossible to fudge.

### 4.3 The analysis domain — where D-18 and D-17 actually meet, and the splice problem

D-18 permits coverage-scoped analysis of `.incomplete` sessions. Doing that honestly requires confronting something neither D-17 nor D-18 states explicitly, and which this unit is the first to need:

> **An `.incomplete` session's saved file is not a truncated recording. It is a spliced one.** Capture stopped at the interruption and resumed on recovery, into the *same* file. The audio on either side of that join is contiguous in file time but separated by tens of seconds of wall time, with **no marker in the file**.

Worked against the real U6b session (`9D4F101A…`, verified in the device backup just now, not recalled):

| Fact | Value | Source |
|---|---|---|
| `startedAt` → `endedAt` | 18:56:06Z → 18:59:08Z = **182 s** wall | session JSON |
| File frames ÷ 48 kHz | 28 688 896 B ÷ 4 ÷ 48 000 = **149.4 s** | file on disk |
| `captureCompleteness` | `.incomplete(endpointAudioSeconds: 149.4)` | session JSON (exact match to the file — D-17 working as specified) |
| `recognitionContinuityGaps` | T+46 s (failed `.ended` restart), T+48 s (fast retry), T+65 s (successful watchdog retry) | session JSON |
| `audioRecordingReliable` / `missingAudioIntervals` | `true` / `[]` | session JSON — correct: **no write ever failed** |

Wall time unaccounted for: 182 − 149.4 = **32.6 s**. If capture resumed at the successful retry (T+65 s) and ran to the end, post-recovery audio is 117 s, implying pre-outage audio of 149.4 − 117 = **32.4 s**, i.e. a splice at file offset ≈32.4 s. The two independent arithmetics agree to 0.2 s — which is exactly why it must **not** be trusted: PLAN.md's own U6b record places post-recovery words at file-time 54.1/54.5 s and characterizes them as arriving "seconds after recovery," which is inconsistent with a 32.4 s splice. Either the derived splice point is wrong, or the timestamps are (and PLAN.md already records a known timestamp-ordering anomaly in exactly those words). **Unresolved, and this unit must not resolve it by assumption.**

The semantics U4a therefore adopts:

```swift
struct AnalysisDomain: Codable {
    let fileDurationSeconds: Double
    let analyzableSpans: [TimeSpan]          // disjoint, ascending, file-relative
    let excludedRegions: [ExcludedRegion]    // each with a reason
    let discontinuityBounds: [DiscontinuityBound]
    let wallClockMappingAvailable: Bool      // false for every .incomplete session
}
```

Construction rules:

1. **`.complete` / `nil`-completeness** (all three fixtures; clean sessions): one analyzable span, `[0, fileDuration]`, minus any `missingAudioIntervals` (D-09 still binding), minus a guard band around each excluded interval's edges.
2. **`.incomplete`**: the domain is **split at every discontinuity bound**, never spanned. A bound is a *region of uncertainty*, not a point, and is derived from two independent sources that must be reported separately:
   - **Lifecycle bound** — from `startedAt`, `endedAt`, `recognitionContinuityGaps`, `endpointAudioSeconds`, with the arithmetic above *and its uncertainty*, expressed as an interval, never a point.
   - **Signal bound** — runs of near-digital silence (A1 below a floor far under plausible room tone; Hermes measured −87 to −90 dBFS for OS mic-mute spans versus −42 to −56 dBFS for speech in these very recordings) and abrupt noise-floor steps across a frame boundary.
   - The two are reported side by side with their agreement/disagreement. **Neither alone establishes the splice**, matching D-17's rule that a duration mismatch is corroboration, never sole basis.
3. **Any window overlapping a discontinuity bound is `.discontinuityAdjacent` and carries `value == nil`.** No rate, pause, or delta measurement may ever be computed across a join. This matters concretely: a splice manufactures a fake instantaneous pitch/intensity step and *erases* a 32.6 s pause that really happened.
4. **No wall-clock claim is ever attached to an `.incomplete` session's measurements.** File-relative time only. `wallClockMappingAvailable = false`, and the report says so in the same breath as every number.
5. **No cross-discontinuity trend.** "Pitch rose over the session" is unsayable when a span of the session is missing; such statements are only ever scoped to a single analyzable span, and the report names the span.
6. **Session-level summary always carries `analyzedSeconds / fileDurationSeconds / sessionWallSeconds`** — for U6b: 182 s intended, 149.4 s captured, ~117 s analyzable after excluding the discontinuity bound and guard bands (the exact figure is an output, not a prediction). An instrument that reports "82% of the session captured, of which N% analyzable, in 2 disjoint spans" is honest; one that reports a single mean pitch for "the session" is not.

### 4.4 Baselines

Within-session, within-analyzable-span only — no cross-session baseline exists in this stage, and none is faked. A baseline requires `minimumBaselineVoicedSeconds` (rule data) of valid voiced frames *inside the same analyzable span*; below that, every baseline-dependent measurement (A7, A17, A18) returns `.insufficientBaseline` with the observed seconds. Because U4a has no diarization, a multi-speaker fixture's "baseline" is **a mixture of speakers**, which is a validity defect, not a nuance — so:

> **Baseline-dependent measurements are computed only for `fixture-solo` and for single-speaker sessions.** For `fixture-multi-a`/`-b`, A7/A17/A18 return `.insufficientBaseline(reason: speaker-mixture)` and only speaker-agnostic measurements (A1, A9–A15 with the mixture caveat recorded) are reported. Speaker-scoped baselines arrive with U3/U4.

---

## 5. Thresholds as SignalLibrary rule data, not Swift constants (item c)

Per D-16 and PROJECT_CONSTRAINTS §7. The existing `SignalDetectionRule` is text-shaped (`phrases: [String]`, matched by `SignalLibraryDetectionEngine.match(rule:lowercasedText:)` against lowercased text) and cannot express an acoustic threshold. The prototype therefore defines the **numeric rule schema it believes the production type should grow**, in test-local Codable types with identical field names, loaded from a JSON file:

```jsonc
{
  "id": "observatory.voice.acoustic.prototype",
  "name": "Acoustic expression (U4a prototype)",
  "version": "0.1.0",
  "domain": "Voice",
  "authorType": "Observatory",
  "calibrationStatus": "uncalibrated-prototype",   // never absent; no rule may claim calibration
  "rules": [
    {
      "id": "u4a.intensityShift.rise",
      "name": "Intensity rise vs within-span baseline",
      "matchType": "numericThreshold",             // the proposed new SignalRuleMatchType case
      "eventKind": "intensityShift",
      "eventCategory": "Voice",
      "confidence": "low",
      "numeric": {
        "metric": "intensity.windowMedian.deltaFromBaseline",
        "unit": "dB",
        "comparison": "greaterThanOrEqual",
        "threshold": 6.0,
        "windowSeconds": 5.0,
        "hopSeconds": 1.0,
        "minContributingFraction": 0.8,
        "minBaselineVoicedSeconds": 20.0,
        "minFrameSNRDb": 10.0,
        "rationale": "6 dB ≈ a doubling of amplitude; chosen as a visibly-large change, NOT validated against perception or any reference annotation."
      }
    }
    // …sibling rules for intensityShift.fall, pitchContourShift (semitones),
    // acceleratedDeliveryCandidate (articulation-rate delta), and the
    // measurement-governing parameters below
  ]
}
```

Also carried as rule data rather than code constants, because today they are hardcoded and D-16 says they should not be:

| Parameter | Today | Under U4a |
|---|---|---|
| Silence/voicing threshold | `SilenceTracker.silenceRMSThreshold = 0.02` (Swift constant, documented as "a heuristic, not a calibrated measurement") | Rule data, expressed in dB-above-noise-floor rather than absolute RMS, so it adapts to `.measurement`-mode levels instead of assuming them |
| Minimum observable pause | `SilenceTracker.minimumGapDuration = 1.5 s` | Rule data (`minimumPauseSeconds`) |
| Resume debounce | `0.3 s` | Rule data |
| Window/hop geometry, SNR gates, coverage floors, baseline minima | n/a | Rule data, per the schema above |

Only values that are **properties of the DSP algorithm itself** stay in code (F0 search range 60–400 Hz, NCCF peak-strength floor, octave-jump rejection, parabolic interpolation) — these are estimator internals, versioned via `estimatorVersion`, not product thresholds. That boundary is stated explicitly so a reviewer can disagree with where it was drawn (**Q2**).

**Migration path to production (U4), concretely:**
1. `SignalRuleMatchType` gains `case numericThreshold = "Numeric Threshold"` (additive; the existing `String`-raw-value Codable conformance decodes old data unchanged).
2. `SignalDetectionRule` gains `var numeric: NumericRuleSpec? = nil` (additive and optional ⇒ existing persisted libraries in `observatory_signal_libraries_v1.json` decode unchanged).
3. Acoustic rules are evaluated by a **sibling** evaluator (`AcousticRuleEvaluator`) consuming `[AcousticMeasurement]`, because `SignalLibraryDetectionEngine.match` takes text and must not be contorted to pretend otherwise. `detect(...)` merges both evaluators' outputs.
4. The prototype's JSON is already shaped as a `SignalLibrary`, so it enters production through the existing `SignalLibraryRegistry.importJSON` path as data — not as a code change.

---

## 6. Acceptance: behavioral milestones with artifact evidence (item d)

Nothing here is satisfied by "the code runs." Each milestone is a **number that could come out wrong**, recorded in a machine-readable artifact.

**The artifact.** Every run emits `U4aMeasurementReport.json` via Swift Testing's `Attachment.record(_:named:)` (confirmed present in the installed Testing framework), so it is extractable from the `.xcresult` bundle exactly the way Hermes extracted E8's callback log. It contains: the run manifest (device/OS/build, estimator IDs + versions, rule-library id + version + `calibrationStatus`), per-source `CaptureProvenance` including file SHA-256, the `AnalysisDomain` with every excluded region and discontinuity bound, every `AcousticMeasurement` with coverage and validity, and every emitted observation with the rule id that selected it. A `[u4a]`-tagged one-line summary per source is also printed, matching the existing `[E8]`/`[E10]` convention so the numbers survive even if attachments are not browsed.

**Privacy, structural not procedural:** the report types have **no field capable of holding transcript text or audio samples** (same technique as U5 §4.3). Channel B contributes frame-level numbers and coverage only — never segment strings.

| ID | Milestone | Where | Passes when |
|---|---|---|---|
| **M1** | **Estimator correctness against known answers.** Synthetic signals generated in-process: pure tones and a glottal-pulse-like harmonic stack at 100/150/220/300 Hz; linear F0 sweeps; amplitude steps of known dB; burst trains with a known nucleus count; alternating speech-like noise and digital silence at known boundaries; the same signals at SNRs of 30/20/10/5 dB | Simulator | F0 within **±1%** of truth on clean signals (reported, with degradation curve, at each SNR); intensity within **±0.5 dB** of the analytic RMS; nucleus count **exact** on clean burst trains; VAD boundaries within **±30 ms**. A miss is reported as a measured limit of the estimator, with the estimator revised — never with the tolerance widened silently |
| **M2** | **Real observations from real recordings — the behavioral milestone.** Run the full Channel-A pipeline over `fixture-solo`, `fixture-multi-a`, `fixture-multi-b`, and at least `9D4F101A…` (U6b, `.incomplete`, 149.4 s) and `4B9A04FD…` (clean, 73.3 s) | Simulator | The attached report contains, for each source: a populated `AnalysisDomain`; ≥1 valid measurement of **each** of F0, intensity, pause, and articulation rate with `contributingFraction ≥ 0.8`; and **≥1 rule-fired observation** on `fixture-solo` (the varied-delivery recording the STABILIZATION plan designates as the Stage 1 correctness fixture) carrying its measurement, window, unit, validity, provenance and rule id. Pre-registered plausibility bands, checked and reported rather than silently passed: voiced fraction of `fixture-solo` in 0.30–0.85; median F0 in 70–300 Hz; articulation rate in 2–8 syll/s. **A value outside a band is a finding to investigate and report, not a test to loosen** |
| **M3** | **Abstention and D-07 invariants.** Negative controls: digital silence; white noise at −50 dBFS; the real **4096-byte orphaned recording** `5FF28F05…` (header only, zero audio frames); a synthetic spliced file built from two fixture excerpts with a known join | Simulator | **Zero** observations from every negative control, each with an explicit `.lowSNR` / `.insufficientCoverage` / `.noAudio` status; no crash on the orphan; the synthetic splice's join lands inside the reported discontinuity bound and every window overlapping it reports `value == nil`; a structural scan of the emitted JSON finds **no `0` in any value field whose validity is not `.valid`**, and no measurement with `.valid` and a `null` value |
| **M4** | **Invariance controls using assets that already exist.** `-identity` vs `-gain` vs base fixtures | Simulator | F0 medians agree within **±1%** between base, `-identity` and `-gain` (F0 must be gain-invariant); intensity differs from base by the **known applied gain** (+12.0 / +15.2 / +18.7 dB per PLAN.md E10b) within ±0.5 dB. This is the check that distinguishes "measures what it claims" from "produces numbers" |
| **M5** | **Channel B coverage — one honest number.** `SFVoiceAnalytics` harvested through the existing replay harness on all three fixtures | **Device**, user-approved, isolated runs per PLAN.md's process note | A reported `voiceAnalyticsCoverage` (B5) per fixture, plus the measured A6↔B2 relationship on co-covered frames. **Any value is a pass**, including near-zero — the deliverable is the number and its interpretation ("`SFVoiceAnalytics` currently covers X% of voiced audio on this device, bounded by E8"), not a threshold |

M1–M4 require **no device approval at all**. M5 is the only device cost: ~6 minutes of fixture audio fed at real time, one trial each ≈ 20–25 minutes including setup.

---

## 7. Implementation location and files (item e)

All new, all in `ObservatoryTests/`:

| File | Contents | Depends on |
|---|---|---|
| `AcousticMeasurementSemantics.swift` | `AcousticMeasurement`, `Unit`, `Coverage`, `Validity`, `AnalysisWindow`, `AnalysisDomain`, `DiscontinuityBound`, `CaptureProvenance`, report types. Pure value types, `Codable`, no AVFoundation | Foundation |
| `AcousticMeasurementPrototype.swift` | Channel A: file reader, frame grid, A1–A18. Deterministic, no recognizer, no network | AVFoundation (file read), Accelerate |
| `AcousticAnalysisDomainBuilder.swift` | §4.3: domain construction from a `ReflectionSession` record + the file, lifecycle bound and signal bound computed separately | `@testable import Observatory` (reads `CaptureCompleteness`, `AudioInterval` — read-only) |
| `AcousticRulePrototype.swift` | Numeric rule schema + `AcousticRuleEvaluator`; the U4 migration shape | Foundation |
| `U4aAcousticRules.json` | The rule data (§5) | test-bundle resource |
| `AcousticMeasurementTests.swift` | M1, M3 (synthetic + orphan) | Testing |
| `AcousticFixtureObservationTests.swift` | M2, M4 | Testing |
| `AcousticVoiceAnalyticsDeviceTests.swift` | M5 | Testing |

**Untouched:** every app-target file; `FixtureReplayHarness.swift` and `AudioFixtureReplayTests.swift` (M5 reads `SFTranscriptionSegment.voiceAnalytics` through a *new, additive* callback parameter only if the harness genuinely cannot expose it otherwise — if so it is flagged for approval before the edit, since E1–E10's comparability depends on that file's existing paths staying byte-identical); the read-only fixtures.

**Session-audio access without putting recordings in the repo.** The smoke-test `.caf` files and `completed_reflections_v1.json` live in `~/Developer/Observatory-device-backups/…`, outside the working tree, and must stay there (`.gitignore` only covers `ObservatoryTests/Fixtures/*.caf`). Proposed mechanism: an environment variable `OBSERVATORY_U4A_SESSION_BACKUP_DIR` naming a backup directory; when unset or unreadable the session tests **skip** (Swift Testing `withKnownIssue`/early return with a recorded reason) rather than fail, so the suite stays green on any other machine and nothing sensitive is ever copied, committed, or logged.

---

## 8. What this unit explicitly will not do

- No transcript content, no word timings, no diarization, no speaker attribution (U3).
- No interpretation, no emotion label, no "probability," no severity score (Stage 2).
- No UI (Stage 2), no production-target file (U4), no change to the recognizer (U5), no change to capture-side DSP (the STABILIZATION plan forbids assuming one).
- No re-recording of fixtures (E7 stays deferred), no new package dependency, no external service (D-04).
- No `.prolongedSoundCandidate` (§3.4 — transcript-dependent by definition).
- No claim of perceptual, emotional, or clinical validity. None is possible without reference annotation, which does not exist.

---

## 9. Exit criteria for this unit

1. M1–M4 green on **simulator**, reported as real counts alongside the existing suite total (currently 62 logic tests) — not "should pass."
2. `U4aMeasurementReport.json` attached to the run and **verified by Hermes from the `.xcresult` bundle**, containing real measurements from at least the three fixtures and two real sessions, one of which is `.incomplete`.
3. The U6b session's report shows a correctly split `AnalysisDomain`, with the lifecycle-derived and signal-derived discontinuity bounds reported separately and their agreement or disagreement stated — including whether the ≈32.4 s arithmetic or PLAN.md's 54.1 s word timing is the one the audio supports.
4. Zero fabricated values: no `0`-as-unknown anywhere in the artifact, all four §4.1 invariants test-enforced.
5. Determinism: the same input produces a byte-identical report modulo timestamps, test-enforced.
6. M5 run on device with user approval, its coverage number reported honestly whatever it is.
7. A written statement, per CONVENTIONS.md, separating measured/tested (estimator correctness, invariance, abstention) from integration-tested-but-not-validated (real-recording measurements) from entirely unverified (anything perceptual).
8. Exit protocol: PLAN.md, STABILIZATION Status line, `VERSION_HISTORY.txt`, a DECISIONS entry if the review settles the §4.3 discontinuity semantics.

**A valid, non-failure outcome:** if Channel A turns out to measure the fixtures poorly — e.g. `.measurement`-mode levels at −46.5 dBFS (solo) leave too little SNR for reliable F0 — the honest result is "transcript-independent acoustic measurement on *these* recordings is SNR-limited; capture-side conditioning is a prerequisite," which is a real finding that reframes U2 and E7, not a failed unit. The design reports it with numbers rather than producing confident garbage.

---

## 10. Questions for the reviewer (D-15)

**Q1 — Is the two-channel split accepted, including the deliberate deviation from the STABILIZATION plan's "no DIY pitch tracker" line?** §2 argues `SFVoiceAnalytics` cannot satisfy transcript-independence by construction, and that M1/M4 supply the validation the plan's objection demands. If the reviewer disagrees, the alternative is a DSP-only unit with no pitch at all (intensity/pause/rate only) until U5 repairs recognition — materially smaller, and a legitimate call to make now rather than after implementation.

**Q2 — Is the code/rule-data boundary drawn in the right place?** §5 keeps F0 search range, NCCF peak floor and octave-jump rejection in code as estimator internals while moving every gate, window, and threshold to rule data. A stricter reading of D-16 would push the search range into data too.

**Q3 — Discontinuity semantics (schema question, Q3/D-17 precedent).** §4.3 proposes that an `.incomplete` session's file be treated as **spliced**, with a bounded-uncertainty discontinuity region, domain splitting, and no wall-clock mapping. Two sub-questions: (a) is that the right measurement semantics under D-18; (b) should the eventual production record carry an explicit discontinuity field on `ReflectionSession` (set from lifecycle evidence at recovery time, when the splice offset is *actually known* rather than reconstructed) — which would make U4's version exact instead of inferential? U4a does not add it; it proposes it for U4.

**Q4 — Channel-B unit handling.** §3.3 refuses to convert `SFVoiceAnalytics.pitch` ("expressed as a logarithm," base/reference unspecified) into Hz by assumption, reporting the measured A6↔B2 relationship instead. Confirm that is preferred over picking a plausible base.

**Q5 — Two mechanical approvals.** (a) Adding `U4aAcousticRules.json` as a test-bundle resource requires a `project.pbxproj` edit — routine (the fixtures are already resources) but out of the stated file scope, so it is requested rather than assumed. (b) The `OBSERVATORY_U4A_SESSION_BACKUP_DIR` mechanism in §7 for reaching smoke-session audio that must not enter the repo.

**Q6 — Scope question that is the user's, not an agent's.** iOS 26+ `SpeechDetector` is a transcript-free voice-activity-detection module that could serve as an independent cross-check on A5 at essentially no cost. It sits inside the `SpeechAnalyzer` family that DECISIONS.md lists as out of scope — though that exclusion was written about *transcription* A/B migration, not VAD. Flagged, not assumed, exactly as PLAN.md flags the recognizer-choice question.

---

## 11. Sequencing

1. This proposal → **ChatGPT review (D-15)** → director (Hermes) review from disk → Q1–Q6 answered.
2. Implement §7's files; run M1, M3, M4 on simulator; report real numbers.
3. Run M2 on simulator; attach the report; Hermes verifies it against the `.xcresult` bundle.
4. M5 on device with explicit user approval, isolated test action, container backup precaution per the prior units.
5. Honest scored report → CONVENTIONS.md exit protocol.
6. Production integration (`Models.swift` additive fields and kinds, `SignalRuleMatchType.numericThreshold`, `AcousticExpressionEngine.swift`, store wiring) stays **U4**, with its own proposal and review.

---

ChatGPT Reply:

1. **Q1 — Accept the two-channel design and the explicit plan deviation, subject to the changes below.**

   Channel A is the right primary architecture for transcript-independent analysis. Repairing recognition in U5 would not remove Channel B’s dependency on recognition, so the pitch-free fallback is not preferable merely to preserve the original plan wording.

   However, **M1/M4 are proposed checks, not validation evidence already obtained.** Passing them would establish synthetic accuracy and selected invariances—not reliable F0, syllable counts, or behavioral measurement on spontaneous recordings. Describe Channel A as an experimental estimator undergoing verification. “Validated detector” currently overstates the evidence.

   Also withdraw the claim that Channel B’s acoustic coverage is necessarily bounded by E8’s **word-recovery percentage**. E8 establishes a serious recognition-output defect. It does not establish that result-level acoustic arrays cover the same proportion of audio. That relationship remains to be measured.

2. **Q2 — Revise the code/data boundary.**

   Keeping interpolation and the NCCF implementation in code is reasonable. But the search range, peak-strength floor, smoothing, and octave-jump limits determine which voices and behaviors become measurable. They are consequential measurement parameters, even when called estimator internals.

   Require a **versioned estimator configuration**, distinct from observation-selection rules, containing those parameters. Record its values and hash in the report. Under the stated D-16 requirement, configurable numeric thresholds belong in data; an estimator version alone does not make them auditable.

   Resolve the direct contradiction: A6 calls the peak-strength floor “rule-data,” while §5 puts it in code.

   The 60–400 Hz range also needs explicit domain handling. Out-of-range periodic speech must not silently become “unvoiced.” Likewise, octave-jump rejection must not silently erase genuine abrupt pitch changes.

3. **Q3 — Accept the exclusion principles; reject the current inference as sufficient to establish safe spans.**

   **(a)** File-relative analysis, exclusion around uncertain joins, and no cross-join pause/rate/trend claims are appropriate. But several corrections are necessary:

   - **`.incomplete` does not universally mean spliced.** It can describe a truncated prefix or other missing-capture patterns. U6b’s reported recovery establishes a splice for that recording; the enum alone does not.
   - **The two duration calculations are algebraically dependent.** Given the assumed T+65 recovery, `149.4 − (182 − 65) = 32.4`; the missing-duration calculation rearranges the same inputs. Their agreement is not independent corroboration.
   - Recognition-restart timestamps are not necessarily capture-resumption timestamps. State the assumptions and bound their uncertainty.
   - Near-digital silence can exist in captured audio without marking a splice; a splice can leave no detectable waveform signature. Noise-floor changes are candidate evidence, not guaranteed join detectors.
   - Missing wall time is **unobserved behavior**, not an established 32.6-second human pause.

   Specify the disagreement policy before implementation. Preserve each evidence source separately; exclude every location still plausibly containing the join, including processing guards. If the evidence cannot support a bounded location, abstain from affected temporal measurements across the unresolved region—even if that leaves little usable audio. Do not manufacture two “safe” spans to satisfy M2.

   Treat `nil` completeness as **unknown provenance**, not equivalent to confirmed complete capture. Also establish the coordinate system of `missingAudioIntervals` before subtracting them from file-relative spans.

   **(b)** Yes: production should persist **capture discontinuity events at recovery**, preferably writer-owned sample offsets plus monotonic capture times before and after the gap, reason, uncertainty, and clock identity. Support multiple events. A recognizer callback timestamp is insufficient. Recording this prospectively should precede production use of splice-sensitive measurements.

   Correct the CAF duration to frame-count-derived seconds, as Hermes requests.

4. **Q4 — Confirm raw-unit reporting; qualify any inferred mapping.**

   Do not choose a plausible logarithm base or reference. Preserve the raw feature, its documented description, and its access path.

   A clean fitted relationship would be an **empirical mapping for the tested API/device/OS/configuration**, not proof of Apple’s universal unit definition. Fit only independently aligned frames, report residuals and sample coverage, and test on held-out material. Channel A’s errors remain a limitation of that comparison.

5. **Q5 — Use result-level metadata as primary; permit alignment to be unavailable.**

   Use `speechRecognitionMetadata.voiceAnalytics` as the primary path. Deprecated segment-level analytics may be collected as an optional compatibility diagnostic, with separate reporting. Do not merge the paths.

   Before implementation, specify:

   - **Result handling:** request/chunk identity, partial versus final policy, revisions, deduplication, and failure handling. Multiple callbacks must not inflate coverage.
   - **Input mapping:** the actual source sample interval submitted to each request, including any resampling or inserted audio.
   - **Feature mapping:** each feature’s array length, frame duration, temporal origin, gaps, and alignment uncertainty. Apple exposes frame duration and per-frame values; those fields alone do not establish the array’s origin in the source file. [Apple documentation](https://developer.apple.com/documentation/speech/sfacousticfeature)
   - **Alignment verification:** use known input regions and controlled leading-silence/offset variants to test the proposed mapping. Do not infer it from suspect word timestamps, callback arrival, or whichever offset maximizes A/B agreement.
   - **Failure semantics:** if alignment cannot be established, B5 and frame-wise A/B comparison are unavailable. Report array availability and duration descriptively instead.

   Define B5 per feature. Let **V** be the union of Channel-A valid voiced intervals within the eligible analysis domain, and **Bₖ** the union of independently anchored, usable intervals for Channel-B feature *k*:

   **Coverageₖ = duration(V ∩ Bₖ) / duration(V).**

   Count overlaps once. Exclude unanchored intervals. Report the numerator, denominator, alignment uncertainty, and Channel-A voicing coverage alongside the ratio. Zero voiced denominator means `nil`; established absence of feature coverage with a positive denominator means a legitimate zero.

   This is **coverage of A-detected voiced audio**, not independently known coverage of all human speech. M5 must allow “unmeasurable because alignment is unresolved” as an honest outcome. Requiring one number regardless would violate D-07.

6. **Q6 — Several measurement and acceptance definitions need correction.**

   **The largest defect is equating unvoiced audio with pauses.** A5’s periodicity gate rejects unvoiced speech as well as noise and silence. Therefore:

   - A9 cannot define pauses simply as runs of `A5 == false`.
   - A11’s “window minus qualifying pauses” is not phonation time.
   - A13 inherits that denominator error.

   Separate speech activity, periodic voicing, pause candidates, and unknown regions. If U4a cannot distinguish them sufficiently, report narrower acoustic proxies. A noise burst also should not be expected to satisfy a periodic-voicing positive control: M1 currently conflates VAD and voicing.

   **Low level is not low SNR.** A mean of −46.5 dBFS alone cannot establish SNR limitation. Flat gain raises signal and noise together. The 10th-percentile floor is a heuristic that may select mic-mute samples or speech energy, depending on the recording. Validate it on known mixtures and changing backgrounds; call A4 a floor-relative level proxy unless stronger SNR evidence exists. A capture-conditioning prerequisite requires evidence beyond low amplitude or failed F0 extraction.

   **A8 needs a precise adaptation specification.** The original De Jong–Wempe study already tested spontaneous Dutch speech, so this is not simply transfer from read speech. It also reported missed, principally unstressed syllables. Your changed envelope, timing, filtering, and voicing implementation require their own checks. Until reference-scored, label the outputs **detected nucleus rate / estimated syllable rate**, and do not import the paper’s correction factor. [Original paper](https://www.fon.hum.uva.nl/archive/2009/2009-brm-JongWempe.pdf)

   **Coverage must be metric-specific.** Requiring contributing voiced frames to occupy 80% of all analyzed frames can reject an otherwise good window merely because it contains pauses. Separate domain coverage, eligible-frame coverage, and successful estimation among eligible frames. Report absolute contributing seconds too. Unknown frames must not be counted as silence. Overlapping frames/windows must not multiply elapsed-time coverage.

   **Specify full estimator support.** A shared 10 ms hop does not make 25 ms and 40 ms frames identical. Define centers, rounding, edge handling, filter context, smoothing, and guard widths. Reset state at joins; noise-floor and baseline estimation must also stay within spans. Add tests at 60/400 Hz boundaries, missing fundamentals, abrupt legitimate pitch changes, and periodic non-speech confounds. Synthetic F0 accuracy must be reported alongside rejection and octave-error rates, so abstention cannot hide failures.

   **Revise the acceptance contradictions:**

   - M2 cannot simultaneously require valid examples of every metric from every source and allow an SNR-limited successful outcome. Define a full-demonstration outcome and an evidence-supported limitation outcome.
   - Do not require a real fixture to fire an uncalibrated rule. Verify rule firing with a controlled positive case; report real-fixture firing or non-firing without threshold tuning to force success.
   - A synthetic splice is not inherently a negative recording. Require abstention across the join, while allowing valid observations within safe spans. Include a seamless splice control that demonstrates when audio alone cannot localize a join.
   - Missing backup access may skip locally, but a skipped session cannot satisfy unit exit evidence.
   - Five-second windows and the plausibility bands are acceptable preregistered exploratory settings, not validation. Define minimum usable duration and boundary-event counting.

   **Tighten the schema.** Digital silence makes `log10(0)` non-finite: define its representation without inventing a physical floor. Require finite numeric values, explicit nulls, bounded counts, and legitimate-zero tests. Keep quality flags alongside a primary validity reason. `.valid` should mean “passes this prototype’s operational gates,” not clinically validated.

   Remove the unexplained A5 “confidence 0–1,” and keep `.reducedArticulationUnsupported` in a capability/status record rather than the observation stream. A global semitone reference is not mathematically required for within-window F0 spread; keeping multi-speaker exclusions is conservative, but record speaker mixture honestly rather than disguising it as insufficient baseline duration.

   Limit byte-identical determinism to a pinned environment and canonical analysis payload. Record environment differences separately. Finally, report schemas with string fields are not structurally incapable of leaking text: use constrained fields, sanitized errors, and explicit checks against transcript/sample inclusion.

   I accept Hermes’s `SpeechDetector` disposition as a **reported local SDK finding**, not an independently verified fact here. It need not expand U4a.

7. **Overall verdict — APPROVE WITH CHANGES; the current proposal is not implementation-ready.**

   Approve the transcript-independent architecture and test-only scope. Before implementation, revise the proposal to settle **speech/voicing/pause semantics, unresolved-splice abstention, estimator configuration, Channel-B alignment and unavailable outcomes, metric-specific coverage, and consistent exit criteria**.

   This review evaluates the supplied proposal and reported artifact findings; it does not independently verify the recordings, SDK inventory, or prior device results. No code changes are requested.