# U6 proposal — Interruption-chain recovery + reliability-record defects

**Author:** Claude (Xcode assistant chat) · **Date:** 2026-10-23

## Recap of the three defects (from PLAN.md's smoke-test section, Hermes-verified against the device-container backup)
1. **(a) Recognition never resumes after a chained interruption** (Observatory → Siri → Maps → manual close → Observatory). Session `A6699F43…` (156.6s) persisted only 2 events / 4 words / 34 chars.
2. **(b) Reliability gate didn't record the disruption.** That same session shows `audioRecordingReliable=true` / `missingAudioIntervals=0` despite the interruption — D-09's gate is blind to this class of gap.
3. **(c) Orphaned header-only recording.** `5FF28F05….caf` (4096 bytes, 22:16:22) was created but never finalized — a writer existed but nothing was ever written to it, and nothing recorded that this happened.

## Code-level findings (verified by reading the current code this session, not re-derived from the earlier hypothesis)

**(a)'s mechanism, confirmed:**
- `handleInterruption(type:optionsValue:)` (`SpeechRecognitionManager.swift:768-811`) is the *only* path that can restart listening after an interruption, and it only runs on `.ended`, gated entirely on the OS-reported `AVAudioSessionInterruptionOptionKey`'s `.shouldResume` bit. If that bit comes back `false` — or `.ended` never fires cleanly because a second app (Maps) took over mid-interruption — `isRecording` stays `false` forever and the UI's only recovery text is "Paused by an interruption. Tap Start to resume," which (per `AudioCaptureScreen.swift`) routes through `startCapture()` → `store.startReflection()`, i.e. **a brand-new reflection**, not a resume of the current one.
- Confirmed by grep: there is **zero** `scenePhase`/`UIApplication` foreground-transition handling anywhere in the app (`ObservatoryApp.swift` has no `.onChange(of: scenePhase)`; the only `UIApplication` reference is `openSettingsURLString` in `AudioCaptureScreen.swift`). So the one unambiguous, locally-verifiable signal available — "the person is back looking at this app" — is never used as a backstop to the unreliable `.shouldResume` bit.

**(b)'s mechanism, confirmed:**
- `AudioFileWriter.isReliable`/`missingAudioIntervals` (`SpeechRecognitionManager.swift:270-271`) are mutated **only** inside `recordLoss(frameCount:)` (line 334), which fires solely on an internal `AVAudioFile.write` failure, a buffer-copy failure, or the `maxOutstanding` queue cap being hit.
- During an interruption, `handleInterruption(.began)` (line 776-779) calls `audioEngine.stop()` + `removeTap` — the tap simply stops firing. No buffers arrive, so `enqueue`/`write`/`recordLoss` never run at all for that span. The writer has no way to know a gap happened; `isReliable` stays `true` by default and `missingAudioIntervals` stays empty. This is a real gap in the audio timeline that the D-09 gate is supposed to catch but structurally cannot, because the gate only watches for *write* failures, not *silence-from-no-tap*.

**(c)'s mechanism, a plausible root cause (not device-reproduced, but internally consistent with the observed artifact):**
- `beginListeningSegment()` constructs a brand-new `AudioFileWriter` (lines 607-619, which creates the file immediately — explaining the bare 4096-byte header) and, on a cold start, installs the tap (line 627) *before* `audioEngine.prepare()`/`try audioEngine.start()` (lines 634-635). If `audioSession.setActive`/`audioEngine.start()` throws after the writer already exists, the `catch` block (line 647-650) only sets a status message and calls `stop()` — and `stop()` never touches `audioWriter` at all (lines 813-835). The writer is left alive with zero successful writes, referenced only by `self.audioWriter`, until something eventually overwrites it.
- `start()` (line 519) does exactly that unconditionally on the *next* reflection: `audioWriter = nil`, discarding whatever was there — including a never-flushed, zero-write writer from a prior failed resume — with no call to `finishAudioCapture()`/flush first. The file it was pointed at is abandoned exactly as described.
- Separately, this failure path never informs `ReflectionSessionStore`: the store's own `isRecording` (`activeSession?.state == .recording`) and `SpeechRecognitionManager.isRecording` are two independent booleans with no link back from the manager's internal `stop()` to the store. A `beginListeningSegment()` failure during a resume attempt leaves `activeSession.state == .recording` stuck forever, with no transcript updates and no UI path to end it except the person manually tapping Stop — which is very plausibly what produced the orphaned file's timing (immediately before the person gave up and started the "clean follow-up" session instead).

**This ties all three together**: the common root is that `beginListeningSegment()`'s resume/failure outcomes are never communicated anywhere — not to the reliability record, not to the session store, not to a backstop trigger beyond the single `.shouldResume` bit.

## Scope (files touched this unit)
- `SpeechRecognitionManager.swift` — the only file with real logic changes:
  - A shared, idempotent resume entry point (used by both `handleInterruption(.ended)` and the new scenePhase backstop) instead of duplicating the restart call.
  - A new `AudioFileWriter.recordExternalGap(fromAudioSeconds:toAudioSeconds:)`-style method, called by the manager when an interruption begins and again when it successfully resumes (or fails to), so the gap is recorded in `missingAudioIntervals` and `isReliable` flips to `false` — using the writer's existing `audioSecondsLocked(for:)` math, not a duplicate.
  - Guaranteed finalization: anywhere `audioWriter` is about to be replaced or discarded (`start()`, and the `beginListeningSegment()` failure `catch`), flush it first via the existing `finishAudioCapture()`-style path instead of a bare `= nil`.
  - A new `@MainActor` failure callback (same shape as the existing `onTranscript`/`onSilenceGap` closures passed into `start()`) invoked when a resume attempt or the restart-loop guard gives up for good, so the caller learns recording has honestly ended instead of staying silently stuck.
- `ReflectionSessionStore.swift` — wire that new failure callback to finalize `activeSession` (call the same completion path `stopAndObserve()` already uses) instead of leaving it stuck in `.recording`. No changes to the D-09 field *definitions* — defect (b)'s fix reuses the existing `audioRecordingReliable`/`missingAudioIntervals` fields rather than adding new model fields.
- `AudioCaptureScreen.swift` and `ObservatoryScreen.swift` — add `@Environment(\.scenePhase)` and `.onChange(of:)` to call the new resume backstop when the app becomes active, and wire the new failure callback through to the store (mirroring how `onTranscript`/`onSilenceGap` are already wired per-screen, per the existing diagnostics-duplication pattern both screens already use).
- `Models.swift` — **no changes proposed.** Flagging this explicitly since U6 is partly a "reliability-record" unit: I considered a new field (e.g. an explicit `interruptionOccurred` marker) but concluded `missingAudioIntervals`/`audioRecordingReliable` already say the same thing honestly once (b) is fixed, and D-16/the "no premature abstraction" guidance argue against adding a field that duplicates existing signal.
- Tests — `ObservatoryTests/ObservatoryTests.swift`: new logic-level unit tests (no device needed) for (1) `recordExternalGap` correctly sets `isReliable=false` and records the right audio-relative interval, (2) the shared resume entry point is a no-op when already recording or when there's nothing to resume, (3) replacing/discarding an `audioWriter` always flushes it first (simulate via the existing test seams, not a real device).

**Explicitly out of scope:** E7 (fixture re-record, still deferred past U5 per PLAN.md), anything in U5's accumulation-prototype territory, and any change to the `.measurement` capture-gain decision (D-04/U2 territory).

