import AVFoundation
import Foundation
import Speech

// U4a-2 Channel B: the frozen configuration and the device-harvest records.
//
// Spec: PROPOSALS/U4a-proposal.md Revision 2 §8 / §9 M5, with amendments A5–A9 as ruled by
// the director in PROPOSALS/U4a-2-plan.md and frozen in `U4a2ChannelBConfig.json`
// (pre-registered at b7bbd9f). That JSON is loaded and hashed here, never edited; every
// algorithm selector it names is checked against what this code actually implements, so
// a config the code does not implement fails loudly instead of being silently ignored.
//
// Harvest records are NUMBERS ONLY. No transcript text, no substrings, no formatted
// strings are ever read from a recognition result — only `isFinal`, the result-level
// `speechRecognitionMetadata`, and segment timestamp/duration for the separate
// deprecated-path diagnostic. Unavailable is `null`, never 0 (D-07).

// MARK: - Frozen configuration

struct U4a2ChannelBConfig: Codable, Equatable, Sendable {
    struct Ladder: Codable, Equatable, Sendable {
        let amendment: String
        let reason: String
        let passageSource: String
        let sourceSampleRateHz: Double
        let passageStartFrame: Int64
        let passageEndFrame: Int64
        let leadingSilenceSeconds: [Double]
        let trailingSilenceSeconds: Double
        let replicateRungs: [Double]

        enum CodingKeys: String, CodingKey {
            case amendment = "_amendment", reason = "_reason"
            case passageSource, sourceSampleRateHz, passageStartFrame, passageEndFrame
            case leadingSilenceSeconds, trailingSilenceSeconds, replicateRungs
        }
    }

    struct Alignment: Codable, Equatable, Sendable {
        let amendment: String
        let reason: String
        let lagMethod: String
        let referenceRung: Double
        let primaryFeature: VoiceFeature
        let corroboratingFeature: VoiceFeature
        let lagSearch: String
        let nonFiniteHandling: String
        let lagToleranceFrames: Double
        let durationToleranceFrames: Double
        let featureLagDisagreementOutcome: ChannelBOutcome
        let missingOrFailedRungOutcome: ChannelBOutcome
        let noAnalyticsOnAnyRungOutcome: ChannelBOutcome
        let uncertaintyFloor: String

        enum CodingKeys: String, CodingKey {
            case amendment = "_amendment", reason = "_reason"
            case lagMethod, referenceRung, primaryFeature, corroboratingFeature, lagSearch
            case nonFiniteHandling, lagToleranceFrames, durationToleranceFrames
            case featureLagDisagreementOutcome, missingOrFailedRungOutcome
            case noAnalyticsOnAnyRungOutcome, uncertaintyFloor
        }
    }

    struct RequestLifecycle: Codable, Equatable, Sendable {
        struct Timeout: Codable, Equatable, Sendable {
            let minimum: Double
            let fedPlus: Double
        }
        struct AudioSessionSettings: Codable, Equatable, Sendable {
            let category: String
            let mode: String
            let options: [String]
        }
        let amendment: String
        let reason: String
        let ladderRequestsPerRung: Int
        let arm2ChunkSeconds: Double
        let arm2ChunkBoundary: String
        let postFinalGraceSeconds: Double
        let timeoutSeconds: Timeout
        let requiresOnDeviceRecognition: Bool
        let shouldReportPartialResults: Bool
        let addsPunctuation: Bool
        let audioSession: AudioSessionSettings
        let matchLiveTapFormat: Bool
        let errorPolicy: String

        enum CodingKeys: String, CodingKey {
            case amendment = "_amendment", reason = "_reason"
            case ladderRequestsPerRung, arm2ChunkSeconds, arm2ChunkBoundary, postFinalGraceSeconds
            case timeoutSeconds, requiresOnDeviceRecognition, shouldReportPartialResults
            case addsPunctuation, audioSession, matchLiveTapFormat, errorPolicy
        }

        /// A7: max(minimum, fed + fedPlus), matching `FixtureReplayHarness.replay`.
        func timeout(forFedSeconds fed: Double) -> Double {
            max(timeoutSeconds.minimum, fed + timeoutSeconds.fedPlus)
        }
    }

