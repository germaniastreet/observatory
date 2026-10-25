import Foundation

// U4a-1 Channel A: measurement semantics.
//
// Every type here exists to make the SaMD-grade rules in PROPOSALS/U4a-proposal.md
// (Revision 2, §5) structural rather than procedural:
//
//   1. `value != nil` <=> `status.primary == .valid`          (enforced by the factories below)
//   2. every encoded number is finite; log10(0) is NEVER given an invented floor
//   3. explicit `null` is emitted, never an omitted key
//   4. legitimate zeros (0 nuclei, 0.0 coverage, 0 dB delta) are real values, not "unknown"
//   5. no string field can carry transcript text: closed enums or charset-constrained ids
//
// Nothing in this file is production code; it is the test-only prototype shape that
// U4 would migrate into `Models.swift` additively.

// MARK: - Closed vocabularies

/// Stable metric identifiers. A closed enum rather than free text so a report can
/// never name a metric that does not exist, and so string scanning (§5.5) has a
/// finite allow-list.
enum MetricID: String, Codable, CaseIterable, Sendable {
    // Frame-derived, span-scoped summaries
    case spanNoiseFloor                 = "level.spanNoiseFloor"
    case spanVoicedSeconds              = "classification.spanVoicedSeconds"
    case spanActiveSeconds              = "classification.spanActiveSeconds"
    case spanInactiveSeconds            = "classification.spanInactiveSeconds"
    case spanUnknownSeconds             = "classification.spanUnknownSeconds"
    case spanVoicedFraction             = "classification.spanVoicedFraction"
    case spanF0Median                   = "f0.spanMedian"
    case spanOctaveJumpRejectionRate    = "f0.spanOctaveJumpRejectionRate"
    case spanSearchRangeRailRate        = "f0.spanSearchRangeRailRate"
    case spanEstimationSuccess          = "f0.spanEstimationSuccess"
    /// Inactive runs that contained an `unknown` frame: not silence, so not a gap
    /// candidate, and counted rather than discarded (review R6.5).
    case spanIndeterminateGapCount      = "gaps.spanIndeterminateCount"

    // Window-level (A9-A18)
    case silenceGapCount                = "gaps.windowCandidateCount"
    case silenceGapSeconds              = "gaps.windowCandidateSeconds"
    case silenceGapRatio                = "gaps.windowCandidateRatio"
    case activeAudioSeconds             = "classification.windowActiveSeconds"
    case voicedSeconds                  = "classification.windowVoicedSeconds"
    case nucleusRate                    = "nuclei.windowRatePerSecond"
    case syllableRatePerActiveSecond    = "nuclei.windowRatePerActiveSecond"
    case levelWindowMedian              = "level.windowMedian"
    case levelWindowIQR                 = "level.windowIQR"
    case f0WindowMedian                 = "f0.windowMedian"
    case f0WindowSpread                 = "f0.windowSpreadSemitones"

    // Deltas against the span baseline (A18)
    case levelDeltaFromSpanBaseline     = "level.windowMedian.deltaFromSpanBaseline"
    case f0DeltaFromSpanBaseline        = "f0.windowMedian.deltaFromSpanBaseline"
    case nucleusRateDeltaFromSpanBaseline = "nuclei.windowRatePerSecond.deltaFromSpanBaseline"
    case syllableRateDeltaFromSpanBaseline = "nuclei.windowRatePerActiveSecond.deltaFromSpanBaseline"
}

enum AcousticUnit: String, Codable, Sendable {
    case dBFS, dB, hertz, semitones
    case nucleiPerSecond, seconds, ratio, count
    /// Reserved for Channel B (U4a-2): `SFVoiceAnalytics.pitch` is documented as
    /// "a logarithm" with unspecified base/reference and is never converted.
    case rawUnspecifiedLog
}

enum EstimatorID: String, Codable, Sendable {
    case level          = "u4a.level.rms"
    case noiseFloor     = "u4a.floor.percentile"
    case activity       = "u4a.activity.hysteresis"
    case periodicity    = "u4a.periodicity.nccf"
    case f0             = "u4a.f0.nccf"
    case nuclei         = "u4a.nuclei.envelopePeak"
    case classification = "u4a.classification.fourState"
    case derived        = "u4a.derived.arithmetic"
}

