import Accelerate
import AVFoundation
import Foundation

// U4a-1 Channel A: transcript-independent acoustic measurement, computed directly on a
// saved `.caf` (or an in-memory synthetic signal). Never opens a recognizer.
//
// STATUS: an EXPERIMENTAL ESTIMATOR UNDERGOING VERIFICATION (review R1.1). M1/M4 are
// checks whose outcomes are unknown until they run; passing them would establish
// synthetic accuracy and selected invariances, and nothing about reliable F0, nucleus
// counts, or behavioural measurement on spontaneous speech.
//
// Frame geometry (§4.1), exact and integer-valued:
//   hop slot i covers [spanStart + i*hop, spanStart + (i+1)*hop)
//   center_i      = spanStart + i*hop + hop/2
//   level frame   = [center - L/2, center + L/2)                       L = 25 ms
//   pitch support = [center - P/2, center + P/2 + maxLag)              P = 40 ms
// Different frame lengths share CENTERS, not extents. A frame is computed only when its
// entire support lies inside the span, which produces the edge/join guard automatically
// — and makes F0's guard wider than the level channel's, because NCCF needs lag
// look-ahead. Elapsed time is always counted in hop slots, never frame extents, so
// overlapping 25 ms / 40 ms frames cannot multiply coverage (review R6.5).

// MARK: - Signal

struct AudioSignal: Sendable {
    let samples: [Float]
    let sampleRate: Double
    var durationSeconds: Double { Double(samples.count) / sampleRate }
}

struct LoadedAudioFile: Sendable {
    let signal: AudioSignal
    let channelCount: Int
    let sampleFormat: SampleFormat
    let frameCount: Int64
    let sha256: String?
}

enum AudioLoadError: Error, CustomStringConvertible {
    case unreadable(String)
    case empty
    var description: String {
        switch self {
        case .unreadable(let detail): return "audio unreadable: \(detail)"
        case .empty: return "audio file contains zero frames"
        }
    }
}

enum AudioSignalLoader {
    /// Duration always comes from the frame count, never from file bytes (Hermes
    /// Finding 3: a CAF header makes byte arithmetic ~0.02 s long).
    static func load(url: URL, hashFile: Bool = true) throws -> LoadedAudioFile {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw AudioLoadError.unreadable(String(describing: type(of: error)))
        }
        let format = file.processingFormat
        let frames = file.length
        guard frames > 0 else { throw AudioLoadError.empty }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw AudioLoadError.unreadable("buffer allocation failed")
        }
        do {
            try file.read(into: buffer)
        } catch {
            throw AudioLoadError.unreadable("read failed")
        }
        guard let channels = buffer.floatChannelData else {
            throw AudioLoadError.unreadable("non-float processing format")
        }
        let n = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var mono = [Float](repeating: 0, count: n)
        if channelCount == 1 {
            mono.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress!.update(from: channels[0], count: n)
            }
        } else {
            for c in 0..<channelCount {
                vDSP_vadd(mono, 1, channels[c], 1, &mono, 1, vDSP_Length(n))
            }
            var scale = Float(1.0 / Double(channelCount))
            vDSP_vsmul(mono, 1, &scale, &mono, 1, vDSP_Length(n))
        }
        return LoadedAudioFile(
            signal: AudioSignal(samples: mono, sampleRate: format.sampleRate),
            channelCount: channelCount,
            sampleFormat: sampleFormat(for: file.fileFormat),
            frameCount: frames,
            sha256: hashFile ? U4aHash.hexOfFile(at: url) : nil)
    }

    private static func sampleFormat(for format: AVAudioFormat) -> SampleFormat {
        switch format.commonFormat {
        case .pcmFormatFloat32: return .float32
        case .pcmFormatInt16: return .int16
        case .pcmFormatInt32: return .int32
        default: return .other
        }
    }
}

// MARK: - Frame classification

enum FrameState: String, Codable, Sendable {
    case voiced            // active AND periodic
    case activeAperiodic   // active, not periodic — NOT a pause; may be unvoiced speech or noise
    case inactive          // below the activity gate — a pause CANDIDATE, not established silence
    case unknown           // outside support, guard, filter settling, or estimator failure
}