    struct FrameMatching: Codable, Equatable, Sendable {
        let amendment: String
        let reason: String
        let mapping: String
        let channelAHopMs: Double
        let requireChannelAState: String
        let requireChannelAF0: Bool
        let requireBFinite: Bool
        let boundaryGuard: String

        enum CodingKeys: String, CodingKey {
            case amendment = "_amendment", reason = "_reason"
            case mapping, channelAHopMs, requireChannelAState, requireChannelAF0, requireBFinite, boundaryGuard
        }
    }

    struct Fit: Codable, Equatable, Sendable {
        let amendment: String
        let reason: String
        let model: String
        let heldOut: String
        let rotations: Int
        let fixtures: [String]
        let minimumMatchedFramesPerFixture: Int
        let report: [String]

        enum CodingKeys: String, CodingKey {
            case amendment = "_amendment", reason = "_reason"
            case model, heldOut, rotations, fixtures, minimumMatchedFramesPerFixture, report
        }
    }

    struct CoverageSpec: Codable, Equatable, Sendable {
        let note: String
        let features: [VoiceFeature]
        let usable: String
        let reportExactZeroFractionSeparately: Bool
        let variants: [CoverageVariant]
        let zeroDenominator: String

        enum CodingKeys: String, CodingKey {
            case note = "_note"
            case features, usable, reportExactZeroFractionSeparately, variants, zeroDenominator
        }
    }

    let configID: String
    let configVersion: String
    let specBase: String
    let ladder: Ladder
    let alignment: Alignment
    let requestLifecycle: RequestLifecycle
    let frameMatching: FrameMatching
    let fit: Fit
    let coverage: CoverageSpec

    /// Every string in the config that selects an ALGORITHM must name the one this code
    /// implements. A mismatch throws rather than running something other than what was
    /// pre-registered.
    func validateImplementedSelectors(channelAHopMs: Double) throws {
        func require(_ field: String, _ actual: String, _ implemented: String) throws {
            guard actual == implemented else { throw ChannelBConfigError.unimplemented(field: field, value: actual) }
        }
        try require("alignment.lagMethod", alignment.lagMethod, "normalizedCrossCorrelation")
        try require("alignment.lagSearch", alignment.lagSearch, "fullRange")
        try require("alignment.nonFiniteHandling", alignment.nonFiniteHandling, "excludeFrameFromCorrelation")
        try require("alignment.uncertaintyFloor", alignment.uncertaintyFloor, "oneFrameDuration")
        try require("requestLifecycle.arm2ChunkBoundary", requestLifecycle.arm2ChunkBoundary, "contiguousNoOverlap")
        try require("requestLifecycle.errorPolicy", requestLifecycle.errorPolicy, "catchAndContinueRecordFailed")
        try require("frameMatching.mapping", frameMatching.mapping, "bFrameCentreToContainingChannelAHopSlot")
        try require("frameMatching.requireChannelAState", frameMatching.requireChannelAState, FrameState.voiced.rawValue)
        try require("frameMatching.boundaryGuard", frameMatching.boundaryGuard, "max(alignmentUncertaintySeconds, bFrameDuration)")
        try require("fit.model", fit.model, "OLS: B2 = a + b * ln(F0_A_Hz)")
        try require("fit.heldOut", fit.heldOut, "leaveOneFixtureOut")
        try require("coverage.usable", coverage.usable, "presentAndFinite")
        try require("coverage.zeroDenominator", coverage.zeroDenominator, "nil")
        guard fit.rotations == fit.fixtures.count else {
            throw ChannelBConfigError.unimplemented(field: "fit.rotations", value: String(fit.rotations))
        }
        guard frameMatching.requireChannelAF0, frameMatching.requireBFinite else {
            throw ChannelBConfigError.unimplemented(field: "frameMatching.require*", value: "false")
        }
        // A8 maps onto Channel A's hop grid; the two configs must agree on what that grid is.
        guard frameMatching.channelAHopMs == channelAHopMs else {
            throw ChannelBConfigError.unimplemented(field: "frameMatching.channelAHopMs",
                                                    value: String(frameMatching.channelAHopMs))
        }
        _ = try requestLifecycle.audioSession.resolved()
    }
}

