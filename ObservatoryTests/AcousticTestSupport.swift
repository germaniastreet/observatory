import Foundation
import Testing

// U4a-1 shared test support: deterministic synthetic signal generation, the analysis
// harness glue, and report assembly/attachment.
//
// Every generator is deterministic (fixed-seed LCG, no system RNG) because §12
// criterion 5 asserts byte-identical canonical payloads across repeated runs within a
// pinned environment.

private final class U4aBundleLocator {}

enum U4aHarness {
    static var bundle: Bundle { Bundle(for: U4aBundleLocator.self) }

    static func loadConfig() throws -> LoadedEstimatorConfig {
        try LoadedEstimatorConfig.loadDefault(bundle: bundle)
    }

    static func loadRules() throws -> LoadedRuleLibrary {
        try LoadedRuleLibrary.loadDefault(bundle: bundle)
    }

    static func fixtureURL(named name: String) -> URL? {
        bundle.url(forResource: name, withExtension: "caf", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "caf")
    }

    /// Analysis of an in-memory synthetic signal. No session record exists, so the
    /// domain builder's Amendment-A3 path applies.
    static func analyzeSynthetic(name: String, signal: AudioSignal,
                                 knownJoin: (start: Double, end: Double)? = nil,
                                 sessionRecord: U4aSessionRecord? = nil) throws -> SourceReport {
        let config = try loadConfig()
        let rules = try loadRules()
        let provenance = CaptureProvenance(
            sourceID: .synthetic(name), fileSHA256: nil, sampleRate: signal.sampleRate,
            channelCount: 1, sampleFormat: .float32, fileDurationSeconds: signal.durationSeconds,
            captureConfiguration: .syntheticSignal, postProcessing: .synthetic,
            completeness: CompletenessRecord(recorded: sessionRecord?.completeness ?? .notApplicable,
                                             pattern: .none,
                                             patternEvidence: [], sessionWallSeconds: sessionRecord?.wallSeconds,
                                             audioRecordingReliable: nil, missingAudioIntervalCount: nil),
            isMultiSpeakerSource: false)
        let domain = AcousticAnalysisDomainBuilder.build(
            signal: signal, fileDurationSeconds: signal.durationSeconds, sessionRecord: sessionRecord,
            config: config.config, syntheticKnownJoin: knownJoin)
        return AcousticAnalyzer.analyze(.init(
            signal: signal, provenance: provenance, domain: domain, config: config, rules: rules,
            measurementParameters: rules.library.measurementParameters, extraFlags: [],
            allowAmplitudeMetricsOnAlteredSource: true))
    }

    /// Analysis of a real recording on disk.
    static func analyzeFile(url: URL, sourceID: SourceID,
                            captureConfiguration: CaptureConfiguration,
                            postProcessing: PostProcessing,
                            isMultiSpeakerSource: Bool,
                            sessionRecord: U4aSessionRecord? = nil,
                            allowAmplitudeMetricsOnAlteredSource: Bool = false) throws -> SourceReport {
        let config = try loadConfig()
        let rules = try loadRules()
        let loaded = try AudioSignalLoader.load(url: url)
        let completeness = CompletenessRecord(
            recorded: sessionRecord?.completeness ?? .notApplicable,
            pattern: .unknownPattern, patternEvidence: [],
            sessionWallSeconds: sessionRecord?.wallSeconds,
            audioRecordingReliable: sessionRecord?.audioRecordingReliable,
            missingAudioIntervalCount: sessionRecord?.missingAudioIntervalCount)
        let provenance = CaptureProvenance(
            sourceID: sourceID, fileSHA256: loaded.sha256, sampleRate: loaded.signal.sampleRate,
            channelCount: loaded.channelCount, sampleFormat: loaded.sampleFormat,
            fileDurationSeconds: Double(loaded.frameCount) / loaded.signal.sampleRate,
            captureConfiguration: captureConfiguration, postProcessing: postProcessing,
            completeness: completeness, isMultiSpeakerSource: isMultiSpeakerSource)
        let domain = AcousticAnalysisDomainBuilder.build(
            signal: loaded.signal, fileDurationSeconds: provenance.fileDurationSeconds,
            sessionRecord: sessionRecord, config: config.config)
        return AcousticAnalyzer.analyze(.init(
            signal: loaded.signal, provenance: provenance, domain: domain, config: config, rules: rules,
            measurementParameters: rules.library.measurementParameters, extraFlags: [],
            allowAmplitudeMetricsOnAlteredSource: allowAmplitudeMetricsOnAlteredSource))
    }

