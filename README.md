# Observatory

Observatory is an iOS app for recording spoken personal reflections and turning them into structured, searchable insight. Speak your thoughts aloud for a few minutes — or half an hour — and Observatory captures the audio, transcribes it on-device, and surfaces patterns: pauses, emotional arc, and (when more than one person is present) who said what.

## What it does

- **Reflection recording** — tap to start, tap to stop. Sessions typically run 5–30 minutes.
- **Live transcription** — speech is transcribed in real time using Apple's `SFSpeechRecognizer`, with a continuous audio pipeline designed to avoid word loss at segment boundaries.
- **Pause visualization** — natural silences are detected and shown inline (short pauses) or as full dividers (extended quiet periods), making it easy to see the shape of a reflection at a glance.
- **Speaker diarization** — an on-device diarization model (Pyannote, via SpeakerKit) attempts to distinguish between speakers when a reflection involves more than one person.
- **Haptic feedback** — subtle haptic cues confirm when recording starts, at regular intervals during recording, and when it stops, so you can record without needing to look at the screen.
- **Reflection history** — completed reflections are saved locally and can be revisited, reviewed, or deleted.

## How it works, briefly

1. You start a reflection. Audio capture begins and a live transcript appears.
2. While recording, the app tracks pauses and streams transcript events as they happen.
3. When you stop, the session is finalized and diarization runs on the captured audio to identify distinct speakers, if any.
4. The finished reflection — transcript, pauses, and speaker labels — is added to your history.

## Project structure

This repository contains the Xcode project (`second.xcodeproj`) for the Observatory iOS app, along with its test targets (`secondTests`). See `ARCHITECTURE.md` for a tour of the codebase and how the pieces fit together.

## Requirements

- Xcode 15 or later
- macOS 13 or later (for building)
- iOS 17 or later (deployment target)
- A physical iPhone is recommended for testing audio capture and haptics

## Status

Observatory is under active development. See `ROADMAP.md` for what's built, what's in progress, and what's planned next.

## Privacy

Observatory records audio of personal reflections, which is inherently sensitive. See `SECURITY.md` for details on how data is handled and stored.