/// Semantic version of the estimator *implementations* in
/// `AcousticMeasurementPrototype.swift`. Bump on any algorithm change; two numbers
/// produced by different versions are never silently comparable.
enum EstimatorVersion {
    static let current = "0.1.0"
}

// MARK: - Status

/// `.valid` means exactly "passes this prototype's operational gates" — NOT
/// clinically, perceptually, or otherwise validated. See PROPOSALS/U4a-proposal.md §5.3.
enum PrimaryStatus: Codable, Equatable, Sendable {
    case valid
    case unavailable(UnavailableReason)

    var isValid: Bool { if case .valid = self { return true } else { return false } }
}

enum NonFiniteCause: String, Codable, Sendable {
    /// RMS == 0 exactly, so 20*log10(rms) is -inf. Represented as unavailable;
    /// a physical floor is NOT invented for it.
    case zeroEnergyFrame
    /// Any other non-finite result from arithmetic (division by an empty set, etc.).
    case notFinite
}

enum EstimatorFailureCode: String, Codable, Sendable {
    case audioUnreadable
    case emptySignal
    case spanTooShortForFloor
    case insufficientSupport
    case noEligibleFrames
    case decimationUnsupported
}

enum UnavailableReason: Codable, Equatable, Sendable {
    case noAudio
    case outsideAnalysisDomain
    case insideUnresolvedRegion
    case insideJoinGuard
    case insufficientEligibleSeconds(eligible: Double, required: Double)
    case lowEstimationSuccess(success: Double, required: Double)
    case nonFiniteInput(NonFiniteCause)
    case saturated(clippedFraction: Double)
    case insufficientBaseline(observedSeconds: Double, required: Double)
    /// Its own reason — never disguised as insufficient baseline duration (review R6.15).
    case multiSpeakerMixture
    /// Channel B only (U4a-2); declared here so the vocabulary is complete.
    case alignmentUnresolved
    case estimatorFailed(EstimatorFailureCode)
}

/// Non-exclusive. May accompany `.valid` — a measurement can pass the gates and
/// still carry caveats that a reader must see.
enum QualityFlag: String, Codable, Sendable {
    case clippingPresent
    case nearJoinGuard
    case filterSettling
    case octaveJumpRejectionsPresent
    case searchRangeRailHits
    /// On real audio there is no independent measurement of the true noise floor,
    /// so A3 (and everything derived from it) is an unverified estimate no matter
    /// how the synthetic cases in M1 come out. Accepted [partial] pushback, R6.3.
    case noiseFloorUnverifiedOnRealAudio
    case noiseFloorStepDetected
    case completenessUnknown
    case multiSpeakerSource
    case boundaryClipped
    case sparseEligibility
    case periodicNonSpeechPossible
}

struct MeasurementStatus: Codable, Equatable, Sendable {
    let primary: PrimaryStatus
    let flags: [QualityFlag]

    init(primary: PrimaryStatus, flags: [QualityFlag] = []) {
        self.primary = primary
        // Sorted for determinism: flag insertion order must never change the bytes.
        self.flags = flags.sorted { $0.rawValue < $1.rawValue }
    }
}

// MARK: - Geometry and coverage

struct AnalysisWindow: Codable, Equatable, Sendable {
    let spanID: Int
    let startSeconds: Double
    let endSeconds: Double
    /// Analysis frame length for the metric's estimator.
    let frameSamples: Int
    /// Total sample support the estimator requires per frame. For NCCF-based F0 this
    /// exceeds `frameSamples` by the maximum lag, which is why F0's edge guard is
    /// wider than the level channel's. §4.1's "entire extent inside the span" rule is
    /// applied to THIS value, not to `frameSamples`.
    let supportSamples: Int
    let hopSamples: Int
}

