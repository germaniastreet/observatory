import Foundation

enum SignalLibraryDomain: String, Codable, CaseIterable, Hashable {
    case cognitive = "Cognitive"
    case language = "Language"
    case voice = "Voice"
    case body = "Body"
    case interaction = "Interaction"
    case clinical = "Clinical"
    case custom = "Custom"
}

enum SignalRuleMatchType: String, Codable, CaseIterable, Hashable {
    case containsAny = "Contains Any"
    case containsAll = "Contains All"
    case repeatedPhrase = "Repeated Phrase"
    case sequence = "Sequence"
}

enum SignalLibraryAuthorType: String, Codable, CaseIterable, Hashable {
    case observatory = "Observatory"
    case user = "User"
    case moderator = "Moderator"
    case thirdParty = "Third Party"
}

struct SignalLibrary: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var version: String
    var author: String
    var authorType: SignalLibraryAuthorType
    var domain: SignalLibraryDomain
    var description: String
    var isEnabledByDefault: Bool
    var createdAt: Date
    var updatedAt: Date
    var rules: [SignalDetectionRule]
}

struct SignalDetectionRule: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var domain: SignalLibraryDomain
    var matchType: SignalRuleMatchType
    var phrases: [String]
    var eventKind: ObservationEventKind
    var eventCategory: ObservationCategory
    var title: String
    var detail: String
    var confidence: SignalQuality
    var tags: [String]
    var isEnabled: Bool
    var notes: String
}

struct SignalLibraryMatch: Identifiable, Codable, Hashable {
    var id = UUID()
    var libraryID: String
    var libraryName: String
    var libraryVersion: String
    var ruleID: String
    var ruleName: String
    var matchedPhrase: String?
    var eventKind: ObservationEventKind
    var eventCategory: ObservationCategory
    var confidence: SignalQuality
    var generatedAt: Date
}
