import Foundation

enum SignalLibraryDetectionEngine {
    static let engineVersion = "1.1"

    static func detect(
        session: ReflectionSession,
        libraries: [SignalLibrary] = PersistentSignalLibraryStore.shared.activeLibraries,
        domain: SignalLibraryDomain? = nil
    ) -> [ObservationEvent] {
        guard let latest = session.transcript.last else { return [] }

        let timestamp = latest.timestamp
        let transcript = session.transcript.map { $0.text }.joined(separator: " ")
        let lower = transcript.lowercased()

        let activeLibraries = libraries.filter { library in
            library.isEnabledByDefault && (domain == nil || library.domain == domain)
        }

        var events: [ObservationEvent] = []

        for library in activeLibraries {
            let activeRules = library.rules.filter { $0.isEnabled }

            for rule in activeRules {
                guard let matchedPhrase = match(rule: rule, lowercasedText: lower) else { continue }

                events.append(
                    ObservationEvent(
                        timestamp: timestamp,
                        kind: rule.eventKind,
                        category: rule.eventCategory,
                        title: rule.title,
                        detail: rule.detail,
                        source: .derived,
                        confidence: rule.confidence,
                        relatedText: matchedPhrase,
                        tags: provenanceTags(library: library, rule: rule, matchedPhrase: matchedPhrase),
                        engineVersion: engineVersion
                    )
                )
            }
        }

        return deduplicated(events)
    }

    static func matches(
        text: String,
        libraries: [SignalLibrary] = PersistentSignalLibraryStore.shared.activeLibraries,
        domain: SignalLibraryDomain? = nil
    ) -> [SignalLibraryMatch] {
        let lower = text.lowercased()
        let activeLibraries = libraries.filter { library in
            library.isEnabledByDefault && (domain == nil || library.domain == domain)
        }

        var results: [SignalLibraryMatch] = []

        for library in activeLibraries {
            for rule in library.rules where rule.isEnabled {
                guard let matchedPhrase = match(rule: rule, lowercasedText: lower) else { continue }

                results.append(
                    SignalLibraryMatch(
                        libraryID: library.id,
                        libraryName: library.name,
                        libraryVersion: library.version,
                        ruleID: rule.id,
                        ruleName: rule.name,
                        matchedPhrase: matchedPhrase,
                        eventKind: rule.eventKind,
                        eventCategory: rule.eventCategory,
                        confidence: rule.confidence,
                        generatedAt: Date()
                    )
                )
            }
        }

        return results
    }

    private static func match(rule: SignalDetectionRule, lowercasedText: String) -> String? {
        let phrases = rule.phrases.map { $0.lowercased() }

        switch rule.matchType {
        case .containsAny:
            return phrases.first(where: { lowercasedText.contains($0) })

        case .containsAll:
            return phrases.allSatisfy { lowercasedText.contains($0) } ? phrases.first : nil

        case .repeatedPhrase:
            for phrase in phrases {
                let count = lowercasedText.components(separatedBy: phrase).count - 1
                if count > 1 {
                    return phrase
                }
            }
            return nil

        case .sequence:
            var searchStart = lowercasedText.startIndex
            var firstMatched: String?

            for phrase in phrases {
                guard let range = lowercasedText.range(of: phrase, range: searchStart..<lowercasedText.endIndex) else {
                    return nil
                }

                if firstMatched == nil {
                    firstMatched = phrase
                }

                searchStart = range.upperBound
            }

            return firstMatched
        }
    }

    private static func provenanceTags(library: SignalLibrary, rule: SignalDetectionRule, matchedPhrase: String?) -> [String] {
        var tags = rule.tags
        tags.append("library:\(library.id)")
        tags.append("library-version:\(library.version)")
        tags.append("rule:\(rule.id)")
        tags.append("rule-domain:\(rule.domain.rawValue)")
        tags.append("store:persistent-local")
        tags.append("engine:\(engineVersion)")

        if let matchedPhrase, !matchedPhrase.isEmpty {
            tags.append("matched:\(matchedPhrase)")
        }

        return tags
    }

    private static func deduplicated(_ events: [ObservationEvent]) -> [ObservationEvent] {
        var seen = Set<String>()
        var result: [ObservationEvent] = []

        for event in events {
            let key = "\(event.kind.rawValue)-\(event.title)-\(event.relatedText ?? "")"
            if !seen.contains(key) {
                seen.insert(key)
                result.append(event)
            }
        }

        return result
    }
}
