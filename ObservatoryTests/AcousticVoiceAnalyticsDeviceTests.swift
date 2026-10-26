// U4a-2 M5 device tests (PROPOSALS/U4a-proposal.md §10's name). They ONLY HARVEST:
// each feeds the frozen plan through `FixtureReplayHarness.harvestVoiceAnalytics`
// and attaches the raw numbers-only record as `U4a2Harvest-<id>.json`. All
// classification and math run later, on the simulator, from the extracted files
// (`ChannelBAnalysisTests.assessment`), so nothing here decides an outcome.
//
// Compiled out on the simulator so the simulator suite total stays comparable with
// U4a-1's (85 tests). Every test is its own isolated device action (D2–D9 of the plan),
// run one at a time with `-only-testing` and separate owner approval; D7–D9 run only
// if the ladder reached O-B1.

#if !targetEnvironment(simulator)
import AVFoundation
import Foundation
import Testing

@Suite("U4a-2 M5 device harvest (Channel B)", .serialized)
@MainActor
struct AcousticVoiceAnalyticsDeviceTests {

    // MARK: Arm 1 — the leading-silence ladder (A5)

    @Test("M5 Arm 1 ladder rung 0 s") func ladderRung0() async throws {
        try await Self.harvestLadderRung(leadingSilenceSeconds: 0, replicateIndex: 0)
    }
    @Test("M5 Arm 1 ladder rung 5 s") func ladderRung5() async throws {
        try await Self.harvestLadderRung(leadingSilenceSeconds: 5, replicateIndex: 0)
    }
    @Test("M5 Arm 1 ladder rung 10 s") func ladderRung10() async throws {
        try await Self.harvestLadderRung(leadingSilenceSeconds: 10, replicateIndex: 0)
    }
    @Test("M5 Arm 1 ladder rung 20 s") func ladderRung20() async throws {
        try await Self.harvestLadderRung(leadingSilenceSeconds: 20, replicateIndex: 0)
    }
    @Test("M5 Arm 1 ladder rung 0 s replicate") func ladderRung0Replicate() async throws {
        try await Self.harvestLadderRung(leadingSilenceSeconds: 0, replicateIndex: 1)
    }

    // MARK: Arm 2 — coverage on the three fixtures (only after O-B1)

    @Test("M5 Arm 2 fixture-solo") func arm2FixtureSolo() async throws {
        try await Self.harvestArm2(fixture: "fixture-solo")
    }
    @Test("M5 Arm 2 fixture-multi-a") func arm2FixtureMultiA() async throws {
        try await Self.harvestArm2(fixture: "fixture-multi-a")
    }
    @Test("M5 Arm 2 fixture-multi-b") func arm2FixtureMultiB() async throws {
        try await Self.harvestArm2(fixture: "fixture-multi-b")
    }

    // MARK: Shared

