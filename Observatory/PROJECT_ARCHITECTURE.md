# Observatory — Project Architecture

## Source of Truth • v1.0 • 2026-07-25

This file is the practical companion to PROJECT_CONSTRAINTS.md. Where
PROJECT_CONSTRAINTS.md defines *what the product is allowed to do*, this file
defines *how the code is actually organized* — folder structure, naming,
data flow, what each engine is responsible for, how data is stored, and
where the boundaries are. It reflects the real code as of v115 (Capture
Reliability update), not an aspirational future design. When the code and
this document disagree, treat that as a bug in this document and fix the
document to match the code — this file should always describe reality.

This document is meant to be usable by anyone or anything working on this
project — Claude, ChatGPT, or a future contributor — so that changes are
measured against the same shared picture of how the app is built, instead
of each contributor re-deriving the architecture from scratch.

## 1. Folder structure

The project currently uses a single flat source folder — there are no
subfolders inside `Observatory/` yet:

```text
Observatory/                          (outer container folder — not tracked by Xcode)
  Observatory.xcodeproj/            (the Xcode project file)
  Observatory/                      (all Swift source + docs — this is the "Observatory" target; the Xcode project/target/scheme were originally named "second" and have since been renamed, but the bundle identifier is still com.germaniastreet.second)
    *.swift                         (all source files, flat, no subfolders)
    Info.plist                      (only exists because of Background Modes; otherwise auto-generated)
    Assets.xcassets/                (app icon, accent color)
    PROJECT_CONSTRAINTS.md
    PROJECT_GLOSSARY.md
    PROJECT_ARCHITECTURE.md         (this file)
    PRE_BUILD_CHECKLIST.md
    PROJECT_STRUCTURE_CLEANUP_v115.md
    README.txt
    VERSION_HISTORY.txt
```

As the project grows past roughly 40 files, grouping into subfolders (e.g.
`Screens/`, `Engines/`, `Models/`, `Stores/`) is worth considering — but
that is itself a rename/move-type change and should be its own controlled
version, the same way the app-name rename was, since Xcode's file
references need to move together with the files.

## 2. Naming conventions actually in use

These aren't proposed conventions — this is what the existing ~28 Swift
files already do consistently, and new files should follow the same
pattern:

- **Screens** (SwiftUI views the user navigates to) are structs named
  `___Screen.swift` — e.g. `ObservatoryScreen`, `AudioCaptureScreen`,
  `SignalLibraryScreen`. Each owns its own `NavigationStack` and reads
  state through `@EnvironmentObject`, never by constructing a store
  itself.
