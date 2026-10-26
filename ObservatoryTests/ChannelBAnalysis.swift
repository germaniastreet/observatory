import Foundation

// U4a-2 Channel B: pure analysis over harvested records. Deterministic, device-free,
// re-runnable on the simulator from the extracted harvest JSON.
//
//   - A6 ladder classifier        → O-B1 / O-B2 / O-B3 (§8.5)
//   - §8.7 B5 coverage            → per feature, both §8.3 variants, ONLY under O-B1
//   - A8 frame matcher            → independently aligned voiced frames (§8.6)
//   - A9 fit                      → OLS B2 ~ a + b·ln(F0_A), leave-one-fixture-out
//   - descriptive array statistics (the whole of the report under O-B2)
//
// Every number the report carries is a `ChannelBValue`, whose factories enforce the
// shared schema invariant: `value != nil ⟺ status.primary == .valid`, finite only.

// MARK: - Values

/// `SFVoiceAnalytics` documents pitch as "a logarithm" (base/reference unspecified) and
/// does not pin the units of jitter/shimmer/voicing; nothing here converts them.
enum ChannelBUnit: String, Codable, Sendable {
    case rawUnspecifiedLog
    case apiUnspecified
    case seconds
    case ratio
    case count

    static func of(_ f: VoiceFeature) -> ChannelBUnit { f == .pitch ? .rawUnspecifiedLog : .apiUnspecified }
}

enum ChannelBQuantity: String, Codable, CaseIterable, Sendable {
    // Feature-array descriptives (§8.4 / O-B2)
    case arrayCount = "array.count"
    case arrayFrameDuration = "array.frameDurationSeconds"
    case arrayNominalSpan = "array.nominalSpanSeconds"
    case arrayFiniteFraction = "array.finiteFraction"
    case arrayNonFiniteFraction = "array.nonFiniteFraction"
    case arrayExactZeroFraction = "array.exactZeroFraction"
    case arrayValueMin = "array.valueMin"
    case arrayValueP10 = "array.valueP10"
    case arrayValueMedian = "array.valueMedian"
    case arrayValueP90 = "array.valueP90"
    case arrayValueMax = "array.valueMax"
    case arrayValueMean = "array.valueMean"
    // Ladder (A6)
    case rungFedDuration = "ladder.fedDurationSeconds"
    case rungSupersededFinals = "ladder.supersededFinalCount"
    case lagFrames = "ladder.lagFrames"
    case lagSeconds = "ladder.lagSeconds"
    case lagResidual = "ladder.lagResidualSeconds"
    case nccPeak = "ladder.nccPeak"
    case durationResidual = "ladder.durationResidualSeconds"
    case alignmentUncertainty = "ladder.alignmentUncertaintySeconds"
    // B5 (§8.7)
    case b5Coverage = "b5.coverage"
    case b5Numerator = "b5.numeratorSeconds"
    case b5Denominator = "b5.denominatorSeconds"
    case b5AlignmentUncertainty = "b5.alignmentUncertaintySeconds"
    case b5ChannelAVoicedFraction = "b5.channelAVoicedFractionOfDomain"
    case b5ExactZeroFraction = "b5.exactZeroFractionOfUsableFrames"
    case b5FailedRequests = "b5.failedRequestCount"
    // Channel A context
    case channelADomainSeconds = "channelA.domainSeconds"
    case channelAVoicedSeconds = "channelA.voicedSeconds"
    case matchedFrames = "a8.matchedFrameCount"
    // A9 fit
    case fitA = "fit.a"
    case fitB = "fit.b"
    case fitR2 = "fit.r2"
    case fitResidualSD = "fit.residualSD"
    case fitSpearmanRho = "fit.spearmanRho"
    case fitHeldOutRMSE = "fit.heldOutRMSE"
    case fitHeldOutBias = "fit.heldOutBias"
    case fitNFit = "fit.nFit"
    case fitNTest = "fit.nTest"
}

struct ChannelBValue: Codable, Equatable, Sendable {
    let quantity: ChannelBQuantity
    let value: Double?
    let unit: ChannelBUnit
    let status: MeasurementStatus

    private init(quantity: ChannelBQuantity, value: Double?, unit: ChannelBUnit, status: MeasurementStatus) {
        self.quantity = quantity
        self.value = value
        self.unit = unit
        self.status = status
    }

    /// The only way to carry a number. Non-finite input is downgraded, never encoded.
    static func measured(_ v: Double, _ q: ChannelBQuantity, _ u: ChannelBUnit) -> ChannelBValue {
        guard v.isFinite else { return unavailable(.nonFiniteInput(.notFinite), q, u) }
        return ChannelBValue(quantity: q, value: v, unit: u, status: MeasurementStatus(primary: .valid))
    }

    static func unavailable(_ r: UnavailableReason, _ q: ChannelBQuantity, _ u: ChannelBUnit) -> ChannelBValue {
        ChannelBValue(quantity: q, value: nil, unit: u, status: MeasurementStatus(primary: .unavailable(r)))
    }

    static func maybe(_ v: Double?, _ q: ChannelBQuantity, _ u: ChannelBUnit,
                      else reason: UnavailableReason) -> ChannelBValue {
        guard let v else { return unavailable(reason, q, u) }
        return measured(v, q, u)
    }

    enum CodingKeys: String, CodingKey { case quantity, value, unit, status }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(quantity, forKey: .quantity)
        if let value { try c.encode(value, forKey: .value) } else { try c.encodeNil(forKey: .value) }
        try c.encode(unit, forKey: .unit)
        try c.encode(status, forKey: .status)
    }
}

// MARK: - Interval arithmetic (unions, so overlaps count once — §8.3)

struct IntervalSet: Equatable, Sendable {
    struct Interval: Codable, Equatable, Sendable {
        let start: Double
        let end: Double
    }
    let intervals: [Interval]

