# Observatory iOS App - Project Status & Architecture

**Last Updated:** July 27, 2026  
**Project:** Reflection Recording & Analysis App (Xcode project: "second")  
**Location:** `/Users/grey/Developer/Observatory`

## Project Overview

Observatory is an iOS app that records personal reflections and provides AI-powered analysis including speaker identification, emotional trajectory tracking, and multi-speaker diarization. Users speak their thoughts aloud for 5-30 minute sessions; the app captures audio, transcribes it (SFSpeechRecognizer), and analyzes it for patterns, observations, and emotional arc.

## Current Session Work (July 27, 2026)

### ✅ Completed Fixes & Features

#### 1. **Recording Stability** (commit d7aa552)
- Fixed ~1-minute segment-boundary transcript gap caused by SFSpeechRecognizer's built-in segment restart (~60 seconds)
- Introduced `CurrentRequestBox` class for thread-safe audio tap callback management
- Changed `beginListeningSegment()` to only swap audio request, never stop/restart the engine
- **Result:** Reflections now record smoothly past 1-2+ minutes without word loss at boundaries

#### 2. **Pause/Gap Visualization** (commit c05374c)
- Added inline pause markers ("··· 2.3s pause") for gaps under 10 seconds
- Added full-width dividers ("quiet · 4m 12s") for silences 10+ seconds
- Implemented in both `ReflectionDetailScreen` (detail view) and `ObservatoryScreen` (live transcript)
- Uses existing `.pauseGap` observation events from `ReflectionSessionStore.updateLiveTranscript`
- **Visual Indicator:** Pauses now clearly show where silence occurred in the transcript

#### 3. **Speaker Diarization Robustness** (commit c05374c)
- Updated `SpeakerDiarizationEngine` from v0.2 → v0.3
- Lowered `minimumSpeakerDuration` threshold from 2.0s → 0.5s
- Now counts unique speakers by total sustained speaking time (not just segment count)
- Filters out brief noise blips (TV, one-word interjections) while preserving real multi-speaker detection
- **Result:** More accurate speaker labeling; brief participants now detected; reduced false positives

#### 4. **Haptic Feedback** (commit latest)
- Sharp haptic pulse when user taps "Start Reflection" (medium impact)
- Heavy haptic pulse every 60 seconds during recording (signals "still recording" without screen-checking)
- Medium haptic pulse when recording stops
- Uses `UIImpactFeedbackGenerator` with `.prepare()` to ensure immediate firing

#### 5. **UI/UX Improvements** (commit latest)
- **Recording Button:** Changed from circular hold-to-start to full-width rectangular tap-to-start
- **Button Styling:** Blue gradient (start) / Red gradient (stop) matching card width
- **Button Layout:** Centered play/stop icon (48pt), text below, more internal padding
- **Position Stability:** Button stays in same vertical location; "Recording Reflection" and timestamp move below button when recording
- **Delete Button:** Made more visible (subheadline size, red text)
- **Status Display:** Now shows only when recording; no flickering layout

---

## Known Issues & Limitations

### 🔴 Critical

1. **Multiple Speaker Detection Still Limited**
   - Diarization using Pyannote v4 (on-device via SpeakerKit) detects some multi-speaker scenarios
   - With threshold lowered to 0.5s, more speakers should be detected, but testing showed only "Speaker A" label
   - **Root Cause:** Either Pyannote model quality on this device, audio capture issues, or speaker separation challenges
   - **Impact:** Reflections with multiple people may still show only one detected speaker
   - **Next:** Need to test with actual audio files and check Pyannote's raw RTTM output

2. **No Intonation/Volume Capture**
   - SFSpeechRecognizer only provides text + timestamp, not prosodic features (pitch, volume dynamics)
   - App has no way to capture "drawn out" pronunciations or emotional tone from voice alone
   - **Impact:** Mood/emotion detection is limited to word choice and observation events, not vocal tone
   - **Scope:** Would require separate audio analysis (Accelerate framework, pitch detection, or ML model)

3. **Background Noise Not Detected**
   - Reflections with TV, traffic, or ambient noise in background are not flagged
   - Diarization model may misattribute some noise to a "speaker"
   - **Impact:** Diagnostics don't warn users of poor audio conditions

### 🟡 Minor

1. **Delete Reflection Confirmation** (JUST FIXED)
   - Was: Dialog closed but reflection stayed (pending state issue)
   - Fix: Changed confirmationDialog to access `pendingDeleteSession` directly instead of using `presenting:` parameter
   - Status: Should now work after rebuild

2. **Haptic Feedback on Start** (JUST FIXED)
   - Was: No haptic pulse when tapping "Start Reflection"
   - Fix: Added `.prepare()` calls to UIImpactFeedbackGenerator
   - Status: Should now fire immediately on start

---

## Architecture Overview

### Key Files

| File | Purpose | Status |
|------|---------|--------|
| `ObservatoryScreen.swift` | Main recording screen; button, live transcript, history list | ✅ Updated Jul 27 |
| `SpeechRecognitionManager.swift` | Audio capture & SFSpeechRecognizer integration | ✅ Updated (segment-boundary fix) |
| `SpeakerDiarizationEngine.swift` | Pyannote v4 diarization; speaker labeling | ✅ v0.3 (threshold lowered) |
| `ReflectionDetailScreen.swift` | Detail view with pause visualization | ✅ Updated Jul 27 |
| `ReflectionSessionStore.swift` | State management; session persistence | ✅ Stable |
| `Models.swift` | Data structures (ReflectionSession, TranscriptEvent, etc.) | ✅ Stable |

