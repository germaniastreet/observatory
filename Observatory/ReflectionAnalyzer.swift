import Foundation

struct ReflectionAnalysisResult {
    let observedPattern: String
    let observatoryNote: String
    let emotionalTone: String
    let cognitiveLoad: String
    let focusSignal: String
    let confidence: SignalQuality
    let wordsPerMinute: Int
    let hesitationMarkers: Int
    let pauseCount: Int
}

enum ReflectionAnalyzer {
    static func analyze(session: ReflectionSession) -> ReflectionAnalysisResult {
        let transcriptText = session.transcript
            .map { $0.text }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let lower = transcriptText.lowercased()
        let words = lower.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        let wordCount = words.count

        let concernTerms = [
            "nervous", "worried", "worry", "concern", "concerned",
            "anxious", "anxiety", "afraid", "scared", "uneasy",
            "i don't know how i'm feeling", "i don't know how i am feeling",
            "i don't know", "i dont know"
        ]

        let conflictTerms = [
            "fight", "fighting", "argument", "argue", "conflict",
            "escalate", "escalated", "escalation", "on the phone"
        ]

        let deescalationTerms = [
            "calm", "calm conversation", "didn't escalate", "did not escalate",
            "why can't we", "why cant we", "why do things", "so quickly"
        ]

        let frustrationTerms = [
            "frustrated", "annoyed", "upset", "irritated", "angry",
            "mad", "tired of", "why does", "why do", "why can't"
        ]

        let reliefTerms = [
            "relieved", "happy", "pleased", "good", "great", "working",
            "better", "glad", "thankful", "grateful", "clear"
        ]

        let selfCriticismTerms = [
            "my fault", "i failed", "i messed up", "i can't", "i cant",
            "i should have", "i shouldn't have", "i am bad", "i'm bad",
            "i hate that i", "why am i"
        ]

        let cognitiveLoadTerms = [
            "think", "thinking", "trying", "figure", "understand",
            "because", "maybe", "probably", "unclear", "confusing",
            "remember", "focus", "decide", "should", "why", "how"
        ]

        let hesitationTerms = ["um", "uh", "like", "you know", "sort of", "kind of"]

        let concernScore = countOccurrences(in: lower, terms: concernTerms)
        let conflictScore = countOccurrences(in: lower, terms: conflictTerms)
        let deescalationScore = countOccurrences(in: lower, terms: deescalationTerms)
        let frustrationScore = countOccurrences(in: lower, terms: frustrationTerms)
        let reliefScore = countOccurrences(in: lower, terms: reliefTerms)
        let selfCriticismScore = countOccurrences(in: lower, terms: selfCriticismTerms)
        let cognitiveScore = countOccurrences(in: lower, terms: cognitiveLoadTerms)
        let hesitationScore = countOccurrences(in: lower, terms: hesitationTerms)
        let repeatedWords = repeatedWordCount(words)
        let questionScore = countQuestionSignals(in: lower)

        let theme = inferTheme(
            concern: concernScore,
            conflict: conflictScore,
            deescalation: deescalationScore,
            frustration: frustrationScore,
            relief: reliefScore,
            selfCriticism: selfCriticismScore,
            questionScore: questionScore
        )

        let emotionalTone = inferEmotionalTone(
            theme: theme,
            concern: concernScore,
            conflict: conflictScore,
            deescalation: deescalationScore,
            frustration: frustrationScore,
            relief: reliefScore,
            selfCriticism: selfCriticismScore
        )

        let cognitiveLoad: String
        if cognitiveScore >= 6 || questionScore >= 3 || wordCount > 90 {
            cognitiveLoad = "Elevated"
        } else if cognitiveScore >= 2 || questionScore >= 1 || wordCount > 35 {
            cognitiveLoad = "Moderate"
        } else {
            cognitiveLoad = "Low"
        }

        let focusSignal: String
        if theme != "None detected" {
            focusSignal = theme
        } else if repeatedWords >= 3 {
            focusSignal = "Word repetition"
        } else if questionScore >= 2 {
            focusSignal = "Reflective questioning"
        } else if wordCount < 8 {
            focusSignal = "Limited sample"
        } else {
            focusSignal = "Coherent"
        }

        let observedPattern = makeObservedPattern(
            theme: theme,
            emotionalTone: emotionalTone,
            questionScore: questionScore,
            wordCount: wordCount
        )

        let observatoryNote = makeObservatoryNote(
            theme: theme,
            emotionalTone: emotionalTone,
            cognitiveLoad: cognitiveLoad,
            focusSignal: focusSignal,
            questionScore: questionScore,
            wordCount: wordCount
        )

        let durationMinutes = max(Double(session.durationSeconds) / 60.0, 0.1)
        let wpm = Int(Double(wordCount) / durationMinutes)

        let confidence: SignalQuality
        if wordCount >= 45 {
            confidence = .medium
        } else if wordCount >= 15 {
            confidence = .medium
        } else if wordCount >= 8 {
            confidence = .low
        } else {
            confidence = .unavailable
        }

        return ReflectionAnalysisResult(
            observedPattern: observedPattern,
            observatoryNote: observatoryNote,
            emotionalTone: emotionalTone,
            cognitiveLoad: cognitiveLoad,
            focusSignal: focusSignal,
            confidence: confidence,
            wordsPerMinute: wpm,
            hesitationMarkers: hesitationScore,
            pauseCount: 0
        )
    }

