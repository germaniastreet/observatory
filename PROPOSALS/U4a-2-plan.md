# U4a-2 plan — Channel B (SFVoiceAnalytics alignment ladder + coverage, M5) with the E7 re-record proposal

**Status: PLAN ONLY — awaiting director (Hermes) review from disk.** Nothing has been implemented, committed, or run. Written 2026-10-24 by Claude.

**Spec:** `PROPOSALS/U4a-proposal.md` Revision 2, §8 and §9 M5. Frozen per director ruling D3: everything below is an addition or a *proposed* amendment, never an edit to the spec. **Scope:** `ObservatoryTests/` and test resources only. No production-target file. The three original fixtures are read-only baselines (D-10).

**Owner rulings recorded so far (2026-10-24):**
- **Q1, harness edit:** approved **in principle**, strictly additive, existing functions untouched. **Director to ratify from this plan.**
- **Q2, amendments A5–A9:** **NOT accepted by the owner** (correctly — the owner is the wrong adjudicator). They appeared here as *proposals only*; the **director (Hermes)** ruled on each against the frozen spec — see the ruling appended at the end of this file (2026-10-25: **A5–A9 ACCEPTED as proposed**, with one added manifest-hashing condition).
- **Q3, E7 multi-speaker logistics:** left to Claude. Claude picks **playback through a second device** (§5), matching the owner's recommendation.

---

## 1. Pre-implementation findings and flags

**SDK, checked against the installed Xcode `iPhoneOS.sdk` Speech headers:**
- `SFSpeechRecognitionMetadata.voiceAnalytics` (nullable) is the result-level primary path. It sits beside `speechStartTimestamp`, `speechDuration`, `speakingRate` and `averagePauseDuration`.
- `SFTranscriptionSegment.voiceAnalytics` is `NS_DEPRECATED(… 14_5, "voiceAnalytics is moved to SFSpeechRecognitionMetadata")`.
- `SFAcousticFeature` exposes only `acousticFeatureValuePerFrame` and `frameDuration`. No origin field exists, which confirms §8.4's premise.

**U4a-1 parts reused unchanged:**
- `U4aHarness` (config and rules loading, `RunManifest`, `Attachment.record`)
- `AudioSignalLoader`
- `AcousticAnalysisDomainBuilder` for the eligible domain
- `AcousticAnalyzer.analyzeSpan` → `SpanFrames.state` / `.f0`, which gives the Channel-A voiced intervals V and A6 at the 10 ms hop (`U4aEstimatorConfig.json` `hopMs: 10`)
- the existing `UnavailableReason.alignmentUnresolved` and `AcousticUnit.rawUnspecifiedLog`

**No U4a-1 file is modified**, so its canonical payload stays byte-identical.

**Flag 1 — the per-fixture number is conditional.** Under §8.5/§9 M5, Arm 2 runs, and a B5 ratio is permitted, **only if Arm 1 reaches O-B1**. Under O-B2, each fixture's honest value is `unavailable(.alignmentUnresolved)` plus descriptive array statistics. Under O-B3, the report states that no analytics were returned. All three outcomes pass. Reporting a coverage number without established alignment fails.

**Flag 2 — harness edit (§10 requires approval; owner-approved in principle, director to ratify).** The voice-analytics harvest has to share `FixtureReplayHarness`'s `private` feed helpers (`appendAudio`, `appendSilence`, `probeEngine`). It also has to listen past the first final, which `runSingleRequest` does not do. The proposal is one **additive** entry point in `FixtureReplayHarness.swift`. Every existing function, including its instrumentation, stays byte-identical, so E1–E10 stay comparable. The director can verify this with `git diff`: the diff should contain only added lines.

**Flag 3 — §11 vs E7.** §11 says "No fixture re-recording (E7 deferred)". This plan only *proposes* E7 (§5), per PLAN.md's later ride-along decision. Recording is a separate owner-approved action.

---

## 2. Proposed pre-registration amendments A5–A9 (DIRECTOR-RULED 2026-10-25: ACCEPTED as proposed — see ruling at end of file)

§8 leaves the following parameters unspecified. If ruled acceptable, they would be frozen in `ObservatoryTests/U4a2ChannelBConfig.json` and committed **before any device run** (D3). Each one carries its reason inline. **Until the owner rules, none of these exist as a file.**

