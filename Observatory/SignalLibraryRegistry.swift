import Foundation
import SwiftUI
import Combine

@MainActor
final class SignalLibraryRegistry: ObservableObject {
    @Published var libraries: [SignalLibrary]

    init(libraries: [SignalLibrary]? = nil) {
        // Not a default parameter value -- Swift evaluates those outside the
        // initializer's own actor context, which is exactly what caused the
        // "main actor-isolated ... nonisolated context" warnings here before.
        // Fetching it in the body instead runs on this class's own MainActor
        // isolation, same as every other method here that touches the store.
        self.libraries = libraries ?? PersistentSignalLibraryStore.shared.librariesSnapshot()
    }

    var enabledLibraries: [SignalLibrary] {
        libraries.filter { $0.isEnabledByDefault }
    }

    var enabledRules: [SignalDetectionRule] {
        enabledLibraries.flatMap { library in
            library.rules.filter { $0.isEnabled }
        }
    }

    func library(id: String) -> SignalLibrary? {
        libraries.first { $0.id == id }
    }

    func rules(for domain: SignalLibraryDomain) -> [SignalDetectionRule] {
        enabledLibraries
            .filter { $0.domain == domain }
            .flatMap { $0.rules }
            .filter { $0.isEnabled }
    }

    func setLibraryEnabled(id: String, isEnabled: Bool) {
        PersistentSignalLibraryStore.shared.setLibraryEnabled(id: id, isEnabled: isEnabled)
        libraries = PersistentSignalLibraryStore.shared.librariesSnapshot()
    }

    func resetToDefaults() {
        PersistentSignalLibraryStore.shared.resetToDefaults()
        libraries = PersistentSignalLibraryStore.shared.librariesSnapshot()
    }

    func exportJSON() throws -> Data {
        try PersistentSignalLibraryStore.shared.exportJSONData()
    }

    func importJSON(_ data: Data) throws {
        try PersistentSignalLibraryStore.shared.importJSONData(data)
        libraries = PersistentSignalLibraryStore.shared.librariesSnapshot()
    }
}

enum SignalLibraryDefaults {
    static var defaultLibraries: [SignalLibrary] {
        [
            observatoryCognitiveLibrary
        ]
    }

    static var observatoryCognitiveLibrary: SignalLibrary {
        let now = Date()

        return SignalLibrary(
            id: "observatory.cognitive.core",
            name: "Observatory Cognitive Core",
            version: "1.0.0",
            author: "Observatory",
            authorType: .observatory,
            domain: .cognitive,
            description: "Default cognitive event phrase rules migrated from prototype hardcoded detection into a versioned signal library.",
            isEnabledByDefault: true,
            createdAt: now,
            updatedAt: now,
            rules: [
                SignalDetectionRule(
                    id: "cognitive.outcomeConcern.v1",
                    name: "Outcome Concern",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["hope i didn't", "hope i did not", "i hope i didn't", "i hope i did not", "mess this up", "miss this up", "worried", "i'm worried", "im worried", "what if", "concerned"],
                    eventKind: .outcomeConcern,
                    eventCategory: .cognitive,
                    title: "Outcome concern",
                    detail: "Language suggested concern about a possible mistake, outcome, or consequence.",
                    confidence: .medium,
                    tags: ["concern", "outcome", "uncertainty", "risk"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule. Future versions should support locale, synonyms, speaker-specific libraries, and domain-specific tuning."
                ),
                SignalDetectionRule(
                    id: "cognitive.verificationAttempt.v1",
                    name: "Verification Attempt",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["let me go back", "go back and take a look", "take a look", "let me check", "double check", "check this", "checking", "verify", "confirm"],
                    eventKind: .verificationAttempt,
                    eventCategory: .cognitive,
                    title: "Verification attempt",
                    detail: "Language suggested checking, confirming, or verifying whether something is correct.",
                    confidence: .medium,
                    tags: ["verification", "checking", "confirmation"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule."
                ),
                SignalDetectionRule(
                    id: "cognitive.selfMonitoring.v1",
                    name: "Self-Monitoring",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["checking checking", "monitoring", "watching", "looking at", "i think it's ok", "i think it's okay", "i think its ok", "i think its okay"],
                    eventKind: .selfMonitoring,
                    eventCategory: .cognitive,
                    title: "Self-monitoring",
                    detail: "Language suggested active monitoring of the situation, output, or internal state.",
                    confidence: .low,
                    tags: ["self-monitoring", "attention", "checking"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule."
                ),
                SignalDetectionRule(
                    id: "cognitive.reliefReassurance.v1",
                    name: "Relief / Reassurance",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["ok looks good", "okay looks good", "looks good", "it's ok", "it's okay", "its ok", "its okay", "all good", "working", "yes", "relief"],
                    eventKind: .relief,
                    eventCategory: .cognitive,
                    title: "Relief / reassurance",
                    detail: "Language suggested reassurance, relief, or a positive resolution after checking.",
                    confidence: .medium,
                    tags: ["relief", "reassurance", "resolution"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule."
                ),
                SignalDetectionRule(
                    id: "cognitive.reorientation.v1",
                    name: "Reorientation Toward Progress",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["moving on", "let's go", "lets go", "now we are cooking", "now we're talking", "continue", "progress", "next"],
                    eventKind: .reorientation,
                    eventCategory: .cognitive,
                    title: "Reorientation toward progress",
                    detail: "Language suggested movement away from the current concern and toward continuation or progress.",
                    confidence: .medium,
                    tags: ["reorientation", "progress", "forward-motion"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule."
                ),
                SignalDetectionRule(
                    id: "cognitive.planning.v1",
                    name: "Planning",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["i'll", "i will", "i should", "i need to", "i'm going to", "im going to", "next i", "plan"],
                    eventKind: .planning,
                    eventCategory: .cognitive,
                    title: "Planning",
                    detail: "Language suggested intention, next action, or planning.",
                    confidence: .low,
                    tags: ["planning", "intention", "next-action"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule."
                ),
                SignalDetectionRule(
                    id: "cognitive.decisionPoint.v1",
                    name: "Decision Point",
                    domain: .cognitive,
                    matchType: .containsAny,
                    phrases: ["i decide", "i decided", "decision", "i'll do", "i will do", "that means", "so i"],
                    eventKind: .decisionPoint,
                    eventCategory: .cognitive,
                    title: "Decision point",
                    detail: "Language suggested a choice, conclusion, or decision point.",
                    confidence: .low,
                    tags: ["decision", "choice", "conclusion"],
                    isEnabled: true,
                    notes: "Initial Observatory phrase rule."
                )
            ]
        )
    }
}
