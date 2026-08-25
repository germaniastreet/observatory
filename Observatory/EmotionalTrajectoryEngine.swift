import Foundation

struct EmotionalTrajectoryResult {
    let title: String
    let detail: String
    let startState: String
    let endState: String
    let movement: String
    let confidence: SignalQuality
    let keyPhrases: [String]
}

enum EmotionalTrajectoryEngine {
    static let engineVersion = "1.8"

    static func analyze(session: ReflectionSession) -> EmotionalTrajectoryResult {
        let text = session.transcript.map { $0.text }.joined(separator: " ").lowercased()

        let negativeMarkers = [
            "damn", "ugh", "frustrating", "frustrated", "disturbing",
            "not working", "come on", "behind", "stuck", "waste my time",
            "no not again", "please work"
        ]

        let positiveMarkers = [
            "yes", "working", "cool", "whoa", "now we're talking",
            "now we are cooking", "let's go", "lets go", "progress",
            "moving on", "all right", "relief"
        ]

        let uncertaintyMarkers = [
            "i don't know", "i dont know", "maybe", "is it working",
            "i think", "not sure", "wait", "oh wait"
        ]

        let regulationMarkers = [
            "deep breath", "breath", "breathe", "ok", "okay",
            "all right", "moving on", "let's go", "lets go"
        ]

        let negativeHits = hits(in: text, markers: negativeMarkers)
        let positiveHits = hits(in: text, markers: positiveMarkers)
        let uncertaintyHits = hits(in: text, markers: uncertaintyMarkers)
        let regulationHits = hits(in: text, markers: regulationMarkers)

        let firstNegative = firstIndex(in: text, markers: negativeMarkers)
        let firstPositive = firstIndex(in: text, markers: positiveMarkers)
        let firstUncertainty = firstIndex(in: text, markers: uncertaintyMarkers)
        let firstRegulation = firstIndex(in: text, markers: regulationMarkers)

        if let n = firstNegative, let p = firstPositive, n < p {
            return EmotionalTrajectoryResult(
                title: "Frustration to relief",
                detail: "The reflection appears to move from frustration or concern toward relief, confirmation, or forward momentum.",
                startState: "Frustration / concern",
                endState: "Relief / momentum",
                movement: "negative → positive",
                confidence: positiveHits.count >= 2 ? .medium : .low,
                keyPhrases: Array((negativeHits + positiveHits).prefix(8))
            )
        }

        if let u = firstUncertainty, let p = firstPositive, u < p {
            return EmotionalTrajectoryResult(
                title: "Uncertainty to confirmation",
                detail: "The reflection appears to move from uncertainty or checking toward confirmation that something is working or becoming clearer.",
                startState: "Uncertainty",
                endState: "Confirmation",
                movement: "uncertainty → clarity",
                confidence: .medium,
                keyPhrases: Array((uncertaintyHits + positiveHits).prefix(8))
            )
        }

        if let n = firstNegative, let r = firstRegulation, n < r {
            return EmotionalTrajectoryResult(
                title: "Activation to regulation",
                detail: "The reflection appears to include activation followed by language associated with regulation, resetting, or moving forward.",
                startState: "Activation",
                endState: "Regulation attempt",
                movement: "activation → regulation",
                confidence: .medium,
                keyPhrases: Array((negativeHits + regulationHits).prefix(8))
            )
        }

        if !positiveHits.isEmpty {
            return EmotionalTrajectoryResult(
                title: "Positive confirmation",
                detail: "The reflection contains positive confirmation or forward-momentum language, but no clear earlier contrasting state was detected.",
                startState: "Unclear",
                endState: "Positive confirmation",
                movement: "confirmation",
                confidence: .low,
                keyPhrases: Array(positiveHits.prefix(8))
            )
        }

        if !negativeHits.isEmpty {
            return EmotionalTrajectoryResult(
                title: "Activation without clear resolution",
                detail: "The reflection contains frustration, concern, or activation language without a clear later resolution signal.",
                startState: "Activation",
                endState: "Unresolved / unclear",
                movement: "activation",
                confidence: .low,
                keyPhrases: Array(negativeHits.prefix(8))
            )
        }

        return EmotionalTrajectoryResult(
            title: "No clear trajectory",
            detail: "No clear emotional movement was detected in this reflection.",
            startState: "Unclear",
            endState: "Unclear",
            movement: "none detected",
            confidence: .low,
            keyPhrases: []
        )
    }

    private static func hits(in text: String, markers: [String]) -> [String] {
        markers.filter { text.contains($0) }
    }

    private static func firstIndex(in text: String, markers: [String]) -> String.Index? {
        markers.compactMap { text.range(of: $0)?.lowerBound }.min()
    }
}