## Open design questions / things I'm not deciding unilaterally
1. **Resume-attempt failure UX**: today a failed resume just sits silently. My plan ends the reflection honestly (transitions to `.completed`, same as a manual Stop) rather than leaving it stuck — but that means a chained interruption that fails to resume will auto-end the reflection rather than offering a manual "try again" affordance. I think auto-ending-honestly is correct (never silently stuck, matches the project's honesty principle), but it's a product-behavior choice, not a pure bug fix — flagging it rather than deciding it silently.
2. **Scope of the scenePhase backstop**: I'm proposing it only as a *backstop* to the existing `.shouldResume`-gated path (same resume function, second trigger), not a replacement — `.ended` still fires first in the ordinary case. Calling the resume function from two triggers needs a guard (`wasRecordingBeforeInterruption == true && !isRecording`) to stay idempotent if both fire close together; I don't expect this to need anything heavier, but wanted to flag the mechanism before writing it.
3. Per D-13/D-15, this is production capture-lifecycle code and this proposal covers three separate (if related) defects — I'd like a second opinion (ChatGPT review, or your direct sign-off) on the plan above before I touch `SpeechRecognitionManager.swift`, rather than proceeding straight from this proposal to code.

## Verification plan (original pass — superseded by Revision 1 below for the device exit criterion)
- Build + existing 28/28 unit test suite on simulator, plus the new logic-level tests above — reported with real pass/fail counts, not "should pass."
- Per CONVENTIONS.md, a device-container backup is required before any build/install, and any device build/install/test needs your explicit per-action approval — I'll ask separately before that step.
- U6's exit criterion per PLAN.md is a **clean smoke-test re-run** (rollover + chained interruption) plus Hermes forensic verification of the new session data — that's a physical-device action only you can perform; I'll hand you exact repro steps once the code's in and simulator tests pass.

---

# Revision 1 (2026-10-23) — per director ruling: ChatGPT review brief #3 verdict "approve-with-changes, do not implement as written" + Hermes's audio-energy forensics

**No production edits have happened.** This revision replaces the mechanism for (a), the resume-guard design, and the (b) gap representation; it keeps the original (b)/(c) *symptoms* and scope list, but changes how they're fixed. Original sections above are left intact as the record of what was superseded and why — don't re-derive from them, this section wins on conflict.

## R1.1 — Reconciling (a)'s mechanism with the audio-energy forensics

**My original mechanism is falsified.** PLAN.md's new bullet (Hermes, 15s-window `ffmpeg volumedetect` on `A6699F43….caf`) shows the file is 156.6s against a ~157s wall-clock session — essentially no missing duration — with real speech-level audio at 0–45s, 75–105s, and 120–157s, and near-digital-silence (−87 to −90 dB) only at 45–75s and 105–120s, matching the OS mic-mute windows. **The tap/engine kept running and the writer kept receiving and successfully writing buffers for the entire session, including after the user returned to the app and resumed speaking.** `handleInterruption(.began)`'s `audioEngine.stop()`/`removeTap` branch is gated on `guard isRecording else { return }`; the most consistent reading of this evidence is that branch **never ran at all** — i.e. `AVAudioSession.interruptionNotification` likely never fired for this Siri/Maps chain in a way this code observed (plausible: a `.record`-category, `.duckOthers` session may not receive a full interruption the way a phone call would), so `wasRecordingBeforeInterruption` stayed `false` throughout and the entire `.began`/`.ended` resume path was simply never exercised.

That reframes the defect: **this is not an engine-teardown-and-never-resumed bug. It's a recognition-task-death-while-capture-continues bug.** Real, recognizable speech sits in the file at 75–105s and 120–157s, yet only 4 words were ever persisted — so whatever killed the transcript happened to the `SFSpeechRecognitionTask`/its result callback, not to the microphone or the writer.

**Candidate mechanisms, ranked, with what would distinguish them:**
1. **Silent callback death (no `isFinal`, no `error`) — currently my leading candidate.** `ObservatoryTests/FixtureReplayHarness.swift:375-385` documents that production's existing `handleRecognition` already treats *any* per-segment error (including the observed `kAFAssistantErrorDomain` code 1110, "No speech detected") as a normal rollover trigger — `shouldRollover = (result?.isFinal == true) || (error != nil)` → seal + `beginListeningSegment()` — not a fatal stop. If a 1110 (or any) error had fired live, the existing code should have already rolled over and kept listening through the 75–105s speech window. Since nothing updated for the rest of the recording, the more consistent explanation is that the recognition task's result handler **simply stopped being invoked at all** after the first long silence — no callback, so `handleRecognition` never runs again, so nothing ever triggers a rollover. This matches E8's own corroboration note (Apple Developer Forums thread 762952, "disappear after pause") and is structurally invisible to every piece of logic in this file, because everything here is purely reactive to that callback.
2. **Restart-loop guard misfire.** If 1110-style errors *did* fire repeatedly in a tight burst right as the mute window began, `isRestartLoopDetected()` (>5 restarts/10s) could trip and call internal `stop()` — but `stop()` tears down the engine/tap, which contradicts the forensics (writer kept receiving buffers through 157s). I'm ranking this below (1) because it doesn't fit the evidence as cleanly, but I can't fully rule it out from static reading alone.
3. **`.began` *did* fire but `.ended` resumed so fast (engine restart) that a 15s ffmpeg window can't distinguish "never stopped" from "stopped and restarted in under a second."** Possible, but doesn't change the fix: either way, something about resuming *recognition* (not capture) after the mute window failed silently.

**Given I can't fully adjudicate between (1) and (2) from code alone, the fix below is deliberately mechanism-agnostic**: rather than betting on one precise cause, it adds (a) a watchdog that detects "we believe we're recording but recognition has gone silent" regardless of *why*, and (b) diagnostic logging (error domain/code, generation, elapsed-since-last-callback) on every recovery attempt, so the next device smoke-test run gives Hermes hard evidence of which mechanism actually fired — closing the loop properly instead of shipping a fix for an unconfirmed cause.

## R1.2 — Replacing the dual-trigger guard with a serialized lifecycle owner + generation identity (ChatGPT Q2)

`SpeechRecognitionManager` is already `@MainActor` (class-level, `SpeechRecognitionManager.swift:6-7`), and every external trigger already hops onto it via `Task { @MainActor ... }` — so "serialized" doesn't require a new actor/lock, just consolidating every trigger into one owning function instead of letting each caller mutate flags and call `beginListeningSegment()` independently. Design:

- **One reflection identity, not just a request generation.** `requestGeneration` (D-06) already invalidates stale *recognition callbacks* within one reflection. This adds a `reflectionID` (the session's own UUID, already the basis of `audioFileName`) set once per `start()` call and threaded through every async trigger — the scenePhase backstop, the watchdog, and the new failure callback all check "is this still the active `reflectionID`" before acting, so a trigger that fires late (after Stop, or after a brand-new reflection started) is a safe no-op instead of reviving or corrupting the wrong session. This directly answers "a delayed trigger could revive an obsolete session."
- **An explicit lifecycle state, not booleans.** Replace the `isRecording`/`wasRecordingBeforeInterruption` boolean pair with one enum owned by a single method:
  ```swift
  private enum LifecycleState {
      case idle
      case active                          // listening normally
      case recovering(attempt: Int)        // a bounded recovery is in flight
      case stopped(Reason)                 // terminal — user, or gave-up-for-good
  }
  private enum Reason { case userStop, recoveryExhausted, unsupported }
  ```
  `isRecording` becomes a computed property (`if case .active = state`). "Recording intent" — whether the *person* wants this reflection still running — is tracked separately as `recordingIntent: Bool`, set `true` in `start()` and set `false` **only** by an explicit user Stop, never by a transient failure; this is what answers "explicit Stop must revoke that intent immediately" and lets recovery logic ask "does the person still want this running?" independent of "is the engine currently running?"
- **One shared recovery function**, `attemptRecovery(reason: RecoveryTrigger)`, called from exactly four places with defined precedence (first match wins, each checks `recordingIntent && reflectionID == current` first):
  1. Normal rollover (`result?.isFinal == true`, no error) — **not** a "recovery," unlimited, unchanged from today.
  2. A recognition error (`error != nil`) — today's existing path, now routed through the shared function instead of inline in `handleRecognition`.
  3. `handleInterruption(.ended)` with `.shouldResume` true (or false — see R1.4's copy fix) — existing OS-signal path, now a trigger into the same function instead of a separate inline call to `beginListeningSegment()`.
  4. **New:** a watchdog timer (fires every ~20s while `state == .active`) comparing `Date()` against a `lastRecognitionCallbackAt` timestamp (updated at the top of `handleRecognition`, success or error) **and** confirming via the writer that buffers are still arriving (`AudioFileWriter` already tracks `writtenFrames`; expose a cheap "frames written since timestamp X" check) — so a real stall is distinguished from the person legitimately being quiet. If recognition has gone stale (>~25s with no callback) while audio keeps flowing, that's mechanism (1) above, live — force a recovery attempt.
  5. **New:** scenePhase becoming `.active` — per ChatGPT's instruction, this does **not** independently call `beginListeningSegment()`; it calls the same `attemptRecovery(reason: .foregroundReconciliation)`, which no-ops immediately if `state == .active` and `lastRecognitionCallbackAt` is recent (nothing wrong), and only acts if the watchdog condition above is *also* true.
- **Bounded, shared recovery budget (ChatGPT Q1).** One counter per reflection (not per 10-second window) — e.g. max 5 recovery attempts with a short cooldown between them, reusing/renaming the existing `recentAutoRestarts`/`isRestartLoopDetected` accounting but scoping it to the whole `reflectionID` and sharing it across *all four* trigger sources above, not just recognition errors. Exhausting the budget, or hitting an unsupported-recognizer condition, is "fails for good": `state = .stopped(.recoveryExhausted)`, engine/tap torn down deliberately (not left in an ambiguous half-state), and the new failure callback fires.

## R1.3 — Resolving the gap coordinate system (ChatGPT Q3)

**Consumer audit (grepped across the whole app this session):** `missingAudioIntervals`/`AudioInterval` are referenced in exactly four places outside their declaration and the writer that produces them: `ReflectionSessionStore.swift` (three plain field-copy sites — session → session, no position math) and the `finishAudioCapture`/`diagnosticsSnapshot` plumbing in `SpeechRecognitionManager.swift` itself. **`SpeakerDiarizationEngine.swift` — the one place PLAN.md/STABILIZATION plan say this field is supposed to gate — only reads the boolean (`guard session.audioRecordingReliable != false else { return session }`, line 79); it never reads interval `.start`/`.end`.** No UI screen displays interval positions. Nothing today depends on this field's coordinate system beyond "non-empty + `false` boolean ⇒ don't trust this audio."

That audit removes the main risk (a live consumer silently misinterpreting a mixed coordinate system) but doesn't remove ChatGPT's actual objection: **the capture-survived case has no "hole" in the file to describe.** Per D-05, file-time only advances on successful writes — during a genuine future write-failure gap (the *original*, still-correct (b) scenario — queue overflow, disk error) there's a real missing span expressible in audio-file-relative seconds. During *this* session's actual failure mode, the writer kept writing real (if quiet or OS-muted) buffers the whole time — there is no missing audio span to report, and fabricating one in `missingAudioIntervals` would be false by this field's own documented meaning (D-05/D-09) and could mislead a future diarization/acoustic consumer into skipping audio that's actually present.

**Decision: narrow, don't overload.**
- **`missingAudioIntervals`/`audioRecordingReliable` keep their exact current meaning and coordinate system, untouched.** They still fire correctly for true write-failure gaps (queue overflow, `AVAudioFile.write` throwing) — that mechanism in the original proposal (writer-side `recordLoss`) was already correct and stays as-is; R1 does not add an interruption-shaped fabrication into this field.
- **One new, minimal, additive field — an honest flag, not an interval** (per ChatGPT's "narrow U6's promise to an honest reliability flag" option, since no existing field can represent this without inventing a coordinate system; D-07-style nil-means-unavailable, backward-compatible decode):
  ```swift
  /// Set when this session's recognition task went silent (or errored
  /// repeatedly) while the audio writer confirms capture continued --
  /// i.e. a recognition-continuity gap, not an audio-loss gap (see
  /// `missingAudioIntervals` for that). Deliberately NOT an AudioInterval:
  /// there is no missing audio span to report (D-05's file timeline has
  /// no "hole" when every buffer still wrote successfully), only a wall-
  /// clock-relative moment recovery was attempted. `nil` means this never
  /// happened or predates this field -- never defaulted to `false`.
  var recognitionContinuityGaps: [Date]? = nil
  ```
  Wall-clock instants only (when `attemptRecovery` fired), no claimed duration, no audio-file offset — exactly the "zero-duration boundary identifies a discontinuity but cannot represent how much capture was missed" framing ChatGPT used to reject the audio-seconds approach, applied honestly instead of worked around. `SpeakerDiarizationEngine`/future Stage-1 code can later decide whether to treat a session with non-empty `recognitionContinuityGaps` specially (e.g. surfacing it in diagnostics); R1 doesn't force that decision, it only makes the fact recordable and honest.
- This is the one deviation from the original proposal's "no Models.swift changes" line — flagging it explicitly as a reversal, for the reason above (ChatGPT's Q3 is correct that the no-new-fields constraint was incompatible with representing this honestly).

## R1.4 — Q1/Q4/Q5/Q6 incorporation

- **Q1 (bounded recovery) — done above in R1.2**: a shared per-reflection budget, not an auto-end-on-first-failure. "Fails for good" = budget exhausted, or an unsupported-recognizer condition, or explicit user Stop — defined precisely rather than left implicit.
- **Q4 (zero-write cleanup by frame count, not byte size).** `AudioFileWriter` gets a `hasWrittenAnyFrames: Bool` accessor (reads the existing private `writtenFrames` under its lock — no new bookkeeping). Wherever a writer is about to be replaced/discarded (`start()`'s old bare `audioWriter = nil`, and the `beginListeningSegment()` failure catch), the revised flow is: flush → check `hasWrittenAnyFrames` → if `true`, keep the file (it has real content, even if short) and record it through whatever finalization path already applies (same as a normal stop); if `false`, close it and **delete the file**, verified by the frame count rather than inferring "orphaned" from a 4096-byte magic number, and treat the deletion failure case explicitly (log it; don't silently swallow a `FileManager` error). This replaces my original "always finalize" language, which didn't distinguish a genuinely empty writer from a short-but-real one.
- **Q5 (session-identified, exactly-once failure callback).** The new terminal-failure callback (fired from `state = .stopped(.recoveryExhausted)` or `.unsupported`) now carries the `reflectionID` it applies to, not just a bare signal. `ReflectionSessionStore` checks `activeSession?.id == thatID` before acting (ignores stale callbacks from an already-superseded reflection) and finalizes through **one shared internal completion helper** that both the user-initiated Stop path and this terminal-failure path call — guarded so it only ever runs once per session (e.g. an early `guard activeSession?.state == .recording else { return }`, which `stopAndObserve` already effectively has). User Stop and terminal failure still produce different user-visible status text (one is "you stopped"; one is "recording ended because recovery failed") even though they share the same finalization mechanics.
- **Q6 — incorporated:**
  - *Capture health vs. transcript health kept separate*, per R1.3: `audioRecordingReliable`/`missingAudioIntervals` = capture health (write-failure only); `recognitionContinuityGaps` = transcript/recognition health. The device exit criterion below checks both independently.
  - *Closing gaps on actual recovery, not just a successful restart call*: for a genuine future write-failure gap (b)'s original mechanism, the gap closes on the writer's **first successful write after the loss**, not when `beginListeningSegment()` merely returns without throwing — `recordLoss`'s existing call site already only fires on an actual failed write, so the "close" side of this is: track the open interval's end only once `write()` succeeds again, not at call-time of the recovery attempt. Outstanding open intervals are also closed out (to "unknown end" rather than left dangling) at terminal stop/failure, same place the terminal-failure callback fires.
  - *Absent notifications handled* via the watchdog in R1.2 (trigger 4) — recovery no longer depends exclusively on `.began`/`.ended` ever firing, matching this session's actual failure mode where they apparently didn't fire at all.
  - *Writer ownership across segments defined*: exactly one `audioWriter` reference is live at a time, owned by the same lifecycle-owner function that owns `state`; replacement always goes through the flush-then-decide-keep-or-delete sequence in the Q4 bullet above, and "flush" here means actually awaiting the writer's `flush()` before the decision, not merely calling it (closing the gap ChatGPT flagged: "initiating it does not establish flush before discard").
  - **Copy fix**: `"Paused by an interruption. Tap Start to resume."` (`SpeechRecognitionManager.swift:805`) is corrected to something that doesn't imply the Start button is a resume affordance — e.g. `"Recording ended — recovery didn't succeed."` when recovery is actually exhausted (since by R1.2's design, the person should rarely if ever see an indefinite "tap to resume" state: either recovery succeeds automatically or the reflection ends honestly). In scope for this unit, per ChatGPT's instruction.
  - **Expanded test matrix** (replacing the original's three thin bullets), all logic-level/simulator, no device needed: duplicate/near-simultaneous triggers (watchdog + scenePhase firing together), a chained-interruption simulation (`.began`→`.began`-again-without-`.ended`→single `.ended`), explicit Stop arriving while a recovery attempt is in flight, a stale failure callback arriving after a *new* reflection already started (must no-op), restart failures injected at each resource-acquisition step in `beginListeningSegment()` (session activation, engine start, tap install), zero-write cleanup (writer created, never written, discarded — file must not exist afterward) vs. partial-write preservation (writer created, one buffer written, discarded — file must be kept), and a rollover happening concurrently with a recovery attempt. Assertions check persisted `ReflectionSession` state and actual file presence/frame counts on disk, not just that a callback fired N times.
  - **Measurable device exit criterion** (replaces the original's vague "clean smoke-test re-run"): a scripted repro — recognizable, distinct scripted phrases before the interruption, during the window right after returning, and near the end — with the following checked post-hoc against the device-container backup, matching Q6's list:
    1. The transcript contains recognizable words from **both** the pre-interruption and post-interruption phrases (not just total word count).
    2. `recognitionContinuityGaps` is non-empty and its timestamp(s) fall within the actual interruption window.
    3. `audioRecordingReliable`/`missingAudioIntervals` correctly reflect whether any *write* failure also occurred (expected: still reliable, since this mechanism is about recognition, not capture — asserting the fix didn't regress into fabricating audio-loss intervals).
    4. Final session `state == .completed`, reached without the person needing to force-stop anything.
    5. No orphaned zero-frame `.caf` file left in the Audio/ directory after the run.
    6. Diagnostic logs captured during the run show which of R1.1's candidate mechanisms (1), (2), or (3) actually fired, closing the open question from R1.1.

## R1.5 — Scope re-confirmation
Still `SpeechRecognitionManager.swift`, `ReflectionSessionStore.swift`, `AudioCaptureScreen.swift`/`ObservatoryScreen.swift`, `ObservatoryTests/ObservatoryTests.swift` — plus, per R1.3, one small additive change to `Models.swift` (`recognitionContinuityGaps` field only). Still excludes E7, U5's accumulation prototype, and the `.measurement` capture-gain decision. No production edits until you sign off on this revision — per your instruction, holding here.

---

# Revision 2 (2026-10-23) — three required fixes per director ruling on Revision 1

Director ruling: approved in direction; all cited line numbers/code claims independently verified accurate; the `Models.swift` reversal (`recognitionContinuityGaps: [Date]?`) is authorized. Three specific defects in Revision 1 itself required fixing before any code. Still no production edits — holding for sign-off after this. Each fix below states which Revision 1 passage it replaces; Revision 1's text above is left as the record of what was wrong and why, per this file's own established convention.

## R2.1 — Fixing the gap-closing contradiction (replaces R1.4's "Closing gaps on actual recovery..." bullet)

**This was simply wrong — withdrawn, not refined.** `recordLoss(frameCount:)` (`SpeechRecognitionManager.swift:334-341`) is called with the exact `frameCount` of the buffer that failed to write, and computes **both** `start` and `end` of the lost span synchronously, in one call, from `writtenFrames` and `writtenFrames + frameCount` — there is no "open" state to later "close." My Revision 1 language ("the gap closes on the writer's first successful write after the loss... track the open interval's end only once write() succeeds again... closed to 'unknown end' at terminal stop") described a stateful open/close mechanism that doesn't exist in the current code, isn't needed, and — as the director points out — has no representation in `AudioInterval` anyway (a half-open interval with an "unknown end" isn't expressible in a `start`/`end` struct without reintroducing the exact fabrication problem R1.3 just resolved).

**Precise statement, replacing it:** `recordLoss(frameCount:)` keeps its exact current one-shot behavior, unmodified by U6. It already correctly records a complete, accurate `AudioInterval` (both bounds known) at the moment a write fails, for true write-failure gaps (queue overflow, `AVAudioFile.write` throwing) — the only case `missingAudioIntervals` represents, per R1.3's decision. U6 adds no new call sites to `recordLoss`, no open-interval bookkeeping, and no "unknown end" variant. The recognition-continuity side (R1.3's `recognitionContinuityGaps: [Date]?`) is a flat list of wall-clock instants with no start/end pairing at all, so it has no open/close question either. There is nothing left for R1 to add here beyond what already existed before this unit started.

## R2.2 — Fixing the quiet-reflection auto-end failure mode (replaces R1.2's "Bounded, shared recovery budget" bullet and the `LifecycleState.recovering(attempt:)` sketch)

Director's framing adopted directly: the fix is **only failed attempts count toward the terminal budget; a successful recovery — of any trigger, including the watchdog — never does**, no matter how many times it happens. This is the stronger and simpler of the two options the director offered (over requiring "prior callback activity in the current segment"), because it fixes the stated failure mode completely on its own: a 10-minute legitimate silence can make the watchdog fire ~24 times, and as long as each `beginListeningSegment()` call successfully swaps in a new request (no throw), the budget stays at zero and the reflection is never auto-ended. The "prior callback activity" check doesn't by itself prevent budget consumption on repeated *successful* watchdog recoveries, so it would need to be paired with this same failure-only rule anyway — adopting the failure-only rule alone is sufficient and simpler, so that's the one stated here.

Precise redefinition:
```swift
private enum LifecycleState {
    case idle
    case active                     // listening normally
    case recovering                 // a recovery attempt is in flight (no attempt count here)
    case stopped(Reason)            // terminal
}
private enum Reason { case userStop, recoveryExhausted, unsupported }

/// Count of CONSECUTIVE failures to establish a new recognition request
/// (beginListeningSegment() throwing, or the equivalent precondition --
/// e.g. recognizer unavailable -- failing) across this reflection's
/// entire lifetime, regardless of which trigger (error callback,
/// watchdog, interruption-end, foreground reconciliation) caused the
/// attempt. Reset to 0 on every SUCCESSFUL attempt. This is NOT a count
/// of attempts or triggers -- a reflection can legitimately accumulate
/// dozens of successful watchdog-triggered rollovers across a long quiet
/// stretch without ever moving this counter off zero.
private var consecutiveRecoveryFailures = 0
private static let maxConsecutiveRecoveryFailures = 5
```
`attemptRecovery(reason:)` calls `beginListeningSegment()` (or the equivalent resource-reacquisition path) and, on success, resets `consecutiveRecoveryFailures = 0` and returns to `.active`; on failure (a thrown error during session/engine/tap setup, mirroring the old `catch` block), increments the counter, and only transitions to `state = .stopped(.recoveryExhausted)` once `consecutiveRecoveryFailures >= maxConsecutiveRecoveryFailures`. This replaces the old `recentAutoRestarts`/`isRestartLoopDetected` time-windowed design (">5 in 10 seconds") with a failure-count design, because the old design had the same class of problem one level down: enough *successful* rollovers within a 10-second window (unlikely but not impossible under pathological audio) could also have tripped it. Counting only failures removes that risk entirely rather than narrowing the window.

This also simplifies R1.4's Q1 answer: "fails for good" is now precisely "five consecutive failed attempts to (re)acquire a working recognition request," not a vaguer "budget exhausted."

## R2.3 — Fixing the stale-tap-reference bug (new section; R1's Q4 "flush-then-keep-or-delete" accounting is amended, not replaced)

Confirmed by rereading the exact code: the cold-start tap install (`SpeechRecognitionManager.swift:627`) is `{ [currentRequestBox, silenceTracker, generationBox, audioWriter] buffer, _ in ... audioWriter?.enqueue(...) }` — an explicit capture list that snapshots the **object reference** `audioWriter` pointed to at the moment the tap was installed. `currentRequestBox`/`generationBox` deliberately avoid this problem already (they're `NSLock`-protected boxes read fresh on every callback via `.get()`); `audioWriter` is the one piece of mutable state in that closure that was captured as a frozen value instead of going through a box. Under the **unmodified existing code**, this never surfaces as a bug, because `beginListeningSegment()` only ever creates a writer when `audioWriter == nil`, and a reflection only ever reaches that state once (at a true cold start) — so the captured reference and `self.audioWriter` happen to stay in sync for the lifetime of any single reflection today. It becomes a real bug the moment U6 introduces any path that can replace `self.audioWriter` for a reflection whose tap is already running — which R1's Q4 flush-then-keep-or-delete logic does, at minimum on the `start()` → next-reflection boundary, and potentially on a same-reflection retry if a future revision ever needed to discard a partially-written writer mid-reflection. Director's fix 3 is correct: Q4 as written is blind to this, and a discarded writer whose tap reference is still live would keep silently receiving `enqueue()` calls forever.

**Chosen mechanism: read the current value on every callback, matching the existing `CurrentRequestBox`/`GenerationBox` pattern — not tap reinstallation.** Reinstalling the tap on every writer replacement was the other option the director offered, but it would violate D-06's explicit invariant ("the audio engine is never stopped/restarted at segment boundaries — only the recognition request is swapped") for a reason that has nothing to do with segment boundaries, and it reintroduces a (smaller but real) gap risk right at the replacement instant. The box pattern has neither problem and costs one small addition, exactly mirroring what's already there:
```swift
private final class AudioWriterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var writer: AudioFileWriter?
    func set(_ newWriter: AudioFileWriter?) {
        lock.lock(); writer = newWriter; lock.unlock()
    }
    func get() -> AudioFileWriter? {
        lock.lock(); defer { lock.unlock() }
        return writer
    }
}
private let audioWriterBox = AudioWriterBox()
```
The cold-start tap install becomes `{ [currentRequestBox, silenceTracker, generationBox, audioWriterBox] buffer, _ in ... audioWriterBox.get()?.enqueue(...) }` — capturing the box (an immutable `let`, safe to capture by value as today) instead of a writer snapshot, so every buffer callback reads whichever writer is *currently* live, with no reinstall needed.

To guarantee `self.audioWriter` (the `@MainActor`-side property everything else reads) and `audioWriterBox` can never disagree, every assignment to `audioWriter` anywhere in the file goes through one helper instead of a bare `=`:
```swift
private func setAudioWriter(_ writer: AudioFileWriter?) {
    audioWriter = writer
    audioWriterBox.set(writer)
}
```
Revision 1's Q4 flush-then-keep-or-delete sequence is amended to end by calling `setAudioWriter(nil)` (writer discarded, whether kept-on-disk or deleted) or `setAudioWriter(newWriter)` (a genuinely new reflection's writer) — never a bare `audioWriter = nil`/`audioWriter = AudioFileWriter(...)`. This closes the window completely: from the moment `setAudioWriter` returns, the running tap's very next buffer callback reads the box and gets the new value — there is no interval, however short, where a live tap feeds a reference nothing else holds.

This also slightly changes R1's scope line for `SpeechRecognitionManager.swift`: it now includes this one new box type + the `setAudioWriter` helper, replacing every existing bare `audioWriter = ...` assignment (there are two in the unmodified code today — `start()`'s reset and `beginListeningSegment()`'s creation — both become calls through the helper).

## R2.4 — Scope re-confirmation (supersedes R1.5)
Unchanged file list: `SpeechRecognitionManager.swift`, `ReflectionSessionStore.swift`, `AudioCaptureScreen.swift`/`ObservatoryScreen.swift`, `ObservatoryTests/ObservatoryTests.swift`, plus the one additive `Models.swift` field (`recognitionContinuityGaps: [Date]?`, authorized). R2.3 adds one small private type (`AudioWriterBox`) and one private helper (`setAudioWriter(_:)`) to `SpeechRecognitionManager.swift` — no new files, no scope-list change. Still excludes E7, U5's accumulation prototype, and the `.measurement` capture-gain decision. **No production edits until you sign off on this revision.**

---

# R2.5 addendum (2026-10-23) — two amendments per director sign-off on Revision 2

Director: CONDITIONALLY APPROVED. R2.1 and R2.3's box-over-reinstall choice stand as written. Two corrections required to R2.2 and R2.3 before implementation; both verified against the current code before writing this addendum (re-read `SpeechRecognitionManager.swift` at the exact lines cited).

## Amendment 1 — keep `isRestartLoopDetected()`; add the consecutive-failure budget alongside it, don't replace it

R2.2 was wrong to retire the existing rate-window guard. `isRestartLoopDetected()` (`SpeechRecognitionManager.swift:756-761`, tripped at the `guard !isRestartLoopDetected()` call site, line 737, >5 restarts in any 10-second window) catches a *different* pathology than the new consecutive-failure counter: a tight loop where `beginListeningSegment()` keeps **succeeding** (session/engine/tap setup all fine) but the recognition task keeps erroring asynchronously almost immediately after each restart. My consecutive-failure counter resets to 0 on every successful `beginListeningSegment()` call, so it would never trip in that scenario — unbounded request churn, every single time. My stated justification for removing it (normal rollovers are ~60s apart; the new watchdog has a ~20s floor; so legitimate cycles can't reach 6-in-10s) was about why the *old* guard wouldn't false-positive under the *new* design — it says nothing about why the old guard is now unnecessary for the pathology it was built for. That pathology is still possible and the new counter doesn't cover it. Confirmed: U6 adds protections, it does not remove existing ones.

**Corrected design:** both guards run, unchanged relative to each other, checked at the same point in `attemptRecovery(reason:)`:
- `isRestartLoopDetected()` — exactly as it exists today (lines 756-761), unmodified. Tripping it is immediately terminal: `state = .stopped(.recoveryExhausted)`, engine/tap torn down, the new session-identified failure callback fires (R1.4's Q5 mechanics) — same terminal path the consecutive-failure budget uses, just reached by a different trigger.
- `consecutiveRecoveryFailures >= maxConsecutiveRecoveryFailures` (R2.2's new counter) — reaches the same terminal path, independently.

Either guard tripping is sufficient on its own; neither is removed in favor of the other. `recentAutoRestarts` (the array `isRestartLoopDetected()` reads) keeps being appended to on every recovery *attempt* (not gated on success/failure, exactly as today — line ~759's `recentAutoRestarts.append(now)` runs unconditionally per attempt); `consecutiveRecoveryFailures` is the new, separate counter that only moves on actual failure, per R2.2.

**"Failure" for the new counter, confirmed to include non-throwing early returns.** `beginListeningSegment()` has three ways to fail to establish a working request: the `catch` around session/engine setup (the throwing path R2.2 already covered), and two **non-throwing early returns** that are just as much a failure to re-acquire recognition: `guard let speechRecognizer, speechRecognizer.isAvailable else { statusMessage = ...; return }` (lines 548-551) and `guard speechRecognizer.supportsOnDeviceRecognition else { statusMessage = ...; stop() }` (lines 560-564). Both must increment `consecutiveRecoveryFailures` exactly as the `catch` block does — a `beginListeningSegment()` call that returns early without ever reaching `isRecording = true`/installing a working request is a failed recovery attempt by definition, whether it failed via `throw` or via `return`. (The `supportsOnDeviceRecognition` guard already calls `stop()` itself, which is correct independent of this — that's an unsupported-device condition, not a transient one, so a future revision could reasonably make it terminal on the first occurrence rather than spending budget on retries that will deterministically fail the same way every time; R2.5 doesn't change that behavior, just confirms it also counts toward the shared failure tally if it's ever reached mid-reflection rather than at cold start.)

## Amendment 2 — four `audioWriter` assignment sites, not two; all four route through `setAudioWriter(_:)`

Re-verified against the current file. R2.3 undercounted — there are **four** bare assignments, not two:
1. `start()`, line 519 — `audioWriter = nil` (reset at the top of a new reflection).
2. `beginListeningSegment()`, line 613 — `audioWriter = try AudioFileWriter(url:format:)` (creation on cold start).
3. `beginListeningSegment()`, line 618 — `audioWriter = nil`, inside the `catch` for the directory-creation/`AudioFileWriter.init` failure at line 614 (missed in R2.3 entirely).
4. `finishAudioCapture()`, line 848 — `audioWriter = nil`, after `await writer.flush()` (missed in R2.3 entirely — and the most important omission: this is the **normal, successful end-of-reflection path**, called on every clean `stopAndObserve()`. A bare `nil` here is exactly the box-vs-property disagreement R2.3 exists to prevent — if the tap happens to still be running at this instant for any reason, it would keep feeding the now-discarded writer via the stale box-less capture R2.3 is replacing; even post-fix, leaving this one site as a bare assignment would reintroduce the exact bug in the one place most reflections actually pass through.)

All four become calls to `setAudioWriter(_:)` (R2.3's helper, unchanged): `setAudioWriter(nil)` at sites 1, 3, and 4; `setAudioWriter(try AudioFileWriter(...))` at site 2 (restructured slightly so the helper is called with the already-constructed writer rather than assigning inside a `do` block, e.g. `let writer = try AudioFileWriter(...); setAudioWriter(writer)`). No bare `audioWriter = ...` assignment remains anywhere in the file after this change.

## R2.6 — Status
Both amendments incorporated into the design above; no further changes to R2.1's withdrawal or R2.3's box mechanism. Per director sign-off, implementation may now begin: `SpeechRecognitionManager.swift`, `ReflectionSessionStore.swift`, `AudioCaptureScreen.swift`/`ObservatoryScreen.swift`, `Models.swift` (`recognitionContinuityGaps` only), `ObservatoryTests/ObservatoryTests.swift`. Build + full unit suite (existing 28 + new matrix) on simulator next, with real pass/fail counts reported — no device build/install/test without asking separately first, and a device-container backup before any device step, per CONVENTIONS.md.

---

# R3 (2026-10-23) — watchdog gate defect found in director verification, fixed

**Defect (found by director code inspection, not by the test suite — the test matrix promised in R2.6 didn't exist yet at the time this shipped):** `attemptRecovery`'s `isRecognitionStale()` gate was applied only to `.foregroundReconciliation`, not to `.watchdogStall`. As implemented, the watchdog timer forced a recovery attempt (and appended a `recognitionContinuityGaps` entry) every `watchdogInterval` (20s) unconditionally — on every healthy recording, not only a stalled one. This would have forced a rollover roughly every 20s instead of Apple's normal ~1-minute cadence (multiplying E8 reset opportunities) and corrupted `recognitionContinuityGaps` with a phantom entry every 20s, directly auto-failing device exit criterion #2 ("`recognitionContinuityGaps` ... timestamp(s) fall within the actual interruption window").

**Fix:** one-line change to the trigger-type check gating `isRecognitionStale()` — `if trigger == .foregroundReconciliation` became `if trigger == .foregroundReconciliation || trigger == .watchdogStall`, so both triggers that are supposed to be stall-gated (per R1.2's original trigger-4/trigger-5 design) actually are. No other logic changed.

**Tests added in response (closing the gap this defect exposed — the matrix itself, not just the fix):**
1. Watchdog does **not** force recovery or append a gap while callbacks are fresh — the test that would have caught this defect directly.
2. Watchdog **does** force recovery and appends exactly one gap entry when callbacks are stale while buffers keep flowing.
3. Zero-write cleanup: a writer that never received a successfully-written frame is deleted on discard.
4. Partial-write preservation: a writer with ≥1 written frame is kept on discard.
5. A stale trigger carrying an old `reflectionID` after a new reflection has started is a no-op.

All five are logic-level, simulator-only, and pass (see director's verification against the `2026-10-23 17:40:14` xcresult bundle: 43/43 logic tests, 28 baseline + 15 new). Achieving this without live hardware required one additional, explicitly-documented change beyond R2's scope: several `SpeechRecognitionManager` recovery-path properties/methods (`lifecycleState`, `reflectionID`, `recordingIntent`, `lastRecognitionCallbackAt`, `recognitionContinuityGaps`, `recentAutoRestarts`, `attemptRecovery`, `setAudioWriter`, `discardCurrentAudioWriterIfAny`, the nested `AudioFileWriter` type) went from `private` to `internal` so tests can drive them directly — no behavior change, access-level only, matching this file's existing precedent (`SpeakerDiarizationEngine`'s exposed static helpers). `discardCurrentAudioWriterIfAny()` additionally now returns its spawned cleanup `Task` (`@discardableResult`) so a test can `await` it deterministically instead of guessing a sleep duration; every production call site still ignores the return value.

## R3.1 — Status
Director verification PASSED. U6 implementation accepted. Next: the device phase (container backup → build/install approval → scripted smoke-test repro mapped to the six device exit criteria), each step gated on separate user approval per CONVENTIONS.md. No PLAN.md/VERSION_HISTORY.txt/DECISIONS.md updates yet and no commit proposal until Hermes forensically verifies the device run against all six criteria.

---

# R4 (2026-10-23) — device smoke test FAILED; design for D1/D3 (DESIGN ONLY, no code yet)

Run 2026-10-23 ~18:20 PDT: criteria 1 ❌, 2 ✓, 3 ❌, 4 ~ (completed only via manual Stop), 5 ✓, 6 ✓ (mechanism identified; restart's own error reason never logged). Two critical defects (D1, D2) and one minor (D3) found from the console log + post-run container. **This section covers D1 and D3 only — D2 (the reliability-record question) is routed to ChatGPT per the Q3 precedent; see `PROPOSALS/U6-chatgpt-review-brief-4.md`.** No implementation until the director reviews this section; D1/D3 may then proceed independently of D2, which waits for the ChatGPT reply.

## R4.1 — D1: the buffers-flowing requirement makes a dead engine permanently unrecoverable

**Mechanism, confirmed from the log:** `.began` (guardPassed=true, engine torn down) → `.ended` (shouldResume=true) → `attemptRecovery(.interruptionEnded)` ran → `beginListeningSegment()` failed (generation advanced 1→2, no "recovery succeeded" line ever printed) → `lifecycleState` stuck at `.recovering`, `consecutiveRecoveryFailures` frozen at 1/5. Every subsequent watchdog/foreground trigger hit `isRecognitionStale()` (`SpeechRecognitionManager.swift:1099-1106`), which requires `audioWriter?.hasReceivedBuffer(since:)` to be true (line 1105) alongside a stale callback — but the engine never restarted, so no buffer will *ever* arrive again. This makes the gate permanently `false`, so `attemptRecovery` never gets past its own `guard isRecognitionStale() else { return }` (line 1059) to even reach `beginListeningSegment()` a second time. `consecutiveRecoveryFailures` can only increment *inside* that call, so it never moves past 1, and `finishWithFailure` never fires. The reflection sat silently broken for 100+ seconds until the person gave up and pressed Stop.

**Root cause, precisely stated:** `isRecognitionStale()` conflates two distinct failure modes under one gate:
- **Mode A (the unit's original target):** the engine/tap is alive and buffers ARE flowing, but the recognition *task* alone has gone silent (no callback). Requiring "buffers flowing" here is correct — it's what distinguishes "recognition died" from "the person backgrounded the app and capture legitimately paused."
- **Mode B (what this run actually hit):** a restart attempt already failed, so the engine itself isn't running — buffers structurally *cannot* be flowing, by construction, until a *future* restart succeeds. Requiring "buffers flowing" as a precondition for *attempting that future restart* is circular: it can never be satisfied by the state it's meant to escape.

My design comment on this gate (R1.2-era) said "a stale callback with NO buffers either just means the engine itself is quiet (e.g. backgrounded with capture legitimately paused)" — true for the backgrounded case, **false** for Mode B, which I didn't distinguish from it. Similarly my comment at `attemptRecovery`'s failure branch ("stays `.recovering` -- the next trigger (the watchdog, most likely) tries again") is false whenever the failure mode is Mode B, because the watchdog's own gate is what's blocking that next try.

**Fix:** add a second, independent condition that doesn't require buffers-flowing, recognizing Mode B directly from state that's already tracked -- no new properties needed. Immediately after the existing guard-chain in `attemptRecovery` establishes `recordingIntent == true` and `lifecycleState != .stopped` (line 1048), `lifecycleState == .recovering` at the moment a watchdog/foreground trigger fires *already* means "the last attempt left us short of `.active`" -- every call to `attemptRecovery` runs synchronously to completion (MainActor-serialized, no concurrent in-flight state to worry about), so there's no intermediate state to distinguish "actively retrying right now" from "stuck after a failed attempt." Replace the trigger gate at lines 1050-1060 with:
```swift
if trigger == .foregroundReconciliation || trigger == .watchdogStall {
    // Mode A: recognition alone went silent while capture continued
    // (isRecognitionStale()'s existing buffers-flowing check). Mode B:
    // a previous restart attempt already left us short of `.active` --
    // buffers structurally cannot be flowing until a FUTURE restart
    // succeeds, so that requirement doesn't apply here. Excludes
    // interruptionInProgress for the same reason isRecognitionStale()
    // does: don't thrash against a restart attempt while the OS still
    // legitimately owns the microphone, waiting on its own `.ended`.
    let modeBStuckAfterFailedRestart = (lifecycleState == .recovering && !interruptionInProgress)
    guard isRecognitionStale() || modeBStuckAfterFailedRestart else { return }
}
```
**Why this correctly bounds itself:** once the gate passes for Mode B, execution reaches `beginListeningSegment()` again on every subsequent watchdog tick (20s apart -- far enough apart that `isRestartLoopDetected()`'s 10s rate window, unchanged, won't trip on this alone). If the restart keeps failing, `consecutiveRecoveryFailures` now actually increments each time (previously it couldn't, because the gate blocked the call before reaching it) -- reaching the 5-failure budget and calling `finishWithFailure(.recoveryExhausted)` after roughly 5 × 20s ≈ 100 seconds of a persistently dead engine, ending the reflection honestly instead of silently. If the restart succeeds on any attempt, `lifecycleState` becomes `.active`, `modeBStuckAfterFailedRestart` becomes false again, and the gate reverts to Mode-A-only behavior -- no change to steady-state healthy operation.

## R4.2 — Logging the restart's actual failure reason (criterion 6 gap)

`beginListeningSegment()` has three failure returns, none logged today:
- `SpeechRecognitionManager.swift:778-781` (`speechRecognizer`/`isAvailable` guard) -- add `print("[u6-recovery] beginListeningSegment failed: speechRecognizer unavailable (nilRecognizer=\(speechRecognizer == nil))")`.
- `SpeechRecognitionManager.swift:791-794` (`supportsOnDeviceRecognition` guard) -- add `print("[u6-recovery] beginListeningSegment failed: on-device recognition not supported")`.
- `SpeechRecognitionManager.swift:877` (the real `catch` around session/engine setup -- almost certainly where *this* run's failure actually occurred, since the device already supports on-device recognition) -- add `print("[u6-recovery] beginListeningSegment failed: domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(error.localizedDescription)")`. Privacy rule unaffected: `error.localizedDescription` for an `AVAudioSession`/`AVAudioEngine` setup failure is a system-generated string about audio hardware/session state, never transcript content.

This closes exactly the gap PLAN.md's criterion-6 record flagged ("mechanism identified, but the restart's error reason was never logged") for any future run that hits this path again.

## R4.3 — D3 fixes (minor)

1. **Duplicate watchdog firing (two `watchdogStall` prints 0.1s apart at T+20s, despite one schedule site and a nil guard):** not yet root-caused -- per the director's framing, this needs *investigation* logging before a fix, not a guessed fix. Add: (a) a monotonic token (`UUID` or `Int`) generated once inside `scheduleWatchdogIfNeeded()` each time it actually creates a new `Timer` (guarded by the existing `watchdogTimer == nil` check), logged at creation (`print("[u6-recovery] watchdog scheduled token=...")`) and captured by the timer's closure so every firing logs which token fired (`print("[u6-recovery] watchdog fired token=...")`) -- if two DIFFERENT tokens both fire near-simultaneously, that proves two Timer instances exist despite the nil guard (a real bug to chase next); if the SAME token fires twice, the bug is in `Timer` delivery/run-loop behavior itself, not in our scheduling logic. Also log every call to `scheduleWatchdogIfNeeded()` itself (not just ones that create a timer), noting whether it was a no-op (`watchdogTimer` already non-nil) -- this alone might reveal a second, unexpected call site.
2. **`attemptRecovery` entry log spamming healthy recordings every 20s:** move the detailed entry print (`SpeechRecognitionManager.swift:1042`) from unconditional-at-entry to immediately after the Mode-A/Mode-B gate decision in R4.1, logging only when a trigger actually proceeds past the gate (or isn't gate-subject at all -- `.recognitionError`, `.interruptionEnded`, `.routineRollover`). A watchdog/foreground trigger that's correctly gated out during healthy operation no longer prints at all, matching Fix 1's own token-based scheduling log for visibility into "the watchdog is alive" instead.

## R4.4 — Mode A (the original defect class) was not exercised by this run; how it stays verified

This run's interruption chain hit Mode B (restart failure) before recognition ever had the chance to go silent-while-capturing, per R4.1's analysis. `isRecognitionStale()`'s original Mode-A gate (stale callback + buffers flowing) is unchanged by R4.1 -- it still requires both conditions, exactly as approved. Verification split honestly:
- **Logic-level (already exists, unaffected by this revision):** `RecoveryPathTests/watchdogDoesNothingWhileCallbacksAreFresh()` and `watchdogForcesRecoveryWhenStaleWithBuffersFlowing()` in `ObservatoryTests.swift` deterministically exercise the Mode-A gate's both-conditions logic on the simulator. These remain the mechanism's regression coverage after R4.1 ships.
- **Device-level (honest gap, not claimed as closed):** the *original* smoke-test incident (PLAN.md's audio-energy forensics) that motivated Mode A happened somewhat serendipitously -- a specific Siri/Maps mic-mute pattern where the engine survived but recognition didn't. This run instead hit the OS tearing the engine down and the restart failing (Mode B), which isn't the same condition and isn't fully reproducible on demand, since it depends on exactly how Siri/Maps interacts with this app's audio session on this iOS version in a given moment. A future device run can *attempt* to target Mode A more deliberately (e.g. a shorter Siri invocation without invoking Maps, or triggering Siri without it taking exclusive session control), but I'm not claiming that guarantees reproduction. Mode A's device-level verification stays **unverified** (logic-tested, not device-confirmed) until a future run happens to hit it -- stating this plainly rather than overclaiming the upcoming re-run will cover both modes.

## R4.5 — Status
DESIGN ONLY -- matches the director's explicit instruction. No `SpeechRecognitionManager.swift` edits made in this pass. D1 (R4.1) and D3 (R4.3) may proceed to implementation once the director reviews this section; D2 is entirely out of this file's scope for now -- see the companion ChatGPT review brief.

---

# R5 (2026-10-23) — D2 implementation design, per ChatGPT's binding ruling (brief #4 reply)

D1 (R4.1) and D3 (R4.2/R4.3) are implemented and reported: 47/55 simulator tests pass (8 pre-existing environmental `AudioFixtureReplayTests` failures, unchanged), all 47 simulator-eligible green including 4 new Mode B tests. This section is the design for D2, ruled on by ChatGPT: **Modified Option B** (reject A's boolean overload, reject C's interval contract). Per the director, the ruling is the design review -- implementing in the same pass, no additional hold.

## R5.1 — Field shape

Enum with an associated value (not a separate status + position field), since it makes "a position only exists for confirmed incompleteness" structural rather than conventional:
```swift
/// Whole-session capture-completeness evidence, established from
/// LIFECYCLE signals (capture ceased via an interruption's `.began`
/// teardown, recovery did not restore it before the session ended) --
/// NEVER from a session-duration/file-duration mismatch alone, which is
/// corroboration/detection only, never the sole basis. `nil` means
/// unknown -- predates this field, or was never determined -- and must
/// NEVER be treated as `.complete` by any consumer. A later successful
/// recovery does not erase an earlier outage: this describes WHOLE-
/// SESSION completeness, not "is capture healthy right now."
enum CaptureCompleteness: Codable, Equatable {
    case complete
    /// `endpointAudioSeconds`, when known, is the saved file's own
    /// audio-file-relative ENDPOINT (its last successfully-written
    /// frame) -- it marks ONLY where the saved audio ends. It does NOT
    /// mean "known-good through this point" (nothing here vouches for
    /// every second before it being continuous), does NOT establish WHEN
    /// capture actually stopped, and does NOT measure how much wall-
    /// clock time is missing. `nil` here means the endpoint itself isn't
    /// known, not that capture was complete.
    case incomplete(endpointAudioSeconds: TimeInterval?)
}
var captureCompleteness: CaptureCompleteness? = nil
```
No custom Codable needed (unlike `Speaker`'s legacy-string decode) -- this field never existed before, so a missing JSON key decodes to `nil` via ordinary synthesized `Decodable`, exactly like `diarizationEngineVersion` already does.

## R5.2 — Establishment rule, precisely

**Trigger:** `handleInterruption(.began)` is the one and only place capture (the engine/tap, buffers) stops being delivered mid-reflection outside of a user-initiated Stop (confirmed by rereading the whole file: `stop()` and `finishWithFailure()` both tear down the engine too, but only as part of ENDING the reflection, not as a mid-session event to flag). A new manager property, `hadCaptureOutage: Bool` (reset `false` in `start()`), is set `true` the moment `.began`'s existing guard passes and the engine is torn down. It is **never reset to `false` again during that reflection** -- not on a successful `.ended`/Mode-B recovery, not anywhere else -- so a later successful recovery cannot erase the fact that an outage happened, per the ruling.

**Capture-side vs. write-completion timestamps:** `AudioFileWriter.lastEnqueueAt` (added in D1/D3's work, R4.2-adjacent) is already set synchronously on the realtime tap thread, at the top of `enqueue()`, BEFORE the async `queue.async { write(...) }` dispatch -- i.e. it's already a capture-side, buffer-arrival timestamp, not a write-completion one. `hadCaptureOutage` itself is a plain lifecycle-event flag (set directly inside `.began`'s handler), not derived from any timestamp comparison at all, which is the safest way to satisfy "don't use write-completion timing to establish incompleteness" -- there's no timing comparison in the establishment rule to get wrong.

**The endpoint position** (`endpointAudioSeconds`, only populated when `hadCaptureOutage == true`) is read at finalization time from `writtenFrames` (converted via the writer's existing `audioSecondsLocked(for:)`, after `flush()` has been awaited) -- this is a simple "how many frames are actually in the file" reading, which is D-05's existing, already-accepted semantics; it answers "where does the saved file end," not "when did capture stop" or "was everything before this point continuous." A session-duration/file-duration mismatch is never computed or used as a trigger anywhere in this design -- only as something a future human/Hermes forensic pass could use as a corroborating sanity check, per the ruling's "corroboration/detection signal only" framing.

## R5.3 — A pre-existing interaction bug found while designing this: `finishWithFailure` currently discards the writer before `captureCompleteness`/diagnostics can ever be read

Tracing the terminal-failure path (the exact path the 2026-10-23 smoke test hit): `finishWithFailure()` calls `discardCurrentAudioWriterIfAny()` immediately, which flushes, keeps-or-deletes, and sets `audioWriter = nil` -- **before** the `onRecordingEnded` callback even fires. That callback is what eventually reaches `ReflectionSessionStore.handleRecordingEndedUnexpectedly` → `stopAndObserve(finishAudioCapture:)` → `await finishAudioCapture()`. By the time that call happens, `audioWriter` is already `nil`, so `finishAudioCapture()` hits its `guard let writer = audioWriter else { return nil }` and returns `nil` -- meaning `audioRecordingReliable`, `missingAudioIntervals`, `recognitionContinuityGaps`, **and the new `captureCompleteness`** would all stay unset on exactly the sessions this unit exists to diagnose. This was already true before D2 (R2.3/Q4's discard logic predates this) but D2 is what exposed it, since it's the first time a terminal-failure session's diagnostics actually need to be read downstream.

**Fix:** `finishWithFailure()` only eagerly discards the writer if nothing will ever ask for it -- i.e. if `currentOnRecordingEnded == nil` (no listener was wired, so nothing will call `finishAudioCapture()` later and Q4's orphaned-writer guarantee still needs to hold). When a listener IS wired (both production screens always wire one), the writer is left alone for `finishAudioCapture()` -- now the single, unified place that flushes, reads diagnostics (including `captureCompleteness`), and discards -- to handle shortly after, via the callback chain. This unifies the normal-Stop and terminal-failure paths through one diagnostics-reading function instead of two divergent ones.

## R5.4 — Consumer wiring: `SpeakerDiarizationEngine.label(session:)`

**Chosen behavior: skip diarization entirely for a confirmed-incomplete session, the same way the existing `audioRecordingReliable == false` guard already does.** Extend the eligibility guard (`SpeakerDiarizationEngine.swift:79`) from `session.audioRecordingReliable != false` to also require `captureCompleteness` isn't `.incomplete`. Reasoning: the saved `.caf` file for an incomplete session is not padded with silence for the missing span (D-05: file-time only advances on writes) -- it's simply shorter, so diarizing it would produce technically-correct results for whatever portion exists, but nothing downstream currently has any notion of "this covers only part of the session" to attach to those results (see R5.5 -- no analysis engine checks anything like this today). Rather than ship partial diarization with no UI/consumer path to express its partial coverage, this unit declines to diarize an incomplete session at all, matching the existing precedent for "don't process audio we don't trust" and explicitly not asserting full coverage. Partial-coverage-aware diarization (using `endpointAudioSeconds` to diarize just the captured portion and flag the rest as unknown) is a reasonable future enhancement but is new scope, not a requirement of this fix -- noted rather than silently built.

## R5.5 — Audit of the downstream path that produced the 21 observations

Grepped every reference to `audioRecordingReliable`/`missingAudioIntervals` across the app: both fields are referenced **only** in `AudioCaptureScreen.swift`, `Models.swift`, `ObservatoryScreen.swift`, `SpeakerDiarizationEngine.swift`, `ReflectionSessionStore.swift`, and `SpeechRecognitionManager.swift` (plumbing only in the last three, documentation in the first two). **None of the 21-observation-producing engines** -- `ObservationEventEngine`, `DynamicsEngine`, `CorrelationEngine`, `ReflectionAnalyzer`, `ReflectionSummaryEngine`, `EmotionalTrajectoryEngine`, `ReflectionArcEngine` -- check audio reliability, completeness, or diarization status at all; they process whatever `session.transcript` text exists, however little, with no notion of "this transcript might only represent part of a reflection." This is exactly, and only, **PLAN.md's pre-existing open issue 2 / unit U3's scope** ("analysis engines run on the whole transcript ... diarization-aware attribution needed before analysis") -- teaching these engines to respect a data-quality/completeness signal is the same shape of fix U3 already exists to make, just extended to one more signal. **This is explicitly not fixed in U6.** Blocking diarization (R5.4) stops speaker-attribution from running on contaminated data; it does not stop the summary/arc/dynamics/correlation engines from narrating a 4-word partial transcript as if it were the whole reflection -- that gap stays open, correctly attributed to U3, not silently patched here.

## R5.6 — Tests (acceptance list from the ruling, logic-level, simulator)
All driven through `SpeechRecognitionManager.finishAudioCapture()` and the existing internal testability seams (`hadCaptureOutage`, `lifecycleState`, `setAudioWriter`, the internal `AudioFileWriter`), plus one `ReflectionSession` Codable test:
1. Normal Stop (`hadCaptureOutage == false` throughout) → `finishAudioCapture()` returns `.complete`.
2. An unrecovered interruption (`hadCaptureOutage == true`, writer has some written frames) → `.incomplete(endpointAudioSeconds:)` with the position matching the writer's actual endpoint.
3. An outage followed by a successful recovery (`hadCaptureOutage == true` set once, then `lifecycleState` returned to `.active`) → still `.incomplete` at finalization -- proving a later success doesn't erase it.
4. Delayed writer draining (enqueue a buffer, then call `finishAudioCapture()` immediately without waiting) → the returned `captureCompleteness` is correct regardless of how long the internal queue actually took to drain, since the status never depends on drain timing by construction (R5.2).
5. A legacy `ReflectionSession` JSON (missing the `captureCompleteness` key entirely) decodes `captureCompleteness == nil`, never `.complete`.
Plus: all D1/D3 Mode-B tests and the full pre-existing suite stay green.

## R5.7 — Status
Implementing now, in this same pass, per the director's instruction that the ruling is the design review. Full file list: `Models.swift` (new enum + field), `SpeechRecognitionManager.swift` (`hadCaptureOutage`, the `.began` trigger, `finishAudioCapture()`'s extended tuple, `finishWithFailure()`'s conditional-discard fix, `AudioFileWriter.endpointAudioSeconds`), `ReflectionSessionStore.swift` (tuple plumbing), `AudioCaptureScreen.swift`/`ObservatoryScreen.swift` (closure signatures), `SpeakerDiarizationEngine.swift` (eligibility guard), `ObservatoryTests/ObservatoryTests.swift` (R5.6's tests). Re-running the full simulator suite and reporting real counts next.
