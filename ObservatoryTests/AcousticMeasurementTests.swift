import Foundation
import Testing

// U4a-1 milestones M1 (estimator checks against known answers) and M3 (abstention,
// join behaviour, schema invariants).
//
// Reporting discipline, per the proposal: every case prints the number it measured,
// including rejection and octave-error rates, so abstention cannot hide a failing
// estimator. Targets are PRE-REGISTERED; a miss is reported and the estimator revised,
// never absorbed by widening a tolerance.

@Suite("U4a-1 M1: estimator checks against known answers")
struct AcousticEstimatorCheckTests {

    /// Truth-scored F0 result for one synthetic case.
    struct F0Score {
        let label: String
        let truthHz: Double
        let medianHz: Double?
        let errorPercent: Double?
        let eligibleFrames: Int
        let estimatedFrames: Int
        let estimationSuccess: Double
        let octaveErrorRate: Double
        let railRate: Double
        let rejectionRate: Double
    }

    static func scoreF0(label: String, truthHz: Double, samples: [Float]) throws -> F0Score {
        let frames = try #require(try U4aHarness.frames(for: Synth.signal(samples)))
        // Score only the frames the pipeline would actually report — i.e. `voiced`.
        // Scoring every frame with a non-nil F0 (including ones the activity gate
        // rejected) flattered the estimator at low SNR in M1's first run.
        let values = zip(frames.state, frames.f0).compactMap { $0.0 == .voiced ? $0.1 : nil }
        let support = max(1, frames.f0SupportFrames)
        let octaveErrors = values.filter {
            abs($0 - truthHz * 2) / (truthHz * 2) < 0.05 || abs($0 - truthHz / 2) / (truthHz / 2) < 0.05
        }.count
        let median = AcousticAnalyzer.median(values)
        return F0Score(
            label: label, truthHz: truthHz, medianHz: median,
            errorPercent: median.map { abs($0 - truthHz) / truthHz * 100 },
            eligibleFrames: frames.f0EligibleFrames, estimatedFrames: values.count,
            estimationSuccess: frames.f0EligibleFrames > 0
                ? Double(values.count) / Double(frames.f0EligibleFrames) : 0,
            octaveErrorRate: values.isEmpty ? 0 : Double(octaveErrors) / Double(values.count),
            railRate: Double(frames.railHits) / Double(support),
            rejectionRate: Double(frames.octaveJumpRejections) / Double(support))
    }

    static func print(_ s: F0Score) {
        Swift.print("[u4a][M1-f0] \(s.label): truth=\(U4aHarness.fmt(s.truthHz, 1))Hz "
            + "median=\(s.medianHz.map { U4aHarness.fmt($0, 2) } ?? "nil")Hz "
            + "error=\(s.errorPercent.map { U4aHarness.fmt($0, 3) } ?? "nil")% "
            + "eligible=\(s.eligibleFrames) estimated=\(s.estimatedFrames) "
            + "success=\(U4aHarness.fmt(s.estimationSuccess, 3)) "
            + "octaveErrorRate=\(U4aHarness.fmt(s.octaveErrorRate, 3)) "
            + "railRate=\(U4aHarness.fmt(s.railRate, 3)) "
            + "jumpRejectionRate=\(U4aHarness.fmt(s.rejectionRate, 3))")
    }

    /// A voiced test signal: harmonic stack over a noise bed at a known SNR. The bed is
    /// deliberate — the activity gate is defined against an ESTIMATED noise floor, so a
    /// signal with no floor at all gives the estimator nothing to work with.
    static func voiced(f0: Double, seconds: Double = 2.0, snrDb: Double = 30,
                       skipFundamental: Bool = false, seed: UInt64 = 7) -> [Float] {
        let signalDb = -20.0
        let body = Synth.harmonicStack(f0: f0, seconds: seconds, dbfs: signalDb,
                                       skipFundamental: skipFundamental)
        let bed = Synth.noise(seconds: seconds, dbfs: signalDb - snrDb, seed: seed)
        let lead = Synth.noise(seconds: 1.0, dbfs: signalDb - snrDb, seed: seed &+ 1)
        let tail = Synth.noise(seconds: 1.0, dbfs: signalDb - snrDb, seed: seed &+ 2)
        return Synth.concat([lead, Synth.mix(body, bed), tail])
    }