/// Four separate quantities, because one ratio cannot describe both "how much of the
/// window exists" and "how much of it this metric could use" (review R6.5).
///
/// All elapsed-time accounting is in hop slots (one 10 ms slot per frame index), never
/// in frame extents, so overlapping 25 ms / 40 ms analysis frames cannot multiply
/// elapsed-time coverage.
struct Coverage: Codable, Equatable, Sendable {
    let nominalWindowSeconds: Double
    let domainSeconds: Double
    /// Never folded into silence, and never counted as domain.
    let unknownSeconds: Double
    let eligibleSeconds: Double
    let estimatedSeconds: Double
    let eligibleFrames: Int
    let estimatedFrames: Int

    var domainFraction: Double {
        nominalWindowSeconds > 0 ? domainSeconds / nominalWindowSeconds : 0
    }
    var eligibleFraction: Double {
        domainSeconds > 0 ? eligibleSeconds / domainSeconds : 0
    }
    var estimationSuccess: Double {
        eligibleSeconds > 0 ? estimatedSeconds / eligibleSeconds : 0
    }

    enum CodingKeys: String, CodingKey {
        case nominalWindowSeconds, domainSeconds, unknownSeconds, eligibleSeconds
        case estimatedSeconds, eligibleFrames, estimatedFrames
        case domainFraction, eligibleFraction, estimationSuccess
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(nominalWindowSeconds, forKey: .nominalWindowSeconds)
        try c.encode(domainSeconds, forKey: .domainSeconds)
        try c.encode(unknownSeconds, forKey: .unknownSeconds)
        try c.encode(eligibleSeconds, forKey: .eligibleSeconds)
        try c.encode(estimatedSeconds, forKey: .estimatedSeconds)
        try c.encode(eligibleFrames, forKey: .eligibleFrames)
        try c.encode(estimatedFrames, forKey: .estimatedFrames)
        // Derived ratios are encoded so a reader never has to recompute them.
        try c.encode(domainFraction, forKey: .domainFraction)
        try c.encode(eligibleFraction, forKey: .eligibleFraction)
        try c.encode(estimationSuccess, forKey: .estimationSuccess)
    }

    init(nominalWindowSeconds: Double, domainSeconds: Double, unknownSeconds: Double,
         eligibleSeconds: Double, estimatedSeconds: Double,
         eligibleFrames: Int, estimatedFrames: Int) {
        self.nominalWindowSeconds = nominalWindowSeconds
        self.domainSeconds = domainSeconds
        self.unknownSeconds = unknownSeconds
        self.eligibleSeconds = eligibleSeconds
        self.estimatedSeconds = estimatedSeconds
        self.eligibleFrames = eligibleFrames
        self.estimatedFrames = estimatedFrames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nominalWindowSeconds = try c.decode(Double.self, forKey: .nominalWindowSeconds)
        domainSeconds = try c.decode(Double.self, forKey: .domainSeconds)
        unknownSeconds = try c.decode(Double.self, forKey: .unknownSeconds)
        eligibleSeconds = try c.decode(Double.self, forKey: .eligibleSeconds)
        estimatedSeconds = try c.decode(Double.self, forKey: .estimatedSeconds)
        eligibleFrames = try c.decode(Int.self, forKey: .eligibleFrames)
        estimatedFrames = try c.decode(Int.self, forKey: .estimatedFrames)
    }

    static func empty(nominalWindowSeconds: Double) -> Coverage {
        Coverage(nominalWindowSeconds: nominalWindowSeconds, domainSeconds: 0, unknownSeconds: 0,
                 eligibleSeconds: 0, estimatedSeconds: 0, eligibleFrames: 0, estimatedFrames: 0)
    }
}

struct BaselineRef: Codable, Equatable, Sendable {
    let spanID: Int
    let metric: MetricID
    let observedVoicedSeconds: Double
    let value: Double
}

// MARK: - The measurement record

struct AcousticMeasurement: Codable, Equatable, Sendable {
    let metric: MetricID
    /// `nil` == unavailable. Never 0-as-unknown (D-07). Always finite when present.
    let value: Double?
    let unit: AcousticUnit
    let window: AnalysisWindow
    let estimator: EstimatorID
    let estimatorVersion: String
    let configID: String
    let configSHA256: String
    let coverage: Coverage
    let status: MeasurementStatus
    let baseline: BaselineRef?
    let provenanceID: String