enum ChannelBConfigError: Error, CustomStringConvertible {
    case missingResource
    case unimplemented(field: String, value: String)
    var description: String {
        switch self {
        case .missingResource: return "Test-bundle resource not found: U4a2ChannelBConfig.json"
        case .unimplemented(let f, let v): return "U4a2ChannelBConfig \(f)=\(v) is not what this code implements"
        }
    }
}

/// Config plus the SHA-256 of the exact bytes it was decoded from.
struct LoadedChannelBConfig: Sendable {
    let config: U4a2ChannelBConfig
    let sha256: String

    static func load(from data: Data, channelAHopMs: Double) throws -> LoadedChannelBConfig {
        let decoded = try JSONDecoder().decode(U4a2ChannelBConfig.self, from: data)
        try decoded.validateImplementedSelectors(channelAHopMs: channelAHopMs)
        return LoadedChannelBConfig(config: decoded, sha256: U4aHash.hex(data))
    }

    static func loadDefault() throws -> LoadedChannelBConfig {
        guard let url = U4aHarness.bundle.url(forResource: "U4a2ChannelBConfig", withExtension: "json") else {
            throw ChannelBConfigError.missingResource
        }
        let channelA = try U4aHarness.loadConfig()
        return try load(from: Data(contentsOf: url), channelAHopMs: channelA.config.frameGeometry.hopMs)
    }
}

extension U4a2ChannelBConfig.RequestLifecycle.AudioSessionSettings {
    /// Only the values the frozen config names are mapped; anything else throws.
    func resolved() throws -> (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions) {
        guard category == "record" else { throw ChannelBConfigError.unimplemented(field: "audioSession.category", value: category) }
        guard mode == "measurement" else { throw ChannelBConfigError.unimplemented(field: "audioSession.mode", value: mode) }
        var opts: AVAudioSession.CategoryOptions = []
        for o in options {
            guard o == "duckOthers" else { throw ChannelBConfigError.unimplemented(field: "audioSession.options", value: o) }
            opts.insert(.duckOthers)
        }
        return (.record, .measurement, opts)
    }
}

// MARK: - Closed vocabularies

enum VoiceFeature: String, Codable, CaseIterable, Sendable {
    case pitch, jitter, shimmer, voicing
}

enum ChannelBOutcome: String, Codable, Sendable {
    case alignmentSupported = "O-B1"
    case alignmentUnresolved = "O-B2"
    case noAnalyticsReturned = "O-B3"
}

enum CoverageVariant: String, Codable, Sendable {
    case wholeEligibleDomain
    case successfullyProcessedFedIntervals
}

// MARK: - §8.2 input mapping

/// One step of a feed plan, in source-file sample coordinates or seconds of synthesized
/// (explicitly zeroed) silence.
enum VoiceAnalyticsFeedItem: Equatable, Sendable {
    case source(Range<Int64>)
    case silence(seconds: Double)
}

enum FedIntervalKind: String, Codable, Sendable {
    case source
    case insertedSilence
}

/// One fed interval on the request's own timeline. Inserted silence is its own interval
/// with no source coordinates, so it can never be mapped into source-file coverage.
struct FedInterval: Codable, Equatable, Sendable {
    let feedOrder: Int
    let kind: FedIntervalKind
    let fedStartSeconds: Double
    let fedEndSeconds: Double
    let durationSeconds: Double
    let sourceStartSample: Int64?
    let sourceEndSample: Int64?

    enum CodingKeys: String, CodingKey {
        case feedOrder, kind, fedStartSeconds, fedEndSeconds, durationSeconds, sourceStartSample, sourceEndSample
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(feedOrder, forKey: .feedOrder)
        try c.encode(kind, forKey: .kind)
        try c.encode(fedStartSeconds, forKey: .fedStartSeconds)
        try c.encode(fedEndSeconds, forKey: .fedEndSeconds)
        try c.encode(durationSeconds, forKey: .durationSeconds)
        if let v = sourceStartSample { try c.encode(v, forKey: .sourceStartSample) } else { try c.encodeNil(forKey: .sourceStartSample) }
        if let v = sourceEndSample { try c.encode(v, forKey: .sourceEndSample) } else { try c.encodeNil(forKey: .sourceEndSample) }
    }
}

