import AVFoundation
import Foundation
import Testing
@testable import Observatory

/// Anchors `Bundle(for:)` to the ObservatoryTests bundle -- Swift Testing
/// structs aren't `NSObject`s, so this empty class exists purely to give
/// `Bundle(for:)` something defined inside this target to key off of.
private final class BundleLocator {}

private struct FixtureCase {
    let name: String
    let expectedMinimumSpeakers: Int
    let expectedMaximumSpeakers: Int?

    /// Real word count from this exact recording's original live capture
    /// (`completed_reflections_v1.json`, summed over `transcript[].words`,
    /// verified directly against the pulled device metadata) -- the ground
    /// truth a replay is actually being checked against. Without this, a
    /// recognizer that returns almost nothing still passes a bare
    /// `wordCount > 0` check: fixture-solo did exactly that, recognizing
    /// only 26 of its real 149 words (an ~83% deficit) while still "passing"
    /// -- a second-opinion review caught this, not this test suite.
    ///
    /// Metric-hygiene caveat (per the ChatGPT review, E10): `wordCount /
    /// groundTruthWordCount` is a raw count ratio, not an alignment-verified
    /// score -- it has no way to detect insertions, substitutions, or
    /// repeated words, any of which could inflate it relative to true
    /// accuracy. Treat every fidelity percentage in this file as an upper
    /// bound on accuracy, not a confirmed one, until a follow-up does
    /// aligned WER scoring.
    let groundTruthWordCount: Int
}

@Suite("Stage 0 audio fixture replay")
struct AudioFixtureReplayTests {
    /// Locates a fixture inside the test bundle -- never the production
    /// `Application Support/Observatory/Audio` directory. Tries both a
    /// "Fixtures" subdirectory (if Xcode preserved the folder structure)
    /// and the bundle root (if it flattened resources), since which one
    /// applies depends on how the `.caf` files are configured as target
    /// resources.
    private static func fixtureURL(named name: String) -> URL? {
        let bundle = Bundle(for: BundleLocator.self)
        return bundle.url(forResource: name, withExtension: "caf", subdirectory: "Fixtures")
            ?? bundle.url(forResource: name, withExtension: "caf")
    }

    private static let cases = [
        FixtureCase(name: "fixture-multi-a", expectedMinimumSpeakers: 2, expectedMaximumSpeakers: nil, groundTruthWordCount: 288),
        FixtureCase(name: "fixture-solo", expectedMinimumSpeakers: 1, expectedMaximumSpeakers: 1, groundTruthWordCount: 149),
        FixtureCase(name: "fixture-multi-b", expectedMinimumSpeakers: 2, expectedMaximumSpeakers: nil, groundTruthWordCount: 192)
    ]

    /// Below this fraction of a fixture's real original word count, a
    /// replay doesn't count as having actually transcribed the recording --
    /// see `FixtureCase.groundTruthWordCount`'s doc comment for why a bare
    /// `wordCount > 0` floor isn't enough.
    private static let minimumWordFidelity = 0.7

