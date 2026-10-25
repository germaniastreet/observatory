import Foundation
import Testing

// U4a-1 milestones M2 (real measurements from real recordings — the behavioural
// milestone) and M4 (invariance controls on assets that already exist).
//
// Director ruling (d): real measurements from real recordings remain the milestone. If
// no rule fires on the real fixtures under the pre-registered uncalibrated thresholds,
// that is an honest finding, not a failure — there are no post-hoc threshold changes,
// and the firing machinery is verified by the controlled positive case below instead.
//
// M2 has two acceptable outcomes (review R6.7):
//   O-A1 full demonstration      — the named metrics come back valid with their coverage
//   O-A2 evidence-supported limitation — a metric is not obtainable, reported WITH the
//                                   specific evidence and what would be needed
// What fails is neither of those: missing coverage reporting, silent absence, or
// numbers presented without their validity context.

@Suite("U4a-1 M2/M4: real recordings")
struct AcousticFixtureObservationTests {

    struct FixtureCase {
        let name: String
        let isMultiSpeaker: Bool
    }

    static let fixtures = [
        FixtureCase(name: "fixture-solo", isMultiSpeaker: false),
        FixtureCase(name: "fixture-multi-a", isMultiSpeaker: true),
        FixtureCase(name: "fixture-multi-b", isMultiSpeaker: true)
    ]

    /// Pre-registered exploratory bands (§9 M2). REPORTED, not enforced: a value outside
    /// a band is a finding to investigate, not a test to loosen.
    struct Band {
        let label: String, low: Double, high: Double
        func check(_ v: Double?) -> String {
            guard let v else { return "\(label)=nil(OUT-OF-BAND: no value)" }
            let inBand = v >= low && v <= high
            return "\(label)=\(U4aHarness.fmt(v, 3))\(inBand ? "(in-band)" : "(OUT-OF-BAND \(low)-\(high))")"
        }
    }

    static func summarize(_ r: SourceReport) -> String {
        let f0 = U4aHarness.windowValues(r, .f0WindowMedian)
        let level = U4aHarness.windowValues(r, .levelWindowMedian)
        let gaps = U4aHarness.windowValues(r, .silenceGapSeconds)
        let rate = U4aHarness.windowValues(r, .syllableRatePerActiveSecond)
        func stat(_ v: [Double]) -> String {
            guard let m = AcousticAnalyzer.median(v) else { return "n=0" }
            return "n=\(v.count) median=\(U4aHarness.fmt(m, 2))"
        }
        return "f0[\(stat(f0))] level[\(stat(level))] gapSeconds[\(stat(gaps))] ratePerActiveSec[\(stat(rate))]"
    }

    static func outcome(_ r: SourceReport) -> String {
        let required: [MetricID] = [.f0WindowMedian, .levelWindowMedian, .silenceGapSeconds,
                                    .syllableRatePerActiveSecond]
        let missing = required.filter { U4aHarness.windowValues(r, $0).isEmpty }
        return missing.isEmpty ? "O-A1(full demonstration)"
                               : "O-A2(evidence-supported limitation: \(missing.map(\.rawValue).joined(separator: ",")))"
    }