enum PeriodicityState: String, Sendable {
    case periodic
    case aperiodic
    /// Peak sits at the search-range rail: out-of-range periodicity, explicitly NOT
    /// reported as unvoiced (review R2.3).
    case outOfRange
    case unavailable
}

/// Per-frame series for one analyzable span. Frame i corresponds to hop slot i.
struct SpanFrames: Sendable {
    let spanID: Int
    let spanStartSeconds: Double
    let hopSeconds: Double
    let frameTimes: [Double]          // span-relative centre of each hop slot, in file seconds
    var levelDb: [Double?]            // A1 — nil when the frame has no support OR RMS == 0
    var zeroEnergy: [Bool]
    var clippedFraction: [Double]
    var aboveFloorDb: [Double?]       // A4 — level above the ESTIMATED floor; not SNR
    var periodicity: [PeriodicityState]
    var peakStrength: [Double?]
    var rawF0: [Double?]
    var f0: [Double?]                 // A6 after smoothing + octave-jump rejection
    var state: [FrameState]
    var nucleusTimes: [Double]
    var noiseFloorDb: Double?
    var octaveJumpRejections: Int
    var railHits: Int
    var widenedRangeRecoveries: Int
    var indeterminateGapCount: Int
    var gaps: [(start: Double, end: Double)]
    /// Frames where periodicity could be computed at all (support present). The
    /// denominator for rail and rejection RATES.
    var f0SupportFrames: Int
    /// Frames eligible for an F0: `active` frames. Unvoiced speech is legitimately
    /// eligible and legitimately yields no F0, which is what makes the success rate
    /// below meaningful instead of tautological.
    var f0EligibleFrames: Int
    /// Eligible frames that actually yielded an F0 — i.e. `voiced`. Always a subset of
    /// `f0EligibleFrames`, so the ratio can never exceed 1.
    var f0EstimatedFrames: Int
}

// MARK: - Analyzer

enum AcousticAnalyzer {

    struct Request: Sendable {
        let signal: AudioSignal
        let provenance: CaptureProvenance
        let domain: AnalysisDomain
        let config: LoadedEstimatorConfig
        let rules: LoadedRuleLibrary
        let measurementParameters: MeasurementParameters
        let extraFlags: [QualityFlag]
        /// Amplitude-domain metrics are refused on `-loudnorm`/`-gain` variants except
        /// inside the M4 invariance control, where the known transformation is the point.
        let allowAmplitudeMetricsOnAlteredSource: Bool
    }

    static func analyze(_ request: Request) -> SourceReport {
        let cfg = request.config.config
        let context = ReportContext(
            provenanceID: request.provenance.sourceID.stringValue,
            configID: cfg.configID,
            configSHA256: request.config.sha256,
            sourceFlags: sourceFlags(for: request))

        let capability = capabilityStatuses(for: request)

        guard !request.domain.sourceExcluded, !request.signal.samples.isEmpty else {
            return SourceReport(provenance: request.provenance, domain: request.domain,
                                spanSummaries: [], windowMeasurements: [], observations: [],
                                capability: capability)
        }

        var spanSummaries: [SpanSummary] = []
        var windowMeasurements: [AcousticMeasurement] = []
        var baselineVoicedSeconds: [Int: Double] = [:]

        for span in request.domain.analyzableSpans {
            guard let frames = analyzeSpan(span: span, request: request) else { continue }
            let baselines = SpanBaselines(frames: frames, config: cfg,
                                          multiSpeaker: request.provenance.isMultiSpeakerSource)
            baselineVoicedSeconds[span.spanID] = baselines.voicedSeconds
            spanSummaries.append(SpanSummary(
                span: span,
                measurements: spanMeasurements(span: span, frames: frames,
                                               baselines: baselines, context: context, config: cfg),
                baselineAvailable: baselines.isAvailable,
                baselineVoicedSeconds: baselines.voicedSeconds))
            windowMeasurements += windowMeasurementsFor(
                span: span, frames: frames, baselines: baselines,
                context: context, config: cfg, request: request)
        }

        let observations = request.domain.joinSensitiveMeasurementsSuppressed
            ? []
            : AcousticRuleEvaluator.evaluate(measurements: windowMeasurements,
                                             library: request.rules.library,
                                             baselineVoicedSecondsBySpan: baselineVoicedSeconds)

        return SourceReport(provenance: request.provenance, domain: request.domain,
                            spanSummaries: spanSummaries,
                            windowMeasurements: windowMeasurements.sorted {
                                ($0.window.startSeconds, $0.metric.rawValue)
                                    < ($1.window.startSeconds, $1.metric.rawValue)
                            },
                            observations: observations,
                            capability: capability)
    }

