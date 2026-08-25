import Foundation

struct ReflectionArcResult {
    let title: String
    let detail: String
    let sequence: String
    let startPhase: String
    let middlePhase: String
    let endPhase: String
    let confidence: SignalQuality
    let keyEvents: [String]
}

enum ReflectionArcEngine {
    static let engineVersion = "2.0"

    static func analyze(session: ReflectionSession) -> ReflectionArcResult {
        let eventTitles = session.observationEvents.map { $0.title.lowercased() }
        let transcript = session.transcript.map { $0.text }.joined(separator: " ").lowercased()

        let hasOutcomeConcern = contains(eventTitles, "outcome concern") || containsAny(transcript, ["hope i didn't", "hope i did not", "mess this up", "miss this up", "worried"])
        let hasVerification = contains(eventTitles, "verification attempt") || containsAny(transcript, ["take a look", "let me check", "checking", "go back"])
        let hasSelfMonitoring = contains(eventTitles, "self-monitoring") || containsAny(transcript, ["checking checking", "i think it's ok", "i think it's okay"])
        let hasRelief = contains(eventTitles, "relief") || containsAny(transcript, ["looks good", "it's ok", "it's okay", "working", "yes"])
        let hasUncertainty = containsAny(transcript, ["i don't know", "i dont know", "maybe", "is it working", "not sure"])
        let hasFrustration = containsAny(transcript, ["damn", "ugh", "frustrating", "frustrated", "come on", "not working"])
        let hasForwardMotion = containsAny(transcript, ["moving on", "let's go", "lets go", "progress", "next", "now we're talking", "now we are cooking"])
        let hasRegulation = containsAny(transcript, ["deep breath", "breathe", "breath", "ok", "okay"])
        let hasPlanning = contains(eventTitles, "planning") || containsAny(transcript, ["i will", "i'll", "i need to", "next i", "plan"])

        if hasOutcomeConcern && hasVerification && hasRelief {
            return makeResult(
                title: "Concern → verification → reassurance",
                detail: "The reflection appears to begin with concern about a possible problem, move into checking or verification, and end with reassurance or acceptance.",
                sequence: "concern → verification → reassurance",
                start: "Concern",
                middle: hasSelfMonitoring ? "Verification / self-monitoring" : "Verification",
                end: "Reassurance",
                confidence: .medium,
                keys: ["Outcome concern", "Verification attempt", "Self-monitoring", "Relief / reassurance"]
            )
        }

        if hasUncertainty && hasRelief {
            return makeResult(
                title: "Uncertainty → confirmation",
                detail: "The reflection appears to move from uncertainty toward confirmation or confidence that the situation is acceptable.",
                sequence: "uncertainty → confirmation",
                start: "Uncertainty",
                middle: hasVerification ? "Checking" : "Sense-making",
                end: "Confirmation",
                confidence: .medium,
                keys: ["Uncertainty", "Verification attempt", "Relief / reassurance"]
            )
        }

        if hasFrustration && hasForwardMotion {
            return makeResult(
                title: "Frustration → forward motion",
                detail: "The reflection appears to start with frustration or blockage and move toward action, momentum, or continuation.",
                sequence: "frustration → forward motion",
                start: "Frustration",
                middle: hasRegulation ? "Regulation" : "Reorientation",
                end: "Forward motion",
                confidence: .medium,
                keys: ["Frustration", "Reorientation toward progress"]
            )
        }

        if hasFrustration && hasRegulation {
            return makeResult(
                title: "Activation → regulation",
                detail: "The reflection appears to include activation or frustration followed by regulation language, such as breathing, resetting, or calming.",
                sequence: "activation → regulation",
                start: "Activation",
                middle: "Regulation attempt",
                end: "Stabilization",
                confidence: .low,
                keys: ["Activation", "Regulation"]
            )
        }

        if hasPlanning {
            return makeResult(
                title: "Idea → plan",
                detail: "The reflection appears to move toward a plan, next step, or intended action.",
                sequence: "idea → plan",
                start: "Idea",
                middle: "Evaluation",
                end: "Plan",
                confidence: .low,
                keys: ["Planning"]
            )
        }

        return makeResult(
            title: "No clear arc",
            detail: "No clear beginning-middle-end reflection arc was detected.",
            sequence: "none detected",
            start: "Unclear",
            middle: "Unclear",
            end: "Unclear",
            confidence: .low,
            keys: []
        )
    }

    private static func makeResult(
        title: String,
        detail: String,
        sequence: String,
        start: String,
        middle: String,
        end: String,
        confidence: SignalQuality,
        keys: [String]
    ) -> ReflectionArcResult {
        ReflectionArcResult(
            title: title,
            detail: detail,
            sequence: sequence,
            startPhase: start,
            middlePhase: middle,
            endPhase: end,
            confidence: confidence,
            keyEvents: keys
        )
    }

    private static func contains(_ titles: [String], _ needle: String) -> Bool {
        titles.contains { $0.contains(needle) }
    }

    private static func containsAny(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { text.contains($0) }
    }
}

