import Foundation

enum DynamicsEngine {
    static let engineVersion = "1.5"

    static func analyze(session: ReflectionSession) -> [DynamicsPattern] {
        let events = session.observationEvents
        let text = session.transcript.map { $0.text }.joined(separator: " ").lowercased()

        var patterns: [DynamicsPattern] = []

        let emotionSearch = events.matching(.emotionSearch)
        let uncertainty = events.matching(.uncertaintyLanguage)
        let qualification = events.matching(.qualificationLanguage)
        let selfCorrection = events.matching(.selfCorrection)
        let breath = events.matching(.breathCue)
        let regulation = events.matching(.regulationAttempt)
        let stress = events.matching(.stressLanguage)
        let conflict = events.matching(.conflictLanguage)
        let questions = events.matching(.reflectiveQuestion)
        let pauses = events.matching(.pauseGap)
        let repetitions = events.matching(.repetition)
        let outcomeConcern = events.matching(.outcomeConcern)
        let verificationAttempt = events.matching(.verificationAttempt)
        let selfMonitoring = events.matching(.selfMonitoring)
        let relief = events.matching(.relief)
        let reorientation = events.matching(.reorientation)
        let planning = events.matching(.planning)

        if !emotionSearch.isEmpty && (!qualification.isEmpty || !selfCorrection.isEmpty || text.contains(" or ")) {
            patterns.append(pattern(
                title: "Emotional clarification",
                kind: .emotionalClarification,
                detail: "The speaker appears to be testing or refining emotional labels rather than stating a single settled feeling.",
                confidence: .medium,
                events: emotionSearch + qualification + selfCorrection,
                tags: ["emotion-search", "clarification", "emotional-granularity"]
            ))
        }

        if text.contains("angry") && (text.contains("frustrated") || text.contains("disappointed")) {
            patterns.append(pattern(
                title: "Emotional ambivalence",
                kind: .emotionalAmbivalence,
                detail: "Multiple emotional labels appeared close together, suggesting the speaker may be comparing possible internal states.",
                confidence: .medium,
                events: emotionSearch + qualification,
                tags: ["ambivalence", "emotion-comparison"]
            ))
        }

        if !regulation.isEmpty || (!breath.isEmpty && (!stress.isEmpty || !conflict.isEmpty)) {
            patterns.append(pattern(
                title: "Regulation effort",
                kind: .regulationEffort,
                detail: "The reflection included signs of attempting to regulate or de-escalate state, such as calm language, restraint language, or breath-related language.",
                confidence: .medium,
                events: regulation + breath + stress + conflict,
                tags: ["regulation", "de-escalation", "state-shift"]
            ))
        }

        if !uncertainty.isEmpty && (!questions.isEmpty || !qualification.isEmpty) {
            patterns.append(pattern(
                title: "Uncertainty loop",
                kind: .uncertaintyLoop,
                detail: "Uncertainty language appeared together with questioning or qualification, suggesting active sense-making rather than a settled conclusion.",
                confidence: .medium,
                events: uncertainty + questions + qualification,
                tags: ["uncertainty", "questioning", "sense-making"]
            ))
        }

        if !selfCorrection.isEmpty || !qualification.isEmpty || !repetitions.isEmpty {
            patterns.append(pattern(
                title: "Speech-construction friction",
                kind: .speechConstructionFriction,
                detail: "The transcript included signs of revision, qualification, repetition, or correction while the speaker was forming language.",
                confidence: .low,
                events: selfCorrection + qualification + repetitions,
                tags: ["speech-construction", "revision", "hesitation"]
            ))
        }

        if !stress.isEmpty && (!breath.isEmpty || !pauses.isEmpty || !regulation.isEmpty) {
            patterns.append(pattern(
                title: "Stress / regulation cluster",
                kind: .stressRegulationCluster,
                detail: "Stress-related language appeared near breath, pause, or regulation events, suggesting a possible attempt to manage activation.",
                confidence: .medium,
                events: stress + breath + pauses + regulation,
                tags: ["stress", "regulation", "cluster"]
            ))
        }

        if !breath.isEmpty {
            patterns.append(pattern(
                title: "Breath-regulation marker",
                kind: .breathRegulationMarker,
                detail: "Breath-related language appeared in the reflection. This is currently language-based and should later be cross-checked against audio or watch respiration signals.",
                confidence: .medium,
                events: breath,
                tags: ["breath", "body", "future-cross-check"]
            ))
        }

        if !questions.isEmpty && !uncertainty.isEmpty {
            patterns.append(pattern(
                title: "Reflective sense-making",
                kind: .reflectiveSenseMaking,
                detail: "The speaker used questioning and uncertainty language, suggesting an attempt to interpret or make sense of the experience.",
                confidence: .medium,
                events: questions + uncertainty,
                tags: ["reflection", "meaning-making", "questioning"]
            ))
        }


        if !outcomeConcern.isEmpty && !verificationAttempt.isEmpty && !relief.isEmpty {
            patterns.append(pattern(
                title: "Resolution seeking",
                kind: .resolutionSeeking,
                detail: "Concern, verification, and reassurance appeared together, suggesting a sequence of noticing a possible problem, checking it, and reaching some relief.",
                confidence: .medium,
                events: outcomeConcern + verificationAttempt + selfMonitoring + relief,
                tags: ["concern", "verification", "relief", "resolution-seeking"]
            ))
        }

        if !verificationAttempt.isEmpty && !selfMonitoring.isEmpty {
            patterns.append(pattern(
                title: "Active checking",
                kind: .activeChecking,
                detail: "Verification and self-monitoring appeared together, suggesting active checking of progress, output, or status.",
                confidence: .medium,
                events: verificationAttempt + selfMonitoring,
                tags: ["checking", "self-monitoring", "verification"]
            ))
        }

        if !outcomeConcern.isEmpty && relief.isEmpty {
            patterns.append(pattern(
                title: "Unresolved concern",
                kind: .unresolvedConcern,
                detail: "Outcome concern appeared without a clear reassurance signal in the same reflection.",
                confidence: .low,
                events: outcomeConcern,
                tags: ["concern", "unresolved", "risk"]
            ))
        }

        if !planning.isEmpty || !reorientation.isEmpty {
            patterns.append(pattern(
                title: "Forward orientation",
                kind: .reflectiveSenseMaking,
                detail: "The reflection included planning or reorientation language, suggesting movement toward a next step.",
                confidence: .low,
                events: planning + reorientation,
                tags: ["planning", "forward-motion", "next-action"]
            ))
        }

        return patterns
    }

    static func summary(_ patterns: [DynamicsPattern]) -> String {
        if patterns.isEmpty {
            return "No dynamics patterns detected yet."
        }

        let titles = patterns.prefix(3).map { $0.title }.joined(separator: ", ")
        return "\(patterns.count) pattern(s): \(titles)"
    }

    private static func pattern(
        title: String,
        kind: DynamicsPatternKind,
        detail: String,
        confidence: SignalQuality,
        events: [ObservationEvent],
        tags: [String]
    ) -> DynamicsPattern {
        DynamicsPattern(
            title: title,
            kind: kind,
            detail: detail,
            confidence: confidence,
            supportingEventIDs: events.map { $0.id },
            tags: tags,
            engineVersion: engineVersion
        )
    }
}

private extension Array where Element == ObservationEvent {
    func matching(_ kind: ObservationEventKind) -> [ObservationEvent] {
        filter { $0.kind == kind }
    }
}