    @MainActor
    @Test("Selected recordings preserve word timing and expected speaker separation")
    func replaySelectedRecordings() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: fixture.name),
                "Fixture '\(fixture.name).caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            // `configureAudioSession`/`matchLiveTapFormat` default to `true`
            // -- this replay is meant to be a fair stand-in for the live
            // path, not a harness-specific artifact of skipping either.
            let result = try await FixtureReplayHarness.replay(audioURL: audioURL)

            #expect(result.audioDuration.isFinite && result.audioDuration > 0)
            #expect(
                Double(result.wordCount) >= Double(fixture.groundTruthWordCount) * Self.minimumWordFidelity,
                "\(fixture.name): recognized \(result.wordCount) words, below \(Int(Self.minimumWordFidelity * 100))% of the real \(fixture.groundTruthWordCount)."
            )
            #expect(result.zeroOrInvalidWordIntervals == 0)
            #expect(result.wordsPastAudioEnd == 0)
            #expect(result.nonMonotonicWordOffsets == 0)
            #expect(result.diarizationCompleted)
            #expect(result.speakerCount >= fixture.expectedMinimumSpeakers)
            if let maximum = fixture.expectedMaximumSpeakers {
                #expect(result.speakerCount <= maximum)
            }

            // E2 (per Hermes's directive): numeric-only instrumentation to
            // discriminate a request-duration/lifecycle defect in the
            // harness from a genuine on-device recognition limitation.
            // `maxSegmentOffsetCovered` far short of `audioDuration` means
            // the recognizer stopped listening long before the audio ended,
            // independent of what the later content contains.
            print("[fixture-replay] \(fixture.name): duration=\(result.audioDuration)s, words=\(result.wordCount)/\(fixture.groundTruthWordCount), speakers=\(result.speakerCount), overlapWords=\(result.overlapWordCount), unknownWords=\(result.unknownWordCount), utterances=\(result.utteranceCount), resultsYielded=\(result.resultsYielded), firstFinalElapsed=\(result.firstFinalElapsedSeconds.map { String(format: "%.1f", $0) } ?? "nil")s, endAudioBeforeFinal=\(result.endAudioCalledBeforeFirstFinal), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s")
        }
    }

    /// E1 (per Hermes's directive): replays only the first and last 30
    /// seconds of `fixture-solo` to discriminate a hard request-duration
    /// cutoff (same word count regardless of which 30s slice, or regardless
    /// of total length) from a genuine content-dependent recognition
    /// problem (proportional word count, ~49 for a healthy recognizer on a
    /// 30/91 slice of 149 real words). Reproducible, in-tree -- not
    /// disabled by default is intentional for now while this investigation
    /// is active; re-add a `.disabled` trait once concluded, per the
    /// pattern used for the now-removed session/format diagnostic (whose
    /// question this file already answered: both were ruled out).
    @MainActor
    @Test("Diagnostic: duration-slice test for fixture-solo (E1)")
    func diagnosticDurationSlice() async throws {
        let audioURL = try #require(Self.fixtureURL(named: "fixture-solo"))
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let sliceFrames = AVAudioFramePosition(30.0 * sampleRate)

        let firstSlice = AVAudioFramePosition(0)..<min(sliceFrames, totalFrames)
        let lastSlice = max(0, totalFrames - sliceFrames)..<totalFrames

        for (label, range) in [("first 30s", firstSlice), ("last 30s", lastSlice)] {
            let result = try await FixtureReplayHarness.replay(audioURL: audioURL, frameRange: range)
            print("[E1] fixture-solo \(label): words=\(result.wordCount) (expected ~49 if proportional to 149 real words over 91.1s), resultsYielded=\(result.resultsYielded), firstFinalElapsed=\(result.firstFinalElapsedSeconds.map { String(format: "%.1f", $0) } ?? "nil")s, endAudioBeforeFinal=\(result.endAudioCalledBeforeFirstFinal), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / fed=\(String(format: "%.1f", result.audioDuration))s")
        }
    }

    /// E3 (per Hermes's directive): required regardless of E1/E2 outcome.
    /// Replays each fixture as a sequence of ≤55s requests instead of one
    /// unbroken request spanning the whole file -- see
    /// `FixtureReplayHarness.replayChunked`'s doc comment for exactly which
    /// production rollover behavior this mirrors. If this recovers
    /// near-ground-truth word counts where the single-request replay in
    /// `replaySelectedRecordings()` did not, that is itself the deciding
    /// evidence that the under-transcription was a single-overlong-request
    /// harness artifact, not a genuine on-device recognition limitation --
    /// not disabled by default while this investigation is active, same as
    /// `diagnosticDurationSlice()` above.
    @MainActor
    @Test("Diagnostic: production-matching chunked replay (E3)")
    func diagnosticChunkedReplay() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: fixture.name),
                "Fixture '\(fixture.name).caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            let result = try await FixtureReplayHarness.replayChunked(audioURL: audioURL)

            let passesFidelity = Double(result.wordCount) >= Double(fixture.groundTruthWordCount) * Self.minimumWordFidelity
            let timingOK = result.zeroOrInvalidWordIntervals == 0 && result.wordsPastAudioEnd == 0 && result.nonMonotonicWordOffsets == 0

            print("[E3] \(fixture.name): words=\(result.wordCount)/\(fixture.groundTruthWordCount), fidelityPass=\(passesFidelity), speakers=\(result.speakerCount), overlapWords=\(result.overlapWordCount), unknownWords=\(result.unknownWordCount), utterances=\(result.utteranceCount), resultsYielded=\(result.resultsYielded), timingAssertionsPass=\(timingOK), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / duration=\(String(format: "%.1f", result.audioDuration))s")
        }
    }

    /// E5 (per Hermes's directive): isolates signal level as a single
    /// variable. `fixture-*-loudnorm.caf` are new files generated from the
    /// read-only baselines via `ffmpeg -af loudnorm=I=-16:TP=-1.5:LRA=11`,
    /// then explicitly resampled back to the baselines' own 48kHz
    /// mono/pcm_f32le format (`loudnorm`'s true-peak limiting otherwise
    /// forces 192kHz output, which would have made sample rate a second,
    /// unintended variable). Measured via `ffmpeg -af volumedetect`: mean
    /// level moved from -37.4/-38.1/-46.5 dB to roughly -17 to -19 dB for
    /// multi-a/multi-b/solo respectively, peaks capped at -1.5 dBFS -- see
    /// PLAN.md's fidelity investigation for the pre-normalization numbers.
    /// Same `replayChunked` call as E3, same ground truth, only the input
    /// audio's level differs -- if fidelity jumps toward the 70% floor
    /// here where E3 fell short, level is the dominant factor.
    @MainActor
    @Test("Diagnostic: gain-normalization A/B (E5)")
    func diagnosticGainNormalization() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: "\(fixture.name)-loudnorm"),
                "Fixture '\(fixture.name)-loudnorm.caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            let result = try await FixtureReplayHarness.replayChunked(audioURL: audioURL)

            let passesFidelity = Double(result.wordCount) >= Double(fixture.groundTruthWordCount) * Self.minimumWordFidelity
            let timingOK = result.zeroOrInvalidWordIntervals == 0 && result.wordsPastAudioEnd == 0 && result.nonMonotonicWordOffsets == 0

            print("[E5] \(fixture.name)-loudnorm: words=\(result.wordCount)/\(fixture.groundTruthWordCount), fidelityPass=\(passesFidelity), speakers=\(result.speakerCount), overlapWords=\(result.overlapWordCount), unknownWords=\(result.unknownWordCount), utterances=\(result.utteranceCount), resultsYielded=\(result.resultsYielded), timingAssertionsPass=\(timingOK), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / duration=\(String(format: "%.1f", result.audioDuration))s")
        }
    }

    /// E6 (per Hermes's directive): required regardless of E5's outcome.
    /// Replays one ~55s chunk of each fixture via a real `AVAudioEngine`
    /// tap (`FixtureReplayHarness.replayLiveTap`) instead of the paced
    /// manual-append loop every other diagnostic here uses, to rule out a
    /// feed-style artifact in the harness itself as a confound distinct
    /// from signal level or recognizer behavior. Ground truth here is only
    /// a loose proportional expectation (chunk covers roughly the first 55s
    /// of a longer recording, not the whole thing), so this prints raw
    /// counts rather than asserting a fidelity floor.
    @MainActor
    @Test("Diagnostic: live-tap feed (E6)")
    func diagnosticLiveTapFeed() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: fixture.name),
                "Fixture '\(fixture.name).caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            let result = try await FixtureReplayHarness.replayLiveTap(audioURL: audioURL)

            print("[E6] \(fixture.name): words=\(result.wordCount) (fed \(String(format: "%.1f", result.audioDuration))s of \(fixture.groundTruthWordCount) real words total), speakers=\(result.speakerCount), overlapWords=\(result.overlapWordCount), unknownWords=\(result.unknownWordCount), utterances=\(result.utteranceCount), resultsYielded=\(result.resultsYielded), firstFinalElapsed=\(result.firstFinalElapsedSeconds.map { String(format: "%.1f", $0) } ?? "nil")s, endAudioBeforeFinal=\(result.endAudioCalledBeforeFirstFinal), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s")
        }
    }

    /// E8 (per ChatGPT's suggested audit, incorporated via Hermes's
    /// re-sequencing ahead of E7): logs every recognition callback
    /// (partial + final) for one ~55s chunk of each fixture, via
    /// `replay(frameRange:onCallback:)` -- computed directly from
    /// `result.bestTranscription` before this harness's own aggregation
    /// (`SpeechTranscriptTimingMapper`) ever runs. See
    /// `RecognitionCallbackLogEntry`'s doc comment for exactly what this
    /// does and doesn't prove. 3 repeat trials per fixture per the
    /// director's note on run-to-run variance.
    @MainActor
    @Test("Diagnostic: raw callback/aggregation audit (E8)")
    func diagnosticCallbackAudit() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: fixture.name),
                "Fixture '\(fixture.name).caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            let file = try AVAudioFile(forReading: audioURL)
            let sampleRate = file.processingFormat.sampleRate
            let chunkFrames = min(file.length, AVAudioFramePosition(55.0 * sampleRate))

            for trial in 1...3 {
                var log: [RecognitionCallbackLogEntry] = []
                let result: FixtureReplayResult
                do {
                    result = try await FixtureReplayHarness.replay(
                        audioURL: audioURL,
                        frameRange: 0..<chunkFrames,
                        onCallback: { entry in log.append(entry) }
                    )
                } catch {
                    // Matches `replayChunked`'s own precedent for a chunk
                    // with no recognizable speech (`kAFAssistantErrorDomain`
                    // code 1110) -- treat as empty, continue to the next
                    // trial instead of aborting the whole diagnostic.
                    print("[E8] \(fixture.name) trial \(trial) produced no final result (\(error.localizedDescription)) -- treating as empty, continuing.")
                    continue
                }

                for entry in log {
                    print("[E8] \(fixture.name) trial \(trial) callback #\(entry.callbackIndex): elapsed=\(String(format: "%.1f", entry.elapsedSeconds))s, isFinal=\(entry.isFinal), transcriptLength=\(entry.transcriptLength), segmentCount=\(entry.segmentCount), segmentOffsets=\(entry.minSegmentOffset.map { String(format: "%.1f", $0) } ?? "nil")-\(entry.maxSegmentOffset.map { String(format: "%.1f", $0) } ?? "nil")s")
                }
                print("[E8] \(fixture.name) trial \(trial) FINAL: words=\(result.wordCount), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / fed=\(String(format: "%.1f", result.audioDuration))s")
            }
        }
    }

    /// E9 (per ChatGPT's suggested control, incorporated via Hermes's
    /// re-sequencing ahead of E7; passage fixture corrected by the
    /// director to `fixture-multi-b-loudnorm` -- solo showed zero gain
    /// response in E5, so a failed `.alone` arm there would be
    /// uninterpretable as duration/position vs. "this fixture doesn't
    /// respond at all"). Passage window (36.0-48.0s) is chosen from
    /// E5/E6's own prior device evidence that this fixture recognizes
    /// words starting around there (E6's unnormalized first-chunk run
    /// covered 36.0-44.9s), not a guess. 3 repeat trials per arm per the
    /// director's note on run-to-run variance.
    ///
    /// Per the director's correction: trailing silence (`.start`'s own
    /// padding) can trigger the recognizer's endpointing and finalize the
    /// request early, which would look like truncation but isn't --
    /// `firstFinalElapsed` in the printed output is how to tell the two
    /// apart (an early final well short of the fed duration means
    /// endpointing-on-silence, not a duration/position limit).
    @MainActor
    @Test("Diagnostic: short-passage position control, multi-b (E9)")
    func diagnosticShortPassageControl() async throws {
        let audioURL = try #require(Self.fixtureURL(named: "fixture-multi-b-loudnorm"))
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let passageRange = AVAudioFramePosition(36.0 * sampleRate)..<AVAudioFramePosition(48.0 * sampleRate)

        for position: PassagePosition in [.alone, .start, .end] {
            for trial in 1...3 {
                let result: FixtureReplayResult
                do {
                    result = try await FixtureReplayHarness.replayPassagePositionControl(
                        audioURL: audioURL,
                        passageRange: passageRange,
                        totalDuration: 55,
                        position: position
                    )
                } catch {
                    print("[E9] multi-b-loudnorm .\(position) trial \(trial) produced no final result (\(error.localizedDescription)) -- treating as empty, continuing.")
                    continue
                }
                print("[E9] multi-b-loudnorm .\(position) trial \(trial): words=\(result.wordCount), fedDuration=\(String(format: "%.1f", result.audioDuration))s, firstFinalElapsed=\(result.firstFinalElapsedSeconds.map { String(format: "%.1f", $0) } ?? "nil")s, endAudioBeforeFinal=\(result.endAudioCalledBeforeFirstFinal), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s")
            }
        }
    }

    /// E9 secondary, optional (per the director: "run solo-loudnorm as a
    /// secondary passage if device time allows"). solo already showed zero
    /// gain response in E5 -- this mainly checks whether `.alone` *also*
    /// fails to recover a known-good passage on this specific fixture,
    /// independent of duration/position. Passage window (38.0-50.0s)
    /// matches E6's unnormalized first-chunk coverage for this fixture
    /// (40.3-50.5s). Single trial per arm, not 3x, to keep this lighter
    /// given its "if time allows" framing.
    @MainActor
    @Test("Diagnostic: short-passage position control, solo secondary (E9b)")
    func diagnosticShortPassageControlSecondarySolo() async throws {
        let audioURL = try #require(Self.fixtureURL(named: "fixture-solo-loudnorm"))
        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let passageRange = AVAudioFramePosition(38.0 * sampleRate)..<AVAudioFramePosition(50.0 * sampleRate)

        for position: PassagePosition in [.alone, .start, .end] {
            let result: FixtureReplayResult
            do {
                result = try await FixtureReplayHarness.replayPassagePositionControl(
                    audioURL: audioURL,
                    passageRange: passageRange,
                    totalDuration: 55,
                    position: position
                )
            } catch {
                print("[E9b] solo-loudnorm .\(position) produced no final result (\(error.localizedDescription)) -- treating as empty, continuing.")
                continue
            }
            print("[E9b] solo-loudnorm .\(position): words=\(result.wordCount), fedDuration=\(String(format: "%.1f", result.audioDuration))s, firstFinalElapsed=\(result.firstFinalElapsedSeconds.map { String(format: "%.1f", $0) } ?? "nil")s, endAudioBeforeFinal=\(result.endAudioCalledBeforeFirstFinal), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s")
        }
    }

    /// E10a (per the ChatGPT review): replays the identity-reencode
    /// fixtures (`ffmpeg` round-tripped through the exact same
    /// pcm_f32le/48kHz path E5's loudnorm fixtures used, but with no
    /// `loudnorm` filter -- verified via `ffmpeg -af volumedetect` to have
    /// identical mean/peak levels to the baselines) through the same
    /// chunked path as E3/E5. Isolates "did merely re-encoding change
    /// anything" from "did the gain change matter" -- this should match
    /// E3's numbers closely if re-encoding itself is a non-factor.
    @MainActor
    @Test("Diagnostic: identity re-encode control (E10a)")
    func diagnosticIdentityControl() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: "\(fixture.name)-identity"),
                "Fixture '\(fixture.name)-identity.caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            for trial in 1...3 {
                let result = try await FixtureReplayHarness.replayChunked(audioURL: audioURL)
                let passesFidelity = Double(result.wordCount) >= Double(fixture.groundTruthWordCount) * Self.minimumWordFidelity
                print("[E10a] \(fixture.name)-identity trial \(trial): words=\(result.wordCount)/\(fixture.groundTruthWordCount), fidelityPass=\(passesFidelity), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / duration=\(String(format: "%.1f", result.audioDuration))s")
            }
        }
    }

    /// E10b (per the director's correction): per-fixture flat digital gain
    /// (`ffmpeg -af volume=XdB`, no `loudnorm` dynamics processing) sized
    /// so true peak lands at exactly -1.5 dBFS for each fixture
    /// individually -- NOT a flat +20dB, which would have clipped
    /// multi-a/multi-b (their original peaks of -13.5/-16.7 dBFS are too
    /// hot for a uniform +20dB). Computed gains: multi-a +12.0dB, multi-b
    /// +15.2dB, solo +18.7dB. Verified via `ffmpeg -af volumedetect`
    /// post-generation: all three hit exactly -1.5 dBFS peak, no clipping.
    /// Isolates a simple linear gain bump from loudnorm's additional
    /// dynamics compression.
    @MainActor
    @Test("Diagnostic: fixed per-fixture gain control (E10b)")
    func diagnosticFixedGainControl() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: "\(fixture.name)-gain"),
                "Fixture '\(fixture.name)-gain.caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            for trial in 1...3 {
                let result = try await FixtureReplayHarness.replayChunked(audioURL: audioURL)
                let passesFidelity = Double(result.wordCount) >= Double(fixture.groundTruthWordCount) * Self.minimumWordFidelity
                print("[E10b] \(fixture.name)-gain trial \(trial): words=\(result.wordCount)/\(fixture.groundTruthWordCount), fidelityPass=\(passesFidelity), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / duration=\(String(format: "%.1f", result.audioDuration))s")
            }
        }
    }

    /// E10c (per the ChatGPT review): re-runs the manual/chunked path
    /// under `.playAndRecord` -- the same session category E6's live-tap
    /// arm needed (see `replayLiveTap`'s doc comment) -- via
    /// `replayChunked`'s new `sessionCategory` parameter, to isolate the
    /// feed mechanism from the category change itself. If this matches
    /// E3's `.record` numbers closely, category isn't the confound in the
    /// E3-vs-E6 comparison; if it differs, category is a second variable
    /// that comparison didn't control for.
    @MainActor
    @Test("Diagnostic: E6 session-category control (E10c)")
    func diagnosticSessionCategoryControl() async throws {
        for fixture in Self.cases {
            let audioURL = try #require(
                Self.fixtureURL(named: fixture.name),
                "Fixture '\(fixture.name).caf' isn't in the ObservatoryTests bundle -- check target resource membership."
            )
            for trial in 1...3 {
                let result = try await FixtureReplayHarness.replayChunked(audioURL: audioURL, sessionCategory: .playAndRecord)
                let passesFidelity = Double(result.wordCount) >= Double(fixture.groundTruthWordCount) * Self.minimumWordFidelity
                print("[E10c] \(fixture.name) trial \(trial) (.playAndRecord): words=\(result.wordCount)/\(fixture.groundTruthWordCount), fidelityPass=\(passesFidelity), coveredOffsets=\(result.minSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")-\(result.maxSegmentOffsetCovered.map { String(format: "%.1f", $0) } ?? "nil")s / duration=\(String(format: "%.1f", result.audioDuration))s")
            }
        }
    }
}
