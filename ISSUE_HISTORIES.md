# Known Issues - Detailed Histories & Semi-Resolutions

## 1. DIARIZATION (Multi-Speaker Detection) 🔴 CRITICAL

### Issue Summary
App fails to detect multiple distinct speakers even when 2-3 people are clearly talking in sequence (no crosstalk).

### History & Evolution

**v0.1 (Initial Implementation)**
- Basic Pyannote v4 speaker diarization via SpeakerKit (on-device)
- All speakers with any detected voice counted toward "multi-speaker"
- **Problem:** Brief noise blips, TV in background, single-word interjections were counted as separate "speakers"
- **Result:** Entire transcript would flip from "You" (single speaker) to "Speaker A/B/C" labels on noise detection
- **User Impact:** Unreliable; frustrating false positives

**v0.2 (First Attempted Fix)**
- Added `minimumSpeakerDuration: TimeInterval = 2.0` threshold
- Logic: Sum total speaking time per speaker; only count if ≥2.0 seconds
- **Intention:** Filter noise, keep real multi-speaker scenarios
- **Problem:** Still too strict for brief but legitimate speakers (person speaks 1.5s total = filtered out)
- **Result:** Testing showed only "Speaker A" when user reported 3 people clearly present

**v0.3 (Current - July 27, 2026)**
- Lowered `minimumSpeakerDuration` from 2.0s → 0.5s
- Same logic: sum total speaking time, threshold at 0.5s
- **Intention:** Catch brief speakers while still filtering noise
- **Status:** Not yet tested after change
- **Expected Impact:** More speakers should appear, but unverified

### Root Cause Analysis

Multiple possible causes (not isolated yet):

1. **Pyannote Model Quality**
   - Trained on general speech; may not handle device's audio capture well
   - May struggle with close-proximity conversation vs. far-field recording
   - May have difficulty with certain accents/speech patterns

2. **Audio Capture Issues**
   - iPhone microphone captures mainly speaker close to device
   - Other speakers at distance get weaker signal
   - Pyannote may not have enough signal to separate them

3. **Speaker Separation Challenge**
   - Pyannote works best with isolated speaker turns (no overlap)
   - If speakers are in same room with same acoustic environment, harder to distinguish
   - Multiple speakers on same device mic (vs. separate mics) = harder problem

4. **RTTM Parsing Correct but Pyannote Output Wrong**
   - Code that parses RTTM (industry-standard diarization format) looks correct
   - Issue may be: Pyannote simply not outputting multiple speaker labels

### Semi-Resolutions Attempted

| Approach | Status | Result |
|----------|--------|--------|
| Add duration threshold (2.0s) | ✅ Implemented v0.2 | Reduced false positives but too aggressive |
| Lower threshold (0.5s) | ✅ Implemented v0.3 | Pending test; should help but unclear if sufficient |
| Filter by confidence score | ❌ Not attempted | Could further refine if RTTM includes confidence |
| Test Pyannote directly on saved audio | ❌ Not attempted | **NEXT STEP** - would clarify if model or parsing is issue |
| Adjust SpeakerKit model settings | ❌ Not attempted | API may not expose tuning parameters |

### What Needs to Happen Next

1. **Extract test audio** from `~/Library/Application Support/Observatory/Audio/` (most recent 3-person reflection)
2. **Check Pyannote output directly** via SpeakerKit API to see raw speaker count in RTTM
3. **Verify RTTM parsing** — does `generateRTTM()` output match what our code expects?
4. **Test audio quality** — is the audio capture clear enough for Pyannote to process?
5. **Consider alternatives:**
   - Switch diarization models (if SpeakerKit supports options)
   - Manual speaker detection UI (user manually labels speakers)
   - Lower threshold further (0.25s?) to see if noise reappears

### Code Location
- **File:** `SpeakerDiarizationEngine.swift`
- **Key Variable:** `minimumSpeakerDuration` (line 38)
- **Logic:** Lines 69-75 (filtering by duration)
- **RTTM Parsing:** `parseSegments()` function (lines 106-125)

---