    private static func inferTheme(
        concern: Int,
        conflict: Int,
        deescalation: Int,
        frustration: Int,
        relief: Int,
        selfCriticism: Int,
        questionScore: Int
    ) -> String {
        if conflict > 0 && deescalation > 0 {
            return "Conflict and de-escalation"
        }

        if concern > 0 && questionScore > 0 {
            return "Concern and sense-making"
        }

        if concern > 0 {
            return "Concern or uncertainty"
        }

        if conflict > 0 {
            return "Conflict or tension"
        }

        if frustration > 0 && questionScore > 0 {
            return "Frustration and questioning"
        }

        if selfCriticism > 0 {
            return "Self-evaluation"
        }

        if relief > 1 {
            return "Relief or positive confirmation"
        }

        return "None detected"
    }

    private static func inferEmotionalTone(
        theme: String,
        concern: Int,
        conflict: Int,
        deescalation: Int,
        frustration: Int,
        relief: Int,
        selfCriticism: Int
    ) -> String {
        if theme == "Conflict and de-escalation" {
            return "Concerned"
        }

        if concern > 0 {
            return "Anxious / uncertain"
        }

        if conflict > 0 {
            return "Tense"
        }

        if frustration > 0 {
            return "Frustrated"
        }

        if selfCriticism > 0 {
            return "Self-critical"
        }

        if relief > 1 {
            return "Relieved / positive"
        }

        if relief > 0 {
            return "Positive"
        }

        return "Neutral"
    }

    private static func makeObservedPattern(
        theme: String,
        emotionalTone: String,
        questionScore: Int,
        wordCount: Int
    ) -> String {
        if wordCount < 8 {
            return "Only a small amount of speech was captured, so no strong pattern is available yet."
        }

        switch theme {
        case "Conflict and de-escalation":
            return "Concern appeared around interpersonal conflict. The speaker returned to escalation and expressed a desire for calmer communication."
        case "Concern and sense-making":
            return "Concern and uncertainty appeared alongside reflective questioning, suggesting the speaker was trying to make sense of an unsettled situation."
        case "Concern or uncertainty":
            return "Uncertainty and concern appeared in the reflection, suggesting the speaker was trying to name or understand an emotional state."
        case "Conflict or tension":
            return "Conflict-related language appeared, suggesting the reflection centered on interpersonal tension or unresolved communication."
        case "Frustration and questioning":
            return "Frustration appeared alongside repeated questioning, suggesting the speaker was trying to understand why the situation felt blocked."
        case "Self-evaluation":
            return "Self-evaluative language appeared, suggesting the speaker may have been considering their own role or responsibility."
        case "Relief or positive confirmation":
            return "Positive confirmation and relief appeared in the reflection, suggesting satisfaction, reassurance, or forward momentum."
        default:
            if questionScore >= 2 {
                return "Reflective questioning appeared in the session, suggesting the speaker was actively trying to understand what happened."
            }
            return "The reflection was captured with a mostly neutral tone and no strong emotional pattern detected."
        }
    }

    private static func makeObservatoryNote(
        theme: String,
        emotionalTone: String,
        cognitiveLoad: String,
        focusSignal: String,
        questionScore: Int,
        wordCount: Int
    ) -> String {
        if wordCount < 8 {
            return "The transcript is too short for a meaningful observation. A longer reflection would improve signal quality."
        }

        let questionText: String
        if questionScore >= 3 {
            questionText = "high"
        } else if questionScore >= 1 {
            questionText = "present"
        } else {
            questionText = "low"
        }

        return "Repeated theme: \(theme). Emotional tone: \(emotionalTone). Cognitive load: \(cognitiveLoad). Question density: \(questionText). These are lightweight text-based observations, not diagnoses."
    }

    private static func countOccurrences(in text: String, terms: [String]) -> Int {
        terms.reduce(0) { count, term in
            count + max(0, text.components(separatedBy: term).count - 1)
        }
    }

    private static func repeatedWordCount(_ words: [String]) -> Int {
        guard words.count > 1 else { return 0 }

        var count = 0
        for index in 1..<words.count {
            if words[index] == words[index - 1] {
                count += 1
            }
        }
        return count
    }

    private static func countQuestionSignals(in text: String) -> Int {
        let punctuationQuestions = text.filter { $0 == "?" }.count
        let starters = ["why ", "how ", "what ", "when ", "where ", "why can't", "why cant", "why do", "how do"]

        let starterCount = starters.reduce(0) { count, starter in
            count + max(0, text.components(separatedBy: starter).count - 1)
        }

        return punctuationQuestions + starterCount
    }
}

