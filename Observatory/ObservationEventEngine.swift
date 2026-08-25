import Foundation

enum ObservationEventEngine {
    static let engineVersion = "1.5"

    static func enrich(session: ReflectionSession) -> [ObservationEvent] {
        var events = session.observationEvents
        let text = session.transcript.map { $0.text }.joined(separator: " ")
        let lower = text.lowercased()
        let timestamp = session.endedAt ?? Date()

        if containsAny(lower, ["deep breath", "breath", "breathe", "inhale", "exhale", "sigh"]) {
            appendIfMissing(
                &events,
                kind: .breathCue,
                category: .body,
                timestamp: timestamp,
                title: "Breath cue",
                detail: "The transcript included language related to breath or air intake.",
                source: .transcript,
                confidence: .medium,
                relatedText: matchingPhrase(in: text, terms: ["deep breath", "breath", "breathe", "inhale", "exhale", "sigh"]),
                tags: ["breath", "regulation", "body-signal-candidate"],
                alternativeExplanations: [
                    "Could be a literal, unrelated mention of breathing (e.g. exercise, illness) rather than emotional regulation.",
                    "Could be describing someone else's breathing, not the speaker's own."
                ]
            )
        }

        if containsAny(lower, ["stress", "stressed", "tension", "tense", "nervous", "anxious", "overwhelmed"]) {
            appendIfMissing(
                &events,
                kind: .stressLanguage,
                category: .language,
                timestamp: timestamp,
                title: "Stress language",
                detail: "The transcript included words associated with stress, tension, or activation.",
                source: .observationEngine,
                confidence: .medium,
                relatedText: matchingPhrase(in: text, terms: ["stress", "stressed", "tension", "tense", "nervous", "anxious", "overwhelmed"]),
                tags: ["stress", "activation", "mood"],
                alternativeExplanations: [
                    "Could describe a past or hypothetical situation rather than the speaker's current state.",
                    "Could be attributed to someone else (e.g. \"my coworker was stressed\") rather than self-reported.",
                    "Could be used casually/idiomatically without indicating real emotional activation."
                ]
            )
        }

        if containsAny(lower, ["fight", "fighting", "conflict", "argument", "escalate", "escalation", "out of hand"]) {
            appendIfMissing(
                &events,
                kind: .conflictLanguage,
                category: .language,
                timestamp: timestamp,
                title: "Conflict language",
                detail: "The transcript included language related to conflict, escalation, or interpersonal tension.",
                source: .observationEngine,
                confidence: .medium,
                relatedText: matchingPhrase(in: text, terms: ["fight", "fighting", "conflict", "argument", "escalate", "escalation", "out of hand"]),
                tags: ["conflict", "interpersonal", "escalation"],
                alternativeExplanations: [
                    "Could refer to a resolved or historical conflict rather than an active one.",
                    "\"Fight\" or \"fighting\" could be used non-literally (e.g. \"fighting for a promotion\") without interpersonal conflict."
                ]
            )
        }

        if containsAny(lower, ["i don't know", "i dont know", "unclear", "confused", "not sure", "maybe", "why"]) {
            appendIfMissing(
                &events,
                kind: .uncertaintyLanguage,
                category: .language,
                timestamp: timestamp,
                title: "Uncertainty language",
                detail: "The transcript included language suggesting uncertainty or sense-making.",
                source: .observationEngine,
                confidence: .medium,
                relatedText: matchingPhrase(in: text, terms: ["i don't know", "i dont know", "unclear", "confused", "not sure", "maybe", "why"]),
                tags: ["uncertainty", "sense-making", "confidence-candidate"],
                alternativeExplanations: [
                    "Could be a rhetorical or conversational filler rather than genuine uncertainty.",
                    "\"Why\" may simply be part of a question about someone/something else, not self-reflection."
                ]
            )
        }

        let questionCount = lower.filter { $0 == "?" }.count + countQuestionStarters(lower)
        if questionCount > 0 {
            appendIfMissing(
                &events,
                kind: .reflectiveQuestion,
                category: .language,
                timestamp: timestamp,
                title: "Reflective questioning",
                detail: "The reflection included one or more questions, suggesting active sense-making.",
                source: .observationEngine,
                confidence: .medium,
                relatedText: nil,
                tags: ["questioning", "sense-making"],
                alternativeExplanations: [
                    "Questions may be addressed to someone else in the room rather than posed reflectively to oneself."
                ]
            )
        }

        if containsAny(lower, ["calm", "keep it cool", "cool", "friendly", "de-escalate", "deescalate", "didn't say", "did not say", "hold back"]) {
            appendIfMissing(
                &events,
                kind: .regulationAttempt,
                category: .behavior,
                timestamp: timestamp,
                title: "Regulation attempt",
                detail: "The transcript included language suggesting restraint, de-escalation, or an attempt to keep the situation regulated.",
                source: .observationEngine,
                confidence: .medium,
                relatedText: matchingPhrase(in: text, terms: ["calm", "keep it cool", "cool", "friendly", "de-escalate", "deescalate", "didn't say", "did not say", "hold back"]),
                tags: ["regulation", "restraint", "de-escalation"],
                alternativeExplanations: [
                    "\"Cool\" or \"calm\" may describe weather, temperature, or an unrelated topic rather than emotional regulation.",
                    "Could describe someone else's regulation attempt, not the speaker's own."
                ]
            )
        }

        if containsAny(lower, ["maybe", "perhaps", "sort of", "kind of", "i guess", "probably", "possibly"]) {
            appendIfMissing(
                &events,
                kind: .qualificationLanguage,
                category: .language,
                timestamp: timestamp,
                title: "Qualification language",
                detail: "The transcript included qualifying language that may indicate uncertainty, nuance, or low confidence.",
                source: .observationEngine,
                confidence: .low,
                relatedText: matchingPhrase(in: text, terms: ["maybe", "perhaps", "sort of", "kind of", "i guess", "probably", "possibly"]),
                tags: ["qualification", "uncertainty", "confidence-candidate"],
                alternativeExplanations: [
                    "Could be a habitual speech pattern or verbal tic rather than genuine hedging.",
                    "May reflect politeness/softening norms rather than actual uncertainty."
                ]
            )
        }

        if containsAny(lower, ["definitely", "absolutely", "certainly", "without question", "for sure", "no doubt"]) {
            appendIfMissing(
                &events,
                kind: .certaintyLanguage,
                category: .language,
                timestamp: timestamp,
                title: "Certainty language",
                detail: "The transcript included language indicating certainty or strong commitment.",
                source: .observationEngine,
                confidence: .low,
                relatedText: matchingPhrase(in: text, terms: ["definitely", "absolutely", "certainly", "without question", "for sure", "no doubt"]),
                tags: ["certainty", "confidence-candidate"],
                alternativeExplanations: [
                    "Could be applied to a minor/low-stakes topic rather than signaling strong conviction overall.",
                    "May be used for emphasis or as a verbal habit rather than reflecting actual certainty."
                ]
            )
        }

        if containsAny(lower, ["actually", "i mean", "no,", "no ", "rather", "what i mean", "let me say that differently"]) {
            appendIfMissing(
                &events,
                kind: .selfCorrection,
                category: .language,
                timestamp: timestamp,
                title: "Self correction",
                detail: "The transcript included language suggesting correction, restatement, or adjustment of meaning.",
                source: .observationEngine,
                confidence: .low,
                relatedText: matchingPhrase(in: text, terms: ["actually", "i mean", "rather", "what i mean", "let me say that differently"]),
                tags: ["self-correction", "speech-construction", "confidence-candidate"],
                alternativeExplanations: [
                    "\"Actually\" or \"I mean\" are common filler transitions and may not reflect a genuine correction of meaning."
                ]
            )
        }

        if containsAny(lower, ["i was going to", "what i was trying to say", "let me start", "start over", "wait"]) {
            appendIfMissing(
                &events,
                kind: .falseStart,
                category: .language,
                timestamp: timestamp,
                title: "False start",
                detail: "The transcript included language suggesting a false start or restart in speech construction.",
                source: .observationEngine,
                confidence: .low,
                relatedText: matchingPhrase(in: text, terms: ["i was going to", "what i was trying to say", "let me start", "start over", "wait"]),
                tags: ["false-start", "speech-construction", "hesitation"],
                alternativeExplanations: [
                    "\"Wait\" may be used to mean \"hold on, one moment\" rather than restarting a thought."
                ]
            )
        }

        if containsAny(lower, ["i don't know if i'm", "i dont know if im", "i don't know whether i'm", "am i angry", "am i sad", "or maybe", "or frustrated", "or disappointed"]) {
            appendIfMissing(
                &events,
                kind: .emotionSearch,
                category: .language,
                timestamp: timestamp,
                title: "Emotion search",
                detail: "The transcript included language suggesting the speaker was searching for the right emotional label.",
                source: .observationEngine,
                confidence: .medium,
                relatedText: matchingPhrase(in: text, terms: ["i don't know if i'm", "i dont know if im", "i don't know whether i'm", "am i angry", "am i sad", "or maybe", "or frustrated", "or disappointed"]),
                tags: ["emotion-search", "emotional-granularity", "sense-making"],
                alternativeExplanations: [
                    "Could be asking about someone else's emotional state rather than the speaker's own."
                ]
            )
        }

        let repeated = repeatedAdjacentWords(text)
        if !repeated.isEmpty {
            appendIfMissing(
                &events,
                kind: .repetition,
                category: .language,
                timestamp: timestamp,
                title: "Word repetition",
                detail: "The transcript contained repeated words, which may indicate emphasis, activation, or searching for language.",
                source: .observationEngine,
                confidence: .low,
                relatedText: repeated.joined(separator: ", "),
                tags: ["repetition", "speech-construction", "emphasis"],
                alternativeExplanations: [
                    "Repetition can also come from speech-to-text stutter/glitch artifacts rather than the speaker actually repeating themselves.",
                    "May simply be a natural speech pattern rather than a sign of emphasis or activation."
                ]
            )
        }

        events.append(contentsOf: CognitiveObservationDetector.detect(session: session))

        return events.sorted { $0.timestamp < $1.timestamp }
    }