    @Test("M2 Channel A over the three fixtures and two real sessions, with the artifact attached")
    func realRecordings() throws {
        var sources: [SourceReport] = []

        for fixture in Self.fixtures {
            let url = try #require(U4aHarness.fixtureURL(named: fixture.name),
                                   "fixture \(fixture.name) missing from the test bundle")
            let report = try U4aHarness.analyzeFile(
                url: url, sourceID: .fixture(fixture.name),
                // Recorded ~1 h before the `.measurement` capture tuning was committed.
                captureConfiguration: .unverifiedPreTuning, postProcessing: .none,
                isMultiSpeakerSource: fixture.isMultiSpeaker)
            sources.append(report)

            let voicedFraction = U4aHarness.spanValue(report, .spanVoicedFraction)
            let f0Median = U4aHarness.spanValue(report, .spanF0Median)
            let rates = U4aHarness.windowValues(report, .syllableRatePerActiveSecond)
            Swift.print("[u4a][M2] \(fixture.name): \(Self.outcome(report)) \(Self.summarize(report))")
            Swift.print("[u4a][M2] \(fixture.name) bands: "
                + Band(label: "voicedFraction", low: 0.30, high: 0.85).check(voicedFraction) + " "
                + Band(label: "medianF0Hz", low: 70, high: 300).check(f0Median) + " "
                + Band(label: "nucleusRatePerActiveSec", low: 2, high: 8)
                    .check(AcousticAnalyzer.median(rates)))
            Swift.print("[u4a][M2] \(fixture.name) diagnostics: "
                + "estimationSuccess=\(U4aHarness.spanValue(report, .spanEstimationSuccess).map { U4aHarness.fmt($0, 3) } ?? "nil") "
                + "railRate=\(U4aHarness.spanValue(report, .spanSearchRangeRailRate).map { U4aHarness.fmt($0, 3) } ?? "nil") "
                + "jumpRejectionRate=\(U4aHarness.spanValue(report, .spanOctaveJumpRejectionRate).map { U4aHarness.fmt($0, 3) } ?? "nil") "
                + "floor=\(U4aHarness.spanValue(report, .spanNoiseFloor).map { U4aHarness.fmt($0, 2) } ?? "nil")dBFS "
                + "indeterminateGaps=\(U4aHarness.spanValue(report, .spanIndeterminateGapCount).map { U4aHarness.fmt($0, 0) } ?? "nil")")
        }

        // Real sessions. Per director ruling (c) the backup root IS set for exit runs,
        // so a skip here cannot satisfy exit evidence — it only keeps the suite green on
        // a machine without the device backups.
        if let root = U4aSessionStore.backupRoot() {
            for (prefix, label) in [("9D4F101A", "u6b-incomplete"), ("4B9A04FD", "clean-73s")] {
                guard let record = U4aSessionStore.findRecord(sessionIDPrefix: prefix, under: root),
                      let audio = U4aSessionStore.findAudio(sessionID: record.id, under: root) else {
                    Swift.print("[u4a][M2] session \(prefix): NOT FOUND under the backup root")
                    continue
                }
                let report = try U4aHarness.analyzeFile(
                    url: audio, sourceID: .session(record.id),
                    captureConfiguration: .measurementModeConfirmed, postProcessing: .none,
                    isMultiSpeakerSource: false, sessionRecord: record)
                sources.append(report)

                Swift.print("[u4a][M2] session \(label) (\(prefix)): \(Self.outcome(report)) \(Self.summarize(report))")
                Swift.print("[u4a][M2] session \(label) domain: "
                    + "wallSeconds=\(record.wallSeconds.map { U4aHarness.fmt($0, 1) } ?? "nil") "
                    + "fileSeconds=\(U4aHarness.fmt(report.provenance.fileDurationSeconds, 1)) "
                    + "analyzable=\(U4aHarness.fmt(report.domain.analyzableSeconds, 1))s "
                    + "spans=\(report.domain.analyzableSpans.map { "[\(U4aHarness.fmt($0.startSeconds,1))-\(U4aHarness.fmt($0.endSeconds,1))]" }.joined()) "
                    + "wallClockMapping=\(report.domain.wallClockMappingAvailable)")
                for e in report.domain.evidence {
                    Swift.print("[u4a][M2] session \(label) evidence: \(e.source.rawValue) "
                        + "interval=\(e.intervalStartSeconds.map { U4aHarness.fmt($0, 2) } ?? "nil")-"
                        + "\(e.intervalEndSeconds.map { U4aHarness.fmt($0, 2) } ?? "nil") "
                        + "note=\(e.note.rawValue) assumptions=\(e.assumptions.map(\.rawValue).joined(separator: "+"))")
                }
            }
        } else {
            Swift.print("[u4a][M2] sessions SKIPPED: OBSERVATORY_U4A_SESSION_BACKUP_DIR is unset "
                + "(a skipped session test cannot satisfy exit evidence — director ruling (c))")
        }