| # | Gap in §8 | Proposed value | Reason |
|---|---|---|---|
| **A5** | Ladder passage and rungs | `fixture-solo-loudnorm`, 38.0–50.0 s (frames 1,824,000 ..< 2,400,000 at 48 kHz). Leading silence 0/5/10/20 s (the §8.5 values), no trailing silence. Rung 0 replicated once | §8.5 requires "one audible passage" but names none. This is the E9 secondary passage (`AudioFixtureReplayTests.diagnosticShortPassageControlSecondarySolo`): single speaker, full word recovery at every position (20/20/18). The loudnorm variant is used because E9 established recovery on it; the ladder compares B against B only, so the altered level does not enter any amplitude claim |
| **A6** | How the shift of the voiced region is measured | **B-to-B lag.** Normalized cross-correlation of each rung's **voicing** array against rung 0's, over the full lag range, never centred on the prediction. **Pitch** lag is computed the same way as corroboration | Avoids every §8.5 banned source: no A/B agreement, no word timestamps, no callback times |
| **A6 rule** | Pass condition for O-B1 | (i) For every rung k ∈ {5, 10, 20}: \|voicing lag − k\| ≤ 1 `frameDuration`. (ii) For every rung including 0, and every feature: \|count × `frameDuration` − fed duration\| ≤ 1 `frameDuration`. (iii) Voicing and pitch lags agree within 1 frame. **Any failed or missing rung, or a disagreement between voicing and pitch lag, ⇒ O-B2.** No analytics on any rung ⇒ O-B3. `alignmentUncertaintySeconds` = max residual across rungs and features (including the rung-0 replicate's lag against rung 0), floored at one `frameDuration` | Conservative by construction: O-B1 can only be reached, never argued into |
| **A7** | Request lifecycle | Ladder: one request per rung (≤ 32 s fed). Arm 2: contiguous, non-overlapping ≤ 55.0 s chunks, matching E3 and production rollover. Consume callbacks until the task ends or **5.0 s after the last final**, so superseded finals can be counted. Timeout = max(120 s, fed + 60 s), matching `replay`. Request flags, session and format match the existing harness: on-device recognition, partial results, punctuation, `.record`/`.measurement`/`.duckOthers`, live-tap format. Errors, including 1110, are caught and the run continues → `chunkOutcome: .failed(code)` | §8.3's "last final per request wins" is untestable if listening stops at the first final. The 55 s chunk length has E3 precedent |
| **A8** | Frame matching for A6↔B2 | Map each B frame centre to the Channel-A 10 ms hop slot that contains it. A frame is used only if all of these hold: A state = `voiced`; A's F0 is non-nil; B's value is finite; and A is `voiced` throughout ± max(`alignmentUncertaintySeconds`, B `frameDuration`) | §8.6 requires fitting "only independently aligned voiced frames". The guard excludes pairings that alignment uncertainty makes ambiguous at voicing boundaries |
| **A9** | Form of the A6↔B2 fit | OLS B2 ~ a + b·ln(F0_A in Hz), leave-one-fixture-out, **all 3 rotations**. Report a, b, R², residual SD, Spearman ρ, held-out RMSE and held-out bias, n_fit and n_test. Fewer than 200 matched frames in any fixture ⇒ that rotation is `unavailable(insufficientEligibleSeconds)` | §8.6 says "fit on two, test on the third" but names no model. Running all three rotations is a documented superset. B2 stays `.rawUnspecifiedLog` and is never converted to Hz (§8.6) |

**B5 as it would be implemented** (§8.7, unchanged — not an amendment):
- Coverageₖ = dur(V ∩ Bₖ) ÷ dur(V), computed as unions of intervals, so overlaps count once.
- It is computed for each of pitch, jitter, shimmer and voicing.
- Two variants are reported, both labelled per §8.3: **whole eligible domain** and **successfully processed fed intervals only**.
- "Usable" means a present and finite value (§8.7). Exact-zero fractions are reported separately.
- dur(V) = 0 ⇒ `nil`. A positive denominator with established zero overlap ⇒ a legitimate `0.0`.
- Every value carries numerator, denominator, `alignmentUncertaintySeconds`, Channel-A voicing coverage, and the statement "coverage of A-detected voiced audio, not of all human speech".

**Draft frozen JSON** (would become `ObservatoryTests/U4a2ChannelBConfig.json` only after the owner rules; values shown exactly as proposed):

```json
{
  "configID": "u4a2.channelB.default",
  "configVersion": "0.1.0",
  "specBase": "PROPOSALS/U4a-proposal.md Revision 2, sections 8 and 9 M5 (pre-registered at 5d83779)",
  "ladder": {
    "_amendment": "A5",
    "_reason": "Section 8.5 requires one audible passage but names none. E9 secondary passage: single speaker, full word recovery at every position (20/20/18).",
    "passageSource": "fixture-solo-loudnorm",
    "sourceSampleRateHz": 48000,
    "passageStartFrame": 1824000,
    "passageEndFrame": 2400000,
    "leadingSilenceSeconds": [0, 5, 10, 20],
    "trailingSilenceSeconds": 0,
    "replicateRungs": [0]
  },
  "alignment": {
    "_amendment": "A6",
    "_reason": "Section 8.5 predicts a shift of the voiced region but does not define its measurement. B-to-B lag over the full range avoids all three banned sources (word timestamps, callback arrival, A/B-agreement-maximizing offset).",
    "lagMethod": "normalizedCrossCorrelation",
    "referenceRung": 0,
    "primaryFeature": "voicing",
    "corroboratingFeature": "pitch",
    "lagSearch": "fullRange",
    "nonFiniteHandling": "excludeFrameFromCorrelation",
    "lagToleranceFrames": 1,
    "durationToleranceFrames": 1,
    "featureLagDisagreementOutcome": "O-B2",
    "missingOrFailedRungOutcome": "O-B2",
    "noAnalyticsOnAnyRungOutcome": "O-B3",
    "uncertaintyFloor": "oneFrameDuration"
  },
  "requestLifecycle": {
    "_amendment": "A7",
    "_reason": "Section 8.3's last-final-wins and superseded-final counting require listening past the first final; 55 s chunking matches E3 and production rollover.",
    "ladderRequestsPerRung": 1,
    "arm2ChunkSeconds": 55.0,
    "arm2ChunkBoundary": "contiguousNoOverlap",
    "postFinalGraceSeconds": 5.0,
    "timeoutSeconds": { "minimum": 120, "fedPlus": 60 },
    "requiresOnDeviceRecognition": true,
    "shouldReportPartialResults": true,
    "addsPunctuation": true,
    "audioSession": { "category": "record", "mode": "measurement", "options": ["duckOthers"] },
    "matchLiveTapFormat": true,
    "errorPolicy": "catchAndContinueRecordFailed"
  },
  "frameMatching": {
    "_amendment": "A8",
    "_reason": "Section 8.6 requires fitting only independently aligned voiced frames; the boundary guard removes pairings that alignment uncertainty makes ambiguous.",
    "mapping": "bFrameCentreToContainingChannelAHopSlot",
    "channelAHopMs": 10,
    "requireChannelAState": "voiced",
    "requireChannelAF0": true,
    "requireBFinite": true,
    "boundaryGuard": "max(alignmentUncertaintySeconds, bFrameDuration)"
  },
  "fit": {
    "_amendment": "A9",
    "_reason": "Section 8.6 names a fit with a held-out split but no model; running all three leave-one-out rotations is a documented superset of fit-on-two-test-on-third.",
    "model": "OLS: B2 = a + b * ln(F0_A_Hz)",
    "heldOut": "leaveOneFixtureOut",
    "rotations": 3,
    "fixtures": ["fixture-solo", "fixture-multi-a", "fixture-multi-b"],
    "minimumMatchedFramesPerFixture": 200,
    "report": ["a", "b", "r2", "residualSD", "spearmanRho", "heldOutRMSE", "heldOutBias", "nFit", "nTest"]
  },
  "coverage": {
    "_note": "Section 8.7 restated as data, not an amendment.",
    "features": ["pitch", "jitter", "shimmer", "voicing"],
    "usable": "presentAndFinite",
    "reportExactZeroFractionSeparately": true,
    "variants": ["wholeEligibleDomain", "successfullyProcessedFedIntervals"],
    "zeroDenominator": "nil"
  }
}
```

If the owner rejects or changes any item, the changed value and the ruling's date go into that item's `_reason` before the file is committed.

---

## 3. Files (all in `ObservatoryTests/`)

| File | Contents |
|---|---|
| `VoiceAnalyticsHarvest.swift` (new) | Codable records, numbers only, no transcript text. They hold: the §8.2 per-request input mapping (sourceID, requestIndex, fed sample range `[start, end)`, source rate, submitted format, resample ratio, inserted-silence intervals, feed order); a per-callback audit `(callbackIndex, isFinal)`; per-final feature arrays plus result metadata; a **separate** deprecated segment-level diagnostic key (segment timestamp and duration plus arrays, no substrings, never merged and never used for B5); `chunkOutcome` (`.succeeded` / `.failed(code)`); a superseded-final count |
| `FixtureReplayHarness.swift` (**additive only**) | `harvestVoiceAnalytics(audioURL:feedPlan:)`, where the feed plan is an ordered list of `.source(range)` / `.silence(seconds)` items. It reuses the existing private feed helpers. No existing line changes |
| `ChannelBAnalysis.swift` (new) | Pure functions: interval union; §8.4 per-feature mapping stats; the A6 ladder classifier → O-B1/O-B2/O-B3; §8.7 B5 (both variants); the A8 matcher; the A9 fit; O-B2 descriptive statistics (array counts, `frameDuration`, value distributions, finite/non-finite fractions, exact-zero fractions per feature) |
| `U4a2ChannelBConfig.json` (new, **only after the owner rules on §2**) | The ruled values, loaded and SHA-256-hashed into the report manifest |
| `ChannelBAnalysisTests.swift` (new) | Simulator tests on synthetic arrays (listed below), plus the **assessment test** |
| `AcousticVoiceAnalyticsDeviceTests.swift` (new; the §10 name) | One test per ladder rung, one for the rung-0 replicate, and one per fixture. Each **only harvests** and attaches raw JSON (`U4a2Harvest-<id>.json`). They compile out on the simulator via `#if targetEnvironment(simulator)`, so the simulator suite total stays comparable (currently 85 tests, with 8 pre-existing environmental failures) |

The synthetic-array tests in `ChannelBAnalysisTests.swift` cover:
- a constructed O-B1
- a constant-lag O-B2, an array shorter than fed audio, and a disagreement between voicing and pitch lag, each ⇒ O-B2
- an empty result ⇒ O-B3
- B5 `nil` on a zero denominator, and a legitimate `0.0`
- overlapping chunks counted once
- a failed chunk appearing in both B5 variants
- superseded-final counting
- a known synthetic log relation recovered by the fit, including the held-out step
- the under-200-frames path to unavailable
- the shared schema scan (finite values only, explicit nulls, `value != nil ⟺ .valid`)

The **assessment test** loads the extracted harvest JSONs from `$OBSERVATORY_U4A_SESSION_BACKUP_DIR/u4a2-device-results/`. That reuses the existing env var, so no xctestplan edit is needed. It skips rather than fails when the folder is absent, but it **must execute** for exit evidence (R6.10 precedent). It then:
- computes Channel A on the simulator over the same files
- classifies the outcome
- computes B5 and the fit when the outcome is O-B1
- attaches `U4a2ChannelBReport.json` with the U4a-1 `RunManifest` and `[u4a2]` summary lines

**Design consequence:** the device only harvests. All classification and math are deterministic, can be re-run without the device, and can be verified by the director from the xcresult.

---

## 4. Device session plan

All runs are **isolated actions** (PLAN.md process note on back-to-back contamination). **Each action below needs the owner's explicit approval, separately.** The budget is about 35–45 minutes (ruling D2). No device action happens before: the owner's §2 ruling, the director's review of this plan, the config commit, and a green simulator suite.

| # | Action | Executed by | Est. |
|---|---|---|---|
| D0 | Back up the app container → `~/Developer/Observatory-device-backups/pre-U4a2-build-<timestamp>/` | Hermes (CLI) | ~3 min |
| D1 | Build and install the test bundle on the iPhone 16 Pro (`00008140-000E28EA22D8401C`) | Hermes (CLI) | ~4 min |
| D2 | Ladder rung 0 s (one isolated `-only-testing` invocation) | Hermes | ~2 min |
| D3 | Ladder rung 5 s | Hermes | ~2 min |
| D4 | Ladder rung 10 s | Hermes | ~2.5 min |
| D5 | Ladder rung 20 s | Hermes | ~2.5 min |
| D6 | Rung-0 replicate (checks drift and contamination) | Hermes | ~2 min |
| — | Extract the xcresults → `u4a2-device-results/`, then run the simulator assessment. **Gate: D7–D9 run only on O-B1** | Hermes + Claude, no device | — |
| D7 | Arm 2: `fixture-solo` (91.1 s, 2 chunks) | Hermes | ~3 min |
| D8 | Arm 2: `fixture-multi-a` (167.5 s, 4 chunks) | Hermes | ~4.5 min |
| D9 | Arm 2: `fixture-multi-b` (95.7 s, 2 chunks) | Hermes | ~3 min |

- **Total:** about 31 minutes, which leaves slack for one isolated re-run.
- **Known risk:** 20 s of leading digital silence may trigger error 1110 on D5. It would be recorded as `.failed` and lead to O-B2 under A6. It is not retried away.
- **No post-run container snapshot** is needed: the harness never writes into the production Audio directory. One can be added as D10 on request.
- **Budget interaction:** if E7 recording rides this budget, it adds about 10–15 minutes. It needs its own separate approvals (§5) and is not part of D0–D9.

---

## 5. E7 — fixture re-record proposal (propose only; no recording before owner approval)

### 5.1 What the originals are

This comes from the device backup `pre-test-run-20261021-195258/completed_reflections_v1.json`, metadata only; no transcript text was read.

| Fixture | Matching session (by start time and length; inferred, not proven) | Diarization at the time | Reference word count used |
|---|---|---|---|
| `fixture-multi-a` 167.5 s | 2026-10-15 13:51:26 PDT (`2EA33A1A…`), 169 s wall | user + Speaker A + Speaker B | 288 |
| `fixture-solo` 91.1 s | 13:54:52 PDT (`058ED3B4…`), 92 s wall | user only | 149 |
| `fixture-multi-b` 95.7 s | 13:56:35 PDT (`7FD1C197…`), 97 s wall | user + A + B | 192 |

- All three are 1 ch / 48 kHz / Float32, the same format as current sessions (checked against U6b `9D4F101A…`).
- All three were recorded about an hour **before** commit `3c46d9b` (14:52), during its "several iterations" of category/mode tuning. Their exact capture configuration cannot be recovered; U4a-1 already labels them `unverifiedPreTuning`.
- **Not recorded anywhere in the repo:** who or what the second voice was, what was said, and how far the mic was from each speaker. The solo fixture is described only as "varied-delivery". Anything the owner remembers goes into the v2 provenance as "original-set notes".

### 5.2 Proposed v2 set (new files only; originals untouched per D-10)

- **Files:** `fixture-solo-v2.caf`, `fixture-multi-a-v2.caf` and `fixture-multi-b-v2.caf` go in `ObservatoryTests/Fixtures/`. They are gitignored, like all `.caf` files.
- **Recording and transfer:** each is recorded through the production app under the current `.record`/`.measurement` config, on the same iPhone 16 Pro. Hermes copies it out of the container (with a container backup first).
- **Provenance:** a tracked sidecar `<name>.provenance.json` holds:
  - date and time, device and OS build, app commit
  - capture config (category/mode/options, as read from `SpeechRecognitionManager.swift` at that commit)
  - speakers as roles (`owner-live`, `playback`), never names
  - the playback device, its volume setting, and the distance from the iPhone
  - room description, owner-to-mic distance
  - script ID and reference word count
  - source session UUID and its `captureCompleteness`
- **Content — scripted, non-personal, and committed to the repo** as `ObservatoryTests/Fixtures/scripts/` text. A reference transcript then exists for U5's aligned scoring:
  - **Solo, about 90 s (owner live, no playback):** normal, fast, slow/stretched, quiet and loud sections, with inserted pauses of 1/2/4 s. Those pauses also give U5 the speech–pause–speech controls E9 never ran.
  - **Multi-a, about 165 s:** two-voice turn-taking with one short deliberate overlap.
  - **Multi-b, about 95 s:** dense back-and-forth with backchannels.

### 5.3 Logistics — chosen: playback through a second device

The owner left the choice to Claude. Playback is chosen because it needs no scheduling and allows repeatable takes.

- **Second voice:** a pre-made playback track of the "other speaker" lines, with scripted gaps where the owner speaks live. The other-speaker lines are spoken by a distinct voice, in one of two ways:
  - **(i) Preferred:** a consenting second person records the lines once, asynchronously, on their own time.
  - **(ii) Fallback:** on-device text-to-speech (`AVSpeechSynthesizer`) on the second device. This is local only, so D-04 is respected.
- **Setup:** the second device plays through its own loudspeaker at a fixed, recorded distance (proposed 1.5 m) and volume. The owner sits at a fixed distance (proposed 0.5 m). The overlap cue is printed in the script.
- **Honest limitation, recorded in provenance:**
  - Loudspeaker playback is acoustically not a live voice.
  - The playback speaker's segments are flagged `playbackSource`, and are excluded from any voice-quality (jitter/shimmer/F0) claim about a human speaker.
  - If option (ii) is used, they are also flagged `syntheticVoice`.
  - The owner's live segments carry no such flag.
- **Device actions (separate approvals, not part of D0–D9):**
  - E7-0: container backup
  - E7-1/2/3: the three recordings, solo first
  - E7-4: container copy-out by Hermes

### 5.4 Not in this unit

Arm 2 on the v2 fixtures. That would be a later amendment.

---

## 6. Sequence

1. **Now: pause.** The director (Hermes) reviews this plan from disk and ratifies or rejects the additive harness edit (Flag 2).
2. ~~The owner rules on A5–A9 against the frozen spec (§2).~~ **DONE 2026-10-25 — director ruling appended below: A5–A9 accepted as proposed** (corrected adjudicator per D-13: amendments are director-ruled; owner gates are the commits and each device action).
3. Only then: `U4a2ChannelBConfig.json` is written with the ruled values, and committed with the user's approval before any device run.
4. Implement §3, run the simulator suite, and report real xcresult numbers.
5. D0–D9, one approval each, with the O-B1 gate before D7.
6. Assessment, then the CONVENTIONS.md exit protocol (PLAN.md, the STABILIZATION Status line, `VERSION_HISTORY.txt`, a DECISIONS entry if a settled choice changed, and the measured / integration-tested-but-not-validated / unverified summary).
7. E7 (§5) proceeds separately, on owner approval of its own actions.

---

## Director review and ruling (Hermes, 2026-10-25 — from disk, against U4a-proposal.md R2 §8/§9 M5, DECISIONS.md, PLAN.md)

**Verdict: APPROVED — implementation may begin after the owner approves the config+plan commit. Amendments A5–A9 are ACCEPTED as proposed.** All checks below were run against the frozen spec and repo artifacts, not the plan's own claims.

**Governance correction (fix before commit):** §0 line 9 and §6 step 2 assign the A5–A9 ruling to the owner. That is the wrong adjudicator: under D-13/D-15 and the U4a kickoff packet, pre-registration amendments are ruled on by the **director** against the frozen spec; the owner's gates are the config+plan commit, each device action, and the exit commit. This section is that ruling. The implementing agent corrects the two lines to point here.

**A5–A9, ruled item by item:**
- **A5 ACCEPTED.** Frame arithmetic exact (38.0 s × 48 kHz = 1,824,000; 50.0 s = 2,400,000). Source file `fixture-solo-loudnorm.caf` verified present in `ObservatoryTests/Fixtures/`. Passage provenance matches PLAN.md's E9 record (secondary solo passage, full recovery 20/20/18). loudnorm variant justified: the ladder is B-to-B only, so altered level enters no amplitude claim. Rung-0 replicate is a conservative superset (drift/contamination check per PLAN.md's process note). Silence values 0/5/10/20 s are §8.5's own.
- **A6 ACCEPTED.** B-to-B voicing lag over the full range touches none of §8.5's three banned evidence sources (word timestamps, callback arrival, A/B-agreement offsets); pitch as corroboration only. Rules (i)+(ii) restate §8.5's pre-registered prediction exactly (shift tracks inserted silence within one frameDuration; count × frameDuration tracks fed duration); rule (iii) (voicing/pitch agreement) makes O-B1 *harder* to reach — conservative, permitted. O-B2/O-B3 mapping matches §8.5's table and §9 M5. Uncertainty floor at one frameDuration, max residual including the replicate: consistent with O-B1's "measured residual carried as alignmentUncertaintySeconds."
- **A7 ACCEPTED.** Rung feeds ≤32 s (20 s silence + 12 s passage) — inside a single request, no rollover confound. Arm-2 55 s contiguous chunks have E3/production-rollover precedent. Listening past the first final until task-end-or-5 s-grace is *required* by §8.3's superseded-final counting — without it the rule is untestable, as the plan says. Request flags match the production replay path; E10c established session category is not a confound. Error policy (catch, continue, record `.failed(code)`) is §8.3 verbatim.
- **A8 ACCEPTED.** Satisfies §8.6's "only independently aligned voiced frames": alignment comes from the B-to-B ladder, never per-frame A/B agreement; the ± max(alignmentUncertainty, frameDuration) boundary guard removes ambiguous voicing-boundary pairings — conservative.
- **A9 ACCEPTED.** All three leave-one-fixture-out rotations are a documented superset of §8.6's "fit on two fixtures, test on the third." B2 stays `.rawUnspecifiedLog`, never converted to Hz (§8.6) ✓. The OLS-on-ln(F0_A) model is itself a pre-registered assumption — acceptable because Spearman ρ is reported alongside R², so a monotone-but-non-logarithmic relationship stays visible. The <200-matched-frames path to `unavailable(insufficientEligibleSeconds)` is D-07-correct.
- **B5 block** correctly labeled a restatement, not an amendment — verified line-by-line against §8.7 (union-of-intervals, per-feature, two labelled variants per §8.3, exact-zero fractions separate, nil vs legitimate 0.0, "coverage of A-detected voiced audio" statement). ✓