    private init(metric: MetricID, value: Double?, unit: AcousticUnit, window: AnalysisWindow,
                 estimator: EstimatorID, configID: String, configSHA256: String,
                 coverage: Coverage, status: MeasurementStatus,
                 baseline: BaselineRef?, provenanceID: String) {
        self.metric = metric
        self.value = value
        self.unit = unit
        self.window = window
        self.estimator = estimator
        self.estimatorVersion = EstimatorVersion.current
        self.configID = configID
        self.configSHA256 = configSHA256
        self.coverage = coverage
        self.status = status
        self.baseline = baseline
        self.provenanceID = provenanceID
    }

    /// The only way to produce a measurement carrying a number. A non-finite input is
    /// downgraded to `.unavailable(.nonFiniteInput)` here rather than being encoded,
    /// so invariant 2 cannot be violated by a caller's arithmetic.
    static func measured(_ value: Double, metric: MetricID, unit: AcousticUnit,
                         window: AnalysisWindow, estimator: EstimatorID,
                         coverage: Coverage, context: ReportContext,
                         flags: [QualityFlag] = [], baseline: BaselineRef? = nil) -> AcousticMeasurement {
        guard value.isFinite else {
            return unavailable(.nonFiniteInput(.notFinite), metric: metric, unit: unit, window: window,
                               estimator: estimator, coverage: coverage, context: context, flags: flags)
        }
        return AcousticMeasurement(
            metric: metric, value: value, unit: unit, window: window, estimator: estimator,
            configID: context.configID, configSHA256: context.configSHA256, coverage: coverage,
            status: MeasurementStatus(primary: .valid, flags: context.flags(adding: flags)),
            baseline: baseline, provenanceID: context.provenanceID)
    }

    static func unavailable(_ reason: UnavailableReason, metric: MetricID, unit: AcousticUnit,
                            window: AnalysisWindow, estimator: EstimatorID,
                            coverage: Coverage, context: ReportContext,
                            flags: [QualityFlag] = [], baseline: BaselineRef? = nil) -> AcousticMeasurement {
        AcousticMeasurement(
            metric: metric, value: nil, unit: unit, window: window, estimator: estimator,
            configID: context.configID, configSHA256: context.configSHA256, coverage: coverage,
            status: MeasurementStatus(primary: .unavailable(reason), flags: context.flags(adding: flags)),
            baseline: baseline, provenanceID: context.provenanceID)
    }

    enum CodingKeys: String, CodingKey {
        case metric, value, unit, window, estimator, estimatorVersion
        case configID, configSHA256, coverage, status, baseline, provenanceID
    }

    /// Hand-written so `value: nil` encodes as an explicit JSON `null`. The synthesized
    /// conformance would use `encodeIfPresent` and omit the key, which invites a
    /// consumer-side default — exactly what D-07 forbids.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(metric, forKey: .metric)
        if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
        try c.encode(unit, forKey: .unit)
        try c.encode(window, forKey: .window)
        try c.encode(estimator, forKey: .estimator)
        try c.encode(estimatorVersion, forKey: .estimatorVersion)
        try c.encode(configID, forKey: .configID)
        try c.encode(configSHA256, forKey: .configSHA256)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(status, forKey: .status)
        if let baseline { try c.encode(baseline, forKey: .baseline) } else { try c.encodeNil(forKey: .baseline) }
        try c.encode(provenanceID, forKey: .provenanceID)
    }
}

/// Carried through analysis so every measurement is stamped with the same config hash,
/// provenance id, and source-wide flags without each call site remembering to do it.
struct ReportContext: Sendable {
    let provenanceID: String
    let configID: String
    let configSHA256: String
    let sourceFlags: [QualityFlag]

    func flags(adding extra: [QualityFlag]) -> [QualityFlag] {
        Array(Set(sourceFlags + extra))
    }
}

// MARK: - Provenance

enum SourceKind: String, Codable, Sendable {
    case fixture, session, synthetic
}