    static func harvestLadderRung(leadingSilenceSeconds k: Double, replicateIndex rep: Int) async throws {
        let loaded = try LoadedChannelBConfig.loadDefault()
        let config = loaded.config
        let ladder = config.ladder
        try #require(ladder.leadingSilenceSeconds.contains(k), "rung \(k) s is not in the frozen ladder")
        if rep > 0 {
            try #require(ladder.replicateRungs.filter { $0 == k }.count >= rep,
                         "replicate \(rep) of rung \(k) s is not in the frozen ladder")
        }
        let url = try #require(U4aHarness.fixtureURL(named: ladder.passageSource),
                               "\(ladder.passageSource) missing from the test bundle")
        let rate = try AVAudioFile(forReading: url).processingFormat.sampleRate
        try #require(rate == ladder.sourceSampleRateHz,
                     "passage source rate \(rate) Hz differs from the frozen \(ladder.sourceSampleRateHz) Hz")

        var plan: [VoiceAnalyticsFeedItem] = []
        if k > 0 { plan.append(.silence(seconds: k)) }
        plan.append(.source(ladder.passageStartFrame..<ladder.passageEndFrame))
        if ladder.trailingSilenceSeconds > 0 { plan.append(.silence(seconds: ladder.trailingSilenceSeconds)) }

        var requests: [RequestHarvest] = []
        for index in 0..<config.requestLifecycle.ladderRequestsPerRung {
            requests.append(try await FixtureReplayHarness.harvestVoiceAnalytics(
                audioURL: url, feedPlan: plan, sourceID: .fixture(ladder.passageSource),
                requestIndex: index, lifecycle: config.requestLifecycle))
        }
        let id = rep == 0 ? "ladder-rung-\(Int(k))" : "ladder-rung-\(Int(k))-replicate-\(rep)"
        try attach(id: id, kind: .ladderRung(leadingSilenceSeconds: k, replicateIndex: rep),
                   requests: requests, loaded: loaded)
    }

    static func harvestArm2(fixture: String) async throws {
        let loaded = try LoadedChannelBConfig.loadDefault()
        let config = loaded.config
        try #require(config.fit.fixtures.contains(fixture), "\(fixture) is not an Arm-2 fixture in the frozen config")
        let url = try #require(U4aHarness.fixtureURL(named: fixture), "\(fixture) missing from the test bundle")
        let file = try AVAudioFile(forReading: url)
        let total = file.length
        // A7: contiguous, non-overlapping chunks of at most arm2ChunkSeconds (E3 precedent).
        let chunk = max(Int64(1), Int64((config.requestLifecycle.arm2ChunkSeconds
                                         * file.processingFormat.sampleRate).rounded(.down)))
        var requests: [RequestHarvest] = []
        var start: Int64 = 0
        var index = 0
        while start < total {
            let end = min(start + chunk, total)
            requests.append(try await FixtureReplayHarness.harvestVoiceAnalytics(
                audioURL: url, feedPlan: [.source(start..<end)], sourceID: .fixture(fixture),
                requestIndex: index, lifecycle: config.requestLifecycle))
            start = end
            index += 1
        }
        try attach(id: "arm2-\(fixture)", kind: .arm2Fixture, requests: requests, loaded: loaded)
    }

    static func attach(id: String, kind: HarvestKind, requests: [RequestHarvest],
                       loaded: LoadedChannelBConfig) throws {
        let manifest = HarvestManifest(
            harvestID: .trusted(id),
            channelBConfigID: loaded.config.configID,
            channelBConfigVersion: loaded.config.configVersion,
            channelBConfigSHA256: loaded.sha256,
            channelBConfigInline: loaded.config,
            inputFiles: InputFileHash.current(config: loaded.config),
            recognizerLocale: .trusted("en-US"),
            generatedAtISO8601: ISO8601DateFormatter().string(from: Date()),
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: U4a2HarvestFile.deviceModel(),
            architecture: U4aHarness.currentArchitecture)
        let harvest = U4a2HarvestFile(schemaVersion: U4a2HarvestFile.Schema.version,
                                      manifest: manifest, kind: kind, requests: requests)
        let data = try U4aMeasurementReport.encoder(pretty: true).encode(harvest)
        Attachment.record(data, named: "U4a2Harvest-\(id).json")

        let passageHash = manifest.inputFiles.first { $0.role == .ladderPassageSource }?.sha256
        print("[u4a2] harvest \(id): requests=\(requests.count) "
              + "passageSourceSHA256=\(passageHash ?? "nil") configSHA256=\(loaded.sha256)")
        for r in requests {
            let arrays = r.winningFinal?.voiceAnalytics ?? []
            let shape = arrays.map { a in
                "\(a.feature.rawValue):n=\(a.count),fd=\(a.frameDuration.map { U4aHarness.fmt($0, 4) } ?? "nil"),nonFinite=\(a.nonFiniteCount)"
            }.joined(separator: " ")
            print("[u4a2] harvest \(id) request \(r.mapping.requestIndex): outcome=\(r.chunkOutcome) "
                  + "end=\(r.listeningEnd.rawValue) fed=\(U4aHarness.fmt(r.mapping.fedDurationSeconds, 3))s "
                  + "resampled=\(r.mapping.resampled) callbacks=\(r.callbacks.count) finals=\(r.finals.count) "
                  + "superseded=\(r.supersededFinalCount) analytics=\(r.winningFinal?.voiceAnalytics != nil) \(shape)")
        }
    }
}
#endif