/// §8.2, recorded before any result arrives. Chunk identity is
/// (sourceID, requestIndex, fedSourceStartSample..<fedSourceEndSample).
struct RequestInputMapping: Codable, Equatable, Sendable {
    let sourceID: SourceID
    let requestIndex: Int
    let fedSourceStartSample: Int64
    let fedSourceEndSample: Int64
    let sourceSampleRateHz: Double
    let submittedSampleRateHz: Double
    let submittedChannelCount: Int
    let submittedSampleFormat: SampleFormat
    let resampled: Bool
    /// submitted rate ÷ source rate; 1.0 when no resampling occurred.
    let resampleRatio: Double
    /// In feed order. Silence durations are the frame counts `appendSilence` actually
    /// synthesizes (rounded up at the submitted rate), so this is what was fed, not what
    /// was asked for.
    let fedIntervals: [FedInterval]
    let fedDurationSeconds: Double

    static func plan(sourceID: SourceID, requestIndex: Int, feedPlan: [VoiceAnalyticsFeedItem],
                     sourceSampleRateHz: Double, submittedSampleRateHz: Double,
                     submittedChannelCount: Int, submittedSampleFormat: SampleFormat) -> RequestInputMapping {
        var t = 0.0
        var intervals: [FedInterval] = []
        for (order, item) in feedPlan.enumerated() {
            switch item {
            case .source(let range):
                let seconds = Double(range.count) / sourceSampleRateHz
                intervals.append(FedInterval(feedOrder: order, kind: .source, fedStartSeconds: t,
                                             fedEndSeconds: t + seconds, durationSeconds: seconds,
                                             sourceStartSample: range.lowerBound, sourceEndSample: range.upperBound))
                t += seconds
            case .silence(let requested):
                let frames = requested > 0 ? (requested * submittedSampleRateHz).rounded(.up) : 0
                let seconds = frames / submittedSampleRateHz
                intervals.append(FedInterval(feedOrder: order, kind: .insertedSilence, fedStartSeconds: t,
                                             fedEndSeconds: t + seconds, durationSeconds: seconds,
                                             sourceStartSample: nil, sourceEndSample: nil))
                t += seconds
            }
        }
        let sourceRanges = intervals.compactMap { i -> (Int64, Int64)? in
            guard let s = i.sourceStartSample, let e = i.sourceEndSample else { return nil }
            return (s, e)
        }
        return RequestInputMapping(
            sourceID: sourceID, requestIndex: requestIndex,
            fedSourceStartSample: sourceRanges.map(\.0).min() ?? 0,
            fedSourceEndSample: sourceRanges.map(\.1).max() ?? 0,
            sourceSampleRateHz: sourceSampleRateHz, submittedSampleRateHz: submittedSampleRateHz,
            submittedChannelCount: submittedChannelCount, submittedSampleFormat: submittedSampleFormat,
            resampled: submittedSampleRateHz != sourceSampleRateHz,
            resampleRatio: submittedSampleRateHz / sourceSampleRateHz,
            fedIntervals: intervals, fedDurationSeconds: t)
    }

    /// Source-file intervals (seconds) covered by a fed-timeline interval under anchor (a)
    /// — §8.4's hypothesis that an array's origin is the start of the fed audio. Inserted
    /// silence maps to nothing.
    func sourceIntervals(fedStart: Double, fedEnd: Double) -> [(Double, Double)] {
        fedIntervals.compactMap { i in
            guard i.kind == .source, let s0 = i.sourceStartSample else { return nil }
            let lo = max(fedStart, i.fedStartSeconds), hi = min(fedEnd, i.fedEndSeconds)
            guard hi > lo else { return nil }
            let base = Double(s0) / sourceSampleRateHz - i.fedStartSeconds
            return (base + lo, base + hi)
        }
    }

    /// Source-file time of a fed-timeline instant, or nil inside inserted silence.
    func sourceTime(fedTime t: Double) -> Double? {
        for i in fedIntervals where i.kind == .source {
            guard let s0 = i.sourceStartSample, t >= i.fedStartSeconds, t < i.fedEndSeconds else { continue }
            return Double(s0) / sourceSampleRateHz + (t - i.fedStartSeconds)
        }
        return nil
    }