- **Engines** (pure analysis logic) are `enum`s with only `static` members
  — never instantiated, never hold state. Every engine exposes a
  `static let engineVersion = "x.y"` constant, and the version string is
  stored on the result it produces and shown in the UI (e.g. "Summary
  engine: 1.8"). This is a deliberate transparency convention — see
  PROJECT_CONSTRAINTS.md #5/#9 — so a user can always see which version of
  which logic produced a given observation.
- **Stores** (shared mutable state) are `final class ... : ObservableObject`
  — there are exactly two: `ReflectionSessionStore` and
  `SignalLibraryRegistry`/`PersistentSignalLibraryStore`. Both are created
  once in `ContentView` and shared via `.environmentObject(...)` to every
  tab, so all screens see the same live state.
- **Models** (plain data types) live in `Models.swift` (session, transcript,
  observation, dynamics, biometrics, correlation) and
  `SignalLibraryModels.swift` (signal library domain only, kept separate
  because it's a distinct subsystem — user/moderator-authored detection
  rules, not reflection data).
- `Components.swift` holds shared, reusable SwiftUI pieces (`AppCard`,
  `MetricRow`, `ScreenHeader`, `SignalBadge`, etc.) used across multiple
  screens — new shared UI pieces belong here, not duplicated per-screen.

## 3. Data flow

`ContentView` is the single root that creates the app's two long-lived
stores and hands them down:

```text
ContentView
  @StateObject sessionStore: ReflectionSessionStore
  @StateObject speechManager: SpeechRecognitionManager
    → .environmentObject() to all 7 tabs
```

The `SignalLibraryRegistry` (backed by `PersistentSignalLibraryStore`) is
created independently and owns the signal-library subsystem — it is a
separate concern from reflection sessions.

The flow for a single reflection, start to finish:

1. `AudioCaptureScreen` (or `ObservatoryScreen`, which shares the same
   store) calls `speechManager.start(onTranscript:)`.
2. `SpeechRecognitionManager` (AVFoundation + Speech framework) turns live
   audio into text and calls back into `store.updateLiveTranscript(_:)`.
3. `ReflectionSessionStore` holds the single `activeSession` as
   `@Published`, so every screen watching it updates automatically.
4. On stop, `store.stopAndObserve()` runs the analysis engines
   (`ObservationEventEngine`, `DynamicsEngine`, `CorrelationEngine`, etc.)
   against the finished session and attaches their results to it.
5. The finished session moves into `store.completedSessions`, where
   `ReflectionTimelineScreen`, `ReflectionDetailScreen`,
   `ConversationDynamicsScreen`, and `CorrelationScreen` all read from it.

**Engines never mutate state themselves.** Every engine is a pure
function: it takes a `ReflectionSession` (or similar) in, and returns a
result type out (e.g. `ConversationDynamicsEngine.analyze(session:) ->
ConversationDynamics?`). Only the store applies the result back onto the
session. This separation is what keeps the "engine" layer testable and
swappable without touching UI or storage code.

## 4. Responsibilities of every engine

| Engine | File | Computes |
|---|---|---|
| `ObservationEventEngine` | ObservationEventEngine.swift | Turns a transcript into individual `ObservationEvent`s (moments worth flagging) |
| `CognitiveObservationDetector` | CognitiveObservationDetector.swift | Keyword/pattern-based detection feeding into observation events |
| `DynamicsEngine` | DynamicsEngine.swift | General session dynamics/patterns (`DynamicsPattern`) |
| `ConversationDynamicsEngine` | ConversationDynamicsEngine.swift | Turn-taking and speaking-share, estimated from transcript word counts (not timed audio — see its doc comment) |
| `CorrelationEngine` | CorrelationEngine.swift | Correlations between observations (`ObservationCorrelation`) |
| `ReflectionAnalyzer` | ReflectionAnalyzer.swift | Overall per-reflection analysis summary |
| `ReflectionArcEngine` | ReflectionArcEngine.swift | The emotional/topical "arc" shape of a single reflection |
| `EmotionalTrajectoryEngine` | EmotionalTrajectoryEngine.swift | Emotional trajectory across a reflection (or across sessions) |
| `ReflectionSummaryEngine` | ReflectionSummaryEngine.swift | Human-readable summary text for a completed reflection |
| `SignalLibraryDetectionEngine` | SignalLibraryDetectionEngine.swift | Matches transcript content against active `SignalLibrary` rules |
| `SpeakerDiarizationEngine` | SpeakerDiarizationEngine.swift | Re-labels a finished session's transcript by speaker, using the saved `.caf` audio and Argmax's on-device SpeakerKit (Pyannote) — see section 7 for its network-access caveat |

All eleven are stateless enums with a version constant, per the naming
convention above. All but `SpeakerDiarizationEngine` make no network calls
at all — see section 7 for why that one is the exception.

## 8. Known issues / active work (as of 2026-10-15)

The speech-capture pipeline (`SpeechRecognitionManager.swift`,
`SpeakerDiarizationEngine.swift`, `ReflectionSessionStore.swift`) has known,
confirmed defects that are not yet fixed in the running code: word timing is
callback-arrival time rather than audio-derived (every saved word currently
has `start == end`), there's a real data race between `endAudio()` and the
realtime audio-append path, recognition callbacks carry no generation
identity to reject stale results across a segment rollover, and diarization
matches whole transcript events against a single wall-clock timestamp while
the underlying RTTM segments are audio-file-relative. A full staged plan to
fix these, plus a new acoustic-expression-observation workstream (measuring
*how* speech is expressed — prolongation, rate, pitch/intensity — not just
transcript content), is written up in `STABILIZATION_AND_EXPRESSION_PLAN.md`
alongside this file. Read that document, and `ONBOARDING.md`'s "Recent
history" section, before changing any of those three files.

## 5. How observations and evidence are produced and stored

"Observations" (in the PROJECT_CONSTRAINTS.md #5 sense — every claim must
retain its evidence) are produced entirely by the engine layer running
against a session's transcript and biometric window at `stopAndObserve()`
time, and are attached directly onto the `ReflectionSession` value as
typed arrays (`observations`, `observationEvents`, `dynamicsPatterns`,
`observationCorrelations`) plus the `engineVersion` string that produced
each layer. There is currently no separate "evidence store" — the
evidence *is* the session's own transcript and biometric window, which
travel with it, so any observation can always be traced back to the raw
transcript text it came from.

`ReflectionSessionStore.completedSessions` is persisted to disk as JSON on
every change (`saveCompletedSessions()`), following the same
JSON-file-in-Application-Support pattern `PersistentSignalLibraryStore`
already uses for signal libraries — see section 6. A finished reflection
therefore survives an app relaunch, phone restart, or the app being
terminated in the background. There is no seeded demo data: an empty
history honestly shows "No Reflections Yet" rather than fabricated
`SampleData` that could be mistaken for a real reflection.

Deletion and export are first-class parts of this same evidence trail
(PROJECT_CONSTRAINTS.md #12): `ReflectionSessionStore.deleteReflection(_:)`
removes one session plus its `.caf` audio file;
`ReflectionSessionStore.deleteAllData()` wipes every session and sweeps the
whole reflection Audio directory (including any orphaned audio a past
crash or bug left behind); `ReflectionSessionStore.exportAllReflectionsJSON()`
writes every completed session (transcript, observations, evidence,
consent/provenance metadata) to a JSON file for the system share sheet.
Export deliberately excludes raw audio.

## 6. "Database" / storage schema

There is no database (no CoreData, no SwiftData, no SQLite). Storage is
JSON files on disk, all under the app's Application Support directory
(`FileManager.default.urls(for: .applicationSupportDirectory, ...)`):

- `Observatory/completed_reflections_v1.json` — `[ReflectionSession]` via
  `JSONEncoder`/`JSONDecoder`, written by `ReflectionSessionStore`.
- `Observatory/Audio/<session-id>.caf` — one raw audio file per reflection
  that captured audio, written by `SpeechRecognitionManager` and read by
  `SpeakerDiarizationEngine`.
- `PersistentSignalLibraryStore` encodes `[SignalLibrary]` the same way,
  in its own file, for the separate signal-library subsystem.

`activeSession` (the in-progress reflection) stays in-memory only
(`@Published`, not persisted) until `stopAndObserve()` moves it into
`completedSessions` — an app kill mid-recording loses that one
in-progress reflection, not the ones already completed.

The core `Codable` model types (defined in Models.swift /
SignalLibraryModels.swift) are effectively the schema:
`ReflectionSession`, `TranscriptEvent`, `ObservationEvent`,
`DynamicsPattern`, `ObservationCorrelation`, `BiometricWindow` /
`BiometricSample`, `VoiceSignals` on the reflection side; `SignalLibrary`,
`SignalDetectionRule`, `SignalLibraryMatch` on the signal-library side.
Any future persistence change should serialize these same types rather
than inventing a parallel representation.

## 7. API boundaries / network access / "AI reasoning"

Every analysis engine listed in section 4 is on-device, rule-based Swift
logic (keyword matching, word counts, simple heuristics) — not a
large-language-model prompt, and none of them make network calls. There is
no `URLSession`/`URLRequest` anywhere in this codebase's own code, and no
integration with any external AI/LLM service — a reflection's *content*
(transcript, observations, audio) never leaves the device.

As of speaker diarization (`SpeakerDiarizationEngine`, built on Argmax's
SpeakerKit), this is no longer a zero-network app: SpeakerKit's underlying
Pyannote CoreML models auto-download from Hugging Face the first time
diarization runs, then cache on-device and run fully offline afterward.
That download carries no reflection data — it's a one-time asset fetch,
not a network call made *with* a user's recording — but it means
`SettingsScreen`'s "Cloud sync: Off" row is about data, not about every
network access the app ever makes; worth being precise about that
distinction if this gets asked about.

If a future version adds real "AI reasoning" (an LLM call, a prompt-based
engine, a cloud service) that would be a meaningful architecture change,
not a routine one — it should get its own controlled version, its own
entry in this document (a "Prompt Contracts" section, defining exactly
what data leaves the device and why), and should not be added quietly
inside an existing engine.

## 9. What this document is not

This file describes the current, real structure of the code. It is not a
roadmap and not a constraints document — see VERSION_HISTORY.txt for what
changed when, and PROJECT_CONSTRAINTS.md for binding product/safety rules.
When either Claude or ChatGPT makes an architecture-level decision (a new
store, a new persistence layer, a new cross-cutting naming convention),
update this document in the same commit as the code change, so it never
drifts out of sync with what's actually true.
