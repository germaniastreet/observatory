# U6b proposal — Fast-backoff restart retry

**Author:** Claude (Xcode assistant chat) · **Date:** 2026-10-24

## Recap (from PLAN.md's U6b queue entry)
U6's device re-run (session `0CA79AED…`) hit a failed `.ended` restart (`NSOSStatusErrorDomain 561015905`, "Session activation failed" — the interrupting app still holding the audio session), then sat `.recovering` for ~36s until the watchdog's next fixed 20s tick happened to land and succeeded. The speech spoken in that window was never captured — physically unrecoverable, now honestly recorded via `captureCompleteness`/`recognitionContinuityGaps`, but avoidable in the common case where the session frees up well before the next watchdog tick. Goal: retry sooner after a failed attempt, bounded, without creating a second uncoordinated recovery mechanism alongside the existing watchdog/budget/rate-guard.

## Current mechanism (verified by rereading `SpeechRecognitionManager.swift` this session)
- `attemptRecovery(trigger:forReflection:)` (line 1070) is the single owner of every recovery attempt. On a failed `beginListeningSegment()` call (line 1143), it increments `consecutiveRecoveryFailures` and, if under `maxConsecutiveRecoveryFailures` (5), does nothing further — the comment at line 1148 says plainly "stays `.recovering` -- the next trigger (the watchdog, most likely) tries again." That "next trigger" is `scheduleWatchdogIfNeeded()`'s fixed 20s-repeating `Timer` (line 1182), which keeps firing regardless of `lifecycleState` once scheduled in `start()`.
- `isRestartLoopDetected()` (line 1038) is a trailing-10-second rate guard: every attempt that reaches it appends a timestamp to `recentAutoRestarts` and trips if more than 5 entries land in the trailing 10s window — independent of, and in addition to, the 5-consecutive-failures budget (R2.5/amendment 1: both guards exist for different pathologies, neither replaces the other).
- `attemptRecovery`'s Mode A/B gate (lines 1077–1111) already means the watchdog's 20s tick isn't idle during a stuck `.recovering` state: `modeBStuckAfterFailedRestart` is true whenever `lifecycleState == .recovering && !interruptionInProgress`, so the watchdog already attempts a retry at its own cadence today — U6b's job is only to add faster attempts *before* that 20s tick, not to invent retrying from scratch.

## Design

### 1. New trigger + backoff schedule
Add one case to the existing `RecoveryTrigger` enum (line 1053): `.scheduledFastRetry`. It is **not** added to the `trigger == .foregroundReconciliation || trigger == .watchdogStall` Mode A/B staleness-gate check (lines 1077–1111) — a fast retry is scheduled specifically *because* the previous attempt already failed and left `lifecycleState == .recovering`; re-deriving "is something wrong" via `isRecognitionStale()`/Mode B would be redundant. This matches how `.recognitionError`/`.interruptionEnded`/`.routineRollover` already bypass that gate today.

```swift
private static let fastRetryBackoffSeconds: [TimeInterval] = [2, 4, 8, 16]
```

Indexed by `consecutiveRecoveryFailures - 1` at the moment a retry is scheduled (so the 1st failure schedules a 2s retry, the 2nd a 4s retry, etc.). With `maxConsecutiveRecoveryFailures = 5`, the array only ever needs 4 entries — the 5th failure goes straight to `finishWithFailure(.recoveryExhausted)` and no 5th retry is scheduled.

**Why this schedule can't false-trip the >5-in-10s rate guard:** cumulative attempt offsets from the first failure are `{0, 2, 6, 14, 30}` seconds (0 = the original failure that triggered scheduling at all). The densest possible 10-second window across those points is `{0, 2, 6}` — 3 attempts. Even allowing one *additional* unrelated attempt to land in the same window (e.g. a watchdog tick or `.interruptionEnded` arriving independently, before cancellation below takes effect), that's 4, still under the `> 5` trip threshold (6+). The schedule was chosen specifically to keep that worst-case cluster small: doubling (not a tighter/linear schedule) pushes the 3rd and 4th attempts far enough apart that they can't stack into the same 10s window with the first two.

