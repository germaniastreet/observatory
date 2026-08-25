import Foundation

enum CorrelationEngine {
    static let engineVersion = "1.6"

    static func analyze(session: ReflectionSession) -> [ObservationCorrelation] {
        let events = session.observationEvents
        var correlations: [ObservationCorrelation] = []

        let uncertainty = events.matching(.uncertaintyLanguage)
        let qualification = events.matching(.qualificationLanguage)
        let selfCorrection = events.matching(.selfCorrection)
        let emotionSearch = events.matching(.emotionSearch)
        let pauseGaps = events.matching(.pauseGap)
        let breath = events.matching(.breathCue)
        let stress = events.matching(.stressLanguage)
        let conflict = events.matching(.conflictLanguage)
        let regulation = events.matching(.regulationAttempt)
        let repetition = events.matching(.repetition)
        let falseStarts = events.matching(.falseStart)
        let outcomeConcern = events.matching(.outcomeConcern)
        let verificationAttempt = events.matching(.verificationAttempt)
        let selfMonitoring = events.matching(.selfMonitoring)
        let relief = events.matching(.relief)

        if !emotionSearch.isEmpty && (!selfCorrection.isEmpty || !qualification.isEmpty) {
            correlations.append(make(
                title: "Emotion search + correction",
                kind: .emotionalClarification,
                summary: "Emotion search appeared with correction or qualification, suggesting the speaker may be refining an emotional label.",
                confidence: .medium,
                events: emotionSearch + selfCorrection + qualification,
                tags: ["emotion-search", "correction", "clarification"]
            ))
        }

        if !uncertainty.isEmpty && !pauseGaps.isEmpty {
            correlations.append(make(
                title: "Uncertainty + pause",
                kind: .reflectiveProcessing,
                summary: "Uncertainty language appeared in the same reflection as pause gaps, suggesting possible reflective processing or hesitation.",
                confidence: .medium,
                events: uncertainty + pauseGaps,
                tags: ["uncertainty", "pause", "reflection"]
            ))
        }

        if !breath.isEmpty && (!pauseGaps.isEmpty || !regulation.isEmpty) {
            correlations.append(make(
                title: "Breath cue + pause/regulation",
                kind: .possibleSelfRegulation,
                summary: "Breath-related language appeared near pause or regulation events, suggesting a possible self-regulation attempt.",
                confidence: .medium,
                events: breath + pauseGaps + regulation,
                tags: ["breath", "pause", "regulation"]
            ))
        }

        if !conflict.isEmpty && !regulation.isEmpty {
            correlations.append(make(
                title: "Conflict + regulation",
                kind: .conflictRegulation,
                summary: "Conflict language appeared together with regulation language, suggesting the speaker may be trying to keep the situation from escalating.",
                confidence: .medium,
                events: conflict + regulation,
                tags: ["conflict", "de-escalation", "regulation"]
            ))
        }

        if !stress.isEmpty && (!pauseGaps.isEmpty || !breath.isEmpty) {
            correlations.append(make(
                title: "Stress + body/voice cue",
                kind: .stressActivation,
                summary: "Stress language appeared with pause or breath cues. This may become more meaningful once audio and watch signals are available.",
                confidence: .low,
                events: stress + pauseGaps + breath,
                tags: ["stress", "voice", "body"]
            ))
        }

        if (!selfCorrection.isEmpty || !falseStarts.isEmpty || !repetition.isEmpty) && !pauseGaps.isEmpty {
            correlations.append(make(
                title: "Speech friction + pause",
                kind: .speechFriction,
                summary: "Correction, repetition, or false-start language appeared with pause gaps, suggesting effort while forming or revising speech.",
                confidence: .low,
                events: selfCorrection + falseStarts + repetition + pauseGaps,
                tags: ["speech-friction", "pause", "revision"]
            ))
        }

        if !uncertainty.isEmpty && !qualification.isEmpty {
            correlations.append(make(
                title: "Uncertainty + qualification",
                kind: .uncertaintyWithQualification,
                summary: "Uncertainty language appeared with qualifying language, suggesting nuance, low certainty, or active sense-making.",
                confidence: .medium,
                events: uncertainty + qualification,
                tags: ["uncertainty", "qualification", "sense-making"]
            ))
        }

        if !breath.isEmpty && (!stress.isEmpty || !conflict.isEmpty || !uncertainty.isEmpty) {
            correlations.append(make(
                title: "Breath cue after concern",
                kind: .breathAfterConcern,
                summary: "Breath language appeared in a reflection that also included concern, stress, conflict, or uncertainty cues.",
                confidence: .medium,
                events: breath + stress + conflict + uncertainty,
                tags: ["breath", "concern", "state-shift"]
            ))
        }


        if !outcomeConcern.isEmpty && !verificationAttempt.isEmpty {
            correlations.append(make(
                title: "Concern + verification",
                kind: .concernVerification,
                summary: "Outcome concern appeared with verification behavior, suggesting the speaker was checking whether a feared problem had occurred.",
                confidence: .medium,
                events: outcomeConcern + verificationAttempt,
                tags: ["concern", "verification", "checking"]
            ))
        }

        if !verificationAttempt.isEmpty && !relief.isEmpty {
            correlations.append(make(
                title: "Verification + relief",
                kind: .verificationRelief,
                summary: "Verification behavior appeared with reassurance or relief language, suggesting a checking-to-resolution sequence.",
                confidence: .medium,
                events: verificationAttempt + relief,
                tags: ["verification", "relief", "resolution"]
            ))
        }

        if !selfMonitoring.isEmpty && !relief.isEmpty {
            correlations.append(make(
                title: "Self-monitoring + reassurance",
                kind: .selfMonitoringReassurance,
                summary: "Self-monitoring appeared with reassurance language, suggesting the speaker was tracking status and then accepting that the situation looked acceptable.",
                confidence: .medium,
                events: selfMonitoring + relief,
                tags: ["self-monitoring", "reassurance", "status-check"]
            ))
        }

        return correlations
    }

    static func summary(_ correlations: [ObservationCorrelation]) -> String {
        guard !correlations.isEmpty else {
            return "No correlations detected yet."
        }

        let titles = correlations.prefix(3).map { $0.title }.joined(separator: ", ")
        return "\(correlations.count) correlation(s): \(titles)"
    }

    private static func make(
        title: String,
        kind: ObservationCorrelationKind,
        summary: String,
        confidence: SignalQuality,
        events: [ObservationEvent],
        tags: [String]
    ) -> ObservationCorrelation {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let timestamp = sorted.first?.timestamp ?? Date()

        return ObservationCorrelation(
            timestamp: timestamp,
            title: title,
            kind: kind,
            summary: summary,
            confidence: confidence,
            sourceEventIDs: sorted.map { $0.id },
            sourceEventTitles: sorted.map { $0.title },
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


