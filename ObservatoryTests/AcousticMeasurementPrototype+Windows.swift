import Foundation

// U4a-1: span baselines, span summaries, and window-level aggregation (A9–A18).
//
// Separated from the frame-level DSP purely for readability; it is the same component
// as `AcousticMeasurementPrototype.swift` in §10's file list.
//
// Every emitted measurement states which of the four frame states it consumed, and its
// coverage is metric-specific: a window full of legitimate pauses is not rejected for
// "low coverage" — pauses are the measurement in the gap metrics, and are simply not
// eligible frames for the F0 or level metrics.

/// Span-scoped baselines. Never per file, never across a join (§4.1 state reset).
struct SpanBaselines: Sendable {
    let levelDb: Double?
    let f0Hz: Double?
    let nucleusRatePerSecond: Double?
    let nucleusRatePerActiveSecond: Double?
    let voicedSeconds: Double
    let activeSeconds: Double
    let classifiedSeconds: Double
    let isAvailable: Bool
    let unavailableReason: UnavailableReason?

    init(frames: SpanFrames, config cfg: EstimatorConfig, multiSpeaker: Bool) {
        let hop = frames.hopSeconds
        var activeLevels: [Double] = []
        var voicedF0: [Double] = []
        var voiced = 0, active = 0, classified = 0
        for i in 0..<frames.state.count {
            switch frames.state[i] {
            case .voiced:
                voiced += 1; active += 1; classified += 1
                if let l = frames.levelDb[i] { activeLevels.append(l) }
                if let f = frames.f0[i] { voicedF0.append(f) }
            case .activeAperiodic:
                active += 1; classified += 1
                if let l = frames.levelDb[i] { activeLevels.append(l) }
            case .inactive:
                classified += 1
            case .unknown:
                break
            }
        }
        voicedSeconds = Double(voiced) * hop
        activeSeconds = Double(active) * hop
        classifiedSeconds = Double(classified) * hop
        levelDb = AcousticAnalyzer.median(activeLevels)
        f0Hz = AcousticAnalyzer.median(voicedF0)
        nucleusRatePerSecond = classifiedSeconds > 0 ? Double(frames.nucleusTimes.count) / classifiedSeconds : nil
        nucleusRatePerActiveSecond = activeSeconds > 0 ? Double(frames.nucleusTimes.count) / activeSeconds : nil

        // A speaker mixture is recorded as what it is, not disguised as insufficient
        // baseline duration (review R6.15).
        if multiSpeaker {
            isAvailable = false
            unavailableReason = .multiSpeakerMixture
        } else if voicedSeconds < cfg.baseline.minimumBaselineVoicedSeconds {
            isAvailable = false
            unavailableReason = .insufficientBaseline(observedSeconds: voicedSeconds,
                                                      required: cfg.baseline.minimumBaselineVoicedSeconds)
        } else {
            isAvailable = true
            unavailableReason = nil
        }
    }
}

extension AcousticAnalyzer {

    // MARK: Span-level summary metrics