    /// Frame-level access for the M1 estimator checks, which need the per-frame series
    /// rather than the window aggregates a `SourceReport` carries.
    static func frames(for signal: AudioSignal) throws -> SpanFrames? {
        let config = try loadConfig()
        let rules = try loadRules()
        let provenance = CaptureProvenance(
            sourceID: .synthetic("frames"), fileSHA256: nil, sampleRate: signal.sampleRate,
            channelCount: 1, sampleFormat: .float32, fileDurationSeconds: signal.durationSeconds,
            captureConfiguration: .syntheticSignal, postProcessing: .synthetic,
            completeness: CompletenessRecord(recorded: .notApplicable, pattern: .none,
                                             patternEvidence: [], sessionWallSeconds: nil,
                                             audioRecordingReliable: nil, missingAudioIntervalCount: nil),
            isMultiSpeakerSource: false)
        let span = TimeSpan(spanID: 0, startSeconds: 0, endSeconds: signal.durationSeconds)
        let domain = AnalysisDomain(fileDurationSeconds: signal.durationSeconds,
                                    analyzableSpans: [span], excludedRegions: [], evidence: [],
                                    unresolvedRegions: [], wallClockMappingAvailable: false,
                                    joinSensitiveMeasurementsSuppressed: false, sourceExcluded: false)
        return AcousticAnalyzer.analyzeSpan(span: span, request: .init(
            signal: signal, provenance: provenance, domain: domain, config: config, rules: rules,
            measurementParameters: rules.library.measurementParameters, extraFlags: [],
            allowAmplitudeMetricsOnAlteredSource: true))
    }

    static func report(_ sources: [SourceReport]) throws -> U4aMeasurementReport {
        let config = try loadConfig()
        let rules = try loadRules()
        let manifest = RunManifest(
            schemaVersion: U4aMeasurementReport.Schema.version,
            estimatorVersion: EstimatorVersion.current,
            configID: config.config.configID, configVersion: config.config.configVersion,
            configSHA256: config.sha256, configInline: config.config,
            rulesLibraryID: rules.library.id, rulesLibraryVersion: rules.library.version,
            rulesSHA256: rules.sha256, calibrationStatus: rules.library.calibrationStatus,
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture)
        return U4aMeasurementReport(manifest: manifest, sources: sources)
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    /// Attaches the machine-readable artifact to the test run so it is extractable from
    /// the `.xcresult` bundle, and prints a `[u4a]` summary line per source so the
    /// numbers survive even if attachments are not browsed.
    static func attach(_ report: U4aMeasurementReport, named name: String) throws {
        let data = try report.encoded(pretty: true)
        Attachment.record(data, named: name)
        for source in report.sources {
            let valid = source.windowMeasurements.filter { $0.status.primary.isValid }.count
            let total = source.windowMeasurements.count
            print("[u4a] \(source.provenance.sourceID.stringValue): "
                  + "duration=\(fmt(source.provenance.fileDurationSeconds))s, "
                  + "spans=\(source.domain.analyzableSpans.count), "
                  + "analyzable=\(fmt(source.domain.analyzableSeconds))s, "
                  + "unresolved=\(source.domain.unresolvedRegions.count), "
                  + "windowMeasurements=\(valid)/\(total) valid, "
                  + "observations=\(source.observations.count), "
                  + "excluded=\(source.domain.sourceExcluded), "
                  + "joinSensitiveSuppressed=\(source.domain.joinSensitiveMeasurementsSuppressed)")
        }
    }

    static func fmt(_ v: Double, _ places: Int = 1) -> String {
        String(format: "%.\(places)f", v)
    }

    // MARK: Report queries used by several milestones

    static func spanValue(_ report: SourceReport, _ metric: MetricID, spanID: Int = 0) -> Double? {
        report.spanSummaries.first(where: { $0.span.spanID == spanID })?
            .measurements.first(where: { $0.metric == metric })?.value
    }

    static func windowValues(_ report: SourceReport, _ metric: MetricID) -> [Double] {
        report.windowMeasurements.filter { $0.metric == metric && $0.status.primary.isValid }
            .compactMap { $0.value }
    }
}

// MARK: - Deterministic synthetic signals

enum Synth {
    static let rate: Double = 48000