    /// Every source-file interval this request was fed, in seconds.
    var fedSourceIntervals: [(Double, Double)] {
        sourceIntervals(fedStart: 0, fedEnd: fedDurationSeconds)
    }
}

// MARK: - §8.3 / §8.4 per-request records

/// Partials are audited by index and finality only; they never contribute (§8.3).
struct CallbackAuditEntry: Codable, Equatable, Sendable {
    let callbackIndex: Int
    let isFinal: Bool
}

/// One `SFAcousticFeature` as returned. Non-finite values stay in place as `null` so
/// `count` is the API's own count; `nonFiniteCount` says how many there were.
struct FeatureArray: Codable, Equatable, Sendable {
    let feature: VoiceFeature
    let frameDuration: Double?
    let count: Int
    let values: [Double?]
    let nonFiniteCount: Int

    init(feature: VoiceFeature, frameDuration: Double, rawValues: [Double]) {
        self.feature = feature
        self.frameDuration = frameDuration.isFinite ? frameDuration : nil
        self.count = rawValues.count
        self.values = rawValues.map { $0.isFinite ? $0 : nil }
        self.nonFiniteCount = rawValues.filter { !$0.isFinite }.count
    }

    enum CodingKeys: String, CodingKey { case feature, frameDuration, count, values, nonFiniteCount }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(feature, forKey: .feature)
        if let v = frameDuration { try c.encode(v, forKey: .frameDuration) } else { try c.encodeNil(forKey: .frameDuration) }
        try c.encode(count, forKey: .count)
        try c.encode(values, forKey: .values)      // nil elements encode as explicit null
        try c.encode(nonFiniteCount, forKey: .nonFiniteCount)
    }
}

/// Result-level metadata. Anchor (b) in §8.4 — recorded as a diagnostic only, never used
/// as an alignment source (recognizer timing is demonstrably unreliable here: E8, U6b).
struct ResultMetadataDiagnostic: Codable, Equatable, Sendable {
    let speakingRate: Double?
    let averagePauseDuration: Double?
    let speechStartTimestamp: Double?
    let speechDuration: Double?

    enum CodingKeys: String, CodingKey { case speakingRate, averagePauseDuration, speechStartTimestamp, speechDuration }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        for (k, v) in [(CodingKeys.speakingRate, speakingRate), (.averagePauseDuration, averagePauseDuration),
                       (.speechStartTimestamp, speechStartTimestamp), (.speechDuration, speechDuration)] {
            if let v { try c.encode(v, forKey: k) } else { try c.encodeNil(forKey: k) }
        }
    }
}

/// §8.1 primary path: `result.speechRecognitionMetadata?.voiceAnalytics`, finals only.
struct FinalResultRecord: Codable, Equatable, Sendable {
    let finalOrdinal: Int
    let callbackIndex: Int
    let metadata: ResultMetadataDiagnostic?
    /// `nil` when the result carried no `SFVoiceAnalytics` at all.
    let voiceAnalytics: [FeatureArray]?

    func array(_ f: VoiceFeature) -> FeatureArray? { voiceAnalytics?.first { $0.feature == f } }

    enum CodingKeys: String, CodingKey { case finalOrdinal, callbackIndex, metadata, voiceAnalytics }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(finalOrdinal, forKey: .finalOrdinal)
        try c.encode(callbackIndex, forKey: .callbackIndex)
        if let v = metadata { try c.encode(v, forKey: .metadata) } else { try c.encodeNil(forKey: .metadata) }
        if let v = voiceAnalytics { try c.encode(v, forKey: .voiceAnalytics) } else { try c.encodeNil(forKey: .voiceAnalytics) }
    }
}

/// §8.1 optional compatibility diagnostic: the deprecated segment-level path. Its own
/// report key, never merged with the primary path, never used for B5. Timestamp and
/// duration only — `substring` is never read.
struct SegmentLevelDiagnostic: Codable, Equatable, Sendable {
    let finalOrdinal: Int
    let segmentIndex: Int
    let segmentTimestamp: Double?
    let segmentDuration: Double?
    let voiceAnalytics: [FeatureArray]?