/// Charset-constrained identifier (§5.5). Construction rejects anything that is not
/// `[A-Za-z0-9._:-]{1,64}`, so a report cannot carry free text in an id field.
struct ConstrainedID: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    static let pattern = "^[A-Za-z0-9._:-]{1,64}$"
    let rawValue: String

    init?(_ raw: String) {
        guard raw.count >= 1, raw.count <= 64 else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")
        guard raw.allSatisfy({ allowed.contains($0) }) else { return nil }
        self.rawValue = raw
    }

    /// For ids built from values this file controls (enum raw values, UUIDs, hashes).
    static func trusted(_ raw: String) -> ConstrainedID {
        ConstrainedID(raw) ?? ConstrainedID("invalid.identifier")!
    }

    var description: String { rawValue }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let v = ConstrainedID(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "identifier outside allowed charset"))
        }
        self = v
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct SourceID: Codable, Equatable, Hashable, Sendable {
    let kind: SourceKind
    let id: ConstrainedID

    static func fixture(_ name: String) -> SourceID { SourceID(kind: .fixture, id: .trusted(name)) }
    static func session(_ uuid: String) -> SourceID { SourceID(kind: .session, id: .trusted(uuid)) }
    static func synthetic(_ name: String) -> SourceID { SourceID(kind: .synthetic, id: .trusted(name)) }

    var stringValue: String { "\(kind.rawValue):\(id.rawValue)" }
}

enum SampleFormat: String, Codable, Sendable {
    case float32, int16, int32, other
}

enum CaptureConfiguration: String, Codable, Sendable {
    case measurementModeConfirmed
    /// The three fixtures: recorded ~1 h before the `.measurement` capture tuning was
    /// committed, so their capture configuration is not the current one (PLAN.md).
    case unverifiedPreTuning
    case unknown
    case syntheticSignal
}

enum PostProcessing: Codable, Equatable, Sendable {
    case none
    case identityReencode
    case flatGain(db: Double)
    case loudnorm
    case synthetic

    /// Amplitude-domain metrics are refused on level-altered variants outside M4.
    var alterslevel: Bool {
        switch self {
        case .none, .identityReencode, .synthetic: return false
        case .flatGain, .loudnorm: return true
        }
    }
}

enum RecordedCompleteness: Codable, Equatable, Sendable {
    case complete
    case incomplete(endpointAudioSeconds: Double?)
    /// `nil` in the session record: unknown provenance, NEVER treated as complete (R3.7).
    case unknownLegacy
    case notApplicable
}

enum DiscontinuityPattern: String, Codable, Sendable {
    case none
    case truncatedTail
    case truncatedHead
    case internalJoin
    case multipleJoins
    /// The default. `.incomplete` alone never narrows this (R3.1).
    case unknownPattern
}

enum EvidenceSource: String, Codable, Sendable {
    case lifecycleRecord
    case signalNearDigitalSilence
    case signalNoiseFloorStep
    case writerLossRecord
    case syntheticConstruction
}

/// One piece of candidate evidence about where a join might be. Sources are kept
/// separate and never fused into a single "the splice is here" (§6.3).
struct EvidenceItem: Codable, Equatable, Sendable {
    let source: EvidenceSource
    let intervalStartSeconds: Double?
    let intervalEndSeconds: Double?
    /// Assumptions this evidence depends on, as closed-vocabulary codes, not prose.
    let assumptions: [EvidenceAssumption]
    let note: EvidenceNote

    enum CodingKeys: String, CodingKey {
        case source, intervalStartSeconds, intervalEndSeconds, assumptions, note
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(source, forKey: .source)
        if let v = intervalStartSeconds { try c.encode(v, forKey: .intervalStartSeconds) } else { try c.encodeNil(forKey: .intervalStartSeconds) }
        if let v = intervalEndSeconds { try c.encode(v, forKey: .intervalEndSeconds) } else { try c.encodeNil(forKey: .intervalEndSeconds) }
        try c.encode(assumptions, forKey: .assumptions)
        try c.encode(note, forKey: .note)
    }
}

enum EvidenceAssumption: String, Codable, Sendable {
    case recognitionRestartEqualsCaptureResumption
    case captureContinuousAfterResumption
    case endedAtEqualsLastWrittenFrame
    case nearSilenceIndicatesMicMute
    case noiseFloorStepIndicatesJoin
    case writerOffsetIsExact
}