    /// Fixed-seed SplitMix64 — no system RNG anywhere, so reports stay byte-identical.
    struct Random {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUniform() -> Double {
            state &+= 0x9E3779B97F4A7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z = z ^ (z >> 31)
            return Double(z >> 11) / Double(1 << 53) * 2 - 1
        }
    }

    static func samples(seconds: Double) -> Int { Int(seconds * rate) }

    static func silence(seconds: Double) -> [Float] {
        [Float](repeating: 0, count: samples(seconds: seconds))
    }

    /// A noise bed is part of every synthetic case on purpose: the activity gate is
    /// defined relative to an ESTIMATED noise floor, and a signal with literally no
    /// floor (pure tone, or digital silence) gives the floor estimator nothing to
    /// work with. That is a property of the estimator worth stating, not hiding.
    static func noise(seconds: Double, dbfs: Double, seed: UInt64) -> [Float] {
        var rng = Random(seed: seed)
        let amp = pow(10, dbfs / 20) * 1.732   // uniform(-a,a) has RMS a/sqrt(3)
        return (0..<samples(seconds: seconds)).map { _ in Float(rng.nextUniform() * amp) }
    }

    static func tone(hz: Double, seconds: Double, dbfs: Double, phase: Double = 0) -> [Float] {
        let amp = pow(10, dbfs / 20) * 2.0.squareRoot()   // sine RMS = a/sqrt(2)
        return (0..<samples(seconds: seconds)).map {
            Float(amp * sin(2 * .pi * hz * Double($0) / rate + phase))
        }
    }

    /// Glottal-pulse-like: a harmonic stack with 1/n amplitude roll-off.
    static func harmonicStack(f0: Double, seconds: Double, dbfs: Double,
                              harmonics: Int = 8, skipFundamental: Bool = false) -> [Float] {
        let n = samples(seconds: seconds)
        var out = [Double](repeating: 0, count: n)
        let first = skipFundamental ? 2 : 1
        for h in first...harmonics {
            let f = f0 * Double(h)
            guard f < rate / 2 else { break }
            let a = 1.0 / Double(h)
            for i in 0..<n { out[i] += a * sin(2 * .pi * f * Double(i) / rate) }
        }
        let peak = out.map { abs($0) }.max() ?? 1
        let target = pow(10, dbfs / 20) * 2.0.squareRoot()
        let scale = peak > 0 ? target / peak : 0
        return out.map { Float($0 * scale) }
    }

    static func sweep(fromHz: Double, toHz: Double, seconds: Double, dbfs: Double) -> [Float] {
        let n = samples(seconds: seconds)
        let amp = pow(10, dbfs / 20) * 2.0.squareRoot()
        var phase = 0.0
        return (0..<n).map { i in
            let t = Double(i) / Double(n)
            let f = fromHz + (toHz - fromHz) * t
            phase += 2 * .pi * f / rate
            return Float(amp * sin(phase))
        }
    }

    static func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = max(a.count, b.count)
        return (0..<n).map { i in
            (i < a.count ? a[i] : 0) + (i < b.count ? b[i] : 0)
        }
    }

    static func concat(_ parts: [[Float]]) -> [Float] { parts.flatMap { $0 } }

    static func signal(_ samples: [Float]) -> AudioSignal {
        AudioSignal(samples: samples, sampleRate: rate)
    }

    /// Voiced burst train with known nucleus count: each burst is one amplitude peak.
    static func burstTrain(count: Int, burstSeconds: Double, gapSeconds: Double,
                           f0: Double, dbfs: Double, bedDbfs: Double, seed: UInt64) -> [Float] {
        var parts: [[Float]] = []
        for _ in 0..<count {
            // Raised-cosine amplitude envelope so each burst has exactly one peak.
            let burst = harmonicStack(f0: f0, seconds: burstSeconds, dbfs: dbfs)
            let n = burst.count
            let shaped = (0..<n).map { i -> Float in
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(max(1, n - 1)))
                return Float(Double(burst[i]) * w)
            }
            parts.append(shaped)
            parts.append(silence(seconds: gapSeconds))
        }
        let body = concat(parts)
        return mix(body, noise(seconds: Double(body.count) / rate, dbfs: bedDbfs, seed: seed))
    }
}
