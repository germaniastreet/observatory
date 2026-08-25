# Observatory — Project Constraints
## Source of Truth • v0.2 • 2026-06-23

This file is binding for every future design, code, data-model, UI, and roadmap decision. If a proposed change conflicts with it, the change must be revised or the constraint must be explicitly amended and versioned.

## 1. Product purpose
Observatory is a multimodal personal observability system. Its long-term purpose is to help a person notice meaningful change in their body, behavior, context, language, and interactions early enough to understand, anticipate, or gently mitigate it.

It is not primarily a journaling app, transcript viewer, detector dashboard, or diagnostic product.

## 2. Primary experience
The primary user experience serves a person living their life:
1. What seems to be happening now?
2. What changed across a useful time window?
3. What evidence supports that observation?
4. What small, safe action or question may help?

Analyst, coach, researcher, clinician, moderator, and technical views remain available as expandable evidence layers. They are not the default surface.

## 3. Core hierarchy
Raw Input → Normalized Signal → Observation Event → Reflection → Session → Day → Longitudinal Pattern → Anticipatory Guidance

Definitions:
- Raw Input: unprocessed source material, e.g. audio, HealthKit sample, lab result, temperature.
- Normalized Signal: source-independent, time-stamped representation of an input.
- Observation Event: an evidence-backed, bounded event derived from one or more signals.
- Reflection: a bounded unit of speech, thought, or interaction selected or inferred for analysis.
- Session: one or more reflections/events over a coherent time window; may include multiple people.
- Day: time-aligned aggregate of sessions and other signals.
- Longitudinal Pattern: a repeat, shift, association, or trend across sessions/days.
- Anticipatory Guidance: a conservative, explainable prompt or recommendation; never an unsupported prediction.

A reflection is not a session. A session may include many reflections, multiple speakers, interruptions, and span minutes, hours, or a day.

## 4. Multimodal input principle
Voice and transcript are one sensor stream among many. Near-term sources include transcript, speaker context, heart rate, HRV, respiration, sleep, workouts, and device context. Later sources may include ambient sound, temperature, motion, location, calendar context, clinical records, labs, medications, and connected devices.

Every source must enter through a normalized signal/provenance layer. External sources must never feed directly into interpretation or diagnosis logic.

## 5. Evidence, uncertainty, and provenance
Every observation, pattern, recommendation, or safety cue must retain:
- source(s)
- timestamps/time window
- confidence/quality and uncertainty
- supporting evidence links
- rule/model/library identifier and version
- generation time
- user confirmation or correction, when applicable

The system must be able to answer: “Why did you say that?” without exposing unnecessary raw data by default.

## 6. Safety and health boundaries
Observatory detects change, associations, and possible need for attention. It does not diagnose disease, infer a medical condition as fact, or present a causal claim without sufficient evidence.

Separate layers are required:
- observation
- interpretation
- coaching
- safety/risk triage
- escalation guidance

Medical or behavioral safety language must be conservative, evidence-backed, and explicitly bounded. Any future regulated/SaMD direction requires a separate intended-use, validation, risk-management, privacy, and clinical-governance workstream.

## 7. Signal libraries are data, not code
Phrases, words, vocal markers (including ums, oks, pauses, garbled language), patterns, thresholds, categories, and domain rules must be modular, external, versioned, importable, attributable, enableable/disableable, auditable, and removable.

Libraries may be created by:
- the user
- a moderator/administrator
- Observatory
- an approved third party

Hard-coded rules are temporary prototypes only. Each must have a documented migration path into a library schema.

## 8. Speaker identity and consent
Speaker handling must be conservative:
Unknown Speaker → Recurring Speaker → Suggested Identity → Confirmed Identity

Diarization (“who spoke when”) is separate from identification (“is this Chris?”). The app must not claim a named identity without enrollment or explicit user confirmation. Multi-speaker sessions must preserve speaker uncertainty and consent boundaries.

## 9. Time claims
Do not use “trajectory,” “arc,” “change,” or similar language unless the available data supports the scope of the claim.
- Session-local sequence: may describe bounded movement within that reflection/session.
- Longitudinal trend: requires multiple time-aligned observations.
- Physiological correlation: requires time-aligned samples and must not imply causation.

“No clear pattern” must not be presented as a product failure. Absence of sufficient evidence is a valid result.

## 10. Interface rules
- Insight first; evidence second; diagnostics third.
- Calm, sparse, contextual, and useful primary UI.
- Show only information that earns its visual space.
- Avoid opaque scores and overconfident labels.
- Make evidence expandable and progressively disclosed.
- Orientation matters: time, place/context, body state, and current situation can help a user understand where they are.
- Recommendations should be gentle, actionable, and proportionate to confidence.

## 11. Modularity and scale
Every new capability must be additive, reversible, backward-compatible, and independently testable.
Separate:
- source adapters
- normalization
- storage
- libraries/rules
- detectors
- pattern engines
- interpretation
- UI
- safety/escalation

No UI screen should own durable business logic. No engine should depend on a specific device/vendor unless it is an adapter.

## 12. Privacy and control
Users must be able to understand, control, export, and remove their data and enabled libraries. Future sharing, moderation, clinical access, or third-party libraries require explicit consent and clear provenance.

## 13. Pre-build gate
Before any version begins, document:
1. Requirements advanced
2. Constraints that must not be violated
3. Data entities added/changed
4. Evidence/provenance behavior
5. Safety implications
6. Migration path for any prototype hardcoding
7. Test plan and rollback path
