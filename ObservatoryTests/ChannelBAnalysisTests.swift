import Foundation
import Testing

// U4a-2 Channel B, simulator side (PROPOSALS/U4a-2-plan.md §3):
//
//   - synthetic-array tests: every classifier, coverage, matching and fit path has a
//     case where the answer is known by construction
//   - the ASSESSMENT test: reads the extracted device harvests from
//     $OBSERVATORY_U4A_SESSION_BACKUP_DIR/u4a2-device-results/, computes Channel A here
//     over the same files, classifies, and attaches `U4a2ChannelBReport.json`. It skips
//     (does not fail) when that folder is absent, but it always executes and always
//     attaches the report with the hashed config in its manifest.

// MARK: - Deterministic synthetic Channel-B records

enum ChannelBSynth {
    static let fd = 0.01
    static let rate = 48000.0
    static let passageSeconds = 12.0

    static func mapping(_ plan: [VoiceAnalyticsFeedItem], source: String = "synthetic-b",
                        requestIndex: Int = 0) -> RequestInputMapping {
        RequestInputMapping.plan(sourceID: .synthetic(source), requestIndex: requestIndex, feedPlan: plan,
                                 sourceSampleRateHz: rate, submittedSampleRateHz: rate,
                                 submittedChannelCount: 1, submittedSampleFormat: .float32)
    }

    static func final(_ arrays: [VoiceFeature: [Double]]?, ordinal: Int = 0, callback: Int = 0) -> FinalResultRecord {
        FinalResultRecord(
            finalOrdinal: ordinal, callbackIndex: callback, metadata: nil,
            voiceAnalytics: arrays.map { a in
                VoiceFeature.allCases.compactMap { f in a[f].map { FeatureArray(feature: f, frameDuration: fd, rawValues: $0) } }
            })
    }

    static func harvest(_ plan: [VoiceAnalyticsFeedItem], finals: [FinalResultRecord],
                        outcome: ChunkOutcome = .succeeded, source: String = "synthetic-b",
                        requestIndex: Int = 0) -> RequestHarvest {
        let callbacks = finals.flatMap { f in
            [CallbackAuditEntry(callbackIndex: f.callbackIndex * 2, isFinal: false),
             CallbackAuditEntry(callbackIndex: f.callbackIndex * 2 + 1, isFinal: true)]
        }
        return RequestHarvest.assemble(
            mapping: mapping(plan, source: source, requestIndex: requestIndex), callbacks: callbacks,
            finals: finals, segmentDiagnostics: [], outcome: outcome,
            listeningEnd: outcome.succeeded ? .taskCompleted : .errorReceived,
            feedItemsCompleted: plan.count, feedItemCount: plan.count, endAudioCalled: true)
    }

    /// Passage-shaped arrays: voicing alternates in random-length blocks; pitch is finite
    /// only where voiced (non-finite elsewhere, exercising `excludeFrameFromCorrelation`).
    static func passage(seed: UInt64) -> [VoiceFeature: [Double]] {
        var rng = Synth.Random(seed: seed)
        let n = Int((passageSeconds / fd).rounded())
        var voicing: [Double] = [], pitch: [Double] = [], jitter: [Double] = [], shimmer: [Double] = []
        var voiced = false
        var level = 0.0
        while voicing.count < n {
            let run = 5 + Int((rng.nextUniform() + 1) * 18)
            for _ in 0..<run where voicing.count < n {
                voicing.append(voiced ? 0.85 + 0.1 * rng.nextUniform() : 0.1 + 0.05 * rng.nextUniform())
                level += 0.05 * rng.nextUniform()
                pitch.append(voiced ? 5.0 + level : .nan)
                jitter.append(abs(rng.nextUniform()))
                shimmer.append(abs(rng.nextUniform()))
            }
            voiced.toggle()
        }
        return [.voicing: voicing, .pitch: pitch, .jitter: jitter, .shimmer: shimmer]
    }

    static func lead(_ a: [VoiceFeature: [Double]], seconds: Double, extraPitchFrames: Int = 0) -> [VoiceFeature: [Double]] {
        let k = Int((seconds / fd).rounded())
        var out: [VoiceFeature: [Double]] = [:]
        for (f, v) in a {
            let fill: Double = f == .pitch ? .nan : 0
            if f == .pitch && extraPitchFrames > 0 {
                out[f] = Array(repeating: fill, count: k + extraPitchFrames) + v.dropLast(extraPitchFrames)
            } else {
                out[f] = Array(repeating: fill, count: k) + v
            }
        }
        return out
    }

    static func ladderPlan(_ k: Double) -> [VoiceAnalyticsFeedItem] {
        let passage: VoiceAnalyticsFeedItem = .source(0..<Int64(passageSeconds * rate))
        return k > 0 ? [.silence(seconds: k), passage] : [passage]
    }

