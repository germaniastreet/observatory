# Architecture

This document describes how Observatory is put together: the main components, the recording pipeline, and where to look when making changes.

## Overview

Observatory is a SwiftUI iOS app built around a single core loop: capture audio, transcribe it live, detect pauses and speakers, and present the result. The app favors on-device processing throughout — audio never needs to leave the phone to produce a transcript or a speaker label.

## Key components

| Component | Responsibility |
|---|---|
| `ObservatoryScreen` | Main recording screen: start/stop control, live transcript view, and reflection history list |
| `SpeechRecognitionManager` | Owns audio capture and the `SFSpeechRecognizer` integration; responsible for keeping transcription continuous across recognizer segment boundaries |
| `SpeakerDiarizationEngine` | Runs on-device diarization (Pyannote, via SpeakerKit) after a recording finishes and labels the transcript by speaker |
| `ReflectionDetailScreen` | Detail view for a completed reflection, including pause visualization |
| `ReflectionSessionStore` | Source of truth for session state; publishes updates that drive the UI |
| `Models` | Core data structures — reflection sessions, transcript events, pause/observation events, and related types |

## Recording flow

1. **Start.** The user taps "Start Reflection." `SpeechRecognitionManager` begins audio capture and a live transcript starts streaming into the UI. A haptic pulse confirms the start.
2. **During recording.** The audio engine runs continuously through `SFSpeechRecognizer`'s internal ~60-second segment boundaries — a dedicated request-swapping mechanism keeps this seamless from the recognizer's perspective, so no words are lost when a segment rolls over. Pauses of 1.5 seconds or more are recorded as observation events and rendered live (inline markers for short pauses, full-width dividers for extended silence). A haptic pulse repeats roughly every 60 seconds as a quiet "still recording" cue.
3. **Stop.** The user taps "Stop Reflection." Recording ends, the session is marked complete, and a haptic pulse confirms the stop.
4. **Diarization (async).** After stop, `SpeakerDiarizationEngine` loads the raw audio and runs on-device diarization. If more than one speaker is detected, the transcript is re-labeled accordingly and the diarization engine version used is stored with the session.
5. **Review.** The finished reflection appears in history. Opening it shows the full transcript with pause markers and, where applicable, speaker labels.

## Storage

- Raw audio for each reflection is stored locally under the app's Application Support directory and is **not** committed to source control (see `.gitignore`).
- Reflection metadata, transcripts, and derived analysis are persisted via `ReflectionSessionStore`.

## Design principles

- **On-device first.** Transcription and diarization both run locally; nothing about the content of a reflection needs to be sent off the device to function.
- **Honest labeling.** Speaker labels are generic ("Speaker 1", "Speaker 2", ...) rather than guessing identity, and the app does not assume which speaker is the device owner.
- **Continuity over restarts.** The audio pipeline is built to avoid interrupting the recognizer mid-session, since restarting the engine is the primary source of transcript gaps.

## Known architectural constraints

Speaker diarization on a single phone microphone is a genuinely hard problem — multiple speakers in the same room, captured on one mic, produce much weaker separation cues than multi-mic setups. Current diarization tuning (a minimum sustained-speaking-time threshold) is a balance between filtering background noise/false positives and not discarding real but brief speakers. See `ROADMAP.md` for the current state of this tradeoff and next steps.
