# Roadmap

This document tracks what's working, what's actively being investigated, and what's planned for Observatory.

## Recently shipped

- **Recording stability** — resolved a transcript gap at `SFSpeechRecognizer`'s internal ~1-minute segment boundary by introducing thread-safe audio request swapping, so long reflections no longer lose words at those boundaries.
- **Pause visualization** — inline markers for short pauses and full-width dividers for extended silence, shown live during recording and in the reflection detail view.
- **Recording controls & feedback** — redesigned start/stop button, haptic pulses on start, roughly every 60 seconds during recording, and on stop.
- **Reflection management** — more reliable delete flow for removing a reflection and its audio.

## In progress

### Multi-speaker detection

The highest-priority open item. Diarization currently detects far fewer distinct speakers than are actually present in multi-person reflections. Work so far has focused on tuning the minimum-sustained-speaking-time threshold used to decide whether a detected voice counts as a real speaker (lowered from 2.0s to 0.5s); this reduces one likely cause (an overly strict filter) but hasn't yet been verified against real recordings with multiple people.

Planned next steps:
- Inspect the diarization model's raw output directly on saved audio, rather than only through the app's parsing layer, to isolate whether the limitation is in detection or in how results are filtered/labeled.
- Evaluate whether single-microphone audio quality is a hard limit on separating close-proximity speakers, and whether any capture-side changes help.
- Consider a manual fallback (letting the user label speakers) if automatic detection has a ceiling worth designing around.

## Planned

- **Vocal tone / intonation capture** — today's transcription captures words and timing but not pitch or volume dynamics, which limits emotional-tone detection to word choice and pause patterns. This would require a separate audio analysis layer and is being scoped as a larger feature.
- **Background noise awareness** — flag reflections recorded in noisy environments so users understand when transcription or diarization quality may be degraded.
- **Diarization UI polish** — clearer visual distinction between speakers (color, avatars) once detection itself is reliable.
- **Performance** — keep diarization responsive on older devices as the app evolves.

## Philosophy

Reliability of the core loop — record, transcribe, review — comes first. Speaker detection and richer emotional analysis are valuable but are being built as layers on top of a recording experience that should never lose a user's words or their trust.