    private static func sourceFlags(for request: Request) -> [QualityFlag] {
        var flags = request.extraFlags
        if request.provenance.sourceID.kind != .synthetic {
            // On real audio there is no independent measurement of the true noise floor,
            // so A3 and everything derived from it stay unverified however M1 turns out.
            flags.append(.noiseFloorUnverifiedOnRealAudio)
        }
        if request.provenance.isMultiSpeakerSource { flags.append(.multiSpeakerSource) }
        if case .unknownLegacy = request.provenance.completeness.recorded { flags.append(.completenessUnknown) }
        if !request.domain.unresolvedRegions.isEmpty { flags.append(.nearJoinGuard) }
        return flags
    }

    private static func capabilityStatuses(for request: Request) -> [CapabilityStatus] {
        var list: [CapabilityStatus] = [
            CapabilityStatus(code: .reducedArticulationUnsupported, supported: false),
            CapabilityStatus(code: .prolongedSoundCandidateRequiresTranscript, supported: false),
            CapabilityStatus(code: .speakerAttributionUnavailable, supported: false),
            CapabilityStatus(code: .periodicNonSpeechNotExcluded, supported: false),
            CapabilityStatus(code: .unvoicedSpeechNotSeparableFromNoise, supported: false),
            CapabilityStatus(code: .channelBDeferredToU4a2, supported: false)
        ]
        if request.provenance.sourceID.kind != .synthetic {
            list.append(CapabilityStatus(code: .noiseFloorUnverifiableOnRealAudio, supported: false))
        }
        return list.sorted { $0.code.rawValue < $1.code.rawValue }
    }

    // MARK: Span analysis