### 2. One pending-task slot, cancelled at the top of every attempt that proceeds
```swift
private var pendingFastRetryTask: Task<Void, Never>?
```
`attemptRecovery` calls `cancelPendingFastRetry()` once its initial guards pass (`recordingIntent`, `reflectionID == triggerReflectionID`, `lifecycleState != .stopped`) and — for `.watchdogStall`/`.foregroundReconciliation` — once the Mode A/B gate itself passes. This is the single mechanism that answers the "no double-attempt" requirement: whichever trigger (a scheduled fast retry, the watchdog, foreground reconciliation, or `.interruptionEnded`) actually reaches the body of `attemptRecovery` first cancels whatever the *other* mechanism had pending, then proceeds alone. If that attempt itself fails, it's the one that schedules the next fast retry (from the now-incremented failure count) — the two mechanisms are continuously merged into one live chain rather than running in parallel.

```swift
private func cancelPendingFastRetry() {
    guard let task = pendingFastRetryTask else { return }
    task.cancel()
    pendingFastRetryTask = nil
    print("[u6-recovery] fast retry cancelled")
}

private func scheduleFastRetry(forReflection triggerReflectionID: UUID) {
    let index = consecutiveRecoveryFailures - 1
    guard index >= 0, index < Self.fastRetryBackoffSeconds.count else { return }
    let delay = Self.fastRetryBackoffSeconds[index]
    print("[u6-recovery] fast retry scheduled delay=\(delay)s attempt=\(consecutiveRecoveryFailures) reflectionID=\(triggerReflectionID)")
    pendingFastRetryTask = Task { @MainActor [weak self] in
        do {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch {
            print("[u6-recovery] fast retry cancelled before firing reflectionID=\(triggerReflectionID)")
            return
        }
        guard !Task.isCancelled, let self else {
            print("[u6-recovery] fast retry cancelled before firing reflectionID=\(triggerReflectionID)")
            return
        }
        print("[u6-recovery] fast retry firing reflectionID=\(triggerReflectionID)")
        self.attemptRecovery(trigger: .scheduledFastRetry, forReflection: triggerReflectionID)
    }
}
```
The explicit `catch` + the belt-and-suspenders `Task.isCancelled` recheck after a *successful* sleep close the one-tick race where `cancel()` lands in the gap between the sleep returning and the next line running. Everything here is still MainActor-serialized (no concurrent mutation is actually possible) — this only resolves strict ordering, it isn't defending against a real data race.

`attemptRecovery`'s existing failure branch (line 1143) becomes:
```swift
} else {
    consecutiveRecoveryFailures += 1
    if consecutiveRecoveryFailures >= Self.maxConsecutiveRecoveryFailures {
        finishWithFailure(.recoveryExhausted)
    } else {
        scheduleFastRetry(forReflection: triggerReflectionID)
    }
}
```

### 3. Cancellation on Stop / new reflection / success elsewhere
- **User Stop:** `stop()` (line 1313) doesn't route through `attemptRecovery`, so it needs its own explicit `cancelPendingFastRetry()` call alongside its existing `watchdogTimer?.invalidate()` line — same idempotent-teardown style already used there.
- **Recovery exhausted / unsupported:** `finishWithFailure(_:)` (line 1215) gets the same explicit call for defense-in-depth, even though every call path that reaches it today already either came from inside `attemptRecovery` (which cancelled at entry) or from `start()`'s first-call failure (where nothing could have been scheduled yet).
- **New reflection:** `start()` (line 728) resets `recentAutoRestarts`/`consecutiveRecoveryFailures`/etc. at lines 762–766; add `cancelPendingFastRetry()` there too, for the same reset-everything hygiene — though a stray old task would already be a safe no-op via the `reflectionID == triggerReflectionID` guard even without this.
- **Success from a racing trigger** (watchdog, foreground reconciliation, or `.interruptionEnded` all winning before the fast retry fires): covered by §2 — the winning trigger cancels the pending fast retry as part of merely *proceeding*, regardless of whether it then succeeds or fails.
- **A fired retry arriving for an already-superseded reflection:** already covered by `attemptRecovery`'s existing top guard (line 1075) — no new logic needed, same mechanism the existing `staleReflectionIDTriggerIsIgnored` test already exercises for `.watchdogStall`.