    /// The five rungs the frozen config expects (0/5/10/20 + the rung-0 replicate),
    /// with `arrays(k, rep)` supplying each rung's winning-final arrays.
    static func ladder(_ arrays: (Double, Int) -> [VoiceFeature: [Double]]?,
                       outcome: (Double, Int) -> ChunkOutcome = { _, _ in .succeeded }) -> [LadderRungInput] {
        [(0.0, 0), (5, 0), (10, 0), (20, 0), (0, 1)].map { k, rep in
            LadderRungInput(leadingSilenceSeconds: k, replicateIndex: rep, harvestID: .trusted("syn-\(Int(k))-\(rep)"),
                            requests: [harvest(ladderPlan(k), finals: [final(arrays(k, rep))], outcome: outcome(k, rep))])
        }
    }

    static func supportedLadder(uncertainty: Double = fd) -> LadderAssessment {
        LadderAssessment(outcome: .alignmentSupported, reasons: [], rungs: [],
                         alignmentUncertainty: .measured(uncertainty, .alignmentUncertainty, .seconds),
                         scopeStatement: .anchorAAdoptedForThisConfigurationOnly)
    }

    static func unresolvedLadder() -> LadderAssessment {
        LadderAssessment(outcome: .alignmentUnresolved, reasons: [], rungs: [],
                         alignmentUncertainty: .unavailable(.alignmentUnresolved, .alignmentUncertainty, .seconds),
                         scopeStatement: .alignmentUnresolved)
    }

    /// One span from 0 s at the 10 ms Channel-A hop; `voiced(i)` decides each slot.
    static func track(slots: Int, voiced: (Int) -> Bool, f0: (Int) -> Double = { _ in 150 }) -> ChannelATrack {
        let states = (0..<slots).map { voiced($0) ? FrameState.voiced : .inactive }
        let f0s = (0..<slots).map { voiced($0) ? Optional(f0($0)) : nil }
        return ChannelATrack(spans: [.init(startSeconds: 0, hopSeconds: 0.01, states: states, f0: f0s)],
                             domainSeconds: Double(slots) * 0.01)
    }

    static func sourceRange(_ start: Double, _ end: Double) -> VoiceAnalyticsFeedItem {
        .source(Int64((start * rate).rounded())..<Int64((end * rate).rounded()))
    }

    static func flat(_ seconds: Double, _ value: Double) -> [VoiceFeature: [Double]] {
        let n = Int((seconds / fd).rounded())
        return Dictionary(uniqueKeysWithValues: VoiceFeature.allCases.map { ($0, Array(repeating: value, count: n)) })
    }
}

@Suite("U4a-2 M5 Channel B analysis (simulator)")
struct ChannelBAnalysisTests {

    static func config() throws -> LoadedChannelBConfig { try LoadedChannelBConfig.loadDefault() }

    static func b5(_ records: [B5Record], _ f: VoiceFeature, _ v: CoverageVariant) -> B5Record? {
        records.first { $0.feature == f && $0.variant == v }
    }

    // MARK: Config

    @Test("Frozen config loads, hashes, and names only implemented algorithms")
    func frozenConfig() throws {
        let loaded = try Self.config()
        let url = try #require(U4aHarness.bundle.url(forResource: "U4a2ChannelBConfig", withExtension: "json"))
        #expect(loaded.sha256 == U4aHash.hex(try Data(contentsOf: url)))
        let c = loaded.config
        #expect(c.configID == "u4a2.channelB.default" && c.configVersion == "0.1.0")
        #expect(c.ladder.passageSource == "fixture-solo-loudnorm")
        #expect(c.ladder.passageStartFrame == 1_824_000 && c.ladder.passageEndFrame == 2_400_000)
        #expect(c.ladder.leadingSilenceSeconds == [0, 5, 10, 20] && c.ladder.replicateRungs == [0])
        #expect(c.requestLifecycle.arm2ChunkSeconds == 55.0 && c.requestLifecycle.postFinalGraceSeconds == 5.0)
        #expect(c.fit.minimumMatchedFramesPerFixture == 200)
        let inputs = InputFileHash.current(config: c)
        let passage = inputs.first { $0.role == .ladderPassageSource }
        Swift.print("[u4a2] config \(c.configID) v\(c.configVersion) sha256=\(loaded.sha256)")
        for i in inputs {
            Swift.print("[u4a2] input \(i.role.rawValue) \(i.sourceID.stringValue) sha256=\(i.sha256 ?? "nil")")
        }
        #expect(passage?.sha256 != nil, "the A5 passage source must be hashable (director's binding condition)")
    }

    // MARK: A6 ladder classifier