    init(_ raw: [(Double, Double)]) {
        let sorted = raw.filter { $0.0.isFinite && $0.1.isFinite && $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
        var merged: [Interval] = []
        for (s, e) in sorted {
            if let last = merged.last, s <= last.end {
                merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, e))
            } else {
                merged.append(Interval(start: s, end: e))
            }
        }
        intervals = merged
    }

    static let empty = IntervalSet([])

    var duration: Double { intervals.reduce(0) { $0 + ($1.end - $1.start) } }

    func union(_ other: IntervalSet) -> IntervalSet {
        IntervalSet((intervals + other.intervals).map { ($0.start, $0.end) })
    }

    func intersection(_ other: IntervalSet) -> IntervalSet {
        var out: [(Double, Double)] = []
        var i = 0, j = 0
        let a = intervals, b = other.intervals
        while i < a.count && j < b.count {
            let lo = max(a[i].start, b[j].start), hi = min(a[i].end, b[j].end)
            if hi > lo { out.append((lo, hi)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return IntervalSet(out)
    }
}

// MARK: - Channel A view used by B5 and A8

/// The Channel-A per-hop-slot state and F0 for each analyzable span of one source.
/// Built from U4a-1's `SpanFrames` unchanged; slot i of a span covers
/// [startSeconds + i·hop, startSeconds + (i+1)·hop).
struct ChannelATrack: Sendable {
    struct Span: Sendable {
        let startSeconds: Double
        let hopSeconds: Double
        let states: [FrameState]
        let f0: [Double?]
        var endSeconds: Double { startSeconds + Double(states.count) * hopSeconds }
    }
    let spans: [Span]
    /// Analyzable-domain seconds (the eligible analysis domain, §8.7).
    let domainSeconds: Double

    init(spans: [Span], domainSeconds: Double) {
        self.spans = spans
        self.domainSeconds = domainSeconds
    }

    init(frames: [SpanFrames], domain: AnalysisDomain) {
        spans = frames.map { Span(startSeconds: $0.spanStartSeconds, hopSeconds: $0.hopSeconds,
                                  states: $0.state, f0: $0.f0) }
        domainSeconds = domain.analyzableSeconds
    }

    /// V: the union of Channel-A `voiced` slots inside the analysis domain.
    func voicedIntervals() -> IntervalSet {
        var raw: [(Double, Double)] = []
        for s in spans {
            var runStart: Int?
            for i in 0...s.states.count {
                let voiced = i < s.states.count && s.states[i] == .voiced
                if voiced, runStart == nil { runStart = i }
                if !voiced, let r = runStart {
                    raw.append((s.startSeconds + Double(r) * s.hopSeconds, s.startSeconds + Double(i) * s.hopSeconds))
                    runStart = nil
                }
            }
        }
        return IntervalSet(raw)
    }

    /// The span and slot whose hop interval contains `t`, if any.
    func slot(containing t: Double) -> (span: Int, index: Int)? {
        for (k, s) in spans.enumerated() where t >= s.startSeconds && t < s.endSeconds {
            let i = Int(((t - s.startSeconds) / s.hopSeconds).rounded(.down))
            if i >= 0 && i < s.states.count { return (k, i) }
        }
        return nil
    }
}

// MARK: - Descriptive statistics (§8.4 / O-B2)

struct FeatureDescriptive: Codable, Equatable, Sendable {
    let feature: VoiceFeature
    let values: [ChannelBValue]

    static func of(_ array: FeatureArray?, feature: VoiceFeature) -> FeatureDescriptive {
        let u = ChannelBUnit.of(feature)
        guard let array else {
            return FeatureDescriptive(feature: feature, values: [
                .unavailable(.noAudio, .arrayCount, .count)
            ])
        }
        let finite = array.values.compactMap { $0 }
        let n = Double(array.count)
        let fd = array.frameDuration
        let sorted = finite.sorted()
        func frac(_ k: Int) -> Double? { array.count > 0 ? Double(k) / n : nil }
        let noFinite = UnavailableReason.estimatorFailed(.noEligibleFrames)
        return FeatureDescriptive(feature: feature, values: [
            .measured(n, .arrayCount, .count),
            .maybe(fd, .arrayFrameDuration, .seconds, else: .nonFiniteInput(.notFinite)),
            .maybe(fd.map { n * $0 }, .arrayNominalSpan, .seconds, else: .nonFiniteInput(.notFinite)),
            .maybe(frac(finite.count), .arrayFiniteFraction, .ratio, else: noFinite),
            .maybe(frac(array.nonFiniteCount), .arrayNonFiniteFraction, .ratio, else: noFinite),
            // A 0.0 in an array may encode "unvoiced"; the documentation does not say (§8.7).
            .maybe(frac(finite.filter { $0 == 0 }.count), .arrayExactZeroFraction, .ratio, else: noFinite),
            .maybe(sorted.first, .arrayValueMin, u, else: noFinite),
            .maybe(AcousticAnalyzer.percentile(sorted, 10), .arrayValueP10, u, else: noFinite),
            .maybe(AcousticAnalyzer.median(sorted), .arrayValueMedian, u, else: noFinite),
            .maybe(AcousticAnalyzer.percentile(sorted, 90), .arrayValueP90, u, else: noFinite),
            .maybe(sorted.last, .arrayValueMax, u, else: noFinite),
            .maybe(sorted.isEmpty ? nil : sorted.reduce(0, +) / Double(sorted.count), .arrayValueMean, u, else: noFinite)
        ])
    }
}

// MARK: - A6: the leading-silence ladder

enum RungAvailability: String, Codable, Sendable {
    case available
    case missing
    case failed
    case requestCountMismatch
    case noFinalResult
    case noVoiceAnalytics
}

enum LadderReasonCode: String, Codable, Sendable {
    case noAnalyticsOnAnyRung
    case rungMissing
    case rungFailed
    case rungRequestCountMismatch
    case rungNoFinalResult
    case rungNoVoiceAnalytics
    case referenceRungUnavailable
    case frameDurationInvalid
    case frameDurationMismatch
    case durationDoesNotTrackFedAudio
    case lagUndefined
    case lagDoesNotTrackInsertedSilence
    case featureLagDisagreement
}

struct LadderReason: Codable, Equatable, Hashable, Sendable {
    let code: LadderReasonCode
    let leadingSilenceSeconds: Double?
    let replicateIndex: Int?
    let feature: VoiceFeature?

    enum CodingKeys: String, CodingKey { case code, leadingSilenceSeconds, replicateIndex, feature }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(code, forKey: .code)
        if let v = leadingSilenceSeconds { try c.encode(v, forKey: .leadingSilenceSeconds) } else { try c.encodeNil(forKey: .leadingSilenceSeconds) }
        if let v = replicateIndex { try c.encode(v, forKey: .replicateIndex) } else { try c.encodeNil(forKey: .replicateIndex) }
        if let v = feature { try c.encode(v, forKey: .feature) } else { try c.encodeNil(forKey: .feature) }
    }
}

struct LadderRungInput: Sendable {
    let leadingSilenceSeconds: Double
    let replicateIndex: Int
    let harvestID: ConstrainedID
    let requests: [RequestHarvest]
}

struct RungFeatureAssessment: Codable, Equatable, Sendable {
    let feature: VoiceFeature
    let descriptive: FeatureDescriptive
    let durationResidual: ChannelBValue
    /// Lag against the reference rung; unavailable for the reference itself.
    let lagFrames: ChannelBValue
    let lagSeconds: ChannelBValue
    let lagResidual: ChannelBValue
    let nccPeak: ChannelBValue
}

struct RungAssessment: Codable, Equatable, Sendable {
    let leadingSilenceSeconds: Double
    let replicateIndex: Int
    let isReference: Bool
    /// Rule (i) applies to k ∈ {5, 10, 20} only; the replicate's lag enters the
    /// uncertainty but is not a pass/fail condition (A6 as ruled).
    let lagRuleApplies: Bool
    let availability: RungAvailability
    let chunkOutcome: ChunkOutcome?
    let listeningEnd: ListeningEnd?
    let fedDuration: ChannelBValue
    let supersededFinals: ChannelBValue
    let features: [RungFeatureAssessment]

    enum CodingKeys: String, CodingKey {
        case leadingSilenceSeconds, replicateIndex, isReference, lagRuleApplies, availability
        case chunkOutcome, listeningEnd, fedDuration, supersededFinals, features
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(leadingSilenceSeconds, forKey: .leadingSilenceSeconds)
        try c.encode(replicateIndex, forKey: .replicateIndex)
        try c.encode(isReference, forKey: .isReference)
        try c.encode(lagRuleApplies, forKey: .lagRuleApplies)
        try c.encode(availability, forKey: .availability)
        if let v = chunkOutcome { try c.encode(v, forKey: .chunkOutcome) } else { try c.encodeNil(forKey: .chunkOutcome) }
        if let v = listeningEnd { try c.encode(v, forKey: .listeningEnd) } else { try c.encodeNil(forKey: .listeningEnd) }
        try c.encode(fedDuration, forKey: .fedDuration)
        try c.encode(supersededFinals, forKey: .supersededFinals)
        try c.encode(features, forKey: .features)
    }
}

struct LadderAssessment: Codable, Equatable, Sendable {
    let outcome: ChannelBOutcome
    let reasons: [LadderReason]
    let rungs: [RungAssessment]
    /// Valid only under O-B1. The measured residual carried on every Channel-B
    /// measurement (§8.5), floored at one frameDuration (A6).
    let alignmentUncertainty: ChannelBValue
    /// Adopted ONLY for this device/OS/SDK/configuration (§8.5 O-B1).
    let scopeStatement: AlignmentScopeStatement
}

enum AlignmentScopeStatement: String, Codable, Sendable {
    case anchorAAdoptedForThisConfigurationOnly =
        "anchor (a) adopted for this device/OS/SDK/configuration only; consistent with contiguity, never proof of it"
    case alignmentUnresolved =
        "alignment unresolved; B5 and all frame-wise A/B comparison unavailable; descriptive statistics only"
    case noAnalyticsReturned =
        "no SFVoiceAnalytics were returned on any rung"
}

enum ChannelBAnalysis {

    /// Normalized cross-correlation lag of `y` against reference `x`, over the FULL lag
    /// range (A6: never centred on the predicted shift). Each series is mean-removed
    /// over its finite frames and normalised by its own full-length energy (the
    /// classic "coeff" normalisation), so small overlaps at extreme lags are penalised
    /// without an extra, unregistered minimum-overlap parameter. Non-finite frames are
    /// excluded from every sum (A6 `excludeFrameFromCorrelation`). A positive lag means
    /// `y`'s content sits later than `x`'s. Ties resolve to the smallest lag.
    static func nccLag(reference x: [Double?], shifted y: [Double?]) -> (lag: Int, peak: Double)? {
        func centred(_ s: [Double?]) -> ([Double], [Bool], Double)? {
            let f = s.compactMap { $0 }
            guard !f.isEmpty else { return nil }
            let mean = f.reduce(0, +) / Double(f.count)
            let values = s.map { ($0 ?? mean) - mean }
            let mask = s.map { $0 != nil }
            let energy = zip(values, mask).reduce(0) { $0 + ($1.1 ? $1.0 * $1.0 : 0) }
            return (values, mask, energy)
        }
        guard let cx = centred(x), let cy = centred(y), cx.2 > 0, cy.2 > 0 else { return nil }
        let (xv, xm, xe) = cx, (yv, ym, ye) = cy
        let norm = (xe * ye).squareRoot()
        var best: (lag: Int, peak: Double)?
        for lag in (-(xv.count - 1))...(yv.count - 1) {
            let iLo = max(0, -lag), iHi = min(xv.count, yv.count - lag)
            guard iHi > iLo else { continue }
            var sum = 0.0
            for i in iLo..<iHi where xm[i] && ym[i + lag] { sum += xv[i] * yv[i + lag] }
            let r = sum / norm
            if best == nil || r > best!.peak { best = (lag, r) }
        }
        return best
    }

    /// A6 as ruled. O-B1 can only be reached, never argued into: every expected rung must
    /// be present and succeeded with analytics; (ii) every rung × feature array duration
    /// tracks the fed duration within `durationToleranceFrames`; (i) each k ∈ {5,10,20}
    /// voicing lag tracks k within `lagToleranceFrames`; (iii) voicing and pitch lags
    /// agree within `lagToleranceFrames` on every lagged rung (the replicate included).
    static func classifyLadder(_ inputs: [LadderRungInput], config: U4a2ChannelBConfig) -> LadderAssessment {
        let ladder = config.ladder, align = config.alignment
        let features = config.coverage.features
        let reference = align.referenceRung

        // Expected rungs: every leading-silence value once, plus each replicate.
        var expected: [(k: Double, rep: Int)] = ladder.leadingSilenceSeconds.map { ($0, 0) }
        for r in ladder.replicateRungs {
            let prior = expected.filter { $0.k == r }.count
            expected.append((r, prior))
        }

        func find(_ k: Double, _ rep: Int) -> LadderRungInput? {
            inputs.first { $0.leadingSilenceSeconds == k && $0.replicateIndex == rep }
        }
        func availability(_ input: LadderRungInput?) -> RungAvailability {
            guard let input else { return .missing }
            guard input.requests.count == config.requestLifecycle.ladderRequestsPerRung else { return .requestCountMismatch }
            guard let req = input.requests.first else { return .missing }
            guard req.chunkOutcome.succeeded else { return .failed }
            guard let final = req.winningFinal else { return .noFinalResult }
            return final.voiceAnalytics == nil ? .noVoiceAnalytics : .available
        }
        func winningArrays(_ input: LadderRungInput?) -> [VoiceFeature: FeatureArray] {
            guard let input, let final = input.requests.first?.winningFinal,
                  let arrays = final.voiceAnalytics else { return [:] }
            return Dictionary(arrays.map { ($0.feature, $0) }, uniquingKeysWith: { a, _ in a })
        }

        var reasons = Set<LadderReason>()
        func flag(_ code: LadderReasonCode, _ k: Double? = nil, _ rep: Int? = nil, _ f: VoiceFeature? = nil) {
            reasons.insert(LadderReason(code: code, leadingSilenceSeconds: k, replicateIndex: rep, feature: f))
        }

        // Analytics returned anywhere at all? Any final on any request counts.
        let anyAnalytics = inputs.contains { $0.requests.contains { $0.finals.contains { $0.voiceAnalytics != nil } } }

        let refInput = find(reference, 0)
        let refArrays = availability(refInput) == .available ? winningArrays(refInput) : [:]
        if refArrays.isEmpty { flag(.referenceRungUnavailable, reference, 0) }

        var uncertaintyTerms: [Double] = []
        var frameDurations: [Double] = []
        var rungs: [RungAssessment] = []

        for (k, rep) in expected {
            let input = find(k, rep)
            let avail = availability(input)
            switch avail {
            case .available: break
            case .missing: flag(.rungMissing, k, rep)
            case .failed: flag(.rungFailed, k, rep)
            case .requestCountMismatch: flag(.rungRequestCountMismatch, k, rep)
            case .noFinalResult: flag(.rungNoFinalResult, k, rep)
            case .noVoiceAnalytics: flag(.rungNoVoiceAnalytics, k, rep)
            }
            let request = input?.requests.first
            let isReference = (k == reference && rep == 0)
            let lagRuleApplies = !isReference && k != reference
            let arrays = avail == .available ? winningArrays(input) : [:]
            let fed = request?.mapping.fedDurationSeconds

            var lags: [VoiceFeature: Int] = [:]
            var featureAssessments: [RungFeatureAssessment] = []
            for f in features {
                let arr = arrays[f]
                let fd = arr?.frameDuration
                var durationResidual = ChannelBValue.unavailable(.noAudio, .durationResidual, .seconds)
                if avail == .available {
                    if let fd, fd > 0, let fed, let arr {
                        frameDurations.append(fd)
                        let residual = abs(Double(arr.count) * fd - fed)
                        durationResidual = .measured(residual, .durationResidual, .seconds)
                        uncertaintyTerms.append(residual)
                        if residual > align.durationToleranceFrames * fd { flag(.durationDoesNotTrackFedAudio, k, rep, f) }
                    } else {
                        flag(.frameDurationInvalid, k, rep, f)
                    }
                }

                var lagFrames = ChannelBValue.unavailable(.alignmentUnresolved, .lagFrames, .count)
                var lagSeconds = ChannelBValue.unavailable(.alignmentUnresolved, .lagSeconds, .seconds)
                var lagResidual = ChannelBValue.unavailable(.alignmentUnresolved, .lagResidual, .seconds)
                var peak = ChannelBValue.unavailable(.alignmentUnresolved, .nccPeak, .ratio)
                let correlated = f == align.primaryFeature || f == align.corroboratingFeature
                if correlated, !isReference, avail == .available, let arr, let fd, fd > 0,
                   let ref = refArrays[f], let refFd = ref.frameDuration {
                    if abs(refFd - fd) > 1e-12 {
                        flag(.frameDurationMismatch, k, rep, f)
                    } else if let r = nccLag(reference: ref.values, shifted: arr.values) {
                        lags[f] = r.lag
                        let seconds = Double(r.lag) * fd
                        let residual = abs(seconds - (k - reference))
                        lagFrames = .measured(Double(r.lag), .lagFrames, .count)
                        lagSeconds = .measured(seconds, .lagSeconds, .seconds)
                        lagResidual = .measured(residual, .lagResidual, .seconds)
                        peak = .measured(r.peak, .nccPeak, .ratio)
                        uncertaintyTerms.append(residual)
                        // Rule (i) is on the PRIMARY feature only.
                        if lagRuleApplies, f == align.primaryFeature, residual > align.lagToleranceFrames * fd {
                            flag(.lagDoesNotTrackInsertedSilence, k, rep, f)
                        }
                    } else {
                        flag(.lagUndefined, k, rep, f)
                    }
                } else if correlated, !isReference, avail == .available, !refArrays.isEmpty {
                    flag(.lagUndefined, k, rep, f)
                }
                featureAssessments.append(RungFeatureAssessment(
                    feature: f, descriptive: .of(arr, feature: f), durationResidual: durationResidual,
                    lagFrames: lagFrames, lagSeconds: lagSeconds, lagResidual: lagResidual, nccPeak: peak))
            }
            // Rule (iii)
            if !isReference, let lv = lags[align.primaryFeature], let lp = lags[align.corroboratingFeature],
               Double(abs(lv - lp)) > align.lagToleranceFrames {
                flag(.featureLagDisagreement, k, rep)
            }

            rungs.append(RungAssessment(
                leadingSilenceSeconds: k, replicateIndex: rep, isReference: isReference,
                lagRuleApplies: lagRuleApplies, availability: avail,
                chunkOutcome: request?.chunkOutcome, listeningEnd: request?.listeningEnd,
                fedDuration: .maybe(fed, .rungFedDuration, .seconds, else: .noAudio),
                supersededFinals: .maybe(request.map { Double($0.supersededFinalCount) },
                                         .rungSupersededFinals, .count, else: .noAudio),
                features: featureAssessments))
        }

        let outcome: ChannelBOutcome
        let finalReasons: [LadderReason]
        if !anyAnalytics {
            outcome = align.noAnalyticsOnAnyRungOutcome
            finalReasons = [LadderReason(code: .noAnalyticsOnAnyRung, leadingSilenceSeconds: nil,
                                         replicateIndex: nil, feature: nil)]
        } else if reasons.isEmpty {
            outcome = .alignmentSupported
            finalReasons = []
        } else {
            // Each reason maps through the config field that names it; tracking failures
            // (duration, lag, undefined lag) are O-B2 by §8.5's own table. Under the
            // frozen config every path is O-B2; O-B3 would win if a field ever said so.
            let mapped: [ChannelBOutcome] = reasons.map { r in
                switch r.code {
                case .featureLagDisagreement: return align.featureLagDisagreementOutcome
                case .rungMissing, .rungFailed, .rungRequestCountMismatch, .rungNoFinalResult,
                     .rungNoVoiceAnalytics, .referenceRungUnavailable: return align.missingOrFailedRungOutcome
                case .noAnalyticsOnAnyRung: return align.noAnalyticsOnAnyRungOutcome
                case .frameDurationInvalid, .frameDurationMismatch, .durationDoesNotTrackFedAudio,
                     .lagUndefined, .lagDoesNotTrackInsertedSilence: return .alignmentUnresolved
                }
            }
            // A failure can never yield O-B1, whatever a config field says.
            outcome = mapped.contains(.noAnalyticsReturned) ? .noAnalyticsReturned : .alignmentUnresolved
            finalReasons = reasons.sorted {
                ($0.code.rawValue, $0.leadingSilenceSeconds ?? -1, $0.replicateIndex ?? -1, $0.feature?.rawValue ?? "")
                    < ($1.code.rawValue, $1.leadingSilenceSeconds ?? -1, $1.replicateIndex ?? -1, $1.feature?.rawValue ?? "")
            }
        }

        let uncertainty: ChannelBValue
        if outcome == .alignmentSupported, let floor = frameDurations.max() {
            uncertainty = .measured(max(floor, uncertaintyTerms.max() ?? 0), .alignmentUncertainty, .seconds)
        } else {
            uncertainty = .unavailable(.alignmentUnresolved, .alignmentUncertainty, .seconds)
        }
        let scope: AlignmentScopeStatement = switch outcome {
        case .alignmentSupported: .anchorAAdoptedForThisConfigurationOnly
        case .alignmentUnresolved: .alignmentUnresolved
        case .noAnalyticsReturned: .noAnalyticsReturned
        }
        return LadderAssessment(outcome: outcome, reasons: finalReasons, rungs: rungs,
                                alignmentUncertainty: uncertainty, scopeStatement: scope)
    }

    // MARK: §8.7 B5

    /// Source-file intervals where feature `f` is usable (present and finite), under
    /// anchor (a), from the winning final of every SUCCEEDED request.
    static func usableIntervals(_ requests: [RequestHarvest], feature f: VoiceFeature)
        -> (set: IntervalSet, usableFrames: Int, exactZeroFrames: Int) {
        var raw: [(Double, Double)] = []
        var usable = 0, zeros = 0
        for req in requests where req.chunkOutcome.succeeded {
            guard let arr = req.winningFinal?.array(f), let fd = arr.frameDuration, fd > 0 else { continue }
            for (j, v) in arr.values.enumerated() {
                guard let v else { continue }
                usable += 1
                if v == 0 { zeros += 1 }
                raw += req.mapping.sourceIntervals(fedStart: Double(j) * fd, fedEnd: Double(j + 1) * fd)
            }
        }
        return (IntervalSet(raw), usable, zeros)
    }

    static func processedIntervals(_ requests: [RequestHarvest]) -> IntervalSet {
        IntervalSet(requests.filter { $0.chunkOutcome.succeeded }.flatMap { $0.mapping.fedSourceIntervals })
    }

    static func coverage(channelA: ChannelATrack, requests: [RequestHarvest],
                         ladder: LadderAssessment, config: U4a2ChannelBConfig) -> [B5Record] {
        let v = channelA.voicedIntervals()
        let failed = Double(requests.filter { !$0.chunkOutcome.succeeded }.count)
        let processed = processedIntervals(requests)
        let voicedFraction: ChannelBValue = channelA.domainSeconds > 0
            ? .measured(v.duration / channelA.domainSeconds, .b5ChannelAVoicedFraction, .ratio)
            : .unavailable(.estimatorFailed(.noEligibleFrames), .b5ChannelAVoicedFraction, .ratio)
        var records: [B5Record] = []
        for f in config.coverage.features {
            let usable = usableIntervals(requests, feature: f)
            for variant in config.coverage.variants {
                let denominatorSet = variant == .wholeEligibleDomain ? v : v.intersection(processed)
                let base = (feature: f, variant: variant)
                guard ladder.outcome == .alignmentSupported else {
                    let r = UnavailableReason.alignmentUnresolved
                    records.append(B5Record(
                        feature: base.feature, variant: base.variant,
                        coverage: .unavailable(r, .b5Coverage, .ratio),
                        numerator: .unavailable(r, .b5Numerator, .seconds),
                        denominator: .measured(denominatorSet.duration, .b5Denominator, .seconds),
                        alignmentUncertainty: ladder.alignmentUncertainty.relabelled(.b5AlignmentUncertainty),
                        channelAVoicedFraction: voicedFraction,
                        exactZeroFraction: .unavailable(r, .b5ExactZeroFraction, .ratio),
                        failedRequests: .measured(failed, .b5FailedRequests, .count),
                        statement: .coverageOfADetectedVoicedAudio))
                    continue
                }
                let numerator = denominatorSet.intersection(usable.set).duration
                let denominator = denominatorSet.duration
                records.append(B5Record(
                    feature: f, variant: variant,
                    // §8.7: dur(V) == 0 ⇒ nil; positive denominator with zero overlap ⇒ a legitimate 0.0.
                    coverage: denominator > 0
                        ? .measured(numerator / denominator, .b5Coverage, .ratio)
                        : .unavailable(.estimatorFailed(.noEligibleFrames), .b5Coverage, .ratio),
                    numerator: .measured(numerator, .b5Numerator, .seconds),
                    denominator: .measured(denominator, .b5Denominator, .seconds),
                    alignmentUncertainty: ladder.alignmentUncertainty.relabelled(.b5AlignmentUncertainty),
                    channelAVoicedFraction: voicedFraction,
                    exactZeroFraction: usable.usableFrames > 0
                        ? .measured(Double(usable.exactZeroFrames) / Double(usable.usableFrames), .b5ExactZeroFraction, .ratio)
                        : .unavailable(.estimatorFailed(.noEligibleFrames), .b5ExactZeroFraction, .ratio),
                    failedRequests: .measured(failed, .b5FailedRequests, .count),
                    statement: .coverageOfADetectedVoicedAudio))
            }
        }
        return records
    }

    // MARK: A8 frame matching

    struct MatchedFrame: Equatable, Sendable {
        let f0Hz: Double
        let b2: Double
    }

    /// A8: each B pitch frame centre → the Channel-A hop slot containing it. Used only if
    /// A is `voiced` with an F0, B is finite, and A is voiced throughout
    /// ± max(alignmentUncertaintySeconds, B frameDuration) inside the same span. Returns
    /// nothing unless the ladder reached O-B1.
    static func matchFrames(channelA: ChannelATrack, requests: [RequestHarvest],
                            ladder: LadderAssessment) -> (frames: [MatchedFrame], bFrameDuration: Double?) {
        guard ladder.outcome == .alignmentSupported, let uncertainty = ladder.alignmentUncertainty.value else {
            return ([], nil)
        }
        var out: [MatchedFrame] = []
        var fdSeen: Double?
        for req in requests where req.chunkOutcome.succeeded {
            guard let arr = req.winningFinal?.array(.pitch), let fd = arr.frameDuration, fd > 0 else { continue }
            fdSeen = fdSeen ?? fd
            let guardSeconds = max(uncertainty, fd)
            for (j, value) in arr.values.enumerated() {
                guard let b2 = value,
                      let t = req.mapping.sourceTime(fedTime: (Double(j) + 0.5) * fd),
                      let slot = channelA.slot(containing: t) else { continue }
                let span = channelA.spans[slot.span], i = slot.index
                guard span.states[i] == .voiced, let f0 = span.f0[i], f0 > 0 else { continue }
                let lo = t - guardSeconds, hi = t + guardSeconds
                guard lo >= span.startSeconds, hi <= span.endSeconds else { continue }
                let first = Int(((lo - span.startSeconds) / span.hopSeconds).rounded(.down))
                let last = Int(((hi - span.startSeconds) / span.hopSeconds).rounded(.up)) - 1
                guard first >= 0, last < span.states.count,
                      (first...last).allSatisfy({ span.states[$0] == .voiced }) else { continue }
                out.append(MatchedFrame(f0Hz: f0, b2: b2))
            }
        }
        return (out, fdSeen)
    }

    // MARK: A9 fit

    static func olsLog(_ frames: [MatchedFrame]) -> (a: Double, b: Double, r2: Double?, residualSD: Double?)? {
        let n = Double(frames.count)
        guard frames.count >= 2 else { return nil }
        let x = frames.map { log($0.f0Hz) }, y = frames.map(\.b2)
        let mx = x.reduce(0, +) / n, my = y.reduce(0, +) / n
        let sxx = x.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let b = sxy / sxx, a = my - b * mx
        let sse = zip(x, y).reduce(0) { $0 + pow($1.1 - (a + b * $1.0), 2) }
        let sst = y.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        return (a, b, sst > 0 ? 1 - sse / sst : nil, frames.count > 2 ? (sse / (n - 2)).squareRoot() : nil)
    }

    static func ranks(_ v: [Double]) -> [Double] {
        let order = v.indices.sorted { v[$0] < v[$1] }
        var r = [Double](repeating: 0, count: v.count)
        var i = 0
        while i < order.count {
            var j = i
            while j + 1 < order.count && v[order[j + 1]] == v[order[i]] { j += 1 }
            let avg = Double(i + j) / 2 + 1
            for k in i...j { r[order[k]] = avg }
            i = j + 1
        }
        return r
    }

    static func spearman(_ frames: [MatchedFrame]) -> Double? {
        guard frames.count >= 2 else { return nil }
        let rx = ranks(frames.map { log($0.f0Hz) }), ry = ranks(frames.map(\.b2))
        let n = Double(frames.count)
        let mx = rx.reduce(0, +) / n, my = ry.reduce(0, +) / n
        let sxy = zip(rx, ry).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let sxx = rx.reduce(0) { $0 + ($1 - mx) * ($1 - mx) }
        let syy = ry.reduce(0) { $0 + ($1 - my) * ($1 - my) }
        guard sxx > 0, syy > 0 else { return nil }
        return sxy / (sxx * syy).squareRoot()
    }

    /// A9: OLS B2 = a + b·ln(F0_A Hz), all three leave-one-fixture-out rotations. A
    /// rotation is available only when EVERY fixture it uses (two to fit, one to test)
    /// has at least `minimumMatchedFramesPerFixture` matched frames — conservative, since
    /// each rotation touches all three fixtures. B2 stays `.rawUnspecifiedLog`.
    static func fit(perFixture: [String: [MatchedFrame]], bFrameDuration: Double?,
                    ladder: LadderAssessment, config: U4a2ChannelBConfig) -> FitAssessment {
        let minimum = config.fit.minimumMatchedFramesPerFixture
        let fixtures = config.fit.fixtures
        let counts = fixtures.map { (fixture: ConstrainedID.trusted($0),
                                     matched: ChannelBValue.measured(Double(perFixture[$0]?.count ?? 0), .matchedFrames, .count)) }
        var rotations: [FitRotation] = []
        for heldOut in fixtures {
            let train = fixtures.filter { $0 != heldOut }.flatMap { perFixture[$0] ?? [] }
            let test = perFixture[heldOut] ?? []
            let nFit = ChannelBValue.measured(Double(train.count), .fitNFit, .count)
            let nTest = ChannelBValue.measured(Double(test.count), .fitNTest, .count)
            let u = ChannelBUnit.rawUnspecifiedLog
            func allUnavailable(_ r: UnavailableReason) -> [ChannelBValue] {
                [.unavailable(r, .fitA, u), .unavailable(r, .fitB, u), .unavailable(r, .fitR2, .ratio),
                 .unavailable(r, .fitResidualSD, u), .unavailable(r, .fitSpearmanRho, .ratio),
                 .unavailable(r, .fitHeldOutRMSE, u), .unavailable(r, .fitHeldOutBias, u), nFit, nTest]
            }
            guard ladder.outcome == .alignmentSupported else {
                rotations.append(FitRotation(heldOut: .trusted(heldOut), values: allUnavailable(.alignmentUnresolved)))
                continue
            }
            let smallest = fixtures.map { perFixture[$0]?.count ?? 0 }.min() ?? 0
            guard smallest >= minimum else {
                let fd = bFrameDuration ?? 0
                rotations.append(FitRotation(heldOut: .trusted(heldOut), values: allUnavailable(
                    .insufficientEligibleSeconds(eligible: Double(smallest) * fd, required: Double(minimum) * fd))))
                continue
            }
            guard let model = olsLog(train) else {
                rotations.append(FitRotation(heldOut: .trusted(heldOut),
                                             values: allUnavailable(.estimatorFailed(.insufficientSupport))))
                continue
            }
            let errors = test.map { (model.a + model.b * log($0.f0Hz)) - $0.b2 }
            let rmse = (errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)).squareRoot()
            let bias = errors.reduce(0, +) / Double(errors.count)
            let insufficient = UnavailableReason.estimatorFailed(.insufficientSupport)
            rotations.append(FitRotation(heldOut: .trusted(heldOut), values: [
                .measured(model.a, .fitA, u), .measured(model.b, .fitB, u),
                .maybe(model.r2, .fitR2, .ratio, else: insufficient),
                .maybe(model.residualSD, .fitResidualSD, u, else: insufficient),
                .maybe(spearman(train), .fitSpearmanRho, .ratio, else: insufficient),
                .measured(rmse, .fitHeldOutRMSE, u), .measured(bias, .fitHeldOutBias, u), nFit, nTest
            ]))
        }
        return FitAssessment(matchedFramesPerFixture: counts.map { FixtureCount(fixture: $0.fixture, matched: $0.matched) },
                             rotations: rotations, statement: .channelAErrorBoundsComparison)
    }
}