    @Test("M1(iii) F0 accuracy on voiced synthetics, with rejection and octave-error rates")
    func f0Accuracy() throws {
        var scores: [F0Score] = []
        for f0 in [100.0, 150.0, 220.0, 300.0] {
            let s = try Self.scoreF0(label: "stack-\(Int(f0))Hz", truthHz: f0, samples: Self.voiced(f0: f0))
            Self.print(s)
            scores.append(s)
        }
        for s in scores {
            let error = try #require(s.errorPercent, "no F0 estimated for \(s.label)")
            #expect(error <= 1.0, "F0 error \(error)% exceeds the pre-registered 1% target for \(s.label)")
        }
    }

    @Test("M1(iii) F0 at the 60 Hz and 400 Hz search-range boundaries")
    func f0Boundaries() throws {
        for f0 in [60.0, 400.0] {
            let s = try Self.scoreF0(label: "boundary-\(Int(f0))Hz", truthHz: f0, samples: Self.voiced(f0: f0))
            Self.print(s)
            let error = try #require(s.errorPercent, "no F0 estimated at the \(f0) Hz boundary")
            #expect(error <= 1.0, "boundary F0 error \(error)% exceeds the 1% target at \(f0) Hz")
        }
    }

    @Test("M1(iii) missing fundamental, abrupt legitimate pitch change, periodic non-speech")
    func f0HardCases() throws {
        let missing = try Self.scoreF0(label: "missing-fundamental-150Hz", truthHz: 150,
                                       samples: Self.voiced(f0: 150, skipFundamental: true))
        Self.print(missing)

        // An abrupt, LEGITIMATE octave step. Octave-jump rejection must not erase it:
        // the frames either side must still be estimated, and the rejection count at the
        // step is reported rather than hidden.
        let step = Synth.concat([
            Synth.noise(seconds: 1.0, dbfs: -50, seed: 11),
            Synth.mix(Synth.harmonicStack(f0: 150, seconds: 1.5, dbfs: -20),
                      Synth.noise(seconds: 1.5, dbfs: -50, seed: 12)),
            Synth.mix(Synth.harmonicStack(f0: 300, seconds: 1.5, dbfs: -20),
                      Synth.noise(seconds: 1.5, dbfs: -50, seed: 13)),
            Synth.noise(seconds: 1.0, dbfs: -50, seed: 14)
        ])
        let frames = try #require(try U4aHarness.frames(for: Synth.signal(step)))
        let voicedF0 = zip(frames.frameTimes, zip(frames.state, frames.f0))
            .compactMap { t, sf -> (Double, Double)? in
                guard sf.0 == .voiced, let f = sf.1 else { return nil }
                return (t, f)
            }
        let firstHalf = voicedF0.filter { $0.0 > 1.3 && $0.0 < 2.4 }.map { $0.1 }
        let secondHalf = voicedF0.filter { $0.0 > 2.6 && $0.0 < 3.9 }.map { $0.1 }
        let m1 = AcousticAnalyzer.median(firstHalf)
        let m2 = AcousticAnalyzer.median(secondHalf)
        Swift.print("[u4a][M1-f0] abrupt-change-150to300: before=\(m1.map { U4aHarness.fmt($0, 2) } ?? "nil")Hz "
            + "after=\(m2.map { U4aHarness.fmt($0, 2) } ?? "nil")Hz "
            + "framesBefore=\(firstHalf.count) framesAfter=\(secondHalf.count) "
            + "jumpRejections=\(frames.octaveJumpRejections)")
        #expect(abs(try #require(m1) - 150) / 150 <= 0.01, "F0 before an abrupt change must stay accurate")
        #expect(abs(try #require(m2) - 300) / 300 <= 0.01, "F0 after an abrupt change must stay accurate")

        // Periodic non-speech: U4a cannot exclude it, and says so rather than pretending.
        let hum = try Self.scoreF0(label: "periodic-non-speech-220Hz-tone", truthHz: 220,
                                   samples: Synth.concat([
                                       Synth.noise(seconds: 1.0, dbfs: -50, seed: 21),
                                       Synth.mix(Synth.tone(hz: 220, seconds: 2.0, dbfs: -20),
                                                 Synth.noise(seconds: 2.0, dbfs: -50, seed: 22)),
                                       Synth.noise(seconds: 1.0, dbfs: -50, seed: 23)]))
        Self.print(hum)
        #expect(hum.estimatedFrames > 0,
                "a pure tone is expected to be called voiced — the capability record states this limit")
    }

    @Test("M1(iii) F0 degradation across known SNRs")
    func f0SNRDegradation() throws {
        for snr in [30.0, 20.0, 10.0, 5.0] {
            let s = try Self.scoreF0(label: "snr-\(Int(snr))dB-150Hz", truthHz: 150,
                                     samples: Self.voiced(f0: 150, snrDb: snr, seed: 31))
            Self.print(s)
        }
        // Reported as a degradation curve; no pre-registered target below 30 dB.
    }

    @Test("M1(i) activity boundaries and M1(ii) periodicity negative control")
    func activityAndPeriodicity() throws {
        // (i) Activity: a louder noise burst inside a quiet noise bed, known boundaries.
        let bed1 = Synth.noise(seconds: 1.0, dbfs: -60, seed: 41)
        let burst = Synth.noise(seconds: 1.0, dbfs: -25, seed: 42)
        let bed2 = Synth.noise(seconds: 1.0, dbfs: -60, seed: 43)
        let frames = try #require(try U4aHarness.frames(for: Synth.signal(Synth.concat([bed1, burst, bed2]))))
        let activeTimes = zip(frames.frameTimes, frames.state)
            .filter { $0.1 == .voiced || $0.1 == .activeAperiodic }.map { $0.0 }
        let onset = activeTimes.min()
        let offset = activeTimes.max()
        Swift.print("[u4a][M1-vad] noise-burst: onset=\(onset.map { U4aHarness.fmt($0, 3) } ?? "nil")s "
            + "(truth 1.000) offset=\(offset.map { U4aHarness.fmt($0, 3) } ?? "nil")s (truth 2.000) "
            + "activeFrames=\(activeTimes.count)")
        #expect(abs(try #require(onset) - 1.0) <= 0.030, "activity onset must land within 30 ms of truth")
        #expect(abs(try #require(offset) - 2.0) <= 0.030, "activity offset must land within 30 ms of truth")

        // (ii) A level-matched NOISE burst is a positive control for ACTIVITY and a
        // NEGATIVE control for periodic voicing. Conflating the two was the defect the
        // review caught; this case exists to keep them apart.
        let burstFrames = zip(frames.frameTimes, frames.state).filter { $0.0 > 1.05 && $0.0 < 1.95 }
        let voicedInBurst = burstFrames.filter { $0.1 == .voiced }.count
        let activeAperiodic = burstFrames.filter { $0.1 == .activeAperiodic }.count
        Swift.print("[u4a][M1-voicing] level-matched noise burst: voiced=\(voicedInBurst) "
            + "activeAperiodic=\(activeAperiodic) of \(burstFrames.count) frames")
        #expect(activeAperiodic > 0, "a loud noise burst must be classified as active")
        #expect(Double(voicedInBurst) / Double(max(1, burstFrames.count)) <= 0.05,
                "aperiodic noise must not be classified as periodic voicing")
    }

    @Test("M1(iv) level accuracy and a known amplitude step")
    func levelAccuracy() throws {
        for target in [-30.0, -20.0, -12.0] {
            let samples = Synth.concat([
                Synth.noise(seconds: 0.5, dbfs: target - 40, seed: 51),
                Synth.mix(Synth.tone(hz: 180, seconds: 2.0, dbfs: target),
                          Synth.noise(seconds: 2.0, dbfs: target - 40, seed: 52)),
                Synth.noise(seconds: 0.5, dbfs: target - 40, seed: 53)])
            let frames = try #require(try U4aHarness.frames(for: Synth.signal(samples)))
            let levels = zip(frames.frameTimes, frames.levelDb)
                .filter { $0.0 > 0.7 && $0.0 < 2.3 }.compactMap { $0.1 }
            let median = try #require(AcousticAnalyzer.median(levels))
            Swift.print("[u4a][M1-level] tone@\(U4aHarness.fmt(target, 1))dBFS: "
                + "measured=\(U4aHarness.fmt(median, 3))dBFS error=\(U4aHarness.fmt(median - target, 3))dB")
            #expect(abs(median - target) <= 0.5, "level error exceeds the pre-registered 0.5 dB target")
        }
    }

    @Test("M1(v) detected-nucleus counts on known burst trains")
    func nucleusCounts() throws {
        for count in [5, 10] {
            let samples = Synth.concat([
                // Lead/tail long enough that the span clears `minSpanSecondsForFloor`
                // even for the 5-burst case: with no floor there is no activity gate,
                // and every frame is correctly `unknown` rather than a nucleus.
                Synth.noise(seconds: 2.0, dbfs: -60, seed: 61),
                Synth.burstTrain(count: count, burstSeconds: 0.20, gapSeconds: 0.12,
                                 f0: 150, dbfs: -20, bedDbfs: -60, seed: 62),
                Synth.noise(seconds: 2.0, dbfs: -60, seed: 63)])
            let frames = try #require(try U4aHarness.frames(for: Synth.signal(samples)))
            Swift.print("[u4a][M1-nuclei] burstTrain(\(count)): detected=\(frames.nucleusTimes.count)")
            #expect(frames.nucleusTimes.count == count,
                    "clean burst train nucleus count must be exact (truth \(count), got \(frames.nucleusTimes.count))")
        }
    }

    @Test("M1(vi) noise-floor estimator on known mixtures, a mid-file floor step, and mic-mute silence")
    func noiseFloorValidation() throws {
        // Known stationary floor under voiced bursts.
        for floorDb in [-60.0, -45.0] {
            let samples = Synth.concat([
                Synth.noise(seconds: 2.0, dbfs: floorDb, seed: 71),
                Synth.mix(Synth.harmonicStack(f0: 140, seconds: 2.0, dbfs: -20),
                          Synth.noise(seconds: 2.0, dbfs: floorDb, seed: 72)),
                Synth.noise(seconds: 2.0, dbfs: floorDb, seed: 73)])
            let frames = try #require(try U4aHarness.frames(for: Synth.signal(samples)))
            let estimated = try #require(frames.noiseFloorDb)
            Swift.print("[u4a][M1-floor] stationary floor truth=\(U4aHarness.fmt(floorDb, 1))dBFS "
                + "estimated=\(U4aHarness.fmt(estimated, 2))dBFS error=\(U4aHarness.fmt(estimated - floorDb, 2))dB")
            #expect(abs(estimated - floorDb) <= 2.0,
                    "floor estimate is more than 2 dB from the known stationary floor")
        }

        // Changing background: the floor STEPS mid-file. A single span-wide percentile
        // cannot represent two floors; the error is measured and reported, not hidden.
        let stepped = Synth.concat([Synth.noise(seconds: 3.0, dbfs: -60, seed: 74),
                                    Synth.noise(seconds: 3.0, dbfs: -40, seed: 75)])
        let steppedFrames = try #require(try U4aHarness.frames(for: Synth.signal(stepped)))
        Swift.print("[u4a][M1-floor] stepped background (-60 then -40 dBFS): "
            + "singleSpanEstimate=\(steppedFrames.noiseFloorDb.map { U4aHarness.fmt($0, 2) } ?? "nil")dBFS "
            + "— a span-scoped percentile represents one floor, so this is a KNOWN limit, "
            + "detected separately as join evidence")

        // Mic-mute-like digital silence embedded in a real-ish bed.
        let muted = Synth.concat([Synth.noise(seconds: 2.0, dbfs: -45, seed: 76),
                                  Synth.silence(seconds: 2.0),
                                  Synth.noise(seconds: 2.0, dbfs: -45, seed: 77)])
        let mutedFrames = try #require(try U4aHarness.frames(for: Synth.signal(muted)))
        let zeroFrames = mutedFrames.zeroEnergy.filter { $0 }.count
        Swift.print("[u4a][M1-floor] embedded digital silence: zeroEnergyFrames=\(zeroFrames) "
            + "floor=\(mutedFrames.noiseFloorDb.map { U4aHarness.fmt($0, 2) } ?? "nil")dBFS "
            + "(zero-energy frames contribute no level value and are never given an invented floor)")
        #expect(zeroFrames > 100, "embedded digital silence must be detected as zero-energy frames")
        #expect(mutedFrames.f0.allSatisfy { $0 == nil || $0! > 0 }, "no F0 value may be zero")
    }
}