    @Test("A6: a constructed ladder whose arrays shift by exactly the inserted silence reaches O-B1")
    func ladderSupported() throws {
        let c = try Self.config().config
        let base = ChannelBSynth.passage(seed: 7)
        let result = ChannelBAnalysis.classifyLadder(
            ChannelBSynth.ladder { k, _ in ChannelBSynth.lead(base, seconds: k) }, config: c)
        let lags = result.rungs.map { r in
            r.features.first { $0.feature == .voicing }?.lagFrames.value
        }
        Swift.print("[u4a2][A6] constructed O-B1: outcome=\(result.outcome.rawValue) reasons=\(result.reasons.count) "
            + "voicingLagFrames=\(lags.map { $0.map { String(Int($0)) } ?? "nil" }) "
            + "uncertainty=\(result.alignmentUncertainty.value.map { U4aHarness.fmt($0, 4) } ?? "nil")s")
        #expect(result.outcome == .alignmentSupported)
        #expect(result.reasons.isEmpty)
        #expect(lags == [nil, 500, 1000, 2000, 0])
        // Perfect construction ⇒ the residual is ~0 and the floor (one frameDuration) applies.
        #expect(result.alignmentUncertainty.value == ChannelBSynth.fd)
    }

    @Test("A6: constant lag, a short array, and a voicing/pitch disagreement each give O-B2")
    func ladderUnresolved() throws {
        let c = try Self.config().config
        let base = ChannelBSynth.passage(seed: 11)

        // (a) Arrays start at speech onset whatever silence was inserted, padded at the end
        // so durations still track — offsets do not.
        let constant = ChannelBAnalysis.classifyLadder(ChannelBSynth.ladder { k, _ in
            let n = Int(((k + ChannelBSynth.passageSeconds) / ChannelBSynth.fd).rounded())
            return base.mapValues { v in v + Array(repeating: v.last ?? 0, count: n - v.count) }
        }, config: c)

        // (b) Rung 10 returns only the passage-length array: shorter than the fed audio.
        let short = ChannelBAnalysis.classifyLadder(ChannelBSynth.ladder { k, _ in
            k == 10 ? base : ChannelBSynth.lead(base, seconds: k)
        }, config: c)

        // (c) Rung 5's pitch sits 3 frames later than its voicing.
        let disagree = ChannelBAnalysis.classifyLadder(ChannelBSynth.ladder { k, _ in
            ChannelBSynth.lead(base, seconds: k, extraPitchFrames: k == 5 ? 3 : 0)
        }, config: c)

        for (label, r) in [("constantLag", constant), ("shortArray", short), ("lagDisagreement", disagree)] {
            Swift.print("[u4a2][A6] \(label): outcome=\(r.outcome.rawValue) "
                + "reasons=\(r.reasons.map { "\($0.code.rawValue)@\($0.leadingSilenceSeconds.map { String(Int($0)) } ?? "-")" })")
            #expect(r.outcome == .alignmentUnresolved)
            #expect(r.alignmentUncertainty.value == nil, "no uncertainty is claimed without O-B1")
        }
        #expect(constant.reasons.contains { $0.code == .lagDoesNotTrackInsertedSilence })
        #expect(!constant.reasons.contains { $0.code == .durationDoesNotTrackFedAudio })
        #expect(short.reasons.contains { $0.code == .durationDoesNotTrackFedAudio && $0.leadingSilenceSeconds == 10 })
        #expect(disagree.reasons.map(\.code) == [.featureLagDisagreement])
    }

    @Test("A6: no analytics on any rung gives O-B3")
    func ladderNoAnalytics() throws {
        let c = try Self.config().config
        let r = ChannelBAnalysis.classifyLadder(ChannelBSynth.ladder({ _, _ in nil }, outcome: { k, _ in
            k == 20 ? .failed(domain: .trusted("kAFAssistantErrorDomain"), code: 1110) : .succeeded
        }), config: c)
        Swift.print("[u4a2][A6] empty result: outcome=\(r.outcome.rawValue) reasons=\(r.reasons.map(\.code.rawValue))")
        #expect(r.outcome == .noAnalyticsReturned)
        #expect(r.rungs.first { $0.leadingSilenceSeconds == 20 }?.availability == .failed)
    }

    // MARK: §8.7 B5

    @Test("B5: nil on a zero denominator, a legitimate 0.0 on established zero overlap")
    func b5ZeroCases() throws {
        let c = try Self.config().config
        let plan = [ChannelBSynth.sourceRange(0, 4)]
        let request = ChannelBSynth.harvest(plan, finals: [ChannelBSynth.final(ChannelBSynth.flat(4, .nan))])

        let noVoice = ChannelBAnalysis.coverage(channelA: ChannelBSynth.track(slots: 400, voiced: { _ in false }),
                                                requests: [request], ladder: ChannelBSynth.supportedLadder(), config: c)
        let voiced = ChannelBAnalysis.coverage(channelA: ChannelBSynth.track(slots: 400, voiced: { (100..<300).contains($0) }),
                                               requests: [request], ladder: ChannelBSynth.supportedLadder(), config: c)
        let nilCase = try #require(Self.b5(noVoice, .pitch, .wholeEligibleDomain))
        let zeroCase = try #require(Self.b5(voiced, .pitch, .wholeEligibleDomain))
        Swift.print("[u4a2][B5] zero denominator: coverage=\(nilCase.coverage.value.map { "\($0)" } ?? "nil") "
            + "| zero overlap: coverage=\(zeroCase.coverage.value.map { "\($0)" } ?? "nil") "
            + "denominator=\(zeroCase.denominator.value ?? -1)s")
        #expect(nilCase.coverage.value == nil)
        #expect(nilCase.coverage.status.primary == .unavailable(.estimatorFailed(.noEligibleFrames)))
        #expect(zeroCase.coverage.value == 0.0 && zeroCase.coverage.status.primary.isValid)
        #expect(abs((zeroCase.denominator.value ?? 0) - 2.0) < 1e-9)
        #expect(zeroCase.exactZeroFraction.value == nil, "no usable frames ⇒ no exact-zero fraction")
        #expect(zeroCase.statement == .coverageOfADetectedVoicedAudio)
    }