**Flag 2 (harness edit): RATIFIED**, with verification condition — at implementation review the director runs `git diff` on `FixtureReplayHarness.swift` and it must contain **added lines only**. (The frozen spec §10 itself anticipates exactly this edit.)

**New condition (minor, binding): untracked-input hashing.** The fixture `.caf` files are gitignored, so the config hash alone cannot pin them. The harvest manifest must record the **SHA-256 of `fixture-solo-loudnorm.caf`** (A5's passage source); recording the hashes of the three Arm-2 fixtures is strongly recommended. This extends the "config as hashed data" discipline (R2.1/R2.2) to untracked inputs.

**File-list deviation: ACCEPTED** per U4a-1 precedent (11 delivered vs 9 listed): `VoiceAnalyticsHarvest.swift`, `ChannelBAnalysis.swift`, `ChannelBAnalysisTests.swift` are additions inside the test seam; no production-target file; `AcousticVoiceAnalyticsDeviceTests.swift` matches §10's name.

**Flag 3 / specBase: verified.** `5d83779` is the real U4a R2 pre-registration commit (2026-10-24 17:01, "Pre-register U4a proposal Revision 2 with its ChatGPT review record"). E7 is correctly proposal-only, outside the frozen §11.

**Device plan (D0–D9): APPROVED as designed.** Isolated actions per PLAN.md's contamination note; D0 container backup before build/install per convention; O-B1 gate before D7–D9 matches Flag 1 and §9 M5; D5's 1110 risk honestly pre-declared and not retried away; ~31 min estimate inside ruling D2's 35–45 min budget. No post-run container snapshot needed (harness writes only xcresult attachments) — D10 remains available on request. Every action still needs the owner's separate explicit approval at run time.

**E7 (§5): APPROVED as a proposal.** Provenance-from-metadata-only (no transcript text) ✓; new files only, originals untouched (D-10) ✓; tracked sidecar provenance + committed scripts (giving U5 a reference transcript) ✓; playback/synthetic flags with exclusion from human voice-quality claims ✓ — this is D-07-grade honesty applied to fixture making. **Two owner decisions remain open:** (a) second voice = option (i) consenting human (preferred by the plan) or option (ii) on-device TTS fallback; (b) E7 rides the D-session (+10–15 min, outside the D2 budget) or happens in a separate session. E7-0…E7-4 each need their own approvals.

**Remaining owner gates, in order:** (1) approve the commit of this plan (with this ruling appended and the two governance lines corrected) + `U4a2ChannelBConfig.json` frozen exactly as §2's JSON with the SHA-256 condition added to the manifest requirements; (2) implementation + simulator suite — director verifies against xcresult before any device action; (3) each of D0–D9 (and E7 actions if chosen) individually; (4) exit-protocol commit.