    enum CodingKeys: String, CodingKey { case finalOrdinal, segmentIndex, segmentTimestamp, segmentDuration, voiceAnalytics }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(finalOrdinal, forKey: .finalOrdinal)
        try c.encode(segmentIndex, forKey: .segmentIndex)
        if let v = segmentTimestamp { try c.encode(v, forKey: .segmentTimestamp) } else { try c.encodeNil(forKey: .segmentTimestamp) }
        if let v = segmentDuration { try c.encode(v, forKey: .segmentDuration) } else { try c.encodeNil(forKey: .segmentDuration) }
        if let v = voiceAnalytics { try c.encode(v, forKey: .voiceAnalytics) } else { try c.encodeNil(forKey: .voiceAnalytics) }
    }
}

/// §8.3: a request that errors contributes no coverage. Harness-side failures (timeout,
/// feed failure) use the `u4a2.harness.*` domains with code 0.
enum ChunkOutcome: Codable, Equatable, Sendable {
    case succeeded
    case failed(domain: ConstrainedID, code: Int)

    var succeeded: Bool { if case .succeeded = self { return true } else { return false } }
}

/// Why the harness stopped listening (A7: task end, or the post-final grace).
enum ListeningEnd: String, Codable, Sendable {
    case taskCompleted
    case postFinalGraceElapsed
    case errorReceived
    case timedOut
    case feedFailed
}

struct RequestHarvest: Codable, Equatable, Sendable {
    let mapping: RequestInputMapping
    let callbacks: [CallbackAuditEntry]
    let finals: [FinalResultRecord]
    let deprecatedSegmentLevelDiagnostic: [SegmentLevelDiagnostic]
    let chunkOutcome: ChunkOutcome
    /// §8.3: the last final per request wins; every earlier final is superseded.
    let supersededFinalCount: Int
    let listeningEnd: ListeningEnd
    let feedItemsCompleted: Int
    let feedItemCount: Int
    let endAudioCalled: Bool

    /// The only constructor, so `supersededFinalCount` is always derived, never asserted.
    static func assemble(mapping: RequestInputMapping, callbacks: [CallbackAuditEntry],
                         finals: [FinalResultRecord], segmentDiagnostics: [SegmentLevelDiagnostic],
                         outcome: ChunkOutcome, listeningEnd: ListeningEnd,
                         feedItemsCompleted: Int, feedItemCount: Int, endAudioCalled: Bool) -> RequestHarvest {
        RequestHarvest(mapping: mapping, callbacks: callbacks, finals: finals,
                       deprecatedSegmentLevelDiagnostic: segmentDiagnostics, chunkOutcome: outcome,
                       supersededFinalCount: max(0, finals.count - 1), listeningEnd: listeningEnd,
                       feedItemsCompleted: feedItemsCompleted, feedItemCount: feedItemCount,
                       endAudioCalled: endAudioCalled)
    }

    /// The final that counts (§8.3), or nil when none arrived.
    var winningFinal: FinalResultRecord? { finals.last }
}

// MARK: - Capture from a live result (numbers only)

/// What the recognition handler hands across to the harvest loop. Built inside the
/// handler so no `SFSpeechRecognitionResult` ever leaves it.
struct VoiceAnalyticsCallbackSnapshot: Sendable {
    let isFinal: Bool
    let metadata: ResultMetadataDiagnostic?
    let voiceAnalytics: [FeatureArray]?
    let segments: [(timestamp: Double?, duration: Double?, analytics: [FeatureArray]?)]
}

enum VoiceAnalyticsCapture {
    static func featureArrays(_ va: SFVoiceAnalytics) -> [FeatureArray] {
        func arr(_ f: VoiceFeature, _ a: SFAcousticFeature) -> FeatureArray {
            FeatureArray(feature: f, frameDuration: a.frameDuration,
                         rawValues: a.acousticFeatureValuePerFrame)
        }
        return [arr(.pitch, va.pitch), arr(.jitter, va.jitter), arr(.shimmer, va.shimmer), arr(.voicing, va.voicing)]
    }

    private static func finite(_ v: Double) -> Double? { v.isFinite ? v : nil }