### Director's verified addendum (2026-10-24, Hermes — git forensics, supersedes nothing above; confirms it)
Verified against commits and diffs, prompted by the owner asking whether early diarization was ever actually good (it was not):
- **v0.1's label-rich output was false positives, not skill.** Any noise blip flipped a solo transcript to Speaker A/B/C — the era that *looked* "very, very good" to the owner was the most broken version.
- **The July "fixes" curbed over-labeling; they never improved or tested detection.** `7ffde91` (engine v0.2) added the ≥2-distinct-speakers guard; `c05374c` (engine v0.3) added the 2.0s `minimumSpeakerDuration` threshold — justified in code comments by reasoning ("a real second participant speaks meaningfully longer than a couple of seconds"), not measurement.
- **The engine was authored blind:** `7ffde91` carries the in-file comment "this is the one file in WayReally built against a third-party package's exact API **without a compiler available here to verify it**."
- **Contemporaneous docs already said detection was failing the other way:** ROADMAP.md as committed `a54ea45` (2026-07-28): "detects far fewer distinct speakers than are actually present… hasn't yet been verified against real recordings with multiple people."
- **As of 2026-10-24, diarization has never passed a ground-truth validation in this project's history.** The only verified multi-speaker result is October's fixture work (server-path recognition found 2 speakers in both multi fixtures).
- **Handoff lesson (owner-relevant):** the July Claude handoff summary (`~/Desktop/wayreally-summary-for-nous-hermes.md`) listed "Diarization bug — fixed" with no caveat, while the honest record sat in this file and ROADMAP.md. Summaries flatter; artifacts don't — verify claims against git/artifacts, per D-13.

---

## 2. BIOMETRICS (Apple Watch/HealthKit) 🟡 DEFERRED

### Issue Summary
App has data structures for biometrics but no actual HealthKit/Apple Watch integration.

### History & Evolution

**Initial Design (Per PROJECT_CONSTRAINTS.md)**
- Reflection sessions should capture heart rate, respiration, HRV (heart rate variability)
- Source: Apple Watch via HealthKit framework
- Purpose: Correlate body signals with mood/emotion during reflection
- Rationale: Physiological signals (elevated HR, stress) complement transcript analysis

**v0.1 (Data Model Ready)**
- `BiometricSample` struct with: timestamp, heartRate, respiration, hrv, source, quality
- `BiometricWindow` struct with: queryStart, queryEnd, samples[], quality
- `ReflectionSession` includes `biometrics: BiometricWindow` field
- Display placeholder: "No biometric samples attached to this session yet. Watch and HealthKit will be connected in a later build."

**Current State (v0.3)**
- ✅ Data structures in place
- ✅ UI layout ready to display biometrics
- ❌ No HealthKit permission requests
- ❌ No Apple Watch data collection
- ❌ Biometrics always empty in sessions
- ✅ Placeholder text correctly explains future work

### Why Deferred

1. **Scope:** Requires:
   - HealthKit permission flow
   - Watch connectivity setup
   - Query API for HR/respiration/HRV
   - Timestamp alignment with reflection session
   - Background data fetching while app records

2. **Complexity:** Medium-high (networking, permissions, data sync)

3. **User Value vs. MVP:** Core feature (recording + analysis) works without it; biometrics are enhancement

4. **Testing:** Would require actual Apple Watch for testing

### User Feedback (from session)

User noted: *"Biometrics could help there by the way to tell the full picture in the later version."*

Context: User was discussing inability to detect long silent walking periods. Biometrics (e.g., movement cessation in watch accelerometer, HR changes) could help identify these gaps.

### Semi-Resolutions

| Approach | Status | Notes |
|----------|--------|-------|
| Data structures ready | ✅ Complete | Can accept biometric data if source provides it |
| UI layout prepared | ✅ Complete | Shows placeholder; ready for data binding |
| Mock biometric data | ❌ Not done | Could inject test data for UI testing |
| HealthKit integration | ❌ Not started | Requires: privacy description, permission flow, API calls |
| Apple Watch sync | ❌ Not started | Requires: Watch app or HealthKit background delivery |

### What Needs to Happen (Future Session)