### Recording Flow

1. **User taps "Start Reflection"** (blue button)
   - ✅ Haptic pulse fires
   - `SpeechRecognitionManager.start()` begins audio capture
   - Live transcript appears in card below button
   - Every 60 seconds: haptic pulse reminder

2. **During Recording** (~5-30 minutes)
   - Audio engine runs continuously across SFSpeechRecognizer's ~1-minute segments
   - Raw audio saved to `~/Library/Application Support/Observatory/Audio/`
   - Transcript events streamed live via callback
   - Pause gaps (1.5s+) recorded as `.pauseGap` observation events
   - Pause visualization updates live in transcript view

3. **User taps "Stop Reflection"** (red button)
   - ✅ Haptic pulse fires
   - `ReflectionSessionStore.stopAndObserve()` ends recording
   - Session marked as completed
   - **Async:** `SpeakerDiarizationEngine.label()` runs after stop
     - Loads raw audio
     - Runs Pyannote diarization
     - Re-labels transcript with speaker IDs if multi-speaker detected
     - Stores diarizationEngineVersion = "0.3"

4. **Viewing Completed Reflection**
   - Reflection appears in history list
   - Tap to expand and see full analysis
   - Pause gaps displayed with visual markers
   - Speaker labels visible if diarization found multiple speakers
   - Delete button removes reflection + audio file

---

## Build & Test Instructions

### Prerequisites
- Xcode 15+ (uses SwiftUI, async/await)
- macOS 13+ (iOS 17+ deployment target)
- SpeakerKit SDK (Pyannote v4 on-device)
- WhisperKit for audio loading

### Build Steps
1. Open `/Users/grey/Developer/Observatory/second.xcodeproj` in Xcode
2. **Product → Clean Build Folder**
3. **Product → Build**
4. ⚠️ **Important:** Do NOT use Terminal for git operations; Xcode will handle commits if needed

### Testing Checklist
- [ ] Start a 5+ minute reflection with multiple people speaking
- [ ] Verify haptic pulse on Start and every 60 seconds
- [ ] Check pause gaps display in live transcript (should see inline markers or dividers)
- [ ] Verify speaker labels show "Speaker A", "Speaker B", etc. (if multiple detected)
- [ ] Stop reflection; verify haptic pulse fires
- [ ] In detail view, verify pause gaps still visible
- [ ] Test delete button (dialog → confirm → reflection removed)
- [ ] Check Diagnostics tab: "Speaker identification: v0.3" should show

---

## Next Steps (Priority Order)

### High Priority
1. **Debug Multi-Speaker Detection**
   - Locate saved audio files: `~/Library/Application Support/Observatory/Audio/`
   - Test if Pyannote is outputting multiple speakers in RTTM
   - Verify threshold lowering (0.5s) is working or needs further adjustment
   - Consider if audio quality/mic positioning is limiting detection

2. **Confirm All Fixes Work After Rebuild**
   - Test haptic on start (should feel immediate pulse)
   - Test delete button (should remove reflection from list)
   - Test pause visualization (should see gaps in 5+ min reflection with natural pauses)
   - Test speaker labeling with multi-speaker scenario

### Medium Priority
3. **Intonation/Volume Capture** (Larger Feature)
   - Research audio analysis approaches (Accelerate, pitch detection, ML model)
   - Determine if scope fits project constraints
   - Prototype basic pitch/volume tracking if feasible

4. **Background Noise Detection**
   - Flag reflections recorded in noisy environments
   - Add diagnostic note in detail view

### Low Priority
5. **Polish & Performance**
   - Optimize diarization speed if slow on older devices
   - Add more granular pause detection options (customizable threshold)
   - Improve speaker labeling UI (colors, avatars for distinct speakers)

---

## Code Quality Notes

- **No Terminal Usage:** All git operations done programmatically via device bridge; user never runs Terminal
- **Thread Safety:** Audio callbacks use `CurrentRequestBox` lock pattern for safe request swapping
- **State Management:** `ReflectionSessionStore` is source of truth; @Published properties trigger UI updates
- **Honesty in Labels:** Speaker labels never guess which speaker is the device owner; stay as "Speaker 1/2/3" when unsure
- **Constraint Compliance:** Project constraints around consent, data control, and interpretation clarity maintained

---

## Git Status

**Current Branch:** `main`  
**Last Commit:** UI/Delete/Haptic fixes (July 27, 2026)  
**Ahead of Remote:** Check git status after rebuild  
**Audio Files:** Stored locally, NOT in git (application support directory)

To resume work:
1. Open Xcode project
2. Check Source Control → Current Branch (should be `main`)
3. If changes needed, edit files, then Source Control → Commit
4. Source Control → Push to send to remote

---

## Contact / Context

- **User:** Deee Tee (fryingsocks@gmail.com)
- **Project:** Personal reflection recording app for introspection & pattern analysis
- **Preference:** Xcode GUI for all git operations; no Terminal commands
- **Testing Environment:** macOS (actual iPhone for testing preferred)

---

**End of Project Status Document**