@Suite("U4a-1 M3: abstention, join behaviour, schema invariants")
struct AcousticAbstentionTests {

    @Test("M3 negative recordings produce zero observations and explicit statuses")
    func negativeRecordings() throws {
        // (a) digital silence
        let silence = try U4aHarness.analyzeSynthetic(
            name: "digital-silence", signal: Synth.signal(Synth.silence(seconds: 6.0)))
        let silenceFloor = silence.spanSummaries.first?.measurements
            .first { $0.metric == .spanNoiseFloor }
        Swift.print("[u4a][M3] digital-silence: observations=\(silence.observations.count) "
            + "floorStatus=\(String(describing: silenceFloor?.status.primary)) "
            + "validWindowMeasurements=\(silence.windowMeasurements.filter { $0.status.primary.isValid }.count)")
        #expect(silence.observations.isEmpty)
        #expect(silenceFloor?.value == nil, "a floor cannot be estimated from zero-energy frames")

        // (b) white noise at -50 dBFS: a floor exists, nothing rises above it
        let noise = try U4aHarness.analyzeSynthetic(
            name: "white-noise-50dbfs",
            signal: Synth.signal(Synth.noise(seconds: 6.0, dbfs: -50, seed: 81)))
        let voicedSeconds = U4aHarness.spanValue(noise, .spanVoicedSeconds) ?? -1
        Swift.print("[u4a][M3] white-noise-50dBFS: observations=\(noise.observations.count) "
            + "voicedSeconds=\(U4aHarness.fmt(voicedSeconds, 2)) "
            + "floor=\(U4aHarness.spanValue(noise, .spanNoiseFloor).map { U4aHarness.fmt($0, 2) } ?? "nil")dBFS")
        #expect(noise.observations.isEmpty)
        #expect(voicedSeconds == 0, "stationary noise must not produce voiced time")

        // (c) the real 4096-byte header-only orphan recording, if the backups are reachable
        if let root = U4aSessionStore.backupRoot(),
           let orphan = U4aSessionStore.findAudio(sessionID: "5FF28F05-46C4-480D-A7CF-B079813E1511", under: root) {
            var threw = false
            do {
                _ = try AudioSignalLoader.load(url: orphan)
            } catch {
                threw = true
                Swift.print("[u4a][M3] orphan header-only recording: handled as \(error) — no crash")
            }
            #expect(threw, "a zero-frame recording must be refused, not analyzed")
        } else {
            Swift.print("[u4a][M3] orphan header-only recording: SKIPPED (no backup root)")
        }
    }