extension ChannelBValue {
    /// Same value and status under a different quantity id (uncertainty carried onto B5).
    func relabelled(_ q: ChannelBQuantity) -> ChannelBValue {
        if let value { return .measured(value, q, unit) }
        if case .unavailable(let r) = status.primary { return .unavailable(r, q, unit) }
        return .unavailable(.alignmentUnresolved, q, unit)
    }
}

// MARK: - Report records

enum CoverageStatement: String, Codable, Sendable {
    case coverageOfADetectedVoicedAudio = "coverage of A-detected voiced audio, not of all human speech"
}

enum FitStatement: String, Codable, Sendable {
    case channelAErrorBoundsComparison =
        "Channel A's own error bounds what this comparison can establish; an empirical mapping for this API/device/OS/configuration, never proof of Apple's unit definition"
}

struct B5Record: Codable, Equatable, Sendable {
    let feature: VoiceFeature
    let variant: CoverageVariant
    let coverage: ChannelBValue
    let numerator: ChannelBValue
    let denominator: ChannelBValue
    let alignmentUncertainty: ChannelBValue
    let channelAVoicedFraction: ChannelBValue
    let exactZeroFraction: ChannelBValue
    let failedRequests: ChannelBValue
    let statement: CoverageStatement
}

struct FitRotation: Codable, Equatable, Sendable {
    let heldOut: ConstrainedID
    let values: [ChannelBValue]
}