enum EvidenceNote: String, Codable, Sendable {
    case lifecycleInferenceUnderStatedAssumptions
    case candidateOnlyFalsePositivesPossible
    case candidateOnlyFalseNegativesPossible
    case exactByConstruction
    case noCandidateFound
}

struct CompletenessRecord: Codable, Equatable, Sendable {
    let recorded: RecordedCompleteness
    let pattern: DiscontinuityPattern
    let patternEvidence: [EvidenceItem]
    let sessionWallSeconds: Double?
    let audioRecordingReliable: Bool?
    let missingAudioIntervalCount: Int?

    enum CodingKeys: String, CodingKey {
        case recorded, pattern, patternEvidence, sessionWallSeconds
        case audioRecordingReliable, missingAudioIntervalCount
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recorded, forKey: .recorded)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(patternEvidence, forKey: .patternEvidence)
        if let v = sessionWallSeconds { try c.encode(v, forKey: .sessionWallSeconds) } else { try c.encodeNil(forKey: .sessionWallSeconds) }
        if let v = audioRecordingReliable { try c.encode(v, forKey: .audioRecordingReliable) } else { try c.encodeNil(forKey: .audioRecordingReliable) }
        if let v = missingAudioIntervalCount { try c.encode(v, forKey: .missingAudioIntervalCount) } else { try c.encodeNil(forKey: .missingAudioIntervalCount) }
    }
}

struct CaptureProvenance: Codable, Equatable, Sendable {
    let sourceID: SourceID
    /// 64 hex chars. Reproducibility anchor; the audio itself never leaves the machine.
    let fileSHA256: String?
    let sampleRate: Double
    let channelCount: Int
    let sampleFormat: SampleFormat
    /// From the frame count (`AVAudioFile.length / sampleRate`), never from file bytes
    /// — a CAF header would make the byte arithmetic ~0.02 s long (Hermes Finding 3).
    let fileDurationSeconds: Double
    let captureConfiguration: CaptureConfiguration
    let postProcessing: PostProcessing
    let completeness: CompletenessRecord
    let isMultiSpeakerSource: Bool

    enum CodingKeys: String, CodingKey {
        case sourceID, fileSHA256, sampleRate, channelCount, sampleFormat
        case fileDurationSeconds, captureConfiguration, postProcessing, completeness, isMultiSpeakerSource
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sourceID, forKey: .sourceID)
        if let v = fileSHA256 { try c.encode(v, forKey: .fileSHA256) } else { try c.encodeNil(forKey: .fileSHA256) }
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(channelCount, forKey: .channelCount)
        try c.encode(sampleFormat, forKey: .sampleFormat)
        try c.encode(fileDurationSeconds, forKey: .fileDurationSeconds)
        try c.encode(captureConfiguration, forKey: .captureConfiguration)
        try c.encode(postProcessing, forKey: .postProcessing)
        try c.encode(completeness, forKey: .completeness)
        try c.encode(isMultiSpeakerSource, forKey: .isMultiSpeakerSource)
    }
}

// MARK: - Analysis domain

struct TimeSpan: Codable, Equatable, Sendable {
    let spanID: Int
    let startSeconds: Double
    let endSeconds: Double
    var durationSeconds: Double { max(0, endSeconds - startSeconds) }
}

enum ExclusionReason: String, Codable, Sendable {
    case unresolvedJoinRegion
    case joinGuard
    case writeLossExcludedSource
    case outsideFile
}

struct ExcludedRegion: Codable, Equatable, Sendable {
    let startSeconds: Double
    let endSeconds: Double
    let reason: ExclusionReason
}

/// The product of §6.4's disagreement policy. `unresolvedRegions` is the union of every
/// location the join might plausibly occupy, guarded — never a single chosen point.
struct AnalysisDomain: Codable, Equatable, Sendable {
    let fileDurationSeconds: Double
    let analyzableSpans: [TimeSpan]
    let excludedRegions: [ExcludedRegion]
    let evidence: [EvidenceItem]
    let unresolvedRegions: [ExcludedRegion]
    /// False for anything but `.complete` with no write losses.
    let wallClockMappingAvailable: Bool
    /// True when the policy left no usable span. An honest, reportable outcome (§6.4).
    let joinSensitiveMeasurementsSuppressed: Bool
    let sourceExcluded: Bool