    @Test("M3 join controls: a detectable join is bounded; a seamless join is honestly undetectable")
    func joinControls() throws {
        let config = try U4aHarness.loadConfig()

        // Detectable: a near-digital-silence region between two recorded stretches,
        // exactly the OS mic-mute signature Hermes measured on real sessions.
        let detectable = Synth.concat([
            Synth.mix(Synth.harmonicStack(f0: 150, seconds: 4.0, dbfs: -25),
                      Synth.noise(seconds: 4.0, dbfs: -55, seed: 91)),
            Synth.noise(seconds: 2.0, dbfs: -88, seed: 92),
            Synth.mix(Synth.harmonicStack(f0: 190, seconds: 4.0, dbfs: -25),
                      Synth.noise(seconds: 4.0, dbfs: -55, seed: 93))])
        let candidates = JoinSignalScanner.scan(signal: Synth.signal(detectable), config: config.config)
        Swift.print("[u4a][M3] detectable join (truth 4.0-6.0s): candidates="
            + candidates.map { "\($0.source.rawValue)[\(U4aHarness.fmt($0.start, 2))-\(U4aHarness.fmt($0.end, 2))]" }
                .joined(separator: ","))
        let covers = candidates.contains { $0.start <= 4.2 && $0.end >= 5.8 }
        #expect(covers, "the near-silence join must fall inside a reported candidate region")

        // And the domain must still yield usable spans EITHER SIDE — a join control is
        // not a negative recording (review R6.9). Splitting only happens for a source
        // whose record says capture was incomplete, so the control carries one.
        let record = U4aSessionRecord(
            id: "synthetic-join", audioFileName: nil, startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 12), completeness: .incomplete(endpointAudioSeconds: 10),
            recognitionContinuityGaps: [], audioRecordingReliable: true, missingAudioIntervalCount: 0)
        let report = try U4aHarness.analyzeSynthetic(name: "join-detectable",
                                                     signal: Synth.signal(detectable),
                                                     sessionRecord: record)
        let spans = report.domain.analyzableSpans
        Swift.print("[u4a][M3] detectable join domain: spans=\(spans.count) "
            + spans.map { "[\(U4aHarness.fmt($0.startSeconds, 2))-\(U4aHarness.fmt($0.endSeconds, 2))]" }.joined()
            + " analyzable=\(U4aHarness.fmt(report.domain.analyzableSeconds, 2))s "
            + "validWindowMeasurements=\(report.windowMeasurements.filter { $0.status.primary.isValid }.count)")
        #expect(spans.count == 2, "a bounded join must split the domain, leaving a usable span either side")
        #expect(spans.allSatisfy { $0.endSeconds <= 3.1 || $0.startSeconds >= 6.9 },
                "no analyzable span may overlap the guarded join region")
        #expect(report.windowMeasurements.contains { $0.status.primary.isValid },
                "valid measurements must still be produced in the safe spans")

        // Seamless: same source, same level, no signature at all. The honest outcome is
        // that signal evidence finds NOTHING — which is why lifecycle evidence cannot be
        // replaced by waveform inspection.
        let halfA = Synth.mix(Synth.harmonicStack(f0: 150, seconds: 4.0, dbfs: -25),
                              Synth.noise(seconds: 4.0, dbfs: -55, seed: 94))
        let halfB = Synth.mix(Synth.harmonicStack(f0: 150, seconds: 4.0, dbfs: -25),
                              Synth.noise(seconds: 4.0, dbfs: -55, seed: 95))
        let seamless = Synth.concat([halfA, halfB])
        let seamlessCandidates = JoinSignalScanner.scan(signal: Synth.signal(seamless), config: config.config)
        Swift.print("[u4a][M3] seamless join (truth 4.0s): candidates=\(seamlessCandidates.count) "
            + "— audio alone cannot localise this join, by construction")
        #expect(seamlessCandidates.isEmpty,
                "a seamless join must produce no signal candidate; detecting one would be a false positive")
    }

    @Test("M3 schema invariants hold in the encoded artifact")
    func schemaInvariants() throws {
        let sources = [
            try U4aHarness.analyzeSynthetic(name: "schema-voiced",
                                            signal: Synth.signal(AcousticEstimatorCheckTests.voiced(f0: 150, seconds: 12))),
            try U4aHarness.analyzeSynthetic(name: "digital-silence", signal: Synth.signal(Synth.silence(seconds: 6)))
        ]
        let report = try U4aHarness.report(sources)
        let data = try report.encoded()          // throws on any non-finite double
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Infinity") && !text.contains("NaN"))

        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        var measurementCount = 0, explicitNulls = 0, legitimateZeros = 0
        var violations: [String] = []

        func walkMeasurement(_ m: [String: Any]) {
            measurementCount += 1
            let statusValid = ((m["status"] as? [String: Any])?["primary"] as? [String: Any])?["valid"] != nil
            let hasValueKey = m.keys.contains("value")
            let isNull = m["value"] is NSNull
            if !hasValueKey { violations.append("measurement omits the value key") }
            if isNull { explicitNulls += 1 }
            if statusValid && isNull { violations.append("status .valid with a null value") }
            if !statusValid && !isNull { violations.append("unavailable status carrying a value") }
            if statusValid, let v = m["value"] as? Double {
                if !v.isFinite { violations.append("non-finite value encoded") }
                if v == 0 { legitimateZeros += 1 }
            }
        }
        func walk(_ any: Any) {
            if let dict = any as? [String: Any] {
                if dict["metric"] != nil && dict["coverage"] != nil { walkMeasurement(dict) }
                dict.values.forEach(walk)
            } else if let arr = any as? [Any] {
                arr.forEach(walk)
            }
        }
        walk(json)

        Swift.print("[u4a][M3] schema scan: measurements=\(measurementCount) explicitNulls=\(explicitNulls) "
            + "legitimateZeros=\(legitimateZeros) violations=\(violations.count)")
        #expect(violations.isEmpty, "schema violations: \(violations.prefix(5).joined(separator: "; "))")
        #expect(measurementCount > 0)
        #expect(explicitNulls > 0, "the silence source must emit explicit nulls, not omitted keys")
        #expect(legitimateZeros > 0, "legitimate zeros must encode as 0 with a valid status")
    }

    @Test("M3 determinism: identical input yields a byte-identical canonical payload")
    func determinism() throws {
        let signal = Synth.signal(AcousticEstimatorCheckTests.voiced(f0: 150, seconds: 12))
        let a = try U4aHarness.report([try U4aHarness.analyzeSynthetic(name: "determinism", signal: signal)])
        let b = try U4aHarness.report([try U4aHarness.analyzeSynthetic(name: "determinism", signal: signal)])
        let pa = try a.canonicalPayload(), pb = try b.canonicalPayload()
        Swift.print("[u4a][M3] determinism: canonicalBytes=\(pa.count) identical=\(pa == pb) "
            + "(scoped to this pinned environment; cross-environment identity is not claimed)")
        #expect(pa == pb)
        #expect(a.manifest.generatedAtISO8601 != "" )
    }
}