struct FixtureCount: Codable, Equatable, Sendable {
    let fixture: ConstrainedID
    let matched: ChannelBValue
}

struct FitAssessment: Codable, Equatable, Sendable {
    let matchedFramesPerFixture: [FixtureCount]
    let rotations: [FitRotation]
    let statement: FitStatement
}

struct RequestSummary: Codable, Equatable, Sendable {
    let requestIndex: Int
    let fedSourceStartSample: Int64
    let fedSourceEndSample: Int64
    let chunkOutcome: ChunkOutcome
    let listeningEnd: ListeningEnd
    let callbackCount: Int
    let finalCount: Int
    let supersededFinalCount: Int
    let winningFinalHasAnalytics: Bool

    init(_ r: RequestHarvest) {
        requestIndex = r.mapping.requestIndex
        fedSourceStartSample = r.mapping.fedSourceStartSample
        fedSourceEndSample = r.mapping.fedSourceEndSample
        chunkOutcome = r.chunkOutcome
        listeningEnd = r.listeningEnd
        callbackCount = r.callbacks.count
        finalCount = r.finals.count
        supersededFinalCount = r.supersededFinalCount
        winningFinalHasAnalytics = r.winningFinal?.voiceAnalytics != nil
    }
}

struct Arm2FixtureAssessment: Codable, Equatable, Sendable {
    let sourceID: SourceID
    let requests: [RequestSummary]
    let channelADomainSeconds: ChannelBValue
    let channelAVoicedSeconds: ChannelBValue
    let coverage: [B5Record]
    let matchedFrames: ChannelBValue
    /// Per-request, per-feature descriptives of the winning finals (all that O-B2 permits).
    let descriptive: [[FeatureDescriptive]]
}