    var analyzableSeconds: Double { analyzableSpans.reduce(0) { $0 + $1.durationSeconds } }
}

// MARK: - Observations and capability

enum PrototypeObservationKind: String, Codable, Sendable {
    case pitchContourShift
    case intensityShift
    case acceleratedDeliveryCandidate
}

/// A measurement plus the rule that selected it. No emotional or state label, no
/// probability, no severity — ever.
struct PrototypeObservation: Codable, Equatable, Sendable {
    let kind: PrototypeObservationKind
    let ruleID: ConstrainedID
    let libraryID: ConstrainedID
    let libraryVersion: ConstrainedID
    let calibrationStatus: ConstrainedID
    let measurement: AcousticMeasurement
    let thresholdValue: Double
    let comparison: NumericComparison
    let observedValue: Double
}

/// Things this prototype cannot measure, stated once in the report header rather than
/// masquerading as observations (review R6.14).
enum CapabilityCode: String, Codable, Sendable {
    case reducedArticulationUnsupported
    case prolongedSoundCandidateRequiresTranscript
    case speakerAttributionUnavailable
    case periodicNonSpeechNotExcluded
    case noiseFloorUnverifiableOnRealAudio
    case unvoicedSpeechNotSeparableFromNoise
    case channelBDeferredToU4a2
}

struct CapabilityStatus: Codable, Equatable, Sendable {
    let code: CapabilityCode
    let supported: Bool
}

// MARK: - Report

struct RunManifest: Codable, Equatable, Sendable {
    let schemaVersion: String
    let estimatorVersion: String
    let configID: String
    let configVersion: String
    let configSHA256: String
    let configInline: EstimatorConfig
    let rulesLibraryID: ConstrainedID
    let rulesLibraryVersion: ConstrainedID
    let rulesSHA256: String
    let calibrationStatus: ConstrainedID
    // Environment fields — excluded from the canonical payload (§12 criterion 5).
    let generatedAtISO8601: String
    let osVersion: String
    let architecture: String
}

struct SpanSummary: Codable, Equatable, Sendable {
    let span: TimeSpan
    let measurements: [AcousticMeasurement]
    let baselineAvailable: Bool
    let baselineVoicedSeconds: Double
}

struct SourceReport: Codable, Equatable, Sendable {
    let provenance: CaptureProvenance
    let domain: AnalysisDomain
    let spanSummaries: [SpanSummary]
    let windowMeasurements: [AcousticMeasurement]
    let observations: [PrototypeObservation]
    let capability: [CapabilityStatus]
}

struct U4aMeasurementReport: Codable, Equatable, Sendable {
    let manifest: RunManifest
    let sources: [SourceReport]

    /// Deterministic encoding: sorted keys, no escaping surprises, and `.throw` on any
    /// non-finite double so invariant 2 fails loudly rather than emitting `"Infinity"`.
    static func encoder(pretty: Bool) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
                                    : [.sortedKeys, .withoutEscapingSlashes]
        e.nonConformingFloatEncodingStrategy = .throw
        return e
    }

    func encoded(pretty: Bool = true) throws -> Data {
        try Self.encoder(pretty: pretty).encode(self)
    }

    /// Everything except the manifest's environment/timing fields. This is what
    /// determinism is asserted over, per §12 criterion 5: byte-identical within a
    /// pinned environment; cross-environment identity is NOT claimed.
    func canonicalPayload() throws -> Data {
        struct Canonical: Encodable {
            let schemaVersion: String
            let estimatorVersion: String
            let configID: String
            let configVersion: String
            let configSHA256: String
            let rulesSHA256: String
            let sources: [SourceReport]
        }
        return try Self.encoder(pretty: false).encode(
            Canonical(schemaVersion: manifest.schemaVersion,
                      estimatorVersion: manifest.estimatorVersion,
                      configID: manifest.configID,
                      configVersion: manifest.configVersion,
                      configSHA256: manifest.configSHA256,
                      rulesSHA256: manifest.rulesSHA256,
                      sources: sources))
    }

    enum Schema {
        static let version = "u4a.report.1"
    }
}