    static func eventSummary(_ events: [ObservationEvent]) -> String {
        if events.isEmpty {
            return "No micro-observation events recorded yet."
        }

        let grouped = Dictionary(grouping: events, by: { $0.category })
        let parts = ObservationCategory.allCases.compactMap { category -> String? in
            guard let count = grouped[category]?.count, count > 0 else { return nil }
            return "\(category.rawValue): \(count)"
        }

        return "Events: \(events.count). " + parts.joined(separator: ". ")
    }

    static func groupedEvents(_ events: [ObservationEvent]) -> [(category: ObservationCategory, events: [ObservationEvent])] {
        let grouped = Dictionary(grouping: events, by: { $0.category })

        return ObservationCategory.allCases.compactMap { category in
            guard let categoryEvents = grouped[category], !categoryEvents.isEmpty else { return nil }
            return (category, categoryEvents.sorted { $0.timestamp < $1.timestamp })
        }
    }

    static func categorySummary(_ category: ObservationCategory, events: [ObservationEvent]) -> String {
        let counts = Dictionary(grouping: events, by: { $0.kind }).mapValues { $0.count }
        let kinds = counts.map { kind, count in
            "\(title(for: kind)) × \(count)"
        }
        .sorted()

        return kinds.joined(separator: ", ")
    }