enum AssessmentStatus: String, Codable, Sendable {
    case deviceResultsAbsent
    case assessed
}

enum Arm2Status: String, Codable, Sendable {
    case notAssessedNoLadder
    case notRunAlignmentGate
    case noHarvests
    case assessed
}

struct HarvestReference: Codable, Equatable, Sendable {
    let harvestID: ConstrainedID
    let kind: HarvestKind
    let harvestFileSHA256: String
    let configSHA256MatchesThisRun: Bool
    let inputHashesMatchThisRun: Bool
    let deviceModel: String
    let deviceOSVersion: String
    let generatedAtISO8601: String
}

struct ChannelBReportManifest: Codable, Equatable, Sendable {
    /// The U4a-1 manifest for the Channel-A side, unchanged.
    let channelA: RunManifest
    let channelBConfigID: String
    let channelBConfigVersion: String
    let channelBConfigSHA256: String
    let channelBConfigInline: U4a2ChannelBConfig
    /// Hashed on THIS machine, compared with what each harvest recorded on device.
    let inputFiles: [InputFileHash]
    let harvests: [HarvestReference]
    let undecodableFileCount: Int
    let duplicateHarvestIDs: [ConstrainedID]
}

struct U4a2ChannelBReport: Codable, Equatable, Sendable {
    let schemaVersion: String
    let manifest: ChannelBReportManifest
    let status: AssessmentStatus
    let ladder: LadderAssessment?
    let arm2Status: Arm2Status
    let arm2: [Arm2FixtureAssessment]
    let fit: FitAssessment?

