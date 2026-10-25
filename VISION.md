# VISION.md — the Observatory trajectory, two tracks
**Status:** v0.2 — codified by Hermes from the owner's articulation, 2026-10-24; **owner-accepted 2026-10-24** (direction to treat this as the project's internalized trajectory). Remaining before fully binding: independent ChatGPT review (D-15 precedent), which should specifically rule on the §3 flags (deception-claim posture; Track II consent inversion). Until then `PROJECT_CONSTRAINTS.md` (v0.2) remains the binding product rulebook, `PLAN.md` remains the single source of truth for current work, and nothing here re-orders the unit queue.

---

## 1. The one idea: one instrument, two audiences

Observatory is a **measurement-grade instrument for human behavior** — it observes, measures, and honestly reports what a person is doing and how they are doing it, starting with the voice (aural behavior), later adding body language and other signals.

Everything in this document follows from one architectural commitment:

> **Build ONE measurement engine. Wrap it in two products.**

- **Track I (self-focus):** a personal app where the observed person IS the user. The user consents for themselves, reads their own measurements, and receives guidance.
- **Track II (third-party focus):** an embeddable engine/model where the observed person is someone else — a caller, a patient, a subject — and the customer (call center, clinic, agency) consumes the engine's output.

The engine is the asset. It turns raw signals into observations that carry evidence, uncertainty, coverage, and provenance (constraints §3–§5). Tracks I and II are shells over the same engine with **different consent architectures and different claim envelopes**, not different codebases. Every unit of work from here on should be describable as "a piece of the engine" or "a piece of a shell."

## 2. Track I — three phases, each a widening of scope

Each phase widens the instrument along three axes at once:

| Axis | Phase 1 | Phase 2 | Phase 3 |
|---|---|---|---|
| **Data breadth** | voice + biometrics during reflections | + ambient behavior in the user's environment | + continuous capture + external sources (health data, email/messages, purchases, appointments) |
| **Continuity** | bounded, user-initiated sessions | passive observation across the day | perpetual, lifelong record |
| **Claim strength** | describe & suggest | interpret in context | predict, advise, potentially alter future behavior/health state |

Regulatory, ethical, and engineering burden grows multiplicatively across those axes — which is why the phases are **gates, not dates** (§5).

### Phase 1 — the reflection instrument (now)
- **Who:** casual users first — with a deliberate beachhead in people with **ADHD and alexithymia (emotional blindness)**, who have a concrete, felt need: help noticing what is happening in them, in the moment and afterward. Longer term: patient users.
- **What:** the app listens and observes biometric signals (voice first; heart rate, HRV, and other channels added over time) and **actively or passively notifies the user** of what is taking place, how they are reacting and feeling (bounded interpretation per D-03 — tentative, correctable, never asserted from a single cue), and proposes actions **in real time and after the fact** to live a more appropriate, productive, fruitful life.
- **Quality bar:** SaMD-grade accuracy and safety **from day one**, because the same measurements must later survive FDA scrutiny. The casual-user product is the usability proof and the data flywheel; the clinical product is the regulatory payload. Same instrument, growing claims.
- **Regulatory arc:** potential FDA clearance as a standalone digital therapeutic (DTx), and/or combined with molecule-based therapeutics for serious psychological disorders (a combination-product conversation that must start early, not at submission time — §6).
- **Why ADHD/alexithymia is a strong beachhead:** measurable unmet need, voice-first interaction fits the population, emotional-awareness training is a plausible first cleared indication, and "casual → patient" lets claims ladder up with evidence instead of leading with them.

### Phase 2 — environmental observation
The instrument observes behavior **within the user's environment** — ambient sound, interactions with other people, context — to advise appropriately. This is where passive capture begins, and where two hard things land: (a) the consent/privacy UX for always-on observation, and (b) the realities of iOS background capture (the U6/U6b interruption-and-suspension evidence is a direct preview of this cost).