    static func analyzeSpan(span: TimeSpan, request: Request) -> SpanFrames? {
        let cfg = request.config.config
        let sr = request.signal.sampleRate
        let hop = Int((sr * cfg.frameGeometry.hopMs / 1000).rounded())
        let levelFrame = Int((sr * cfg.frameGeometry.levelFrameMs / 1000).rounded())
        guard hop > 0, levelFrame > 0 else { return nil }

        let startSample = max(0, Int((span.startSeconds * sr).rounded()))
        let endSample = min(request.signal.samples.count, Int((span.endSeconds * sr).rounded()))
        guard endSample - startSample > levelFrame else { return nil }
        let spanSamples = Array(request.signal.samples[startSample..<endSample])
        let spanLength = spanSamples.count
        let frameCount = spanLength / hop
        guard frameCount > 0 else { return nil }

        var frames = SpanFrames(
            spanID: span.spanID, spanStartSeconds: span.startSeconds,
            hopSeconds: cfg.frameGeometry.hopMs / 1000,
            frameTimes: (0..<frameCount).map { span.startSeconds + (Double($0) * Double(hop) + Double(hop) / 2) / sr },
            levelDb: Array(repeating: nil, count: frameCount),
            zeroEnergy: Array(repeating: false, count: frameCount),
            clippedFraction: Array(repeating: 0, count: frameCount),
            aboveFloorDb: Array(repeating: nil, count: frameCount),
            periodicity: Array(repeating: .unavailable, count: frameCount),
            peakStrength: Array(repeating: nil, count: frameCount),
            rawF0: Array(repeating: nil, count: frameCount),
            f0: Array(repeating: nil, count: frameCount),
            state: Array(repeating: .unknown, count: frameCount),
            nucleusTimes: [], noiseFloorDb: nil,
            octaveJumpRejections: 0, railHits: 0, widenedRangeRecoveries: 0,
            indeterminateGapCount: 0, gaps: [],
            f0SupportFrames: 0, f0EligibleFrames: 0, f0EstimatedFrames: 0)

        // ---- A1/A2: level and clipping on the shared centre grid
        for i in 0..<frameCount {
            let center = i * hop + hop / 2
            let lo = center - levelFrame / 2
            let hi = lo + levelFrame
            guard lo >= 0, hi <= spanLength else { continue }   // support rule => edge guard
            var sumSq: Double = 0
            var clipped = 0
            for n in lo..<hi {
                let v = Double(spanSamples[n])
                sumSq += v * v
                if abs(v) >= 0.999 { clipped += 1 }
            }
            let rms = (sumSq / Double(levelFrame)).squareRoot()
            frames.clippedFraction[i] = Double(clipped) / Double(levelFrame)
            if rms == 0 {
                // log10(0) is non-finite. No physical floor is invented for it: the frame
                // carries no level value and is classified inactive on physical grounds.
                frames.zeroEnergy[i] = true
            } else {
                frames.levelDb[i] = 20 * log10(rms)
            }
        }

        // ---- A3: noise floor, span-scoped (never per file)
        let levels = frames.levelDb.compactMap { $0 }
        if span.durationSeconds >= cfg.noiseFloor.minSpanSecondsForFloor, !levels.isEmpty {
            frames.noiseFloorDb = percentile(levels, cfg.noiseFloor.percentile)
        }

        // ---- A4: level above the ESTIMATED floor (a proxy, not SNR — review R6.3)
        if let floor = frames.noiseFloorDb {
            for i in 0..<frameCount {
                if let l = frames.levelDb[i] { frames.aboveFloorDb[i] = l - floor }
                else if frames.zeroEnergy[i] { frames.aboveFloorDb[i] = -Double.infinity }
            }
        }

        // ---- Activity (hysteresis + minimum run lengths)
        let active = activityStates(frames: frames, config: cfg, frameCount: frameCount)

        // ---- Periodicity and F0
        computePeriodicity(&frames, spanSamples: spanSamples, sampleRate: sr,
                           hop: hop, frameCount: frameCount, config: cfg)
        smoothAndRejectOctaveJumps(&frames, config: cfg)

        // ---- Four-state classification
        for i in 0..<frameCount {
            guard let hasLevel = active[i] else { frames.state[i] = .unknown; continue }
            if !hasLevel {
                frames.state[i] = .inactive
            } else if frames.periodicity[i] == .periodic && frames.f0[i] != nil {
                frames.state[i] = .voiced
            } else {
                frames.state[i] = .activeAperiodic
            }
        }
        frames.f0SupportFrames = frames.periodicity.filter { $0 != .unavailable }.count
        frames.f0EligibleFrames = frames.state.filter { $0 == .voiced || $0 == .activeAperiodic }.count
        frames.f0EstimatedFrames = frames.state.filter { $0 == .voiced }.count

        // ---- A8: nuclei on the band-limited envelope
        detectNuclei(&frames, spanSamples: spanSamples, sampleRate: sr,
                     hop: hop, levelFrame: levelFrame, frameCount: frameCount, config: cfg)

        // ---- A9: silence-gap candidates
        detectGaps(&frames, frameCount: frameCount,
                   parameters: request.measurementParameters, hopSeconds: frames.hopSeconds)

        return frames
    }

    /// nil => unknown (no level support); true => active; false => inactive.
    private static func activityStates(frames: SpanFrames, config cfg: EstimatorConfig,
                                       frameCount: Int) -> [Bool?] {
        var raw = [Bool?](repeating: nil, count: frameCount)
        guard frames.noiseFloorDb != nil else { return raw }
        var isActive = false
        for i in 0..<frameCount {
            if frames.zeroEnergy[i] {
                isActive = false
                raw[i] = false
                continue
            }
            guard let above = frames.aboveFloorDb[i] else { continue }  // stays unknown
            if isActive {
                if above < cfg.activity.offsetAboveFloorDb { isActive = false }
            } else {
                if above >= cfg.activity.onsetAboveFloorDb { isActive = true }
            }
            raw[i] = isActive
        }
        let hopMs = cfg.frameGeometry.hopMs
        let minActive = max(1, Int((cfg.activity.minActiveRunMs / hopMs).rounded()))
        let minInactive = max(1, Int((cfg.activity.minInactiveRunMs / hopMs).rounded()))
        return removeShortRuns(raw, minActiveRun: minActive, minInactiveRun: minInactive)
    }