        let report = try U4aHarness.report(sources)
        try U4aHarness.attach(report, named: "U4aMeasurementReport.json")

        // Every source must carry a populated domain and a coverage-bearing measurement
        // set. Neither outcome (O-A1/O-A2) excuses missing coverage reporting.
        for source in sources {
            #expect(!source.capability.isEmpty, "every source must carry its capability record")
            if !source.domain.sourceExcluded {
                #expect(!source.domain.analyzableSpans.isEmpty)
                #expect(!source.spanSummaries.isEmpty)
                for m in source.windowMeasurements {
                    #expect(m.coverage.nominalWindowSeconds > 0, "every measurement must carry coverage")
                }
            }
            // A source whose join location is unbounded must abstain from every
            // join-sensitive metric and emit NO observations, while still reporting its
            // frame-local measurements (§6.4).
            if source.domain.joinSensitiveMeasurementsSuppressed {
                #expect(source.observations.isEmpty)
                let joinSensitive = source.windowMeasurements.filter {
                    [.silenceGapSeconds, .nucleusRate, .syllableRatePerActiveSecond,
                     .levelDeltaFromSpanBaseline, .f0DeltaFromSpanBaseline].contains($0.metric)
                }
                #expect(joinSensitive.allSatisfy { $0.status.primary == .unavailable(.insideUnresolvedRegion) },
                        "join-sensitive metrics must abstain when the join is unbounded")
                let frameLocal = U4aHarness.windowValues(source, .levelWindowMedian)
                Swift.print("[u4a][M2] \(source.provenance.sourceID.stringValue) unbounded-join source: "
                    + "joinSensitiveAbstained=\(joinSensitive.count) frameLocalLevelValues=\(frameLocal.count)")
            }
        }
        #expect(sources.count >= 3)
    }

    @Test("M2 rule firing verified by a controlled positive case, not by tuning a real fixture")
    func controlledRuleFiring() throws {
        // Built to cross `u4a.intensityShift.rise` by a known +12 dB margin: a long quiet
        // voiced stretch establishes the span baseline, then the same voice 12 dB louder.
        //
        // The speech is INTERLEAVED WITH PAUSES on purpose. A continuously-voiced signal
        // has no noise floor below the speech, so the 10th-percentile estimator lands on
        // the quiet speech itself and the activity gate then rejects it — measured in an
        // earlier run of this very case, which produced zero eligible baseline seconds.
        func passage(dbfs: Double, blocks: Int, seed: UInt64) -> [Float] {
            var parts: [[Float]] = []
            for b in 0..<blocks {
                parts.append(Synth.mix(Synth.harmonicStack(f0: 150, seconds: 4.0, dbfs: dbfs),
                                       Synth.noise(seconds: 4.0, dbfs: -64, seed: seed &+ UInt64(b))))
                parts.append(Synth.noise(seconds: 1.0, dbfs: -64, seed: seed &+ 100 &+ UInt64(b)))
            }
            return Synth.concat(parts)
        }
        let signal = Synth.concat([passage(dbfs: -34, blocks: 10, seed: 101),
                                   passage(dbfs: -22, blocks: 3, seed: 201)])
        let report = try U4aHarness.analyzeSynthetic(name: "rule-positive-control",
                                                     signal: Synth.signal(signal))
        let fired = report.observations.filter { $0.ruleID.rawValue == "u4a.intensityShift.rise" }
        Swift.print("[u4a][M2-rule] controlled positive case: observations=\(report.observations.count) "
            + "intensityRise=\(fired.count) "
            + "firstObserved=\(fired.first.map { U4aHarness.fmt($0.observedValue, 2) } ?? "nil")dB "
            + "threshold=\(fired.first.map { U4aHarness.fmt($0.thresholdValue, 1) } ?? "nil")dB")
        #expect(!fired.isEmpty, "the rule-firing machinery must fire on a signal built to cross the threshold")
        for o in fired {
            #expect(o.measurement.status.primary.isValid)
            #expect(o.measurement.value != nil)
            #expect(o.calibrationStatus.rawValue == "uncalibrated-prototype")
        }
    }

    @Test("M4 invariance: F0 is gain-invariant and level tracks the known applied gain")
    func invarianceControls() throws {
        // Applied gains from PLAN.md E10b, peak-matched to -1.5 dBFS per fixture.
        let appliedGain: [String: Double] = ["fixture-multi-a": 12.0, "fixture-multi-b": 15.2,
                                             "fixture-solo": 18.7]
        for fixture in Self.fixtures {
            guard let baseURL = U4aHarness.fixtureURL(named: fixture.name),
                  let identityURL = U4aHarness.fixtureURL(named: "\(fixture.name)-identity"),
                  let gainURL = U4aHarness.fixtureURL(named: "\(fixture.name)-gain") else {
                Swift.print("[u4a][M4] \(fixture.name): variant missing from the bundle — SKIPPED")
                continue
            }
            func analyze(_ url: URL, _ post: PostProcessing) throws -> SourceReport {
                try U4aHarness.analyzeFile(url: url, sourceID: .fixture(fixture.name),
                                           captureConfiguration: .unverifiedPreTuning,
                                           postProcessing: post,
                                           isMultiSpeakerSource: fixture.isMultiSpeaker,
                                           // M4 is the one place amplitude metrics are
                                           // permitted on a level-altered source.
                                           allowAmplitudeMetricsOnAlteredSource: true)
            }
            let base = try analyze(baseURL, .none)
            let identity = try analyze(identityURL, .identityReencode)
            let gain = try analyze(gainURL, .flatGain(db: appliedGain[fixture.name] ?? 0))

            let f0Base = U4aHarness.spanValue(base, .spanF0Median)
            let f0Identity = U4aHarness.spanValue(identity, .spanF0Median)
            let f0Gain = U4aHarness.spanValue(gain, .spanF0Median)
            let lvlBase = AcousticAnalyzer.median(U4aHarness.windowValues(base, .levelWindowMedian))
            let lvlGain = AcousticAnalyzer.median(U4aHarness.windowValues(gain, .levelWindowMedian))

            func pct(_ a: Double?, _ b: Double?) -> Double? {
                guard let a, let b, b != 0 else { return nil }
                return abs(a - b) / b * 100
            }
            let identityErr = pct(f0Identity, f0Base)
            let gainErr = pct(f0Gain, f0Base)
            let levelDelta = (lvlGain != nil && lvlBase != nil) ? lvlGain! - lvlBase! : nil
            let expectedGain = appliedGain[fixture.name] ?? 0

            Swift.print("[u4a][M4] \(fixture.name): f0 base=\(f0Base.map { U4aHarness.fmt($0, 2) } ?? "nil")Hz "
                + "identity=\(f0Identity.map { U4aHarness.fmt($0, 2) } ?? "nil")Hz (\(identityErr.map { U4aHarness.fmt($0, 3) } ?? "nil")%) "
                + "gain=\(f0Gain.map { U4aHarness.fmt($0, 2) } ?? "nil")Hz (\(gainErr.map { U4aHarness.fmt($0, 3) } ?? "nil")%) | "
                + "level base=\(lvlBase.map { U4aHarness.fmt($0, 2) } ?? "nil")dBFS "
                + "gain=\(lvlGain.map { U4aHarness.fmt($0, 2) } ?? "nil")dBFS "
                + "delta=\(levelDelta.map { U4aHarness.fmt($0, 2) } ?? "nil")dB (expected \(expectedGain))")

            if let identityErr { #expect(identityErr <= 1.0, "F0 must survive an identity re-encode within 1%") }
            if let gainErr { #expect(gainErr <= 1.0, "F0 must be gain-invariant within 1%") }
            if let levelDelta {
                #expect(abs(levelDelta - expectedGain) <= 0.5,
                        "measured level change must match the known applied gain within 0.5 dB")
            }
        }
    }
}