### Phase 3 — the living record
Perpetual capture and storage, fused with any available external data: other sensors, health records, conversations in email/messaging, purchases, doctor appointments. The output is a **living diagnostic record** and guidance that extends beyond the emotional into a **clinical aid** — beginning to predict, advise, influence, and potentially alter the user's future behavior or health state. This is the highest-claim, highest-burden phase: predictive claims are where FDA engagement, validation evidence, and privacy architecture all peak.

## 3. Track II — the embeddable engine for observers

Track I's engine, packaged as an **embeddable SDK/model** for third parties who observe others:

- **Customer-service call centers** — agent-facing state/wellbeing signals about the caller.
- **Clinical / HCP settings** — patient state measurement as a clinical aid.
- **Investigative / law-enforcement contexts** — subject state measurement.

**Two structural facts that must shape Track II design (flagged for review, §5):**

1. **The consent architecture inverts.** In Track I the user consents for themselves. In Track II the person being measured is usually NOT the product's user. Consent of the observed party, disclosure, and jurisdictional compliance become *product requirements*, not afterthoughts (constraints §8, §12).
2. **"Truth or deception" is the one claim this document refuses to promise as-is.** Decades of research (polygraph literature onward) have not established a reliable vocal or physiological marker of lying. A person-level "deception" label would violate the project's own evidence discipline (constraints §6, §9) and destroy the SaMD credibility that makes the rest of the product valuable. The defensible Track II positioning is: **measure stress, arousal, cognitive-load indicators, and emotional-state correlates — with honest uncertainty — and let the customer's trained humans draw conclusions.** If the owner wants a deception claim, it requires its own funded validation research program first. This is an owner decision, escalated to the ChatGPT review of this document.

**Regulatory horizon for Track II:** the EU AI Act prohibits emotion recognition in workplaces and education (narrow exceptions) and treats law-enforcement emotion inference as high-risk/restricted; US state laws (e.g. Illinois BIPA for voice biometrics, Colorado AI Act) touch call-center deployments. Track II needs per-deployment compliance design — another argument for selling an *engine with honest uncertainty metadata* rather than verdicts.

## 4. The shared foundation (what we are actually building right now)

The foundation is built **once** and must hold under all three phases and both tracks. Each item names the current unit that serves it:

1. **Normalized signal + provenance layer** (constraints §4) — every source enters the same way: mic audio today; HealthKit biometrics next; email/health records in Phase 3; Track II's customer feeds via adapters. No source ever feeds interpretation directly.
2. **Measurement-validity discipline** — D-07 (unavailable, never fabricated), D-17 (capture completeness as its own signal), D-18 (coverage-scoped analysis: every measurement carries what span it covers and what's known-missing). **This is the SaMD differentiator and Track II's selling point**: an engine that refuses to overclaim is the only kind that survives clinical and legal scrutiny.
3. **Signal libraries as versioned data, not code** (D-16, constraints §7) — thresholds, definitions, and rules shippable per audience (Track I casual vs. patient; Track II per-industry) without app updates. This is a productization requirement for Track II, not just hygiene.
4. **Layer separation** — observation / interpretation / self-report persisted separately (D-03); safety and escalation as distinct layers (constraints §6). The same engine output feeds a gentle Track I nudge and a Track II clinical dashboard without either corrupting the measurement.
5. **Consent and speaker-identity conservatism** (constraints §8, D-11) — never guess identity; enrollment or explicit confirmation only. This is the seed of both consent architectures.
6. **Capture-lifecycle robustness** (U6/U6b) — interruption chains, OS mic-mute spans, background suspension, honest gap records. Phase 2/3's continuous capture is this problem at 100× scale; every lesson banked now is banked for then.

**Current queue mapping (no re-ordering):** U4a (acoustic-expression measurement, transcript-independent) is the **first true behavioral-measurement component of the engine** — Phase 1's core channel and Track II's first licensable capability. U5/U2/U3 serve the words-as-context layer (D-02). After U4a/U5, the vision implies these candidate units for PLAN.md's queue (to be scoped when reached): HealthKit biometric adapter (Phase 1's second channel), the notification/guidance surface (Phase 1's "actively or passively notify"), and a consent-framework sketch (Phase 2's gate).