    static func spanMeasurements(span: TimeSpan, frames: SpanFrames, baselines: SpanBaselines,
                                 context: ReportContext, config cfg: EstimatorConfig) -> [AcousticMeasurement] {
        let hop = frames.hopSeconds
        let window = AnalysisWindow(spanID: span.spanID, startSeconds: span.startSeconds,
                                    endSeconds: span.endSeconds,
                                    frameSamples: 0, supportSamples: 0, hopSamples: 0)
        let classifiedFrames = frames.state.filter { $0 != .unknown }.count
        let unknownFrames = frames.state.filter { $0 == .unknown }.count
        let coverage = Coverage(nominalWindowSeconds: span.durationSeconds,
                                domainSeconds: span.durationSeconds,
                                unknownSeconds: Double(unknownFrames) * hop,
                                eligibleSeconds: Double(classifiedFrames) * hop,
                                estimatedSeconds: Double(classifiedFrames) * hop,
                                eligibleFrames: classifiedFrames, estimatedFrames: classifiedFrames)

        func make(_ metric: MetricID, _ value: Double?, _ unit: AcousticUnit,
                  _ estimator: EstimatorID, flags: [QualityFlag] = []) -> AcousticMeasurement {
            if let value {
                return .measured(value, metric: metric, unit: unit, window: window,
                                 estimator: estimator, coverage: coverage, context: context, flags: flags)
            }
            return .unavailable(.estimatorFailed(.noEligibleFrames), metric: metric, unit: unit,
                                window: window, estimator: estimator, coverage: coverage,
                                context: context, flags: flags)
        }

        var out: [AcousticMeasurement] = []
        if let floor = frames.noiseFloorDb {
            out.append(make(.spanNoiseFloor, floor, .dBFS, .noiseFloor))
        } else {
            // Distinguish "the span is too short to estimate a floor" from "every frame
            // had exactly zero energy, so there are no finite levels to take a
            // percentile of" — digital silence is the second, not the first.
            let reason: UnavailableReason = span.durationSeconds < cfg.noiseFloor.minSpanSecondsForFloor
                ? .estimatorFailed(.spanTooShortForFloor)
                : .estimatorFailed(.noEligibleFrames)
            out.append(.unavailable(reason, metric: .spanNoiseFloor,
                                    unit: .dBFS, window: window, estimator: .noiseFloor,
                                    coverage: coverage, context: context))
        }
        out.append(make(.spanVoicedSeconds, baselines.voicedSeconds, .seconds, .classification))
        out.append(make(.spanActiveSeconds, baselines.activeSeconds, .seconds, .classification))
        out.append(make(.spanInactiveSeconds,
                        baselines.classifiedSeconds - baselines.activeSeconds, .seconds, .classification))
        out.append(make(.spanUnknownSeconds, Double(unknownFrames) * hop, .seconds, .classification))
        out.append(make(.spanVoicedFraction,
                        span.durationSeconds > 0 ? baselines.voicedSeconds / span.durationSeconds : nil,
                        .ratio, .classification))
        out.append(make(.spanF0Median, baselines.f0Hz, .hertz, .f0,
                        flags: frames.railHits > 0 ? [.searchRangeRailHits] : []))
        out.append(make(.spanIndeterminateGapCount, Double(frames.indeterminateGapCount), .count, .classification))

        // Rates are taken over the frames their numerator can actually occur in:
        // rail hits and jump rejections over frames where periodicity was computed at
        // all, estimation success over ELIGIBLE (active) frames. Mixing those
        // denominators is what produced a "success rate" of 201.0 in M1's first run.
        let support = frames.f0SupportFrames
        out.append(make(.spanOctaveJumpRejectionRate,
                        support > 0 ? Double(frames.octaveJumpRejections) / Double(support) : nil,
                        .ratio, .f0,
                        flags: frames.octaveJumpRejections > 0 ? [.octaveJumpRejectionsPresent] : []))
        out.append(make(.spanSearchRangeRailRate,
                        support > 0 ? Double(frames.railHits) / Double(support) : nil, .ratio, .f0,
                        flags: frames.railHits > 0 ? [.searchRangeRailHits] : []))
        out.append(make(.spanEstimationSuccess,
                        frames.f0EligibleFrames > 0
                            ? Double(frames.f0EstimatedFrames) / Double(frames.f0EligibleFrames)
                            : nil,
                        .ratio, .f0))
        return out
    }

    // MARK: Window-level metrics