    @Test("B5: without O-B1 every coverage number is unavailable(.alignmentUnresolved)")
    func b5RequiresAlignment() throws {
        let c = try Self.config().config
        let request = ChannelBSynth.harvest([ChannelBSynth.sourceRange(0, 4)],
                                            finals: [ChannelBSynth.final(ChannelBSynth.flat(4, 0.5))])
        let records = ChannelBAnalysis.coverage(channelA: ChannelBSynth.track(slots: 400, voiced: { $0 >= 100 }),
                                                requests: [request], ladder: ChannelBSynth.unresolvedLadder(), config: c)
        #expect(records.count == c.coverage.features.count * c.coverage.variants.count)
        #expect(records.allSatisfy { $0.coverage.value == nil && $0.coverage.status.primary == .unavailable(.alignmentUnresolved) })
        #expect(records.allSatisfy { $0.numerator.value == nil })
    }

    @Test("B5: overlapping chunks are counted once (union, never a sum)")
    func b5OverlapCountedOnce() throws {
        let c = try Self.config().config
        let a = ChannelBSynth.harvest([ChannelBSynth.sourceRange(0, 4)],
                                      finals: [ChannelBSynth.final(ChannelBSynth.flat(4, 0.5))], requestIndex: 0)
        let b = ChannelBSynth.harvest([ChannelBSynth.sourceRange(2, 5)],
                                      finals: [ChannelBSynth.final(ChannelBSynth.flat(3, 0.5))], requestIndex: 1)
        let track = ChannelBSynth.track(slots: 500, voiced: { (100..<300).contains($0) || (400..<500).contains($0) })
        let r = try #require(Self.b5(ChannelBAnalysis.coverage(channelA: track, requests: [a, b],
                                                               ladder: ChannelBSynth.supportedLadder(), config: c),
                                     .voicing, .wholeEligibleDomain))
        Swift.print("[u4a2][B5] overlap: numerator=\(r.numerator.value ?? -1)s denominator=\(r.denominator.value ?? -1)s "
            + "coverage=\(r.coverage.value ?? -1) (a sum would give 1.333)")
        #expect(abs((r.numerator.value ?? 0) - 3.0) < 1e-6)
        #expect(abs((r.coverage.value ?? 0) - 1.0) < 1e-6)
    }

    @Test("B5: a failed chunk appears in both variants, labelled, and is not hidden")
    func b5FailedChunk() throws {
        let c = try Self.config().config
        let ok = ChannelBSynth.harvest([ChannelBSynth.sourceRange(0, 3)],
                                       finals: [ChannelBSynth.final(ChannelBSynth.flat(3, 0.5))], requestIndex: 0)
        let failed = ChannelBSynth.harvest([ChannelBSynth.sourceRange(3, 6)], finals: [],
                                           outcome: .failed(domain: .trusted("kAFAssistantErrorDomain"), code: 1110),
                                           requestIndex: 1)
        let track = ChannelBSynth.track(slots: 600, voiced: { (100..<200).contains($0) || (400..<500).contains($0) })
        let records = ChannelBAnalysis.coverage(channelA: track, requests: [ok, failed],
                                                ladder: ChannelBSynth.supportedLadder(), config: c)
        let whole = try #require(Self.b5(records, .pitch, .wholeEligibleDomain))
        let processed = try #require(Self.b5(records, .pitch, .successfullyProcessedFedIntervals))
        Swift.print("[u4a2][B5] failed chunk: whole=\(whole.coverage.value ?? -1) (\(whole.numerator.value ?? -1)/\(whole.denominator.value ?? -1)s) "
            + "processed=\(processed.coverage.value ?? -1) (\(processed.numerator.value ?? -1)/\(processed.denominator.value ?? -1)s) "
            + "failedRequests=\(whole.failedRequests.value ?? -1)")
        #expect(abs((whole.coverage.value ?? 0) - 0.5) < 1e-6)
        #expect(abs((processed.coverage.value ?? 0) - 1.0) < 1e-6)
        #expect(whole.failedRequests.value == 1 && processed.failedRequests.value == 1)
    }

    @Test("§8.3: superseded finals are counted and the last final wins")
    func supersededFinals() throws {
        let c = try Self.config().config
        let finals = [ChannelBSynth.final(ChannelBSynth.flat(4, .nan), ordinal: 0, callback: 0),
                      ChannelBSynth.final(ChannelBSynth.flat(4, .nan), ordinal: 1, callback: 1),
                      ChannelBSynth.final(ChannelBSynth.flat(4, 0.5), ordinal: 2, callback: 2)]
        let request = ChannelBSynth.harvest([ChannelBSynth.sourceRange(0, 4)], finals: finals)
        let r = try #require(Self.b5(ChannelBAnalysis.coverage(
            channelA: ChannelBSynth.track(slots: 400, voiced: { $0 >= 200 }), requests: [request],
            ladder: ChannelBSynth.supportedLadder(), config: c), .jitter, .wholeEligibleDomain))
        Swift.print("[u4a2][8.3] finals=\(request.finals.count) superseded=\(request.supersededFinalCount) "
            + "partials=\(request.callbacks.filter { !$0.isFinal }.count) coverageFromLastFinal=\(r.coverage.value ?? -1)")
        #expect(request.supersededFinalCount == 2)
        #expect(request.winningFinal?.finalOrdinal == 2)
        #expect(abs((r.coverage.value ?? 0) - 1.0) < 1e-6, "only the last final's (finite) arrays count")
    }

    // MARK: A8 + A9

    /// Three synthetic fixtures with B2 = 0.3 + 2.0·ln(F0) + small deterministic noise,
    /// voicing gaps every 50 slots so the A8 boundary guard has something to exclude.
    static func fitFixtures(slotsFor: (String) -> Int) throws
        -> (perFixture: [String: [ChannelBAnalysis.MatchedFrame]], expectedMatches: [String: Int]) {
        let c = try config().config
        var perFixture: [String: [ChannelBAnalysis.MatchedFrame]] = [:]
        var expected: [String: Int] = [:]
        for (n, name) in c.fit.fixtures.enumerated() {
            let slots = slotsFor(name)
            let voiced: (Int) -> Bool = { $0 % 50 >= 3 }
            let f0: (Int) -> Double = { 100 * exp(0.5 * sin(Double($0) / 37 + Double(n))) }
            let track = ChannelBSynth.track(slots: slots, voiced: voiced, f0: f0)
            var rng = Synth.Random(seed: 40 + UInt64(n))
            let pitch = (0..<slots).map { i in 0.3 + 2.0 * log(f0(i)) + 0.005 * rng.nextUniform() }
            let request = ChannelBSynth.harvest(
                [ChannelBSynth.sourceRange(0, Double(slots) * ChannelBSynth.fd)],
                finals: [ChannelBSynth.final([.pitch: pitch, .voicing: pitch, .jitter: pitch, .shimmer: pitch])],
                source: name)
            perFixture[name] = ChannelBAnalysis.matchFrames(channelA: track, requests: [request],
                                                            ladder: ChannelBSynth.supportedLadder()).frames
            // Guard = max(uncertainty, fd) = 10 ms ⇒ slots j-1, j, j+1 must all be voiced.
            expected[name] = (1..<(slots - 1)).filter { voiced($0 - 1) && voiced($0) && voiced($0 + 1) }.count
        }
        return (perFixture, expected)
    }

    static func value(_ r: FitRotation, _ q: ChannelBQuantity) -> Double? {
        r.values.first { $0.quantity == q }?.value
    }

    @Test("A8/A9: a known synthetic log relation is recovered, held-out step included")
    func fitRecoversKnownRelation() throws {
        let c = try Self.config().config
        let (perFixture, expected) = try Self.fitFixtures(slotsFor: { _ in 600 })
        for name in c.fit.fixtures {
            #expect(perFixture[name]?.count == expected[name], "A8 boundary guard must exclude exactly the edge frames")
        }
        let fit = ChannelBAnalysis.fit(perFixture: perFixture, bFrameDuration: ChannelBSynth.fd,
                                       ladder: ChannelBSynth.supportedLadder(), config: c)
        #expect(fit.rotations.count == 3)
        for r in fit.rotations {
            Swift.print("[u4a2][A9] heldOut=\(r.heldOut.rawValue): "
                + r.values.map { "\($0.quantity.rawValue)=\($0.value.map { U4aHarness.fmt($0, 4) } ?? "nil")" }.joined(separator: " "))
            #expect(abs((Self.value(r, .fitA) ?? 99) - 0.3) < 0.02)
            #expect(abs((Self.value(r, .fitB) ?? 99) - 2.0) < 0.005)
            #expect((Self.value(r, .fitR2) ?? 0) > 0.999)
            #expect((Self.value(r, .fitSpearmanRho) ?? 0) > 0.999)
            #expect((Self.value(r, .fitHeldOutRMSE) ?? 1) < 0.01)
            #expect(abs(Self.value(r, .fitHeldOutBias) ?? 1) < 0.005)
            #expect(r.values.allSatisfy { $0.status.primary.isValid })
        }
        #expect(fit.statement == .channelAErrorBoundsComparison)
    }

    @Test("A9: fewer than 200 matched frames in a fixture makes the rotations unavailable")
    func fitUnderMinimum() throws {
        let c = try Self.config().config
        let small = c.fit.fixtures[1]
        let (perFixture, _) = try Self.fitFixtures(slotsFor: { $0 == small ? 160 : 600 })
        let n = perFixture[small]?.count ?? 0
        #expect(n < c.fit.minimumMatchedFramesPerFixture)
        let fit = ChannelBAnalysis.fit(perFixture: perFixture, bFrameDuration: ChannelBSynth.fd,
                                       ladder: ChannelBSynth.supportedLadder(), config: c)
        Swift.print("[u4a2][A9] under-minimum: \(small) matched=\(n) ⇒ "
            + fit.rotations.map { "\($0.heldOut.rawValue):a=\(Self.value($0, .fitA).map { "\($0)" } ?? "nil")" }.joined(separator: " "))
        for r in fit.rotations {
            let a = try #require(r.values.first { $0.quantity == .fitA })
            guard case .unavailable(.insufficientEligibleSeconds) = a.status.primary else {
                Issue.record("rotation \(r.heldOut.rawValue) should be insufficientEligibleSeconds, got \(a.status.primary)")
                continue
            }
            #expect(a.value == nil)
            #expect(Self.value(r, .fitNFit) != nil && Self.value(r, .fitNTest) != nil, "counts stay reported")
        }
    }

    // MARK: Shared schema scan

    @Test("Schema scan: finite values only, explicit nulls, value != nil ⟺ .valid, numbers-only harvests")
    func schemaScan() throws {
        let loaded = try Self.config()
        let c = loaded.config
        let base = ChannelBSynth.passage(seed: 3)
        let ladderFiles: [U4a2HarvestFile] = ChannelBSynth.ladder { k, _ in ChannelBSynth.lead(base, seconds: k) }.map { r in
            U4a2HarvestFile(schemaVersion: U4a2HarvestFile.Schema.version,
                            manifest: Self.syntheticManifest(id: r.harvestID.rawValue, loaded: loaded),
                            kind: .ladderRung(leadingSilenceSeconds: r.leadingSilenceSeconds, replicateIndex: r.replicateIndex),
                            requests: r.requests)
        }
        let arm2Files: [U4a2HarvestFile] = c.fit.fixtures.map { name in
            let request = ChannelBSynth.harvest([ChannelBSynth.sourceRange(0, 6)],
                                                finals: [ChannelBSynth.final(ChannelBSynth.flat(6, 0.25))], source: name)
            return U4a2HarvestFile(schemaVersion: U4a2HarvestFile.Schema.version,
                                   manifest: Self.syntheticManifest(id: "arm2-\(name)", loaded: loaded),
                                   kind: .arm2Fixture, requests: [request])
        }
        let inputs = Self.syntheticInputs(c)
        let channelAManifest = try U4aHarness.report([]).manifest
        func assemble(_ files: [U4a2HarvestFile]) throws -> U4a2ChannelBReport {
            try ChannelBAnalysis.assemble(
                harvests: try files.map { ($0, U4aHash.hex(try U4aMeasurementReport.encoder(pretty: false).encode($0))) },
                undecodableFileCount: 0, loaded: loaded, channelAManifest: channelAManifest, inputFiles: inputs,
                channelA: { _ in ChannelBSynth.track(slots: 600, voiced: { $0 % 50 >= 3 }) })
        }
        // One supported run (valid values) and one with rung 20 missing (O-B2: explicit nulls).
        let supported = try assemble(ladderFiles + arm2Files)
        let unresolved = try assemble(ladderFiles.filter { $0.manifest.harvestID.rawValue != "syn-20-0" } + arm2Files)
        #expect(supported.ladder?.outcome == .alignmentSupported)
        #expect(unresolved.ladder?.outcome == .alignmentUnresolved)
        #expect(unresolved.arm2.allSatisfy { $0.coverage.allSatisfy { $0.coverage.value == nil } })

        var counts = (values: 0, nulls: 0, zeros: 0)
        var violations: [String] = []
        func walk(_ any: Any) {
            if let d = any as? [String: Any] {
                if d["quantity"] != nil, d["status"] != nil {
                    counts.values += 1
                    let valid = ((d["status"] as? [String: Any])?["primary"] as? [String: Any])?["valid"] != nil
                    let isNull = d["value"] is NSNull
                    if !d.keys.contains("value") { violations.append("value key omitted") }
                    if isNull { counts.nulls += 1 }
                    if valid && isNull { violations.append("valid with null") }
                    if !valid && !isNull { violations.append("unavailable carrying a value") }
                    if valid, let v = d["value"] as? Double {
                        if !v.isFinite { violations.append("non-finite") }
                        if v == 0 { counts.zeros += 1 }
                    }
                }
                d.values.forEach(walk)
            } else if let a = any as? [Any] { a.forEach(walk) }
        }
        for report in [supported, unresolved] {
            let data = try report.encoded()    // throws on any non-finite double
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("NaN") && !text.contains("Infinity"))
            walk(try JSONSerialization.jsonObject(with: data))
        }

        // Privacy: every string inside a harvest's request records is a closed-vocabulary
        // token or a charset-constrained id — nothing with room for transcript text.
        var harvestStrings = 0
        var freeText: [String] = []
        func strings(_ any: Any) {
            if let s = any as? String {
                harvestStrings += 1
                if ConstrainedID(s) == nil { freeText.append(s) }
            } else if let d = any as? [String: Any] {
                d.forEach { strings($0.key); strings($0.value) }
            } else if let a = any as? [Any] { a.forEach(strings) }
        }
        for f in ladderFiles + arm2Files {
            let json = try JSONSerialization.jsonObject(with: try U4aMeasurementReport.encoder(pretty: false).encode(f))
            strings(((json as? [String: Any])?["requests"]) ?? [])
        }

        Swift.print("[u4a2][schema] values=\(counts.values) explicitNulls=\(counts.nulls) legitimateZeros=\(counts.zeros) "
            + "violations=\(violations.count) harvestStrings=\(harvestStrings) freeText=\(freeText.count)")
        #expect(violations.isEmpty, "\(violations.prefix(5))")
        #expect(counts.values > 0 && counts.nulls > 0 && counts.zeros > 0)
        #expect(freeText.isEmpty, "harvest strings outside the constrained charset: \(freeText.prefix(5))")
    }

    static func syntheticInputs(_ c: U4a2ChannelBConfig) -> [InputFileHash] {
        [InputFileHash(role: .ladderPassageSource, sourceID: .fixture(c.ladder.passageSource), sha256: String(repeating: "a", count: 64))]
            + c.fit.fixtures.map { InputFileHash(role: .arm2Fixture, sourceID: .fixture($0), sha256: String(repeating: "b", count: 64)) }
    }

    static func syntheticManifest(id: String, loaded: LoadedChannelBConfig) -> HarvestManifest {
        HarvestManifest(harvestID: .trusted(id), channelBConfigID: loaded.config.configID,
                        channelBConfigVersion: loaded.config.configVersion, channelBConfigSHA256: loaded.sha256,
                        channelBConfigInline: loaded.config, inputFiles: syntheticInputs(loaded.config),
                        recognizerLocale: .trusted("en-US"), generatedAtISO8601: "synthetic",
                        osVersion: "synthetic", deviceModel: "synthetic", architecture: "synthetic")
    }

    // MARK: Assessment (reads the extracted device harvests)

    static func channelATrack(fixture: String) throws -> ChannelATrack? {
        guard let url = U4aHarness.fixtureURL(named: fixture) else { return nil }
        let config = try U4aHarness.loadConfig()
        let rules = try U4aHarness.loadRules()
        let loaded = try AudioSignalLoader.load(url: url)
        let duration = Double(loaded.frameCount) / loaded.signal.sampleRate
        let provenance = CaptureProvenance(
            sourceID: .fixture(fixture), fileSHA256: loaded.sha256, sampleRate: loaded.signal.sampleRate,
            channelCount: loaded.channelCount, sampleFormat: loaded.sampleFormat, fileDurationSeconds: duration,
            captureConfiguration: .unverifiedPreTuning, postProcessing: .none,
            completeness: CompletenessRecord(recorded: .notApplicable, pattern: .unknownPattern, patternEvidence: [],
                                             sessionWallSeconds: nil, audioRecordingReliable: nil,
                                             missingAudioIntervalCount: nil),
            isMultiSpeakerSource: fixture != "fixture-solo")
        let domain = AcousticAnalysisDomainBuilder.build(signal: loaded.signal, fileDurationSeconds: duration,
                                                         sessionRecord: nil, config: config.config)
        let request = AcousticAnalyzer.Request(
            signal: loaded.signal, provenance: provenance, domain: domain, config: config, rules: rules,
            measurementParameters: rules.library.measurementParameters, extraFlags: [],
            allowAmplitudeMetricsOnAlteredSource: false)
        let frames = domain.analyzableSpans.compactMap { AcousticAnalyzer.analyzeSpan(span: $0, request: request) }
        return ChannelATrack(frames: frames, domain: domain)
    }

    @Test("M5 assessment: classify the extracted device harvests and attach U4a2ChannelBReport.json")
    func assessment() throws {
        let loaded = try Self.config()
        let inputs = InputFileHash.current(config: loaded.config)
        let channelAManifest = try U4aHarness.report([]).manifest

        var harvests: [(file: U4a2HarvestFile, sha256: String)] = []
        var undecodable = 0
        let directory = U4aSessionStore.backupRoot()?.appendingPathComponent("u4a2-device-results", isDirectory: true)
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            let files = (FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL } ?? [])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.path < $1.path }
            for url in files {
                let data = try Data(contentsOf: url)
                if let file = try? JSONDecoder().decode(U4a2HarvestFile.self, from: data) {
                    harvests.append((file, U4aHash.hex(data)))
                } else {
                    undecodable += 1
                }
            }
        }

        let report = try ChannelBAnalysis.assemble(
            harvests: harvests, undecodableFileCount: undecodable, loaded: loaded,
            channelAManifest: channelAManifest, inputFiles: inputs,
            channelA: { try Self.channelATrack(fixture: $0) })
        Attachment.record(try report.encoded(pretty: true), named: "U4a2ChannelBReport.json")

        Swift.print("[u4a2] assessment: status=\(report.status.rawValue) configSHA256=\(loaded.sha256) "
            + "harvests=\(harvests.count) undecodable=\(undecodable) "
            + "passageSourceSHA256=\(inputs.first { $0.role == .ladderPassageSource }?.sha256 ?? "nil")")
        guard report.status == .assessed else {
            Swift.print("[u4a2] assessment SKIPPED: no device harvests under "
                + "\(directory?.path ?? "$OBSERVATORY_U4A_SESSION_BACKUP_DIR (unset)")/ — the report above is "
                + "attached with the hashed config only; a skipped assessment cannot satisfy M5 exit evidence")
            return
        }

        for h in report.manifest.harvests {
            Swift.print("[u4a2] harvest \(h.harvestID.rawValue): configMatch=\(h.configSHA256MatchesThisRun) "
                + "inputsMatch=\(h.inputHashesMatchThisRun) device=\(h.deviceModel)")
            #expect(h.configSHA256MatchesThisRun, "\(h.harvestID.rawValue) ran a different config")
            #expect(h.inputHashesMatchThisRun, "\(h.harvestID.rawValue) ran on different input files")
        }
        #expect(report.manifest.duplicateHarvestIDs.isEmpty)
        if let ladder = report.ladder {
            Swift.print("[u4a2] ladder outcome=\(ladder.outcome.rawValue) "
                + "uncertainty=\(ladder.alignmentUncertainty.value.map { U4aHarness.fmt($0, 4) } ?? "nil")s "
                + "reasons=\(ladder.reasons.map { "\($0.code.rawValue)@\($0.leadingSilenceSeconds.map { String($0) } ?? "-")/\($0.feature?.rawValue ?? "-")" })")
            for r in ladder.rungs {
                let parts = r.features.map { f in
                    "\(f.feature.rawValue):lag=\(f.lagFrames.value.map { String(Int($0)) } ?? "nil")"
                        + ",lagResid=\(f.lagResidual.value.map { U4aHarness.fmt($0, 4) } ?? "nil")"
                        + ",durResid=\(f.durationResidual.value.map { U4aHarness.fmt($0, 4) } ?? "nil")"
                }.joined(separator: " ")
                Swift.print("[u4a2] rung \(r.leadingSilenceSeconds)s rep\(r.replicateIndex): \(r.availability.rawValue) "
                    + "fed=\(r.fedDuration.value.map { U4aHarness.fmt($0, 3) } ?? "nil")s \(parts)")
            }
            // What fails M5 is a coverage number without established alignment.
            if ladder.outcome != .alignmentSupported {
                #expect(report.arm2.allSatisfy { $0.coverage.allSatisfy { $0.coverage.value == nil } })
            }
        }
        Swift.print("[u4a2] arm2 status=\(report.arm2Status.rawValue)")
        for f in report.arm2 {
            for b in f.coverage {
                Swift.print("[u4a2] B5 \(f.sourceID.id.rawValue) \(b.feature.rawValue) \(b.variant.rawValue): "
                    + "coverage=\(b.coverage.value.map { U4aHarness.fmt($0, 4) } ?? "nil") "
                    + "(\(b.numerator.value.map { U4aHarness.fmt($0, 2) } ?? "nil")/\(b.denominator.value.map { U4aHarness.fmt($0, 2) } ?? "nil")s) "
                    + "exactZero=\(b.exactZeroFraction.value.map { U4aHarness.fmt($0, 3) } ?? "nil") "
                    + "failedRequests=\(b.failedRequests.value.map { String(Int($0)) } ?? "nil") — \(b.statement.rawValue)")
            }
        }
        for r in report.fit?.rotations ?? [] {
            Swift.print("[u4a2] fit heldOut=\(r.heldOut.rawValue): "
                + r.values.map { "\($0.quantity.rawValue)=\($0.value.map { U4aHarness.fmt($0, 4) } ?? "nil")" }.joined(separator: " "))
        }
    }
}
