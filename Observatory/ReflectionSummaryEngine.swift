import Foundation

struct ReflectionSummaryResult {
    let summary: String
    let observedPattern: String
    let keySignals: [String]
    let suggestedDirection: String
    let confidence: SignalQuality
}

enum ReflectionSummaryEngine {
    static let engineVersion = "1.7"

    static func analyze(session: ReflectionSession) -> ReflectionSummaryResult {
        let transcriptText = session.transcript.map { $0.text }.joined(separator: " ").lowercased()
        let eventKinds = Set(session.observationEvents.map { $0.kind })
        let dynamicsKinds = Set(session.dynamicsPatterns.map { $0.kind })
        let correlationKinds = Set(session.observationCorrelations.map { $0.kind })

        let hasBreath =
            eventKinds.contains(.breathCue) ||
            dynamicsKinds.contains(.breathRegulationMarker) ||
            correlationKinds.contains(.possibleSelfRegulation) ||
            correlationKinds.contains(.breathAfterConcern)

        let hasSpeechFriction =
            eventKinds.contains(.repetition) ||
            eventKinds.contains(.falseStart) ||
            eventKinds.contains(.selfCorrection) ||
            dynamicsKinds.contains(.speechConstructionFriction) ||
            correlationKinds.contains(.speechFriction)

        let hasUncertainty =
            eventKinds.contains(.uncertaintyLanguage) ||
            eventKinds.contains(.qualificationLanguage) ||
            dynamicsKinds.contains(.uncertaintyLoop) ||
            correlationKinds.contains(.uncertaintyWithQualification) ||
            correlationKinds.contains(.reflectiveProcessing)

        let hasEmotionSearch =
            eventKinds.contains(.emotionSearch) ||
            dynamicsKinds.contains(.emotionalClarification) ||
            dynamicsKinds.contains(.emotionalAmbivalence) ||
            correlationKinds.contains(.emotionalClarification)

        let hasConflict =
            eventKinds.contains(.conflictLanguage) ||
            correlationKinds.contains(.conflictRegulation)

        let hasStress =
            eventKinds.contains(.stressLanguage) ||
            correlationKinds.contains(.stressActivation)

        let hasProgressLanguage =
            transcriptText.contains("progress") ||
            transcriptText.contains("moving on") ||
            transcriptText.contains("let's go") ||
            transcriptText.contains("lets go") ||
            transcriptText.contains("again")

        let hasOutcomeConcern = eventKinds.contains(.outcomeConcern)
        let hasVerificationAttempt = eventKinds.contains(.verificationAttempt)
        let hasSelfMonitoring = eventKinds.contains(.selfMonitoring)
        let hasRelief = eventKinds.contains(.relief)
        let hasReorientation = eventKinds.contains(.reorientation)
        let hasPlanning = eventKinds.contains(.planning)

        let hasFrustrationLanguage =
            transcriptText.contains("ugh") ||
            transcriptText.contains("oh boy") ||
            transcriptText.contains("behind") ||
            transcriptText.contains("frustrated") ||
            transcriptText.contains("waste my time") ||
            transcriptText.contains("hope this works")

        var keySignals: [String] = []

        if hasOutcomeConcern { keySignals.append("Outcome concern") }
        if hasVerificationAttempt { keySignals.append("Verification attempt") }
        if hasSelfMonitoring { keySignals.append("Self-monitoring") }
        if hasRelief { keySignals.append("Relief / reassurance") }
        if hasReorientation { keySignals.append("Reorientation toward progress") }
        if hasPlanning { keySignals.append("Planning") }
        if hasBreath { keySignals.append("Breath-related regulation cue") }
        if hasSpeechFriction { keySignals.append("Speech-construction friction") }
        if hasUncertainty { keySignals.append("Uncertainty or sense-making") }
        if hasEmotionSearch { keySignals.append("Emotional clarification") }
        if hasConflict { keySignals.append("Conflict or de-escalation signal") }
        if hasStress { keySignals.append("Stress or activation language") }
        if hasProgressLanguage { keySignals.append("Reorientation toward progress") }
        if hasFrustrationLanguage { keySignals.append("Mild frustration or effort language") }

        if keySignals.isEmpty {
            return ReflectionSummaryResult(
                summary: "This reflection was captured with no strong pattern detected yet. The available evidence is limited, so the system is holding the interpretation lightly.",
                observedPattern: "The reflection was captured with a mostly neutral tone and no strong emotional pattern detected.",
                keySignals: ["Limited signal"],
                suggestedDirection: "Continue collecting reflections so patterns can be compared over time.",
                confidence: .low
            )
        }


        if hasOutcomeConcern && hasVerificationAttempt && hasRelief {
            return ReflectionSummaryResult(
                summary: "The reflection began with concern about a possible mistake, shifted into verification behavior, and ended with reassurance that the situation looked acceptable.",
                observedPattern: "Outcome concern moved into checking and then reassurance.",
                keySignals: keySignals,
                suggestedDirection: "Note what was verified and whether the reassurance feels complete or temporary.",
                confidence: .medium
            )
        }

        if hasVerificationAttempt && hasSelfMonitoring {
            return ReflectionSummaryResult(
                summary: "The reflection included checking and self-monitoring, suggesting the speaker was actively verifying status or progress.",
                observedPattern: "Verification and self-monitoring appeared together.",
                keySignals: keySignals,
                suggestedDirection: "Identify what evidence would be enough to stop checking and move forward.",
                confidence: .medium
            )
        }

        if hasFrustrationLanguage && hasBreath && hasProgressLanguage {
            return ReflectionSummaryResult(
                summary: "The reflection suggests mild frustration or effort alongside an attempt to regulate and move forward. Breath-related language and progress-oriented phrasing appeared together, suggesting the speaker may have been trying to reorient rather than remain stuck.",
                observedPattern: "Mild frustration appeared alongside breath-related regulation and a stated effort to keep moving forward.",
                keySignals: keySignals,
                suggestedDirection: "Pause briefly, name the immediate feeling, then choose one small next action.",
                confidence: .medium
            )
        }

        if hasSpeechFriction && hasBreath {
            return ReflectionSummaryResult(
                summary: "The reflection included speech-construction friction together with breath-related language. This suggests the speaker may have been working through a moment of activation while trying to steady or organize their thoughts.",
                observedPattern: "Speech-construction friction appeared alongside a breath-related regulation cue.",
                keySignals: keySignals,
                suggestedDirection: "Take one slower breath and restate the main concern in a single sentence.",
                confidence: .medium
            )
        }

        if hasUncertainty && hasEmotionSearch {
            return ReflectionSummaryResult(
                summary: "The reflection suggests active sense-making. Uncertainty and emotional clarification signals appeared together, suggesting the speaker may have been trying to identify what they were feeling rather than reaching a settled conclusion.",
                observedPattern: "Uncertainty appeared alongside emotional clarification, suggesting active sense-making.",
                keySignals: keySignals,
                suggestedDirection: "Try naming two possible emotions and what each one may be responding to.",
                confidence: .medium
            )
        }

        if hasConflict && (hasBreath || hasStress) {
            return ReflectionSummaryResult(
                summary: "The reflection suggests concern around interpersonal tension, with signs of regulation or activation also present. The speaker may have been trying to prevent escalation or regain steadiness.",
                observedPattern: "Conflict or concern appeared alongside regulation or activation cues.",
                keySignals: keySignals,
                suggestedDirection: "Separate what happened from what it means before deciding what to do next.",
                confidence: .medium
            )
        }

        if hasStress || hasFrustrationLanguage {
            return ReflectionSummaryResult(
                summary: "The reflection suggests some activation or frustration, but the available signals are not yet strong enough to determine a more specific pattern.",
                observedPattern: "Activation or frustration language appeared, but the overall pattern remains tentative.",
                keySignals: keySignals,
                suggestedDirection: "Notice whether the feeling is about urgency, disappointment, uncertainty, or pressure.",
                confidence: .low
            )
        }

        return ReflectionSummaryResult(
            summary: "Several lightweight observation signals were detected. The system has enough evidence to identify possible movement in the reflection, but not enough to form a strong interpretation.",
            observedPattern: "Multiple lightweight signals appeared, but no dominant pattern was detected.",
            keySignals: keySignals,
            suggestedDirection: "Continue reflecting and compare this session against future sessions.",
            confidence: .low
        )
    }
}