    private static func removeShortRuns(_ input: [Bool?], minActiveRun: Int, minInactiveRun: Int) -> [Bool?] {
        var out = input
        var i = 0
        while i < out.count {
            guard let value = out[i] else { i += 1; continue }
            var j = i
            while j < out.count, out[j] == value { j += 1 }
            let runLength = j - i
            let minimum = value ? minActiveRun : minInactiveRun
            if runLength < minimum, i > 0 || j < out.count {
                for k in i..<j { out[k] = !value }
            }
            i = j
        }
        return out
    }

    // MARK: NCCF periodicity / F0

    private static func computePeriodicity(_ frames: inout SpanFrames, spanSamples: [Float],
                                           sampleRate: Double, hop: Int, frameCount: Int,
                                           config cfg: EstimatorConfig) {
        let targetRate = cfg.frameGeometry.pitchAnalysisRateHz
        let factorDouble = sampleRate / targetRate
        let factor = Int(factorDouble.rounded())
        guard factor >= 1, abs(factorDouble - Double(factor)) < 1e-9, hop % factor == 0 else {
            return   // frames stay `.unavailable`; F0 is reported as estimator-failed upstream
        }
        let decRate = sampleRate / Double(factor)
        let decimated = decimate(spanSamples, factor: factor, sampleRate: sampleRate, cutoff: decRate * 0.4)
        let decHop = hop / factor
        let pitchFrame = Int((decRate * cfg.frameGeometry.pitchFrameMs / 1000).rounded())
        let minLag = max(2, Int((decRate / cfg.periodicity.searchMaxHz).rounded()))
        let maxLag = Int((decRate / cfg.periodicity.searchMinHz).rounded())
        guard maxLag > minLag + 2, pitchFrame > 0 else { return }

        let wideMinLag = max(2, Int((decRate / cfg.periodicity.diagnosticWidenedRange.maxHz).rounded()))
        let wideMaxLag = Int((decRate / cfg.periodicity.diagnosticWidenedRange.minHz).rounded())

        // Prefix sums of squares in Double: energies in O(1) per lag, without the
        // cancellation a running Float sum would accumulate over a long span.
        var prefix = [Double](repeating: 0, count: decimated.count + 1)
        for i in 0..<decimated.count {
            let v = Double(decimated[i])
            prefix[i + 1] = prefix[i] + v * v
        }

        decimated.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            for i in 0..<frameCount {
                let center = (i * hop + hop / 2) / factor
                let lo = center - pitchFrame / 2
                let hi = lo + pitchFrame + maxLag + railMarginLags
                guard lo >= 0, hi <= decimated.count else { continue }   // support rule

                let result = nccfPeak(base: base, prefix: prefix, start: lo, window: pitchFrame,
                                      minLag: minLag, maxLag: maxLag,
                                      subharmonicPreference: cfg.periodicity.subharmonicPreference)
                frames.peakStrength[i] = result.strength
                guard let strength = result.strength, let lag = result.lag else {
                    frames.periodicity[i] = .aperiodic
                    continue
                }
                if result.atRail {
                    frames.periodicity[i] = .outOfRange
                    frames.railHits += 1
                    if cfg.periodicity.diagnosticWidenedRange.enabled,
                       lo >= 0, lo + pitchFrame + wideMaxLag <= decimated.count {
                        let wide = nccfPeak(base: base, prefix: prefix, start: lo, window: pitchFrame,
                                            minLag: wideMinLag, maxLag: wideMaxLag,
                                            subharmonicPreference: cfg.periodicity.subharmonicPreference)
                        if let ws = wide.strength, ws >= cfg.periodicity.peakStrengthFloor, !wide.atRail {
                            frames.widenedRangeRecoveries += 1
                        }
                    }
                    continue
                }
                if strength >= cfg.periodicity.peakStrengthFloor {
                    frames.periodicity[i] = .periodic
                    frames.rawF0[i] = decRate / lag
                } else {
                    frames.periodicity[i] = .aperiodic
                }
            }
        }
    }

    private struct NCCFResult {
        let strength: Double?
        let lag: Double?
        let atRail: Bool
    }

    /// The correlation is searched over a small margin BEYOND the configured range, and
    /// "rail" means the peak landed in that margin. Without the margin a tone sitting
    /// exactly on a configured bound (e.g. 400 Hz, lag 60 at 24 kHz) would be reported
    /// as out-of-range purely because its true lag equals the first searched lag —
    /// the bound itself has to remain measurable. The margin is part of the NCCF
    /// implementation, which the review agreed stays in code.
    private static let railMarginLags = 2

    private static func nccfPeak(base: UnsafePointer<Float>, prefix: [Double],
                                 start: Int, window: Int, minLag: Int, maxLag: Int,
                                 subharmonicPreference: Double) -> NCCFResult {
        let e0 = prefix[start + window] - prefix[start]
        guard e0 > 0 else { return NCCFResult(strength: nil, lag: nil, atRail: false) }
        let searchMin = max(2, minLag - railMarginLags)
        let searchMax = maxLag + railMarginLags
        guard start + searchMax + window < prefix.count else {
            return NCCFResult(strength: nil, lag: nil, atRail: false)
        }
        var best = -Double.infinity
        var bestLag = searchMin
        var values = [Double](repeating: -1, count: searchMax - searchMin + 1)
        for lag in searchMin...searchMax {
            let eL = prefix[start + lag + window] - prefix[start + lag]
            guard eL > 0 else { continue }
            var dot: Float = 0
            vDSP_dotpr(base + start, 1, base + start + lag, 1, &dot, vDSP_Length(window))
            let r = Double(dot) / (e0 * eL).squareRoot()
            values[lag - searchMin] = r
            if r > best { best = r; bestLag = lag }
        }
        guard best > -Double.infinity else { return NCCFResult(strength: nil, lag: nil, atRail: false) }

        // Sub-harmonic preference (Amendment A4). A perfectly periodic signal has
        // near-equal normalised peaks at every integer multiple of its period, and the
        // longest lag can win by a hair — M1's first run measured a 300 Hz stack as
        // 100 Hz and a 400 Hz stack as 100 Hz for exactly that reason. Walking the lags
        // upward and taking the FIRST local maximum that reaches `subharmonicPreference`
        // of the global peak selects the true period instead of a multiple of it.
        if subharmonicPreference > 0, best > 0 {
            let threshold = best * subharmonicPreference
            for k in 1..<(values.count - 1) {
                let r = values[k]
                guard r >= threshold, r > values[k - 1], r >= values[k + 1] else { continue }
                best = r
                bestLag = k + searchMin
                break
            }
        }

        let atRail = (bestLag < minLag || bestLag > maxLag)
        let minLag = searchMin   // interpolation indexes against the searched range
        // Parabolic interpolation on the correlation peak for sub-sample lag resolution.
        var refined = Double(bestLag)
        let idx = bestLag - minLag
        if idx > 0, idx < values.count - 1 {
            let ym = values[idx - 1], y0 = values[idx], yp = values[idx + 1]
            let denom = (ym - 2 * y0 + yp)
            if denom != 0 {
                let delta = 0.5 * (ym - yp) / denom
                if abs(delta) <= 1 { refined = Double(bestLag) + delta }
            }
        }
        return NCCFResult(strength: best, lag: refined, atRail: atRail)
    }

    /// Median-of-N smoothing then octave-jump rejection. Rejection NEVER substitutes a
    /// value (review R2.4): the frame becomes `nil`, the raw candidate stays in
    /// `rawF0`, and the rejection count is reported alongside accuracy.
    private static func smoothAndRejectOctaveJumps(_ frames: inout SpanFrames, config cfg: EstimatorConfig) {
        let n = frames.rawF0.count
        guard n > 0 else { return }
        let half = max(0, cfg.f0Smoothing.medianWidthFrames / 2)
        var smoothed = [Double?](repeating: nil, count: n)
        for i in 0..<n {
            guard frames.rawF0[i] != nil else { continue }
            // No smoothing support at a span edge => the frame is unknown, not guessed.
            guard i >= half, i + half < n else { continue }
            var window: [Double] = []
            for k in (i - half)...(i + half) {
                if let v = frames.rawF0[k] { window.append(v) }
            }
            guard !window.isEmpty else { continue }
            window.sort()
            smoothed[i] = window[window.count / 2]
        }

        var lastAccepted: (index: Int, value: Double)?
        for i in 0..<n {
            guard let v = smoothed[i] else { continue }
            if let last = lastAccepted, i - last.index == 1 {
                let semitones = abs(12 * log2(v / last.value))
                if semitones > cfg.f0Smoothing.maxOctaveJumpSemitonesPerFrame {
                    frames.octaveJumpRejections += 1
                    continue     // f0 stays nil; rawF0 retains the candidate
                }
            }
            frames.f0[i] = v
            lastAccepted = (i, v)
        }
    }

    // MARK: Nuclei

    private static func detectNuclei(_ frames: inout SpanFrames, spanSamples: [Float],
                                     sampleRate: Double, hop: Int, levelFrame: Int,
                                     frameCount: Int, config cfg: EstimatorConfig) {
        var band = biquadLowPass(spanSamples, sampleRate: sampleRate, cutoff: cfg.nuclei.bandHighHz)
        band = biquadHighPass(band, sampleRate: sampleRate, cutoff: cfg.nuclei.bandLowHz)
        let settlingFrames = Int((cfg.nuclei.filterSettlingMs / cfg.frameGeometry.hopMs).rounded())

        var envelope = [Double?](repeating: nil, count: frameCount)
        for i in 0..<frameCount {
            let center = i * hop + hop / 2
            let lo = center - levelFrame / 2
            let hi = lo + levelFrame
            guard lo >= 0, hi <= band.count else { continue }
            var sumSq: Double = 0
            for n in lo..<hi { let v = Double(band[n]); sumSq += v * v }
            let rms = (sumSq / Double(levelFrame)).squareRoot()
            if rms > 0 { envelope[i] = 20 * log10(rms) }
        }

        let minSeparation = max(1, Int((cfg.nuclei.minInterNucleusMs / cfg.frameGeometry.hopMs).rounded()))
        var lastPeak: (index: Int, level: Double)?
        for i in 1..<max(1, frameCount - 1) {
            guard i >= settlingFrames else { continue }
            guard let here = envelope[i], let prev = envelope[i - 1], let next = envelope[i + 1] else { continue }
            guard here > prev, here >= next else { continue }
            if cfg.nuclei.requirePeriodicFrame && frames.state[i] != .voiced { continue }
            if frames.state[i] == .inactive || frames.state[i] == .unknown { continue }
            if let last = lastPeak {
                guard i - last.index >= minSeparation else { continue }
                // Dip rule: the trough between two accepted nuclei must be deep enough
                // that they are separate syllabic peaks, not one peak with ripple.
                var trough = Double.infinity
                for k in last.index...i { if let v = envelope[k] { trough = min(trough, v) } }
                guard trough.isFinite,
                      (here - trough) >= cfg.nuclei.dipDb,
                      (last.level - trough) >= cfg.nuclei.dipDb else { continue }
            }
            lastPeak = (i, here)
            frames.nucleusTimes.append(frames.frameTimes[i])
        }
    }

    // MARK: Gaps

    /// A silence-gap CANDIDATE: a run of `inactive` frames, terminated only once active
    /// audio is sustained for the resume debounce (matching `SilenceTracker`'s live
    /// semantics). A run containing any `unknown` frame is not a candidate — it is
    /// counted as indeterminate, because an unknown frame is not silence (review R6.5).
    private static func detectGaps(_ frames: inout SpanFrames, frameCount: Int,
                                   parameters: MeasurementParameters, hopSeconds: Double) {
        let minGapFrames = Int((parameters.minimumGapSeconds / hopSeconds).rounded())
        let debounceFrames = max(1, Int((parameters.resumeDebounceSeconds / hopSeconds).rounded()))
        var i = 0
        while i < frameCount {
            guard frames.state[i] == .inactive else { i += 1; continue }
            var j = i
            var containsUnknown = false
            var resumeStart: Int?
            while j < frameCount {
                if frames.state[j] == .inactive {
                    j += 1
                    continue
                }
                if frames.state[j] == .unknown { containsUnknown = true; break }
                // Candidate resumption: require a sustained active streak.
                var streak = 0
                var k = j
                while k < frameCount, frames.state[k] == .voiced || frames.state[k] == .activeAperiodic {
                    streak += 1; k += 1
                    if streak >= debounceFrames { break }
                }
                if streak >= debounceFrames { resumeStart = j; break }
                if k < frameCount, frames.state[k] == .unknown { containsUnknown = true; break }
                j = k
            }
            let endIndex = resumeStart ?? j
            let runLength = endIndex - i
            if containsUnknown {
                frames.indeterminateGapCount += 1
            } else if runLength >= minGapFrames {
                frames.gaps.append((start: frames.frameTimes[i],
                                    end: frames.frameTimes[min(endIndex, frameCount - 1)]))
            }
            i = max(endIndex, i + 1)
        }
    }

    // MARK: Filters

    private static func decimate(_ input: [Float], factor: Int, sampleRate: Double, cutoff: Double) -> [Float] {
        guard factor > 1 else { return input }
        let filtered = biquadLowPass(input, sampleRate: sampleRate, cutoff: cutoff)
        var out = [Float](); out.reserveCapacity(input.count / factor + 1)
        var i = 0
        while i < filtered.count { out.append(filtered[i]); i += factor }
        return out
    }

    /// RBJ-cookbook biquads, Q = 1/sqrt(2). State is created fresh on every call, which
    /// is what "filter state reset per span" means in practice (§4.1).
    static func biquadLowPass(_ x: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        let w0 = 2 * Double.pi * min(cutoff, sampleRate * 0.49) / sampleRate
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let cosw = cos(w0)
        let b0 = (1 - cosw) / 2, b1 = 1 - cosw, b2 = (1 - cosw) / 2
        let a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha
        return applyBiquad(x, b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func biquadHighPass(_ x: [Float], sampleRate: Double, cutoff: Double) -> [Float] {
        let w0 = 2 * Double.pi * max(1, min(cutoff, sampleRate * 0.49)) / sampleRate
        let alpha = sin(w0) / (2 * (1 / 2.0.squareRoot()))
        let cosw = cos(w0)
        let b0 = (1 + cosw) / 2, b1 = -(1 + cosw), b2 = (1 + cosw) / 2
        let a0 = 1 + alpha, a1 = -2 * cosw, a2 = 1 - alpha
        return applyBiquad(x, b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    private static func applyBiquad(_ x: [Float], b0: Double, b1: Double, b2: Double,
                                    a1: Double, a2: Double) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in 0..<x.count {
            let xn = Double(x[i])
            let yn = b0 * xn + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            y[i] = Float(yn)
            x2 = x1; x1 = xn; y2 = y1; y1 = yn
        }
        return y
    }

    // MARK: Statistics

    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let rank = (p / 100) * Double(sorted.count - 1)
        let lo = Int(rank.rounded(.down)), hi = Int(rank.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = rank - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    static func median(_ values: [Double]) -> Double? { percentile(values, 50) }
}

/// Pause-definition parameters live in the rules library, not in code (§7).
struct MeasurementParameters: Codable, Equatable, Sendable {
    let minimumGapSeconds: Double
    let resumeDebounceSeconds: Double

    static let fallback = MeasurementParameters(minimumGapSeconds: 1.5, resumeDebounceSeconds: 0.3)
}