### 4. Interaction with the consecutive-failure budget and the Mode-B watchdog gate
- Each fast retry **is** a recovery attempt and counts toward `consecutiveRecoveryFailures` exactly like any other trigger — no separate counter. A chain of 4 fast retries plus the original failure that reaches the 5th consecutive failure ends the reflection honestly via the existing `finishWithFailure(.recoveryExhausted)` path, now reached in ~30s instead of ~80–100s (4+ watchdog ticks).
- The Mode-B gate (`modeBStuckAfterFailedRestart`, line 1110) still lets the watchdog's own fixed-cadence tick attempt a recovery during the backoff window — this is intentional, not a gap: §2's cancel-on-proceed design means whichever one (fast retry or watchdog tick) gets there first wins and cancels the other, so they can never both execute for the same failure. A successful watchdog tick mid-backoff is a clean win (fast retry's now-redundant pending task is cancelled, no second attempt fires); a successful fast retry mid-watchdog-interval is the whole point of this unit.
- `isRecognitionStale()` (Mode A) is untouched — `.scheduledFastRetry` never passes through that gate at all (§1), so nothing here changes Mode A's existing behavior or its device-unverified status noted in R4.4.

## Scope
- `SpeechRecognitionManager.swift` only, within the existing recovery path: the new `RecoveryTrigger` case, `fastRetryBackoffSeconds`, `pendingFastRetryTask`, `scheduleFastRetry`/`cancelPendingFastRetry`, the three call sites above (`attemptRecovery`'s entry + failure branch, `stop()`, `finishWithFailure()`, `start()`), and `[u6-recovery]` logging on schedule/fire/cancel.
- `ObservatoryTests/ObservatoryTests.swift` — new tests only (list below).
- **No Models.swift change.** `recognitionContinuityGaps: [Date]?` already records "every wall-clock moment a non-routine recovery was attempted" (its existing doc comment); `.scheduledFastRetry` is one more non-routine trigger value fitting that existing definition as-is — no schema change, no reinterpretation of D-17's `captureCompleteness` semantics (a shorter outage still records `.incomplete`, unchanged).
- No changes to Mode-A gating, `ReflectionSessionStore.swift`, either screen, or anything outside the recovery path, per the queue entry's out-of-scope list.
- `pendingFastRetryTask`, `fastRetryBackoffSeconds`, `scheduleFastRetry`, `cancelPendingFastRetry` go in at `internal` access, matching this file's existing testability-seam precedent (same rationale as `lifecycleState`/`attemptRecovery`/etc.: no live `AVAudioEngine`/`SFSpeechRecognizer` permission on the simulator).

## Tests (logic-level, simulator, `ObservatoryTests.swift`)
All added to the existing `RecoveryPathTests` suite, following its established pattern of driving `attemptRecovery` directly through the internal seams rather than through `start()`.

1. **"A failed recovery attempt schedules a fast retry under the budget"** — `lifecycleState = .recovering`, `consecutiveRecoveryFailures = 0`, no writer (so `beginListeningSegment()` deterministically fails on this permission-less simulator, same precondition the existing Mode-B tests already rely on); call `attemptRecovery(trigger: .watchdogStall, ...)`; assert `pendingFastRetryTask != nil` and `consecutiveRecoveryFailures == 1`.
2. **"A failed recovery attempt does not schedule a fast retry once the budget is exhausted"** — pre-seed `consecutiveRecoveryFailures = maxConsecutiveRecoveryFailures - 1`, trigger one more failing attempt, assert `lifecycleState == .stopped`, `pendingFastRetryTask == nil` (mirrors the existing "Repeated retries..." test's whichever-way-it-resolves style for the edge case where `beginListeningSegment()` unexpectedly succeeds on some simulator config).
3. **"A pending fast retry actually fires and attempts recovery again after its backoff delay"** — schedule via a failing attempt (as in test 1), then `try await Task.sleep` for slightly longer than `fastRetryBackoffSeconds[0]` (2s) in the test itself, then assert `consecutiveRecoveryFailures == 2` (the fired retry attempted and failed again) — the one real-time test in this set, needed to confirm the scheduled `Task` actually fires end-to-end rather than only asserting the scheduling decision.
4. **"Stop cancels a pending fast retry"** — schedule via a failing attempt, call `manager.stop()`, assert `pendingFastRetryTask == nil`.
5. **"A different trigger winning the race cancels the pending fast retry before proceeding"** — schedule via a failing `.watchdogStall` attempt to populate `pendingFastRetryTask`, capture that `Task` reference, then drive a second trigger (`.interruptionEnded`, which isn't gated and always proceeds) and assert the originally-captured task's `isCancelled == true` afterward — proves the cancel-on-proceed mechanism fires regardless of the second attempt's own success/failure outcome.
6. **"A fired fast retry carrying a stale reflectionID after a new reflection has started is a no-op"** — same shape as the existing `staleReflectionIDTriggerIsIgnored` test, but calling `attemptRecovery(trigger: .scheduledFastRetry, forReflection: oldReflectionID)` directly (simulating the retry firing late) after `reflectionID` has moved on; assert no state change.
7. **"Backoff-spaced attempts stay under the rate guard's trip threshold"** — pre-seed `recentAutoRestarts` with the worst-case cluster timestamps the schedule can produce relative to "now" (`[now-6, now-4, now]`, i.e. 3 attempts already landed within the trailing 10s window, the densest cluster identified above), then call one more `attemptRecovery`; assert it does **not** take the rate-guard's `finishWithFailure` branch (distinguish from budget-exhaustion by asserting `consecutiveRecoveryFailures` incremented normally by exactly 1, rather than jumping straight to `.stopped` on an attempt where the budget isn't yet exhausted).

## Device exit criteria
Unchanged from PLAN.md's U6b entry — restated here only for completeness, not proposing any change: if a restart failure occurs, logs show fast retries at the backoff cadence and recovery succeeds within ~10s of the first failure (vs. 36s); immediate post-return speech is present in the audio file; the record stays honest (`.incomplete` with the true endpoint — this doesn't change regardless of how fast recovery is); no rate-guard false-trip; no zombie state. If the first restart succeeds outright, verify no regression and that the simulator tests above carry the fast-retry verification on their own.

## Status
Holding for director sign-off per the queue entry (bounded extension of the already-reviewed U6 recovery architecture — direct review, no ChatGPT round unless this raises a schema/product-behavior question). No `SpeechRecognitionManager.swift` or test edits made yet.

---

# Revision 1 (2026-10-24) — two required fixes per director review

Director: APPROVED WITH TWO REQUIRED FIXES. Both incorporated below; implementing immediately after, no further hold.

## R1.1 — FIX 1: raise `maxConsecutiveRecoveryFailures` 5→10 so merged exhaustion doesn't regress below the U6 watchdog-only baseline

**The regression, confirmed:** the original proposal kept `maxConsecutiveRecoveryFailures = 5` unchanged. Because every fast retry counts toward the same counter as every other trigger (by design — §4 of the original proposal), and the backoff schedule's 4th retry lands at cumulative t≈30s, a continuously-failing session would hit the 5-failure cap at t≈30s — *before* the U6 passing run's actual recovery point (session `0CA79AED…`, watchdog succeeded at +46s from the interruption; the earlier failed run sat `.recovering` for 100+s before the person gave up). Shipped U6 structurally cannot terminate a reflection before giving the watchdog's own 5-strikes-at-20s-apart budget (~100s, per R4.1's own stated arithmetic) a chance to work. U6b's fast retries must only improve the *typical* case (recovering sooner when the session frees up quickly) without shrinking the *worst-case* grace period the shipped mechanism already gives a slow-to-clear interruption.

**Fix: `maxConsecutiveRecoveryFailures` 5 → 10. Backoff schedule (`fastRetryBackoffSeconds = [2, 4, 8, 16]`) unchanged — only 4 entries, since it only needs to cover the fast portion of the chain; once `consecutiveRecoveryFailures` passes the schedule's length, `scheduleFastRetry`'s existing bounds guard (`index < fastRetryBackoffSeconds.count`) already no-ops cleanly, leaving the independent 20s watchdog `Timer` as the sole remaining driver for the rest of the budget** — no new code needed beyond the constant change, because the array-exhaustion guard was already written defensively in the original design.

**(a) Merged attempt timeline under continuous failure**, worst-case watchdog phase (ticks independent of the chain, 20s apart, phase arbitrary relative to t=0):
- t=0: original failure (attempt 1, trigger e.g. `.interruptionEnded`) → schedule fast retry, delay=2s.
- t=2: fast retry fires, fails (attempt 2) → schedule delay=4s.
- t=6: fails (attempt 3) → schedule delay=8s.
- t=14: fails (attempt 4) → schedule delay=16s.
- t≈20–30 (watchdog-phase-dependent): either the t=30 fast retry fires uncontested (attempt 5, pure fast-retry path), **or** an independent watchdog tick lands first (anywhere the phase places it, e.g. t=20 or t=25 in the traced examples below), cancels the still-pending fast retry via `cancelPendingFastRetry()`, and becomes attempt 5 itself instead. Either way, attempt 5 happens no later than t=30 and no earlier than roughly t=14+ε (the fastest a watchdog tick could conceivably land right after attempt 4). Call this time `t₅`, `t₅ ∈ [~14, 30]`.
- The moment `consecutiveRecoveryFailures` reaches 5, `scheduleFastRetry`'s index becomes `5-1=4`, out of bounds for a length-4 array — **no further fast retry is ever scheduled for this reflection.** From `t₅` onward, only the watchdog's independent, fixed 20s-apart ticks can produce attempts 6 through 10 — 5 more ticks, each structurally ≥20s apart (`Timer.scheduledTimer(withTimeInterval: 20, repeats: true)` can't fire faster than that regardless of anything in this chain).
- Attempts 6, 7, 8, 9, 10 land at `t₅ + δ`, `t₅ + δ + 20`, `t₅ + δ + 40`, `t₅ + δ + 60`, `t₅ + δ + 80`, where `δ` (≤20s) is the phase gap from `t₅` to the next watchdog tick. **Attempt 10 — the one that trips the cap — lands no earlier than `t₅ + 80` ≈ 94–110s, and typically closer to 110–130s** (traced examples below land at t=120s and t=125s for two different assumed phases).

Two concretely traced phases (shown in full in scratch work, summarized here): phase A (watchdog ticks at 20,40,60,...) → attempt 5 at t=20 (watchdog preempts), attempts 6–10 at 40,60,80,100,120 → **exhaustion at t=120s**. Phase B (watchdog ticks at 5,25,45,...) → attempt 5 at t=25, attempts 6–10 at 45,65,85,105,125 → **exhaustion at t=125s**. No traced or reasoned phase produces exhaustion below ~100s; the lower bound is structural (5 full watchdog-only intervals, 20s each, cannot be compressed by anything in this chain), satisfying the director's requirement.

**(b) Densest 10-second window, unchanged from the original analysis:** the fast-retry-only cluster `{0, 2, 6}` (3 attempts) is the densest the backoff schedule itself can produce in any 10s window — this doesn't change with the cap, since the schedule array is unchanged. Adding one independent watchdog tick landing inside that same window (the only way a 4th attempt could land within 10s, since watchdog ticks are themselves ≥20s apart from each other) gives a worst case of **4**, still ≤4 as required and still under the `>5` trip threshold with one full attempt of margin. Past `t₅` (once the schedule is exhausted), only 20s-apart watchdog ticks remain — nowhere near a 10s-window risk.

**(c) Exhaustion time ≥ ~100s:** shown in (a) — structurally bounded below by `t₅ + 80s` where `t₅ ≥ ~14s`, giving a floor around ~94–100s and typical traced values of 120–125s. This matches (and in most phases slightly exceeds) the original watchdog-only mechanism's ~100s budget, so U6b cannot terminate a reflection sooner than shipped U6 would have for a persistently-failing restart — it only ever *helps* the common case (the session clears within the first 2–30s) without regressing the worst case.

**Test 2 updated:** "A failed recovery attempt does not schedule a fast retry once the budget is exhausted" now pre-seeds `consecutiveRecoveryFailures = SpeechRecognitionManager.maxConsecutiveRecoveryFailures - 1` (dynamically, i.e. 9 under the new cap of 10 — not a hardcoded literal) rather than a hardcoded 4, so the test tracks the constant automatically.

**New test added (schedule exhaustion is not confused with budget exhaustion):** "Once the backoff schedule's 4 entries are used up, no further fast retry is scheduled but the reflection stays `.recovering`, not terminated" — pre-seed `consecutiveRecoveryFailures = SpeechRecognitionManager.fastRetryBackoffSeconds.count` (4), drive one more failing attempt (→5), assert `pendingFastRetryTask == nil` **and** `lifecycleState == .recovering` (not `.stopped` — 5 is well under the new cap of 10). This is the test that would have caught a bug where the array-exhaustion guard was accidentally wired to end the reflection instead of silently falling back to watchdog-only pacing.

**Incidental test hygiene, same cause:** the pre-existing `repeatedRetriesReachAnInternallyConsistentOutcome` test (line 825) loops `attemptRecovery` up to `maxConsecutiveRecoveryFailures` times synchronously; with fast retries now wired in, a failing iteration under the new higher cap can leave one real, unawaited `pendingFastRetryTask` outstanding after the test function returns (it would fire harmlessly in the background a few seconds later against a `weak self` — not a correctness bug, since `manager` is local to the test and the closure doesn't keep it alive — but avoidable stray async work during the rest of the suite's run). Adding `defer { manager.pendingFastRetryTask?.cancel() }` at the top of that test closes this cleanly; no assertion changes needed since the test already reads `maxConsecutiveRecoveryFailures` dynamically rather than a hardcoded 5.

## R1.2 — FIX 2: a fast retry must not fire into a fresh interruption

**The gap, confirmed:** `.scheduledFastRetry` was deliberately excluded from the `trigger == .foregroundReconciliation || trigger == .watchdogStall` gate (§1 of the original design) — correct for skipping the Mode A/B staleness re-check, but that gate was also the *only* place `interruptionInProgress` gets consulted before a trigger proceeds (via `isRecognitionStale()`'s own `guard !interruptionInProgress else { return false }` and the `modeBStuckAfterFailedRestart` condition's explicit `!interruptionInProgress` clause). By skipping the whole gate, `.scheduledFastRetry` also skipped that protection — a retry scheduled before a *second*, fresh `.began` arrives would fire mid-interruption, fail deterministically (the OS owns the microphone), and burn one more step of the budget purely because of unlucky timing, something shipped U6 never does (its only two recovery entry points, `.interruptionEnded` and the Mode A/B-gated watchdog/foreground triggers, both either wait for `.ended` or explicitly exclude `interruptionInProgress`).

**Fix, both layers, as directed:**

**(a) `handleInterruption(.began)` cancels the pending fast retry directly**, alongside its existing teardown (right after `interruptionInProgress = true` / `hadCaptureOutage = true`, before the engine/tap teardown):
```swift
case .began:
    let guardPassed = (lifecycleState == .active || lifecycleState == .recovering)
    print("[u6-recovery] interruption .began received, guardPassed=\(guardPassed)")
    guard guardPassed else { return }
    interruptionInProgress = true
    hadCaptureOutage = true
    cancelPendingFastRetry()
    currentGenerationState = .sealed
    sealCurrentSegment()
    // ...unchanged teardown below
```

**(b) Defense-in-depth: `attemptRecovery` refuses a `.scheduledFastRetry` trigger while `interruptionInProgress` is true**, independent of (a) — covers the race where the retry's `Task` already passed its own `Task.isCancelled` recheck (§2 of the original design) before `.began`'s cancellation lands, since both are separately-scheduled async hops onto the same `@MainActor` and their relative order isn't guaranteed by anything written so far:
```swift
func attemptRecovery(trigger: RecoveryTrigger, forReflection triggerReflectionID: UUID) {
    guard recordingIntent, reflectionID == triggerReflectionID, lifecycleState != .stopped else { return }

    if trigger == .scheduledFastRetry, interruptionInProgress {
        print("[u6-recovery] fast retry no-op, interruption in progress")
        return
    }

    if trigger == .foregroundReconciliation || trigger == .watchdogStall {
        // ...unchanged Mode A/B gate
    }

    cancelPendingFastRetry()
    // ...unchanged proceeding log, gap recording, rate guard, beginListeningSegment()
}
```

**Testability note:** `handleInterruption(type:optionsValue:)` (currently `private`) becomes `internal`, matching this file's existing testability-seam precedent (same rationale already applied to `attemptRecovery`, `reconcileAfterForeground`, `lifecycleState`, etc. — no live `AVAudioSession`/`AVAudioEngine` permission on the simulator, so driving the public notification-based path isn't possible from a test). Access-level only, no behavior change.

**New test:** "A new interruption `.began` cancels a pending fast retry, and a fast retry that still fires anyway no-ops while the interruption is in progress":
```swift
@Test("A new interruption .began cancels a pending fast retry and blocks it from firing while in progress")
func interruptionBeganCancelsAndBlocksPendingFastRetry() {
    let manager = SpeechRecognitionManager()
    let reflectionID = UUID()
    manager.reflectionID = reflectionID
    manager.recordingIntent = true
    manager.lifecycleState = .recovering
    manager.interruptionInProgress = false
    manager.lastRecognitionCallbackAt = Date()

    // Fail one attempt to populate pendingFastRetryTask (Mode B: stuck
    // in .recovering, no buffers flowing).
    manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)
    let scheduledTask = manager.pendingFastRetryTask
    #expect(scheduledTask != nil)

    // A fresh interruption begins while that retry is still pending.
    manager.handleInterruption(type: .began, optionsValue: nil)

    #expect(scheduledTask?.isCancelled == true)
    #expect(manager.pendingFastRetryTask == nil)

    // Defense-in-depth (fix 2b): even if a stale fast-retry trigger fires
    // anyway, it must no-op while interruptionInProgress is true, not
    // burn another step of the budget.
    manager.attemptRecovery(trigger: .scheduledFastRetry, forReflection: reflectionID)
    #expect(manager.consecutiveRecoveryFailures == 1) // unchanged from the one real failure above
}
```

## R1.3 — Minor note (no change required, per director)
`recognitionContinuityGaps` gains one entry per fast-retry *attempt* (via the existing, unmodified `if trigger != .routineRollover { recognitionContinuityGaps.append(Date()) }` line), not one per outage — a persistently-failing restart now produces up to 9 entries (attempts 2–10; attempt 1's triggering mechanism, e.g. `.interruptionEnded`, already counted under the pre-U6b behavior) instead of up to 4 (one per watchdog tick, under the old cap of 5) before this unit. This is honest per the field's existing documented definition ("every wall-clock moment a non-routine recovery was attempted") and requires no Models.swift change — stated here for the record, not treated as a regression.

## R1.4 — Status
Both fixes incorporated. Implementing now: `SpeechRecognitionManager.swift` (schedule/cancel plumbing from the original design, `maxConsecutiveRecoveryFailures = 10`, the `.scheduledFastRetry` interruption guard, `handleInterruption`'s new `cancelPendingFastRetry()` call, the `private` → `internal` access change on `handleInterruption`) and `ObservatoryTests/ObservatoryTests.swift` (original 7 tests with test 2 updated, 2 new tests from R1.1/R1.2, 1 hygiene `defer` added to the pre-existing loop test). Full simulator suite next, real pass/fail counts reported, holding for Hermes verification before any device step.
