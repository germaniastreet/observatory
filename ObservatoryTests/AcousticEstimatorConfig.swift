import CryptoKit
import Foundation

// U4a-1: the estimator configuration is DATA, not code (review R2.1/R2.2).
//
// These parameters determine which voices and behaviours become measurable at all, so
// they are versioned, hashed, and recorded inline in every report — distinct from the
// observation-selection rules in `AcousticRulePrototype.swift`, which decide which
// measurements get reported as observations.
//
// Only the NCCF implementation itself, the parabolic interpolation, and the
// percentile/IQR arithmetic remain in code, versioned by `EstimatorVersion.current`.

struct EstimatorConfig: Codable, Equatable, Sendable {
    struct FrameGeometry: Codable, Equatable, Sendable {
        let hopMs: Double
        let levelFrameMs: Double
        let pitchFrameMs: Double
        /// The F0 channel is decimated to this rate before correlation. Must divide the
        /// source rate by an integer factor; otherwise F0 reports
        /// `.estimatorFailed(.decimationUnsupported)` rather than resampling silently.
        let pitchAnalysisRateHz: Double
    }
    struct NoiseFloor: Codable, Equatable, Sendable {
        let method: String
        let percentile: Double
        let minSpanSecondsForFloor: Double
    }
    struct Activity: Codable, Equatable, Sendable {
        let onsetAboveFloorDb: Double
        let offsetAboveFloorDb: Double
        let minActiveRunMs: Double
        let minInactiveRunMs: Double
    }
    struct WidenedRange: Codable, Equatable, Sendable {
        let minHz: Double
        let maxHz: Double
        let enabled: Bool
    }
    struct Periodicity: Codable, Equatable, Sendable {
        let searchMinHz: Double
        let searchMaxHz: Double
        let peakStrengthFloor: Double
        /// Amendment A4 — see the `_subharmonicPreferenceReason` field in
        /// `U4aEstimatorConfig.json`. Prefer the smallest lag whose correlation peak
        /// reaches this fraction of the global maximum.
        let subharmonicPreference: Double
        let diagnosticWidenedRange: WidenedRange
    }
    struct F0Smoothing: Codable, Equatable, Sendable {
        let medianWidthFrames: Int
        let maxOctaveJumpSemitonesPerFrame: Double
    }
    struct Nuclei: Codable, Equatable, Sendable {
        let bandLowHz: Double
        let bandHighHz: Double
        let dipDb: Double
        let minInterNucleusMs: Double
        let filterSettlingMs: Double
        let requirePeriodicFrame: Bool
    }
    struct Joins: Codable, Equatable, Sendable {
        let guardSeconds: Double
    }
    struct Windows: Codable, Equatable, Sendable {
        let windowSeconds: Double
        let hopSeconds: Double
        let minimumUsableWindowSeconds: Double
    }
    /// Amendment A1 — see the `_amendmentReason` field in `U4aEstimatorConfig.json`.
    struct JoinEvidence: Codable, Equatable, Sendable {
        let nearDigitalSilenceDbfs: Double
        let minNearSilenceRunSeconds: Double
        let noiseFloorStepDb: Double
        let noiseFloorStepBlockSeconds: Double
    }
    struct Baseline: Codable, Equatable, Sendable {
        let minimumBaselineVoicedSeconds: Double
    }

    let configID: String
    let configVersion: String
    let frameGeometry: FrameGeometry
    let noiseFloor: NoiseFloor
    let activity: Activity
    let periodicity: Periodicity
    let f0Smoothing: F0Smoothing
    let nuclei: Nuclei
    let joins: Joins
    let windows: Windows
    let joinEvidence: JoinEvidence
    let baseline: Baseline
}

/// Config plus the SHA-256 of the exact bytes it was decoded from, so a report records
/// what actually ran rather than what the struct happens to hold.
struct LoadedEstimatorConfig: Sendable {
    let config: EstimatorConfig
    let sha256: String

    static func load(from data: Data) throws -> LoadedEstimatorConfig {
        let decoded = try JSONDecoder().decode(EstimatorConfig.self, from: data)
        return LoadedEstimatorConfig(config: decoded, sha256: U4aHash.hex(data))
    }

    static func loadDefault(bundle: Bundle) throws -> LoadedEstimatorConfig {
        guard let url = bundle.url(forResource: "U4aEstimatorConfig", withExtension: "json") else {
            throw U4aResourceError.missingResource("U4aEstimatorConfig.json")
        }
        return try load(from: Data(contentsOf: url))
    }
}

enum U4aResourceError: Error, CustomStringConvertible {
    case missingResource(String)
    var description: String {
        switch self {
        case .missingResource(let name): return "Test-bundle resource not found: \(name)"
        }
    }
}

enum U4aHash {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming hash so a 32 MB fixture is never fully resident just to be fingerprinted.
    static func hexOfFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