    enum Schema { static let version = "u4a2.report.1" }

    enum CodingKeys: String, CodingKey { case schemaVersion, manifest, status, ladder, arm2Status, arm2, fit }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(manifest, forKey: .manifest)
        try c.encode(status, forKey: .status)
        if let v = ladder { try c.encode(v, forKey: .ladder) } else { try c.encodeNil(forKey: .ladder) }
        try c.encode(arm2Status, forKey: .arm2Status)
        try c.encode(arm2, forKey: .arm2)
        if let v = fit { try c.encode(v, forKey: .fit) } else { try c.encodeNil(forKey: .fit) }
    }

    func encoded(pretty: Bool = true) throws -> Data {
        try U4aMeasurementReport.encoder(pretty: pretty).encode(self)
    }
}

// MARK: - Assessment assembly (pure; Channel A injected so synthetic tests share this path)

extension ChannelBAnalysis {
    /// Builds `U4a2ChannelBReport` from decoded harvest files. A harvest is EXCLUDED from
    /// analysis (and its rung then counts as missing ⇒ O-B2) when its recorded config
    /// hash or input-file hashes differ from this run's, or when its harvest id appears
    /// more than once — results that cannot be tied to the pre-registered inputs are not
    /// argued into an outcome.
    static func assemble(harvests: [(file: U4a2HarvestFile, sha256: String)], undecodableFileCount: Int,
                         loaded: LoadedChannelBConfig, channelAManifest: RunManifest,
                         inputFiles: [InputFileHash],
                         channelA: (String) throws -> ChannelATrack?) rethrows -> U4a2ChannelBReport {
        let config = loaded.config
        let idCounts = Dictionary(harvests.map { ($0.file.manifest.harvestID, 1) }, uniquingKeysWith: +)
        let duplicates = idCounts.filter { $0.value > 1 }.map(\.key).sorted { $0.rawValue < $1.rawValue }

        func inputsMatch(_ recorded: [InputFileHash]) -> Bool {
            inputFiles.allSatisfy { mine in
                guard let ours = mine.sha256 else { return false }
                return recorded.contains { $0.role == mine.role && $0.sourceID == mine.sourceID && $0.sha256 == ours }
            }
        }
        var references: [HarvestReference] = []
        var usable: [U4a2HarvestFile] = []
        for (file, sha) in harvests {
            let m = file.manifest
            let configOK = m.channelBConfigSHA256 == loaded.sha256
            let inputsOK = inputsMatch(m.inputFiles)
            references.append(HarvestReference(
                harvestID: m.harvestID, kind: file.kind, harvestFileSHA256: sha,
                configSHA256MatchesThisRun: configOK, inputHashesMatchThisRun: inputsOK,
                deviceModel: m.deviceModel, deviceOSVersion: m.osVersion, generatedAtISO8601: m.generatedAtISO8601))
            if configOK, inputsOK, file.schemaVersion == U4a2HarvestFile.Schema.version,
               (idCounts[m.harvestID] ?? 0) == 1 {
                usable.append(file)
            }
        }
        references.sort { $0.harvestID.rawValue < $1.harvestID.rawValue }

        let ladderInputs: [LadderRungInput] = usable.compactMap { f in
            guard case .ladderRung(let k, let rep) = f.kind else { return nil }
            return LadderRungInput(leadingSilenceSeconds: k, replicateIndex: rep,
                                   harvestID: f.manifest.harvestID, requests: f.requests)
        }
        let anyLadderHarvest = harvests.contains { if case .ladderRung = $0.file.kind { return true } else { return false } }
        let ladder = anyLadderHarvest ? classifyLadder(ladderInputs, config: config) : nil

        let arm2Files = usable.filter { $0.kind == .arm2Fixture }
        var arm2: [Arm2FixtureAssessment] = []
        var matched: [String: [MatchedFrame]] = [:]
        var bFrameDuration: Double?
        if let ladder {
            for fixture in config.fit.fixtures {
                guard let f = arm2Files.first(where: { $0.requests.first?.mapping.sourceID == .fixture(fixture) }),
                      let track = try channelA(fixture) else { continue }
                let match = matchFrames(channelA: track, requests: f.requests, ladder: ladder)
                matched[fixture] = match.frames
                bFrameDuration = bFrameDuration ?? match.bFrameDuration
                arm2.append(Arm2FixtureAssessment(
                    sourceID: .fixture(fixture),
                    requests: f.requests.map(RequestSummary.init),
                    channelADomainSeconds: .measured(track.domainSeconds, .channelADomainSeconds, .seconds),
                    channelAVoicedSeconds: .measured(track.voicedIntervals().duration, .channelAVoicedSeconds, .seconds),
                    coverage: coverage(channelA: track, requests: f.requests, ladder: ladder, config: config),
                    matchedFrames: ladder.outcome == .alignmentSupported
                        ? .measured(Double(match.frames.count), .matchedFrames, .count)
                        : .unavailable(.alignmentUnresolved, .matchedFrames, .count),
                    descriptive: f.requests.map { r in
                        config.coverage.features.map { FeatureDescriptive.of(r.winningFinal?.array($0), feature: $0) }
                    }))
            }
        }
        let arm2Status: Arm2Status
        switch (ladder?.outcome, arm2.isEmpty) {
        case (nil, _): arm2Status = .notAssessedNoLadder
        case (.some(.alignmentSupported), true): arm2Status = .noHarvests
        case (.some, true): arm2Status = .notRunAlignmentGate
        case (.some, false): arm2Status = .assessed
        }
        let fit = (ladder != nil && !arm2.isEmpty)
            ? ChannelBAnalysis.fit(perFixture: matched, bFrameDuration: bFrameDuration, ladder: ladder!, config: config)
            : nil

        return U4a2ChannelBReport(
            schemaVersion: U4a2ChannelBReport.Schema.version,
            manifest: ChannelBReportManifest(
                channelA: channelAManifest, channelBConfigID: config.configID,
                channelBConfigVersion: config.configVersion, channelBConfigSHA256: loaded.sha256,
                channelBConfigInline: config, inputFiles: inputFiles, harvests: references,
                undecodableFileCount: undecodableFileCount, duplicateHarvestIDs: duplicates),
            status: harvests.isEmpty ? .deviceResultsAbsent : .assessed,
            ladder: ladder, arm2Status: arm2Status, arm2: arm2, fit: fit)
    }
}
