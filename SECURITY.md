# Security & Privacy

Observatory records audio of personal, often unguarded, spoken reflections. This document describes how that data is handled.

## What is recorded

- **Audio.** Raw audio of each reflection session.
- **Transcript.** Text produced from that audio via on-device speech recognition, along with timing information used for pause detection.
- **Speaker labels.** Generic labels (e.g., "Speaker 1", "Speaker 2") produced by on-device diarization when more than one voice is detected. Labels are never tied to a real identity, and the app never assumes which speaker is the device owner.

## Where data lives

- Raw audio is stored locally on-device, under the app's Application Support directory, and is explicitly excluded from source control (see `.gitignore`).
- Transcripts, pause/observation events, and diarization results are persisted locally alongside the audio.
- No reflection content — audio, transcript, or speaker data — is transmitted off the device as part of normal app operation. Transcription and diarization both run on-device.

## Consent and multi-speaker recordings

Reflections may capture the voices of people other than the device owner (for example, a conversation with others present). Because of this:

- Speaker labeling is intentionally conservative and generic rather than attempting to identify individuals.
- Anyone building on or extending this app should treat recording of other people's voices as requiring the same care as recording one's own — at minimum, informing anyone present that recording is happening.

## Source control hygiene

- Audio files, build artifacts, and local Xcode user state (`xcuserstate`, `DerivedData`, `build/`) are excluded from this repository via `.gitignore`.
- Internal working notes, project-history documents, and handoff summaries used during development are intentionally kept out of the public documentation set to avoid exposing internal debugging detail or personal reflection content by accident.

## Reporting a concern

This is currently a personal project without a formal disclosure process. If you're evaluating this codebase and have a security or privacy concern, please raise it directly with the project owner rather than filing a public issue with sensitive details.