1. **Add HealthKit permission request** in app launch
2. **Query HealthKit for HR/respiration** around reflection timeframe
3. **Timestamp alignment:** Match watch samples to reflection session start/end
4. **Display:** Bind BiometricWindow to UI (already has layout)
5. **Test:** With actual Apple Watch during reflection
6. **Correlation analysis:** Eventually correlate spikes in HR with transcript events

### Code Locations
- **Data Model:** `Models.swift` (lines 266-306, BiometricSample/BiometricWindow)
- **Session Integration:** `Models.swift` (line 158, biometrics field)
- **UI Display:** `ReflectionDetailScreen.swift` (lines ~423-435, Diagnostics section)
- **Status Display:** "No biometric samples attached to this session yet..."

### Design Decision: Keep Empty for Now

Current approach is correct:
- ✅ Honest placeholder text
- ✅ Data structure ready
- ✅ UI layout prepared
- ✅ No fake data; doesn't pretend to work
- ✅ Minimal implementation tax (just empty array + placeholder)

---

## 3. INTONATION/VOLUME (Emotional Prosody) 🔴 OUT OF SCOPE

### Issue Summary
Transcript captures only words and timing; no emotional tone (pitch, volume, tempo) is recorded.

### History

**Root Cause: Architecture Limitation**
- SFSpeechRecognizer (Apple's API) returns: `text`, `timestamp`, `confidence`
- Does NOT return: pitch, volume, rate of speech, prosody features
- App has raw audio file but no analysis of it for intonation

**User Feedback (from session)**
*"Reflections not capturing intonation and volume which help define mood. i need... indication of drawn out pronunciations like doooooor came out door. aaaannnd came out as and."*

**Why This Matters**
- Drawn-out syllables ("dooooor") often indicate hesitation, emotion, emphasis
- Fast speech → stress/anxiety
- Volume changes → emotional intensity
- Current system misses this signal entirely

### Why Not Fixed

1. **Apple Limitation:** SFSpeechRecognizer doesn't expose audio features
2. **No Built-in Prosody API:** Would need custom audio analysis
3. **Complexity:** Requires:
   - Real-time pitch detection (complex signal processing)
   - Volume/RMS calculation
   - Prosodic feature extraction
   - ML model for emotion classification from audio
   - OR: Manual annotation of emphasis/tone by user

4. **Out of MVP Scope:** Core reflection recording works without it

### Possible Solutions (Future)

| Approach | Complexity | Feasibility |
|----------|-----------|------------|
| Fundamental frequency (pitch) detection | Medium | ✅ Doable with Accelerate framework |
| Volume/energy RMS calculation | Low | ✅ Straightforward signal processing |
| Speech rate measurement | Medium | ✅ Time between speech events |
| Prosody emotion classifier (ML) | High | ⚠️ Requires training data/model |
| User manual annotation | Low | ❌ UX burden; not appealing |

### Design Decision: Accept Current Limitation

- ✅ Transcript captures content accurately
- ✅ Pause visualization shows silence/thinking time
- ✅ Speaker diarization handles multiple people
- ❌ Emotion tone from voice not captured
- **Status:** Document as limitation; consider future feature

---

## Summary Table

| Issue | Type | Status | Last Attempt | Next Action |
|-------|------|--------|--------------|------------|
| **Diarization (Multi-Speaker)** | 🔴 Critical | Broken (v0.3) | Lower threshold 2.0s→0.5s | Test; check Pyannote raw output |
| **Biometrics (Apple Watch)** | 🟡 Deferred | Not Started | Data structures ready | Design HealthKit integration |
| **Intonation/Volume** | 🔴 Limitation | Not Started | N/A | Accept or plan major audio analysis feature |

---

## For Next Session

**Priority Actions:**
1. **Test v0.3 diarization** with the 0.5s threshold (rebuild & test multi-person reflection)
2. **Debug diarization** if still broken (extract audio, test Pyannote directly)
3. **Document findings** in this file if changes needed
4. **Plan biometrics** if user wants it before other features

**Do NOT attempt:**
- ❌ Major audio prosody analysis without architectural redesign
- ❌ Biometrics without HealthKit setup discussion
- ❌ Alternative diarization models without testing current one