    static func title(for kind: ObservationEventKind) -> String {
        switch kind {
        case .pauseGap: return "Pause gap"
        case .breathCue: return "Breath cue"
        case .stressLanguage: return "Stress language"
        case .conflictLanguage: return "Conflict language"
        case .uncertaintyLanguage: return "Uncertainty language"
        case .reflectiveQuestion: return "Reflective questioning"
        case .regulationAttempt: return "Regulation attempt"
        case .repetition: return "Word repetition"
        case .falseStart: return "False start"
        case .selfCorrection: return "Self correction"
        case .qualificationLanguage: return "Qualification language"
        case .certaintyLanguage: return "Certainty language"
        case .emotionSearch: return "Emotion search"
        case .outcomeConcern: return "Outcome concern"
        case .verificationAttempt: return "Verification attempt"
        case .selfMonitoring: return "Self-monitoring"
        case .relief: return "Relief / reassurance"
        case .reorientation: return "Reorientation toward progress"
        case .planning: return "Planning"
        case .decisionPoint: return "Decision point"
        }
    }

    private static func appendIfMissing(
        _ events: inout [ObservationEvent],
        kind: ObservationEventKind,
        category: ObservationCategory,
        timestamp: Date,
        title: String,
        detail: String,
        source: SignalSource,
        confidence: SignalQuality,
        relatedText: String?,
        tags: [String],
        alternativeExplanations: [String] = []
    ) {
        guard !events.contains(where: { $0.kind == kind && $0.title == title }) else { return }

        events.append(
            ObservationEvent(
                timestamp: timestamp,
                kind: kind,
                category: category,
                title: title,
                detail: detail,
                source: source,
                confidence: confidence,
                relatedText: relatedText,
                tags: tags,
                alternativeExplanations: alternativeExplanations,
                engineVersion: engineVersion
            )
        )
    }

    private static func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private static func matchingPhrase(in text: String, terms: [String]) -> String? {
        let lower = text.lowercased()
        return terms.first(where: { lower.contains($0) })
    }

    private static func countQuestionStarters(_ text: String) -> Int {
        let starters = ["why ", "how ", "what ", "when ", "where ", "why can't", "why cant", "why do", "how do"]
        return starters.reduce(0) { count, starter in
            count + max(0, text.components(separatedBy: starter).count - 1)
        }
    }

    private static func repeatedAdjacentWords(_ text: String) -> [String] {
        let words = text
            .lowercased()
            .split { !$0.isLetter }
            .map(String.init)

        guard words.count > 1 else { return [] }

        var repeated: [String] = []

        for index in 1..<words.count {
            if words[index] == words[index - 1], !repeated.contains(words[index]) {
                repeated.append(words[index])
            }
        }

        return repeated
    }
}