    static func windowMeasurementsFor(span: TimeSpan, frames: SpanFrames, baselines: SpanBaselines,
                                      context: ReportContext, config cfg: EstimatorConfig,
                                      request: Request) -> [AcousticMeasurement] {
        var out: [AcousticMeasurement] = []
        let hop = frames.hopSeconds
        let nominal = cfg.windows.windowSeconds
        let step = cfg.windows.hopSeconds
        guard step > 0, nominal > 0 else { return out }

        let levelFrameSamples = Int((request.signal.sampleRate * cfg.frameGeometry.levelFrameMs / 1000).rounded())
        let pitchFrameSamples = Int((request.signal.sampleRate * cfg.frameGeometry.pitchFrameMs / 1000).rounded())
        let hopSamples = Int((request.signal.sampleRate * cfg.frameGeometry.hopMs / 1000).rounded())
        let maxLagSamples = Int((request.signal.sampleRate / cfg.periodicity.searchMinHz).rounded())

        var start = span.startSeconds
        while start < span.endSeconds {
            let nominalEnd = start + nominal
            let end = min(nominalEnd, span.endSeconds)
            let usable = end - start
            if usable < cfg.windows.minimumUsableWindowSeconds { break }
            let boundaryClipped = nominalEnd > span.endSeconds

            let indices = (0..<frames.frameTimes.count).filter {
                frames.frameTimes[$0] >= start && frames.frameTimes[$0] < end
            }
            if indices.isEmpty { start += step; continue }

            var voicedLevels: [Double] = [], activeLevels: [Double] = [], voicedF0: [Double] = []
            var voiced = 0, active = 0, inactive = 0, unknown = 0
            var clippedSum = 0.0
            for i in indices {
                clippedSum += frames.clippedFraction[i]
                switch frames.state[i] {
                case .voiced:
                    voiced += 1; active += 1
                    if let l = frames.levelDb[i] { activeLevels.append(l); voicedLevels.append(l) }
                    if let f = frames.f0[i] { voicedF0.append(f) }
                case .activeAperiodic:
                    active += 1
                    if let l = frames.levelDb[i] { activeLevels.append(l) }
                case .inactive: inactive += 1
                case .unknown: unknown += 1
                }
            }
            let classified = voiced + active - voiced + inactive   // active includes voiced
            let classifiedFrames = voiced + (active - voiced) + inactive
            _ = classified
            let clippedMean = clippedSum / Double(indices.count)
            var windowFlags: [QualityFlag] = []
            if boundaryClipped { windowFlags.append(.boundaryClipped) }
            if clippedMean > 0 { windowFlags.append(.clippingPresent) }
            if frames.railHits > 0 { windowFlags.append(.searchRangeRailHits) }
            if frames.octaveJumpRejections > 0 { windowFlags.append(.octaveJumpRejectionsPresent) }

            let levelWindow = AnalysisWindow(spanID: span.spanID, startSeconds: start, endSeconds: end,
                                             frameSamples: levelFrameSamples,
                                             supportSamples: levelFrameSamples, hopSamples: hopSamples)
            let pitchWindow = AnalysisWindow(spanID: span.spanID, startSeconds: start, endSeconds: end,
                                             frameSamples: pitchFrameSamples,
                                             supportSamples: pitchFrameSamples + maxLagSamples,
                                             hopSamples: hopSamples)

            // §6.4: when the join's location is unbounded, anything that INTEGRATES over
            // the window — gaps, rates, deltas against a span baseline — abstains,
            // because such a window may straddle the join. Frame-local measurements
            // (level, F0, within-window spread) stay reportable and flagged.
            let suppressJoinSensitive = request.domain.joinSensitiveMeasurementsSuppressed

            func coverage(eligibleFrames: Int, estimatedFrames: Int) -> Coverage {
                Coverage(nominalWindowSeconds: nominal, domainSeconds: usable,
                         unknownSeconds: Double(unknown) * hop,
                         eligibleSeconds: Double(eligibleFrames) * hop,
                         estimatedSeconds: Double(estimatedFrames) * hop,
                         eligibleFrames: eligibleFrames, estimatedFrames: estimatedFrames)
            }

            // ---- Classification seconds
            let classCoverage = coverage(eligibleFrames: classifiedFrames, estimatedFrames: classifiedFrames)
            out.append(.measured(Double(active) * hop, metric: .activeAudioSeconds, unit: .seconds,
                                 window: levelWindow, estimator: .classification,
                                 coverage: classCoverage, context: context, flags: windowFlags))
            out.append(.measured(Double(voiced) * hop, metric: .voicedSeconds, unit: .seconds,
                                 window: pitchWindow, estimator: .classification,
                                 coverage: classCoverage, context: context, flags: windowFlags))

            // ---- A9/A10: silence-gap candidates (events assigned by their own time;
            //      duration clipped to the window, which is what `boundaryClipped` marks)
            let gapsStarting = frames.gaps.filter { $0.start >= start && $0.start < end }
            let gapSeconds = frames.gaps.reduce(0.0) { acc, g in
                acc + max(0, min(g.end, end) - max(g.start, start))
            }
            if suppressJoinSensitive {
                for (metric, unit) in [(MetricID.silenceGapCount, AcousticUnit.count),
                                       (.silenceGapSeconds, .seconds),
                                       (.silenceGapRatio, .ratio),
                                       (.nucleusRate, .nucleiPerSecond),
                                       (.syllableRatePerActiveSecond, .nucleiPerSecond),
                                       (.levelDeltaFromSpanBaseline, .dB),
                                       (.f0DeltaFromSpanBaseline, .semitones),
                                       (.nucleusRateDeltaFromSpanBaseline, .nucleiPerSecond),
                                       (.syllableRateDeltaFromSpanBaseline, .nucleiPerSecond)] {
                    out.append(.unavailable(.insideUnresolvedRegion, metric: metric, unit: unit,
                                            window: levelWindow, estimator: .derived,
                                            coverage: classCoverage, context: context, flags: windowFlags))
                }
            } else if classifiedFrames > 0 {
                out.append(.measured(Double(gapsStarting.count), metric: .silenceGapCount, unit: .count,
                                     window: levelWindow, estimator: .classification,
                                     coverage: classCoverage, context: context, flags: windowFlags))
                out.append(.measured(gapSeconds, metric: .silenceGapSeconds, unit: .seconds,
                                     window: levelWindow, estimator: .classification,
                                     coverage: classCoverage, context: context, flags: windowFlags))
                out.append(.measured(gapSeconds / usable, metric: .silenceGapRatio, unit: .ratio,
                                     window: levelWindow, estimator: .classification,
                                     coverage: classCoverage, context: context, flags: windowFlags))
            } else {
                out.append(.unavailable(.insufficientEligibleSeconds(eligible: 0, required: hop),
                                        metric: .silenceGapCount, unit: .count, window: levelWindow,
                                        estimator: .classification, coverage: classCoverage,
                                        context: context, flags: windowFlags))
            }

            // ---- A12/A13: nucleus rates (named as detected/estimated, never "syllables")
            let nuclei = frames.nucleusTimes.filter { $0 >= start && $0 < end }.count
            let activeSeconds = Double(active) * hop
            let nucleiCoverage = coverage(eligibleFrames: active, estimatedFrames: active)
            if suppressJoinSensitive {
                // already emitted as unavailable above
            } else if true {
                out.append(.measured(Double(nuclei) / usable, metric: .nucleusRate, unit: .nucleiPerSecond,
                                     window: levelWindow, estimator: .nuclei,
                                     coverage: classCoverage, context: context, flags: windowFlags))
            }
            if suppressJoinSensitive {
                // already emitted as unavailable above
            } else if activeSeconds >= hop {
                out.append(.measured(Double(nuclei) / activeSeconds, metric: .syllableRatePerActiveSecond,
                                     unit: .nucleiPerSecond, window: levelWindow, estimator: .nuclei,
                                     coverage: nucleiCoverage, context: context, flags: windowFlags))
            } else {
                out.append(.unavailable(.insufficientEligibleSeconds(eligible: activeSeconds, required: hop),
                                        metric: .syllableRatePerActiveSecond, unit: .nucleiPerSecond,
                                        window: levelWindow, estimator: .nuclei,
                                        coverage: nucleiCoverage, context: context, flags: windowFlags))
            }

            // ---- A14/A15: level (refused outright on level-altered sources outside M4)
            let levelCoverage = coverage(eligibleFrames: active, estimatedFrames: activeLevels.count)
            let levelAllowed = !request.provenance.postProcessing.alterslevel
                || request.allowAmplitudeMetricsOnAlteredSource
            if !levelAllowed {
                out.append(.unavailable(.estimatorFailed(.noEligibleFrames), metric: .levelWindowMedian,
                                        unit: .dBFS, window: levelWindow, estimator: .level,
                                        coverage: levelCoverage, context: context, flags: windowFlags))
            } else if clippedMean > 0.01 {
                out.append(.unavailable(.saturated(clippedFraction: clippedMean), metric: .levelWindowMedian,
                                        unit: .dBFS, window: levelWindow, estimator: .level,
                                        coverage: levelCoverage, context: context, flags: windowFlags))
            } else if let med = median(activeLevels), activeLevels.count >= 3 {
                out.append(.measured(med, metric: .levelWindowMedian, unit: .dBFS, window: levelWindow,
                                     estimator: .level, coverage: levelCoverage, context: context,
                                     flags: windowFlags))
                if let p75 = percentile(activeLevels, 75), let p25 = percentile(activeLevels, 25) {
                    out.append(.measured(p75 - p25, metric: .levelWindowIQR, unit: .dB, window: levelWindow,
                                         estimator: .level, coverage: levelCoverage, context: context,
                                         flags: windowFlags))
                }
                if suppressJoinSensitive {
                    // already emitted as unavailable above
                } else if baselines.isAvailable, let base = baselines.levelDb {
                    out.append(.measured(med - base, metric: .levelDeltaFromSpanBaseline, unit: .dB,
                                         window: levelWindow, estimator: .derived, coverage: levelCoverage,
                                         context: context, flags: windowFlags,
                                         baseline: BaselineRef(spanID: span.spanID, metric: .levelWindowMedian,
                                                               observedVoicedSeconds: baselines.voicedSeconds,
                                                               value: base)))
                } else {
                    out.append(.unavailable(baselines.unavailableReason ?? .insufficientBaseline(observedSeconds: baselines.voicedSeconds, required: cfg.baseline.minimumBaselineVoicedSeconds),
                                            metric: .levelDeltaFromSpanBaseline, unit: .dB,
                                            window: levelWindow, estimator: .derived, coverage: levelCoverage,
                                            context: context, flags: windowFlags))
                }
            } else {
                out.append(.unavailable(.insufficientEligibleSeconds(eligible: Double(activeLevels.count) * hop,
                                                                     required: 3 * hop),
                                        metric: .levelWindowMedian, unit: .dBFS, window: levelWindow,
                                        estimator: .level, coverage: levelCoverage, context: context,
                                        flags: windowFlags))
            }

            // ---- A16/A17/A18: F0
            let f0Coverage = coverage(eligibleFrames: voiced + (active - voiced), estimatedFrames: voicedF0.count)
            if voicedF0.count >= 3, let med = median(voicedF0) {
                out.append(.measured(med, metric: .f0WindowMedian, unit: .hertz, window: pitchWindow,
                                     estimator: .f0, coverage: f0Coverage, context: context, flags: windowFlags))
                // Within-window spread is a ratio: no global reference is required, so it
                // stays available on multi-speaker sources (review R6.15).
                if let p95 = percentile(voicedF0, 95), let p05 = percentile(voicedF0, 5), p05 > 0 {
                    out.append(.measured(12 * log2(p95 / p05), metric: .f0WindowSpread, unit: .semitones,
                                         window: pitchWindow, estimator: .f0, coverage: f0Coverage,
                                         context: context, flags: windowFlags))
                }
                if suppressJoinSensitive {
                    // already emitted as unavailable above
                } else if baselines.isAvailable, let base = baselines.f0Hz, base > 0 {
                    out.append(.measured(12 * log2(med / base), metric: .f0DeltaFromSpanBaseline,
                                         unit: .semitones, window: pitchWindow, estimator: .derived,
                                         coverage: f0Coverage, context: context, flags: windowFlags,
                                         baseline: BaselineRef(spanID: span.spanID, metric: .f0WindowMedian,
                                                               observedVoicedSeconds: baselines.voicedSeconds,
                                                               value: base)))
                } else {
                    out.append(.unavailable(baselines.unavailableReason ?? .insufficientBaseline(observedSeconds: baselines.voicedSeconds, required: cfg.baseline.minimumBaselineVoicedSeconds),
                                            metric: .f0DeltaFromSpanBaseline, unit: .semitones,
                                            window: pitchWindow, estimator: .derived, coverage: f0Coverage,
                                            context: context, flags: windowFlags))
                }
            } else {
                out.append(.unavailable(.insufficientEligibleSeconds(eligible: Double(voicedF0.count) * hop,
                                                                     required: 3 * hop),
                                        metric: .f0WindowMedian, unit: .hertz, window: pitchWindow,
                                        estimator: .f0, coverage: f0Coverage, context: context,
                                        flags: windowFlags))
            }

            // ---- Rate deltas
            if suppressJoinSensitive {
                // already emitted as unavailable above
            } else if baselines.isAvailable, let base = baselines.nucleusRatePerActiveSecond,
                      activeSeconds >= hop {
                out.append(.measured(Double(nuclei) / activeSeconds - base,
                                     metric: .syllableRateDeltaFromSpanBaseline, unit: .nucleiPerSecond,
                                     window: levelWindow, estimator: .derived, coverage: nucleiCoverage,
                                     context: context, flags: windowFlags,
                                     baseline: BaselineRef(spanID: span.spanID,
                                                           metric: .syllableRatePerActiveSecond,
                                                           observedVoicedSeconds: baselines.voicedSeconds,
                                                           value: base)))
            }
            if suppressJoinSensitive {
                // already emitted as unavailable above
            } else if baselines.isAvailable, let base = baselines.nucleusRatePerSecond {
                out.append(.measured(Double(nuclei) / usable - base,
                                     metric: .nucleusRateDeltaFromSpanBaseline, unit: .nucleiPerSecond,
                                     window: levelWindow, estimator: .derived, coverage: classCoverage,
                                     context: context, flags: windowFlags,
                                     baseline: BaselineRef(spanID: span.spanID, metric: .nucleusRate,
                                                           observedVoicedSeconds: baselines.voicedSeconds,
                                                           value: base)))
            }

            start += step
        }
        return out
    }
}