## 5. How the roadmap works: foundations + gates + a claims ladder

**No dates — gates.** A phase begins when its entry criteria are met, because the failure mode of date-driven roadmaps in regulated products is shipping claims the evidence can't support.

- **Phase 1 → 2 gate:** Phase 1 measurements demonstrated valid on real-world data (not just fixtures); consent UX for passive capture designed; iOS background-capture strategy proven beyond bounded reflection sessions.
- **Phase 2 → 3 gate:** longitudinal data model proven (constraints §3 hierarchy: session → day → pattern); external-source ingestion architecture reviewed for privacy; regulatory posture for the first predictive claim defined.
- **Track I → Track II gate:** engine measured and packaged independently of the app shell; observed-party consent architecture designed; per-jurisdiction compliance review done.

**The claims ladder** governs what the product may *say*, in either track:

> describe → correlate → advise → predict → influence/alter

Each rung requires its own validation evidence and regulatory posture before it is claimed in product language. The app may sit on rung 3 (advise) while the marketing sits on rung 1 (describe) — but never the reverse. Constraints §9 (time claims) is this ladder applied to wording.

**One engine, two shells** governs *how* features get built: measurement capabilities land engine-first behind a test-only or non-UI seam (the U4a pattern: prototype in `ObservatoryTests/`, validate against artifacts, only then integrate into production), then get surfaced in whichever shell needs them.

## 6. The parallel regulatory/business workstream (owner-led, quiet for now)

The code roadmap cannot itself produce FDA clearance; a parallel workstream must (eventually) run beside it:

- **QMS formalization is cheaper than it sounds, because it already exists in embryo.** The three-agent protocol (proposal → independent review → director verification against artifacts → exit protocol) is producing design-history-grade evidence today. Formalizing it against IEC 62304 (software lifecycle), ISO 14971 (risk management), and IEC 62366 (usability) is a documentation-mapping exercise, not a rebuild.
- **Intended-use statement first.** The single most load-bearing sentence in the regulatory strategy is the first cleared indication (e.g. "adjunct self-awareness tool for adults with ADHD/alexithymia" vs. a DTx claim). It determines pathway (510(k) vs. De Novo vs. PMA-adjacent), and it should be drafted before Phase 1 clinical features are built, not after.
- **Combination-product early signal.** If the molecule-combined therapeutic is real, FDA combination-product jurisdiction questions (drug-led vs. device-led) belong in a pre-submission meeting agenda ~12–18 months before any submission.
- **Track II is likely revenue before clearance** (enterprise licensing of the engine doesn't itself need FDA), which can fund the Track I regulatory work — but only if Track II claims stay inside the §3 honesty envelope; one overclaiming enterprise feature can poison the SaMD story.

## 7. Immediate effect on present coding activity

**None that changes the queue.** U4a proceeds exactly as proposed — its design (transcript-independent Channel A, rule-data thresholds, validity/coverage metadata, artifact-based milestones, test-only seam) is already the first component of the Track I/II shared engine, and this vision document retroactively explains *why* it was sequenced first. Two reading notes for whoever implements/reviews it:

1. Keep measurement types **source-agnostic and shell-agnostic** (no UI or app-session coupling in the measurement layer) — this is what makes the same code licensable as Track II later.
2. The validity evidence U4a produces (synthetic-signal validation, coverage numbers, gain invariance) is the **currency of every future claim** on the ladder — archive it as such, not as throwaway prototype output.

---
*Legacy note: `ROADMAP.md` (repo root) predates the stabilization program and the unit-queue process; it is tactical history, superseded by PLAN.md for current work and by this document for direction. Candidate cleanup: fold or mark it superseded once this vision is approved.*
