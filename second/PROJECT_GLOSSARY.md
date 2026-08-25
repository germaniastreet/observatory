# Observatory — Project Glossary
## Source of Truth • v0.2 • 2026-06-23

| Term | Definition |
|---|---|
| Raw Input | Original source material: audio, HealthKit record, lab result, device reading, context signal. |
| Signal | Normalized, timestamped representation of a raw input, independent of vendor/device. |
| Signal Source | The origin of a signal, e.g. Apple Watch, Oura, transcript, Sutter, Quest. |
| Observation Event | A bounded, evidence-backed detection derived from one or more signals. |
| Reflection | A bounded segment of speech, thought, or interaction selected/inferred for analysis. |
| Session | A coherent time window containing one or more reflections/events and possibly multiple speakers. |
| Speaker Cluster | Acoustic grouping that may represent a recurring voice; not a named identity. |
| Speaker Identity | A user-confirmed or enrolled person associated with a cluster. |
| Signal Library | Importable, versioned data package of phrases, patterns, thresholds, rules, metadata, and provenance. |
| Detector | A component that applies library definitions or models to signals and produces observation events. |
| Pattern | A repeated, sequenced, or correlated set of observations across an explicit time scope. |
| Arc | A bounded session/reflection sequence only; it must not imply long-term change. |
| Trajectory | A longitudinal pattern across sufficient time-aligned observations. |
| Correlation | Time-aligned association; never proof of causation. |
| Interpretation | Human-readable explanation of an observation/pattern with uncertainty and alternatives. |
| Guidance | A gentle, proportionate prompt or suggested action. |
| Safety Recommendation | A separately governed response to possible risk; not a diagnosis. |
| Provenance | Source, time, transformation, library/model version, and evidence chain behind an output. |
| Analyst View | Expandable technical/evidence interface for inspection, research, coaching, or moderation. |
| Primary View | Calm user-facing view focused on useful awareness and next steps. |