    /// Partials yield only their finality. Finals additionally yield the result-level
    /// analytics, the metadata diagnostic, and the deprecated per-segment diagnostic.
    static func snapshot(_ result: SFSpeechRecognitionResult) -> VoiceAnalyticsCallbackSnapshot {
        guard result.isFinal else {
            return VoiceAnalyticsCallbackSnapshot(isFinal: false, metadata: nil, voiceAnalytics: nil, segments: [])
        }
        let md = result.speechRecognitionMetadata
        let metadata = md.map {
            ResultMetadataDiagnostic(speakingRate: finite($0.speakingRate),
                                     averagePauseDuration: finite($0.averagePauseDuration),
                                     speechStartTimestamp: finite($0.speechStartTimestamp),
                                     speechDuration: finite($0.speechDuration))
        }
        let segments = result.bestTranscription.segments.map { s in
            (timestamp: finite(s.timestamp), duration: finite(s.duration),
             analytics: deprecatedSegmentAnalytics(s).map(featureArrays))
        }
        return VoiceAnalyticsCallbackSnapshot(isFinal: true, metadata: metadata,
                                              voiceAnalytics: md?.voiceAnalytics.map(featureArrays),
                                              segments: segments)
    }

    /// The deprecated path, isolated to this one call site (§8.1 compatibility
    /// diagnostic) — its single deprecation warning is expected.
    ///
    /// INTENTIONAL DEPRECATION WARNING — do not "fix". The U4a-2 plan (§8.1 and
    /// the `VoiceAnalyticsHarvest.swift` row of its file table) pre-registers a
    /// separate `deprecatedSegmentLevelDiagnostic` key that reads exactly this
    /// iOS 14.5-deprecated property. Marking this helper `@available(deprecated:)`
    /// would only move the warning to the caller in `snapshot(_:)`, so the
    /// warning is left visible here as the single, documented marker.
    private static func deprecatedSegmentAnalytics(_ s: SFTranscriptionSegment) -> SFVoiceAnalytics? {
        s.voiceAnalytics
    }
}

// MARK: - Harvest file (one per device test, attached as U4a2Harvest-<id>.json)

enum HarvestKind: Codable, Equatable, Sendable {
    case ladderRung(leadingSilenceSeconds: Double, replicateIndex: Int)
    case arm2Fixture
}

enum InputFileRole: String, Codable, Sendable {
    /// A5's passage source — hash required by the director's binding condition.
    case ladderPassageSource
    /// Arm-2 fixtures — hashes strongly recommended by the same ruling.
    case arm2Fixture
}

/// The fixtures are gitignored, so the config hash alone cannot pin them.
struct InputFileHash: Codable, Equatable, Sendable {
    let role: InputFileRole
    let sourceID: SourceID
    let sha256: String?

    enum CodingKeys: String, CodingKey { case role, sourceID, sha256 }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(sourceID, forKey: .sourceID)
        if let v = sha256 { try c.encode(v, forKey: .sha256) } else { try c.encodeNil(forKey: .sha256) }
    }

    static func current(config: U4a2ChannelBConfig) -> [InputFileHash] {
        func hash(_ name: String) -> String? { U4aHarness.fixtureURL(named: name).flatMap(U4aHash.hexOfFile) }
        let passage = config.ladder.passageSource
        return [InputFileHash(role: .ladderPassageSource, sourceID: .fixture(passage), sha256: hash(passage))]
            + config.fit.fixtures.map { InputFileHash(role: .arm2Fixture, sourceID: .fixture($0), sha256: hash($0)) }
    }
}

struct HarvestManifest: Codable, Equatable, Sendable {
    let harvestID: ConstrainedID
    let channelBConfigID: String
    let channelBConfigVersion: String
    let channelBConfigSHA256: String
    let channelBConfigInline: U4a2ChannelBConfig
    let inputFiles: [InputFileHash]
    let recognizerLocale: ConstrainedID
    // Environment fields
    let generatedAtISO8601: String
    let osVersion: String
    let deviceModel: String
    let architecture: String
}

struct U4a2HarvestFile: Codable, Equatable, Sendable {
    let schemaVersion: String
    let manifest: HarvestManifest
    let kind: HarvestKind
    let requests: [RequestHarvest]

    enum Schema { static let version = "u4a2.harvest.1" }

    static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
