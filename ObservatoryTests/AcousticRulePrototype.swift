import Foundation

// U4a-1: observation-selection rules as SignalLibrary-shaped DATA (D-16).
//
// Distinct from the estimator configuration: these decide WHICH measurements are
// reported as observations. The field names mirror what `SignalDetectionRule` would
// grow in U4 (`matchType: "numericThreshold"` + an optional `numeric` block), so the
// production migration is an additive schema change plus a sibling evaluator, not a
// rewrite — and this JSON can be imported through the existing
// `SignalLibraryRegistry.importJSON` path as data.

enum NumericComparison: String, Codable, Sendable {
    case greaterThanOrEqual
    case lessThanOrEqual

    func matches(_ value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThanOrEqual: return value >= threshold
        case .lessThanOrEqual: return value <= threshold
        }
    }
}

struct NumericRuleGates: Codable, Equatable, Sendable {
    /// Named against the specific coverage quantities in `Coverage` (§5.2) rather than
    /// one undifferentiated "coverage" number: a window full of legitimate pauses must
    /// not be rejected for low coverage.
    let minDomainFraction: Double
    let minEligibleSeconds: Double
    let minEstimationSuccess: Double
    let minBaselineVoicedSeconds: Double
    let requireNoFlags: [QualityFlag]
}

struct NumericRuleSpec: Codable, Equatable, Sendable {
    let metric: MetricID
    let unit: AcousticUnit
    let comparison: NumericComparison
    let threshold: Double
    let gates: NumericRuleGates
    /// Authored by us in the rules file. The only free text anywhere in the report
    /// pipeline, and it never touches audio or transcripts.
    let rationale: String
}

struct AcousticRule: Codable, Equatable, Sendable {
    let id: ConstrainedID
    let name: String
    let matchType: String
    let eventKind: PrototypeObservationKind
    let eventCategory: String
    let confidence: String
    let numeric: NumericRuleSpec
}

struct AcousticRuleLibrary: Codable, Equatable, Sendable {
    let id: ConstrainedID
    let name: String
    let version: ConstrainedID
    let domain: String
    let authorType: String
    /// Never absent; no rule in this unit may claim calibration.
    let calibrationStatus: ConstrainedID
    /// Amendment A2 — see the `_amendmentReason` field in `U4aAcousticRules.json`.
    let measurementParameters: MeasurementParameters
    let rules: [AcousticRule]
}

struct LoadedRuleLibrary: Sendable {
    let library: AcousticRuleLibrary
    let sha256: String

    static func load(from data: Data) throws -> LoadedRuleLibrary {
        LoadedRuleLibrary(library: try JSONDecoder().decode(AcousticRuleLibrary.self, from: data),
                          sha256: U4aHash.hex(data))
    }

    static func loadDefault(bundle: Bundle) throws -> LoadedRuleLibrary {
        guard let url = bundle.url(forResource: "U4aAcousticRules", withExtension: "json") else {
            throw U4aResourceError.missingResource("U4aAcousticRules.json")
        }
        return try load(from: Data(contentsOf: url))
    }
}

/// Sibling to `SignalLibraryDetectionEngine` rather than an extension of it: that engine
/// matches text, and contorting it to pretend a measurement is a phrase would be the
/// wrong migration shape for U4.
enum AcousticRuleEvaluator {

    static func evaluate(measurements: [AcousticMeasurement],
                         library: AcousticRuleLibrary,
                         baselineVoicedSecondsBySpan: [Int: Double]) -> [PrototypeObservation] {
        var out: [PrototypeObservation] = []
        for rule in library.rules {
            for m in measurements where m.metric == rule.numeric.metric {
                guard let value = m.value, m.status.primary.isValid else { continue }
                guard passesGates(m, gates: rule.numeric.gates,
                                  baselineVoicedSeconds: baselineVoicedSecondsBySpan[m.window.spanID] ?? 0)
                else { continue }
                guard rule.numeric.comparison.matches(value, threshold: rule.numeric.threshold) else { continue }

                out.append(PrototypeObservation(
                    kind: rule.eventKind,
                    ruleID: rule.id,
                    libraryID: library.id,
                    libraryVersion: library.version,
                    calibrationStatus: library.calibrationStatus,
                    measurement: m,
                    thresholdValue: rule.numeric.threshold,
                    comparison: rule.numeric.comparison,
                    observedValue: value))
            }
        }
        // Deterministic ordering independent of rule/measurement iteration order.
        return out.sorted {
            ($0.measurement.window.startSeconds, $0.ruleID.rawValue)
                < ($1.measurement.window.startSeconds, $1.ruleID.rawValue)
        }
    }

    static func passesGates(_ m: AcousticMeasurement,
                            gates: NumericRuleGates,
                            baselineVoicedSeconds: Double) -> Bool {
        guard m.coverage.domainFraction >= gates.minDomainFraction else { return false }
        guard m.coverage.eligibleSeconds >= gates.minEligibleSeconds else { return false }
        guard m.coverage.estimationSuccess >= gates.minEstimationSuccess else { return false }
        guard baselineVoicedSeconds >= gates.minBaselineVoicedSeconds else { return false }
        for flag in gates.requireNoFlags where m.status.flags.contains(flag) { return false }
        return true
    }
}
