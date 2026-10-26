import AVFoundation
import Foundation
import Speech
@testable import Observatory

struct FixtureReplayResult {
    let audioDuration: TimeInterval
    let wordCount: Int
    let zeroOrInvalidWordIntervals: Int
    let wordsPastAudioEnd: Int
    let nonMonotonicWordOffsets: Int
    let diarizationCompleted: Bool
    let speakerCount: Int
    let overlapWordCount: Int
    let unknownWordCount: Int

    // Diagnostics added to discriminate a harness/lifecycle defect (a
    // recognition request ending early, well short of the fed audio) from a
    // genuine on-device recognition limitation. Numeric only -- no
    // transcript text, per SECURITY.md and this investigation's own rule.
    let utteranceCount: Int
    let resultsYielded: Int
    let firstFinalElapsedSeconds: TimeInterval?
    let endAudioCalledBeforeFirstFinal: Bool
    /// Earliest/latest point in the *fed* audio (not the whole file, when a
    /// `frameRange` slice is used) actually covered by the final result's
    /// segments. If this falls far short of what was fed, the recognizer
    /// stopped listening long before `endAudio()`, independent of what the
    /// acoustic content past that point contains.
    ///
    /// Metric-hygiene caveat (per the ChatGPT review, E10): this is a
    /// min-max *range* of observed segment offsets, not proof the
    /// recognizer covered every second in between -- a gap inside that
    /// range is invisible here. Likewise `wordCount` above is a raw
    /// recognized-word count divided by a reference count elsewhere
    /// (`AudioFixtureReplayTests.FixtureCase.groundTruthWordCount`), not an
    /// alignment-verified score -- insertions/substitutions/repetitions
    /// could inflate it. Treat both as upper bounds, not confirmed
    /// coverage/accuracy, until a follow-up does aligned WER scoring.
    let minSegmentOffsetCovered: TimeInterval?
    let maxSegmentOffsetCovered: TimeInterval?
}

/// E8 (per ChatGPT's suggested audit, incorporated via Hermes's
/// re-sequencing ahead of E7): one entry per recognition callback
/// (partial or final), captured directly from `result.bestTranscription`
/// inside `runSingleRequest`'s own result loop -- before
/// `SpeechTranscriptTimingMapper` or anything else in this file
/// aggregates it. Lets a single device run distinguish "the recognizer's
/// own result stream never had the early audio" (no callback, ever, has
/// a low `minSegmentOffset`) from "a later callback superseded/dropped
/// what an earlier one already reported" (an early callback has a low
/// `minSegmentOffset`, the final one doesn't) -- a different claim from
/// "our aggregation dropped it," since this log never touches that
/// layer. `transcriptLength` is a character count only, never the
/// transcript text -- numeric-only, per SECURITY.md and this
/// investigation's own rule.
struct RecognitionCallbackLogEntry {
    let callbackIndex: Int
    let elapsedSeconds: TimeInterval
    let isFinal: Bool
    let transcriptLength: Int
    let segmentCount: Int
    let minSegmentOffset: TimeInterval?
    let maxSegmentOffset: TimeInterval?
}

/// E9's passage-position arm. See `FixtureReplayHarness.replayPassagePositionControl`.
enum PassagePosition: CustomStringConvertible {
    case alone
    case start
    case end

    var description: String {
        switch self {
        case .alone: return "alone"
        case .start: return "start"
        case .end: return "end"
        }
    }
}

enum FixtureReplayError: Error, CustomStringConvertible {
    case speechPermissionNotGranted
    case onDeviceRecognitionUnavailable
    case recognizerUnavailable
    case missingFinalResult
    case recognitionTimedOut
    case couldNotAllocateAudioBuffer

    var description: String {
        switch self {
        case .speechPermissionNotGranted:
            return "Speech permission is not already authorized; the harness will not trigger a permission prompt."
        case .onDeviceRecognitionUnavailable:
            return "This test destination does not support on-device recognition."
        case .recognizerUnavailable:
            return "The en-US speech recognizer is unavailable on this destination."
        case .missingFinalResult:
            return "Speech recognition ended without a final result."
        case .recognitionTimedOut:
            return "On-device recognition did not finish within the configured watchdog window."
        case .couldNotAllocateAudioBuffer:
            return "Could not allocate an audio buffer for fixture replay."
        }
    }
}

enum FixtureReplayHarness {
    /// Created once and never started -- only its `inputNode`'s format is
    /// ever read, to probe the live mic tap's native hardware format
    /// without actually capturing audio through it. Shared/cached rather
    /// than a fresh instance per call: constructing and discarding a new
    /// `AVAudioEngine` on every `replay(audioURL:)` call crashed the test
    /// host on repeated use within a single test run (reproduced twice);
    /// this reused instance does not.
    @MainActor
    private static let probeEngine = AVAudioEngine()

    /// `requiresOnDeviceRecognition` defaults to `true`, matching
    /// production. The `false` path exists only for diagnostics comparing
    /// on-device vs. Apple's server-based recognizer on local test fixtures
    /// -- never used for anything but already-local test fixtures, never
    /// the production or default committed-test behavior. See SECURITY.md.
    ///
    /// `configureAudioSession`/`matchLiveTapFormat` default to `true` to
    /// match production exactly -- both were tested as possible confounds
    /// for under-transcription and ruled out (numbers were identical with
    /// either on or off).
    ///
    /// `frameRange`, when non-nil, feeds only that slice of the file
    /// (file-relative frame offsets) instead of the whole thing -- used to
    /// test whether recognition stops at a roughly fixed point regardless of
    /// how much audio follows, which would indicate a request-duration
    /// limit rather than an acoustic-content problem. Offsets reported in
    /// the result remain relative to the *fed slice*, not the original file.
    @MainActor
    static func replay(
        audioURL: URL,
        requiresOnDeviceRecognition: Bool = true,
        configureAudioSession: Bool = true,
        matchLiveTapFormat: Bool = true,
        frameRange: Range<AVAudioFramePosition>? = nil,
        onCallback: ((RecognitionCallbackLogEntry) -> Void)? = nil
    ) async throws -> FixtureReplayResult {
        let authorization = await speechAuthorization()
        guard authorization == .authorized else {
            throw FixtureReplayError.speechPermissionNotGranted
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw FixtureReplayError.recognizerUnavailable
        }
        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw FixtureReplayError.onDeviceRecognitionUnavailable
            }
        }

        if configureAudioSession {
            // Matches SpeechRecognitionManager.beginListeningSegment's cold-start
            // configuration exactly -- see that file for why `.measurement`.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let fedRange: Range<AVAudioFramePosition> = frameRange ?? (0..<file.length)
        let duration = Double(fedRange.count) / sampleRate

        // The live mic tap's actual hardware format -- probed via a single
        // cached, never-started engine (see `probeEngine`), after the
        // session above is configured (same ordering production uses).
        let targetFormat: AVAudioFormat = matchLiveTapFormat
            ? Self.probeEngine.inputNode.outputFormat(forBus: 0)
            : file.processingFormat

        let run = try await runSingleRequest(
            file: file,
            range: fedRange,
            targetFormat: targetFormat,
            recognizer: recognizer,
            requiresOnDeviceRecognition: requiresOnDeviceRecognition,
            timeoutSeconds: max(120, duration + 60),
            onCallback: onCallback
        )

        let segments = run.finalResult.bestTranscription.segments
        let minSegmentOffsetCovered = segments.map(\.timestamp).min()
        let maxSegmentOffsetCovered = segments.map { $0.timestamp + $0.duration }.max()

        let wallClockAnchor = Date()
        let utterances = SpeechTranscriptTimingMapper.utterances(
            from: segments,
            formattedString: run.finalResult.bestTranscription.formattedString,
            audioOffset: { $0 },
            wallClock: { wallClockAnchor.addingTimeInterval($0) },
            fallbackWallClockAnchor: wallClockAnchor
        )
        let words = utterances.flatMap(\.words)

        let zeroOrInvalidIntervals = words.filter { word in
            guard let start = word.audioStart, let end = word.audioEnd else { return true }
            return !start.isFinite || !end.isFinite || start < 0 || end <= start
        }.count
        let pastEnd = words.filter { ($0.audioEnd ?? .infinity) > duration + 0.25 }.count
        let nonMonotonic = zip(words, words.dropFirst()).filter { previous, next in
            guard let previousStart = previous.audioStart, let nextStart = next.audioStart else { return true }
            return nextStart < previousStart
        }.count

        let startedAt = Date()
        let transcript = utterances.map {
            TranscriptEvent(
                timestamp: $0.start,
                speaker: .user,
                text: $0.text,
                source: .transcript,
                words: $0.words
            )
        }
        let window = BiometricWindow(
            queryStart: startedAt,
            queryEnd: startedAt.addingTimeInterval(duration),
            samples: [],
            quality: .unavailable
        )
        var session = ReflectionSession(
            title: "Local fixture replay",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            state: .completed,
            transcript: transcript,
            observations: [],
            observationEvents: [],
            dynamicsPatterns: [],
            observationCorrelations: [],
            observationEngineVersion: "fixture",
            dynamicsEngineVersion: "fixture",
            correlationEngineVersion: "fixture",
            biometrics: window,
            voice: VoiceSignals(wordsPerMinute: 0, pauseCount: 0, hesitationMarkers: 0, durationSeconds: Int(duration))
        )
        // Descriptive only -- not used to resolve a path. Diarization below
        // is handed `audioURL` (the real, test-bundle fixture location)
        // directly, via the explicit-URL overload, so this replay never
        // copies into or depends on the production Audio directory. A test
        // fixture written there once already caused real reflection audio
        // to be lost -- see STABILIZATION_AND_EXPRESSION_PLAN.md.
        session.audioFileName = audioURL.lastPathComponent
        session.audioRecordingReliable = true

        let diarized = await SpeakerDiarizationEngine.label(session: session, audioURL: audioURL)
        let speakerLabels = Set(diarized.transcript.compactMap { event -> String? in
            switch event.speaker {
            case .user: return "You"
            case .other(let label): return label
            case .overlap, .unknown: return nil
            }
        })
        return FixtureReplayResult(
            audioDuration: duration,
            wordCount: words.count,
            zeroOrInvalidWordIntervals: zeroOrInvalidIntervals,
            wordsPastAudioEnd: pastEnd,
            nonMonotonicWordOffsets: nonMonotonic,
            diarizationCompleted: diarized.diarizationEngineVersion != nil,
            speakerCount: speakerLabels.count,
            overlapWordCount: diarized.transcript
                .filter { $0.speaker == .overlap }
                .reduce(0) { $0 + $1.words.count },
            unknownWordCount: diarized.transcript
                .filter { $0.speaker == .unknown }
                .reduce(0) { $0 + $1.words.count },
            utteranceCount: utterances.count,
            resultsYielded: run.resultsYielded,
            firstFinalElapsedSeconds: run.firstFinalElapsedSeconds,
            endAudioCalledBeforeFirstFinal: run.endAudioCalledBeforeFirstFinal,
            minSegmentOffsetCovered: minSegmentOffsetCovered,
            maxSegmentOffsetCovered: maxSegmentOffsetCovered
        )
    }

    /// E3 (per Hermes's directive): replays a fixture as a *sequence* of
    /// independent recognition requests, each fed no more than
    /// `chunkDuration` seconds of file-relative audio, instead of one
    /// unbroken request spanning the whole file -- mirroring
    /// `SpeechRecognitionManager.beginListeningSegment()`'s rollover, which
    /// never lets a single live `SFSpeechAudioBufferRecognitionRequest` run
    /// indefinitely either: production starts a fresh request every time the
    /// previous one finalizes (`result.isFinal`) on its own after roughly a
    /// minute of continuous speech (see `handleRecognition(result:error:generation:)`,
    /// specifically the `sealCurrentSegment(); beginListeningSegment()` call
    /// at the end of its "quietly keep going" branch). The harness can't wait
    /// for that same natural finalization when replaying a single
    /// pre-recorded file into one long-lived request -- E2 showed that, fed
    /// continuously with `endAudio()` never called early, a single request's
    /// own final transcription does not naturally roll over on its own and
    /// instead degrades to covering only a short trailing window of the
    /// whole fed duration. This reproduces production's actual constraint
    /// directly: no single request here is ever fed more than `chunkDuration`
    /// seconds before this harness calls `endAudio()` on it and starts the
    /// next one, exactly as production never lets one request run
    /// unbounded.
    ///
    /// Utterances from every chunk are accumulated with cumulative,
    /// file-relative audio offsets (this chunk's own start offset, in
    /// seconds, plus each segment's in-chunk timestamp) -- analogous to
    /// production's `AudioFileWriter.audioOffset(forGeneration:segmentTimestamp:)`,
    /// which maps a segment timestamp relative to *its own* generation's
    /// request back onto the one audio file spanning every generation.
    @MainActor
    static func replayChunked(
        audioURL: URL,
        chunkDuration: TimeInterval = 55,
        requiresOnDeviceRecognition: Bool = true,
        configureAudioSession: Bool = true,
        matchLiveTapFormat: Bool = true,
        sessionCategory: AVAudioSession.Category = .record
    ) async throws -> FixtureReplayResult {
        let authorization = await speechAuthorization()
        guard authorization == .authorized else {
            throw FixtureReplayError.speechPermissionNotGranted
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw FixtureReplayError.recognizerUnavailable
        }
        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw FixtureReplayError.onDeviceRecognitionUnavailable
            }
        }

        if configureAudioSession {
            // E10c (per the ChatGPT review): defaults to `.record`, matching
            // production and every existing caller (E3/E5 don't pass this),
            // but callers can override to `.playAndRecord` to isolate E6's
            // session-category change from its feed-mechanism change --
            // `replayLiveTap` needed `.playAndRecord` purely so
            // `AVAudioEngine.start()` had an output route to initialize
            // against (see that function's doc comment); this lets the
            // manual/chunked path run under the *same* category for a
            // controlled comparison.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(sessionCategory, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let duration = Double(totalFrames) / sampleRate
        let targetFormat: AVAudioFormat = matchLiveTapFormat
            ? Self.probeEngine.inputNode.outputFormat(forBus: 0)
            : file.processingFormat

        let chunkFrames = max(AVAudioFramePosition(1), AVAudioFramePosition((chunkDuration * sampleRate).rounded(.down)))

        var allUtterances: [SpeechRecognitionManager.Utterance] = []
        var totalResultsYielded = 0
        var firstChunkFirstFinalElapsedSeconds: TimeInterval?
        var allChunksEndedAudioBeforeFinal = true
        var overallMinOffsetCovered: TimeInterval?
        var overallMaxOffsetCovered: TimeInterval?

        var chunkStart: AVAudioFramePosition = 0
        while chunkStart < totalFrames {
            let chunkEnd = min(chunkStart + chunkFrames, totalFrames)
            let chunkStartSeconds = Double(chunkStart) / sampleRate
            let chunkSeconds = Double(chunkEnd - chunkStart) / sampleRate

            // Matches `handleRecognition(result:error:generation:)`'s
            // `shouldRollover = (result?.isFinal == true) || (error != nil)`
            // followed by its "quietly keep going" branch
            // (`sealCurrentSegment(); beginListeningSegment()`): production
            // treats *any* per-segment recognition error -- not just a
            // missing final result -- as a reason to roll over to a fresh
            // request and keep listening, not as a fatal failure. A chunk
            // that genuinely contains no recognizable speech (observed on
            // device: `kAFAssistantErrorDomain` code 1110, "No speech
            // detected") throws exactly this way; it contributes zero words
            // for this chunk instead of aborting the whole replay.
            let run: SingleRequestRun
            do {
                run = try await runSingleRequest(
                    file: file,
                    range: chunkStart..<chunkEnd,
                    targetFormat: targetFormat,
                    recognizer: recognizer,
                    requiresOnDeviceRecognition: requiresOnDeviceRecognition,
                    timeoutSeconds: max(60, chunkSeconds + 30)
                )
            } catch {
                print("[E3] chunk at \(String(format: "%.1f", chunkStartSeconds))s produced no final result (\(error.localizedDescription)) -- treating as empty, continuing.")
                chunkStart = chunkEnd
                continue
            }

            totalResultsYielded += run.resultsYielded
            if firstChunkFirstFinalElapsedSeconds == nil {
                firstChunkFirstFinalElapsedSeconds = run.firstFinalElapsedSeconds
            }
            allChunksEndedAudioBeforeFinal = allChunksEndedAudioBeforeFinal && run.endAudioCalledBeforeFirstFinal

            let segments = run.finalResult.bestTranscription.segments
            if let chunkMin = segments.map(\.timestamp).min() {
                let fileRelative = chunkStartSeconds + chunkMin
                overallMinOffsetCovered = min(overallMinOffsetCovered ?? fileRelative, fileRelative)
            }
            if let chunkMax = segments.map({ $0.timestamp + $0.duration }).max() {
                let fileRelative = chunkStartSeconds + chunkMax
                overallMaxOffsetCovered = max(overallMaxOffsetCovered ?? fileRelative, fileRelative)
            }

            let wallClockAnchor = Date()
            let chunkUtterances = SpeechTranscriptTimingMapper.utterances(
                from: segments,
                formattedString: run.finalResult.bestTranscription.formattedString,
                audioOffset: { chunkStartSeconds + $0 },
                wallClock: { wallClockAnchor.addingTimeInterval($0) },
                fallbackWallClockAnchor: wallClockAnchor
            )
            allUtterances.append(contentsOf: chunkUtterances)

            chunkStart = chunkEnd
        }

        let words = allUtterances.flatMap(\.words)
        let zeroOrInvalidIntervals = words.filter { word in
            guard let start = word.audioStart, let end = word.audioEnd else { return true }
            return !start.isFinite || !end.isFinite || start < 0 || end <= start
        }.count
        let pastEnd = words.filter { ($0.audioEnd ?? .infinity) > duration + 0.25 }.count
        let nonMonotonic = zip(words, words.dropFirst()).filter { previous, next in
            guard let previousStart = previous.audioStart, let nextStart = next.audioStart else { return true }
            return nextStart < previousStart
        }.count

        let startedAt = Date()
        let transcript = allUtterances.map {
            TranscriptEvent(
                timestamp: $0.start,
                speaker: .user,
                text: $0.text,
                source: .transcript,
                words: $0.words
            )
        }
        let window = BiometricWindow(
            queryStart: startedAt,
            queryEnd: startedAt.addingTimeInterval(duration),
            samples: [],
            quality: .unavailable
        )
        var session = ReflectionSession(
            title: "Local fixture replay (chunked)",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(duration),
            state: .completed,
            transcript: transcript,
            observations: [],
            observationEvents: [],
            dynamicsPatterns: [],
            observationCorrelations: [],
            observationEngineVersion: "fixture",
            dynamicsEngineVersion: "fixture",
            correlationEngineVersion: "fixture",
            biometrics: window,
            voice: VoiceSignals(wordsPerMinute: 0, pauseCount: 0, hesitationMarkers: 0, durationSeconds: Int(duration))
        )
        session.audioFileName = audioURL.lastPathComponent
        session.audioRecordingReliable = true

        let diarized = await SpeakerDiarizationEngine.label(session: session, audioURL: audioURL)
        let speakerLabels = Set(diarized.transcript.compactMap { event -> String? in
            switch event.speaker {
            case .user: return "You"
            case .other(let label): return label
            case .overlap, .unknown: return nil
            }
        })
        return FixtureReplayResult(
            audioDuration: duration,
            wordCount: words.count,
            zeroOrInvalidWordIntervals: zeroOrInvalidIntervals,
            wordsPastAudioEnd: pastEnd,
            nonMonotonicWordOffsets: nonMonotonic,
            diarizationCompleted: diarized.diarizationEngineVersion != nil,
            speakerCount: speakerLabels.count,
            overlapWordCount: diarized.transcript
                .filter { $0.speaker == .overlap }
                .reduce(0) { $0 + $1.words.count },
            unknownWordCount: diarized.transcript
                .filter { $0.speaker == .unknown }
                .reduce(0) { $0 + $1.words.count },
            utteranceCount: allUtterances.count,
            resultsYielded: totalResultsYielded,
            firstFinalElapsedSeconds: firstChunkFirstFinalElapsedSeconds,
            endAudioCalledBeforeFirstFinal: allChunksEndedAudioBeforeFinal,
            minSegmentOffsetCovered: overallMinOffsetCovered,
            maxSegmentOffsetCovered: overallMaxOffsetCovered
        )
    }

    /// Thread-safe wrapper for the single `SFSpeechAudioBufferRecognitionRequest`
    /// touched from `replayLiveTap`'s `installTap` callback, which (like
    /// production's own tap in `SpeechRecognitionManager`) fires on a
    /// real-time audio thread outside this enum's `@MainActor` isolation --
    /// mirrors that file's `CurrentRequestBox` exactly, down to routing
    /// every `append`/`endAudio` through the same lock.
    private final class LiveTapRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var hasEndedAudio = false

        func set(request: SFSpeechAudioBufferRecognitionRequest) {
            lock.lock(); self.request = request; lock.unlock()
        }

        /// Called from the player node's tap on a real-time thread for every buffer.
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            request?.append(buffer)
        }

        /// Called once the scheduled segment finishes playing (from the
        /// player node's own completion thread, also non-main) and,
        /// redundantly, from `onTermination` on cancellation/timeout --
        /// idempotent so whichever fires first wins.
        func endAudioIfNeeded() {
            lock.lock(); defer { lock.unlock() }
            guard !hasEndedAudio else { return }
            hasEndedAudio = true
            request?.endAudio()
        }

        func hasCalledEndAudio() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return hasEndedAudio
        }
    }

    /// E6 (per Hermes's directive): feeds one ~`chunkDuration` chunk of
    /// file-relative audio to a request via a *real* `AVAudioEngine` tap --
    /// an `AVAudioPlayerNode` playing the chunk with `installTap` delivering
    /// the buffers -- instead of `appendAudio`'s paced manual
    /// `request.append(...)` loop every other replay function in this file
    /// uses. This rules out whether the harness's own manual feed (rather
    /// than anything about on-device recognition itself) is a confound, by
    /// mirroring production's actual feed mechanism
    /// (`inputNode.installTap` in `SpeechRecognitionManager`) as closely as
    /// a pre-recorded file allows. `engine.mainMixerNode.outputVolume = 0`
    /// below silences audible playback through the test host's speakers --
    /// `installTap` is on `playerNode` itself, upstream of the mixer, so it
    /// still receives full-volume buffers regardless.
    @MainActor
    static func replayLiveTap(
        audioURL: URL,
        chunkDuration: TimeInterval = 55,
        requiresOnDeviceRecognition: Bool = true,
        configureAudioSession: Bool = true
    ) async throws -> FixtureReplayResult {
        let authorization = await speechAuthorization()
        guard authorization == .authorized else {
            throw FixtureReplayError.speechPermissionNotGranted
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw FixtureReplayError.recognizerUnavailable
        }
        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw FixtureReplayError.onDeviceRecognitionUnavailable
            }
        }

        if configureAudioSession {
            // `.record` (what `replay`/`replayChunked` use to match
            // production exactly) is input-only and has no output route at
            // all -- `AVAudioEngine.start()` then fails trying to
            // initialize its output unit (`kAUInitialize` on `*outputNode`,
            // CoreAudio -10851), even with `mainMixerNode.outputVolume`
            // muted, since the failure is about route existence, not
            // volume. `.playAndRecord` is the minimum category that gives
            // the engine a valid (if silenced) output route to initialize
            // against; `.measurement` mode is unaffected and still applies.
            // This is a mechanical requirement of using a real
            // AVAudioEngine playback graph at all, not a deliberate change
            // to the conditions E6 is testing -- recognition itself reads
            // only the PCM buffers appended to the request, not the
            // session category.
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let totalFrames = file.length
        let chunkFrames = min(
            totalFrames,
            max(AVAudioFramePosition(1), AVAudioFramePosition((chunkDuration * sampleRate).rounded(.down)))
        )
        let fedDuration = Double(chunkFrames) / sampleRate

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

        let requestBox = LiveTapRequestBox()
        requestBox.set(request: request)

        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
        engine.mainMixerNode.outputVolume = 0

        let stream = AsyncThrowingStream<SFSpeechRecognitionResult, Error> { continuation in
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result)
                    if result.isFinal {
                        continuation.finish()
                        return
                    }
                }
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            let timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(max(60, fedDuration + 30)))
                    continuation.finish(throwing: FixtureReplayError.recognitionTimedOut)
                } catch {
                    // Stream completion cancels this watchdog.
                }
            }

            continuation.onTermination = { [requestBox] _ in
                timeoutTask.cancel()
                requestBox.endAudioIfNeeded()
                Task { @MainActor in
                    playerNode.removeTap(onBus: 0)
                    playerNode.stop()
                    engine.stop()
                    recognitionTask.cancel()
                }
            }

            playerNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [requestBox] buffer, _ in
                requestBox.append(buffer)
            }

            do {
                try engine.start()
            } catch {
                continuation.finish(throwing: error)
                return
            }

            playerNode.scheduleSegment(
                file,
                startingFrame: 0,
                frameCount: AVAudioFrameCount(chunkFrames),
                at: nil
            ) { [requestBox] in
                requestBox.endAudioIfNeeded()
            }
            playerNode.play()
        }

        var finalResult: SFSpeechRecognitionResult?
        var resultsYielded = 0
        var firstFinalElapsedSeconds: TimeInterval?
        var endAudioCalledBeforeFirstFinal = false
        let streamStart = Date()
        for try await result in stream {
            resultsYielded += 1
            if result.isFinal {
                firstFinalElapsedSeconds = Date().timeIntervalSince(streamStart)
                endAudioCalledBeforeFirstFinal = requestBox.hasCalledEndAudio()
                finalResult = result
                break
            }
        }
        guard let finalResult else { throw FixtureReplayError.missingFinalResult }

        let segments = finalResult.bestTranscription.segments
        let minSegmentOffsetCovered = segments.map(\.timestamp).min()
        let maxSegmentOffsetCovered = segments.map { $0.timestamp + $0.duration }.max()

        let wallClockAnchor = Date()
        let utterances = SpeechTranscriptTimingMapper.utterances(
            from: segments,
            formattedString: finalResult.bestTranscription.formattedString,
            audioOffset: { $0 },
            wallClock: { wallClockAnchor.addingTimeInterval($0) },
            fallbackWallClockAnchor: wallClockAnchor
        )
        let words = utterances.flatMap(\.words)

        let zeroOrInvalidIntervals = words.filter { word in
            guard let start = word.audioStart, let end = word.audioEnd else { return true }
            return !start.isFinite || !end.isFinite || start < 0 || end <= start
        }.count
        let pastEnd = words.filter { ($0.audioEnd ?? .infinity) > fedDuration + 0.25 }.count
        let nonMonotonic = zip(words, words.dropFirst()).filter { previous, next in
            guard let previousStart = previous.audioStart, let nextStart = next.audioStart else { return true }
            return nextStart < previousStart
        }.count

        let startedAt = Date()
        let transcript = utterances.map {
            TranscriptEvent(
                timestamp: $0.start,
                speaker: .user,
                text: $0.text,
                source: .transcript,
                words: $0.words
            )
        }
        let window = BiometricWindow(
            queryStart: startedAt,
            queryEnd: startedAt.addingTimeInterval(fedDuration),
            samples: [],
            quality: .unavailable
        )
        var session = ReflectionSession(
            title: "Local fixture replay (live tap)",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(fedDuration),
            state: .completed,
            transcript: transcript,
            observations: [],
            observationEvents: [],
            dynamicsPatterns: [],
            observationCorrelations: [],
            observationEngineVersion: "fixture",
            dynamicsEngineVersion: "fixture",
            correlationEngineVersion: "fixture",
            biometrics: window,
            voice: VoiceSignals(wordsPerMinute: 0, pauseCount: 0, hesitationMarkers: 0, durationSeconds: Int(fedDuration))
        )
        session.audioFileName = audioURL.lastPathComponent
        session.audioRecordingReliable = true

        let diarized = await SpeakerDiarizationEngine.label(session: session, audioURL: audioURL)
        let speakerLabels = Set(diarized.transcript.compactMap { event -> String? in
            switch event.speaker {
            case .user: return "You"
            case .other(let label): return label
            case .overlap, .unknown: return nil
            }
        })
        return FixtureReplayResult(
            audioDuration: fedDuration,
            wordCount: words.count,
            zeroOrInvalidWordIntervals: zeroOrInvalidIntervals,
            wordsPastAudioEnd: pastEnd,
            nonMonotonicWordOffsets: nonMonotonic,
            diarizationCompleted: diarized.diarizationEngineVersion != nil,
            speakerCount: speakerLabels.count,
            overlapWordCount: diarized.transcript
                .filter { $0.speaker == .overlap }
                .reduce(0) { $0 + $1.words.count },
            unknownWordCount: diarized.transcript
                .filter { $0.speaker == .unknown }
                .reduce(0) { $0 + $1.words.count },
            utteranceCount: utterances.count,
            resultsYielded: resultsYielded,
            firstFinalElapsedSeconds: firstFinalElapsedSeconds,
            endAudioCalledBeforeFirstFinal: endAudioCalledBeforeFirstFinal,
            minSegmentOffsetCovered: minSegmentOffsetCovered,
            maxSegmentOffsetCovered: maxSegmentOffsetCovered
        )
    }

    /// E9 (per ChatGPT's suggested control, incorporated via Hermes's
    /// re-sequencing ahead of E7): replays a single clearly-audible
    /// `passageRange` three ways -- `.alone`, padded with trailing silence
    /// (passage at the START of a `totalDuration`-long single request), and
    /// padded with leading silence (passage at the END) -- fresh request
    /// each, identical settings otherwise, to isolate duration/position
    /// dependence from content. Silence is synthesized in-process
    /// (`appendSilence`, explicitly zeroed buffers), not a new fixture file.
    ///
    /// Per the director's correction: trailing silence can trigger the
    /// recognizer's own endpointing and finalize the request early, which
    /// would look like truncation but isn't. `firstFinalElapsedSeconds` on
    /// the returned result (already present on every `FixtureReplayResult`)
    /// is how the caller tells the two apart -- a `.start`/`.end` arm whose
    /// final arrives much earlier than `totalDuration` finalized on
    /// silence (endpointing), not on a duration/position limit.
    @MainActor
    static func replayPassagePositionControl(
        audioURL: URL,
        passageRange: Range<AVAudioFramePosition>,
        totalDuration: TimeInterval,
        position: PassagePosition,
        requiresOnDeviceRecognition: Bool = true,
        configureAudioSession: Bool = true,
        matchLiveTapFormat: Bool = true
    ) async throws -> FixtureReplayResult {
        let authorization = await speechAuthorization()
        guard authorization == .authorized else {
            throw FixtureReplayError.speechPermissionNotGranted
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw FixtureReplayError.recognizerUnavailable
        }
        if requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw FixtureReplayError.onDeviceRecognitionUnavailable
            }
        }

        if configureAudioSession {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        }

        let file = try AVAudioFile(forReading: audioURL)
        let sampleRate = file.processingFormat.sampleRate
        let passageDuration = Double(passageRange.count) / sampleRate
        let fedDuration: TimeInterval = position == .alone ? passageDuration : max(passageDuration, totalDuration)
        let silenceDuration = max(0, fedDuration - passageDuration)

        let targetFormat: AVAudioFormat = matchLiveTapFormat
            ? Self.probeEngine.inputNode.outputFormat(forBus: 0)
            : file.processingFormat

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

        var endAudioCalled = false
        let feedingTaskBox = FeedingTaskBox()

        let stream = AsyncThrowingStream<SFSpeechRecognitionResult, Error> { continuation in
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result)
                    if result.isFinal {
                        continuation.finish()
                        return
                    }
                }
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            let timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(max(60, fedDuration + 30)))
                    continuation.finish(throwing: FixtureReplayError.recognitionTimedOut)
                } catch {
                    // Stream completion cancels this watchdog.
                }
            }

            continuation.onTermination = { [feedingTaskBox] _ in
                timeoutTask.cancel()
                feedingTaskBox.cancel()
                Task { @MainActor in recognitionTask.cancel() }
            }

            let feedingTask = Task { @MainActor in
                do {
                    switch position {
                    case .alone:
                        try await appendAudio(from: file, range: passageRange, to: request, targetFormat: targetFormat)
                    case .start:
                        try await appendAudio(from: file, range: passageRange, to: request, targetFormat: targetFormat)
                        try await appendSilence(duration: silenceDuration, to: request, targetFormat: targetFormat)
                    case .end:
                        try await appendSilence(duration: silenceDuration, to: request, targetFormat: targetFormat)
                        try await appendAudio(from: file, range: passageRange, to: request, targetFormat: targetFormat)
                    }
                    request.endAudio()
                    endAudioCalled = true
                } catch is CancellationError {
                    // Stream already terminated; nothing more to do.
                } catch {
                    request.endAudio()
                    endAudioCalled = true
                    continuation.finish(throwing: error)
                }
            }
            feedingTaskBox.set(feedingTask)
        }

        var finalResult: SFSpeechRecognitionResult?
        var resultsYielded = 0
        var firstFinalElapsedSeconds: TimeInterval?
        var endAudioCalledBeforeFirstFinal = false
        let streamStart = Date()
        for try await result in stream {
            resultsYielded += 1
            if result.isFinal {
                firstFinalElapsedSeconds = Date().timeIntervalSince(streamStart)
                endAudioCalledBeforeFirstFinal = endAudioCalled
                finalResult = result
                break
            }
        }
        guard let finalResult else { throw FixtureReplayError.missingFinalResult }

        let segments = finalResult.bestTranscription.segments
        let minSegmentOffsetCovered = segments.map(\.timestamp).min()
        let maxSegmentOffsetCovered = segments.map { $0.timestamp + $0.duration }.max()

        let wallClockAnchor = Date()
        let utterances = SpeechTranscriptTimingMapper.utterances(
            from: segments,
            formattedString: finalResult.bestTranscription.formattedString,
            audioOffset: { $0 },
            wallClock: { wallClockAnchor.addingTimeInterval($0) },
            fallbackWallClockAnchor: wallClockAnchor
        )
        let words = utterances.flatMap(\.words)

        let zeroOrInvalidIntervals = words.filter { word in
            guard let start = word.audioStart, let end = word.audioEnd else { return true }
            return !start.isFinite || !end.isFinite || start < 0 || end <= start
        }.count
        let pastEnd = words.filter { ($0.audioEnd ?? .infinity) > fedDuration + 0.25 }.count
        let nonMonotonic = zip(words, words.dropFirst()).filter { previous, next in
            guard let previousStart = previous.audioStart, let nextStart = next.audioStart else { return true }
            return nextStart < previousStart
        }.count

        let startedAt = Date()
        let transcript = utterances.map {
            TranscriptEvent(
                timestamp: $0.start,
                speaker: .user,
                text: $0.text,
                source: .transcript,
                words: $0.words
            )
        }
        let window = BiometricWindow(
            queryStart: startedAt,
            queryEnd: startedAt.addingTimeInterval(fedDuration),
            samples: [],
            quality: .unavailable
        )
        var session = ReflectionSession(
            title: "Local fixture replay (passage position control)",
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(fedDuration),
            state: .completed,
            transcript: transcript,
            observations: [],
            observationEvents: [],
            dynamicsPatterns: [],
            observationCorrelations: [],
            observationEngineVersion: "fixture",
            dynamicsEngineVersion: "fixture",
            correlationEngineVersion: "fixture",
            biometrics: window,
            voice: VoiceSignals(wordsPerMinute: 0, pauseCount: 0, hesitationMarkers: 0, durationSeconds: Int(fedDuration))
        )
        session.audioFileName = audioURL.lastPathComponent
        session.audioRecordingReliable = true

        let diarized = await SpeakerDiarizationEngine.label(session: session, audioURL: audioURL)
        let speakerLabels = Set(diarized.transcript.compactMap { event -> String? in
            switch event.speaker {
            case .user: return "You"
            case .other(let label): return label
            case .overlap, .unknown: return nil
            }
        })
        return FixtureReplayResult(
            audioDuration: fedDuration,
            wordCount: words.count,
            zeroOrInvalidWordIntervals: zeroOrInvalidIntervals,
            wordsPastAudioEnd: pastEnd,
            nonMonotonicWordOffsets: nonMonotonic,
            diarizationCompleted: diarized.diarizationEngineVersion != nil,
            speakerCount: speakerLabels.count,
            overlapWordCount: diarized.transcript
                .filter { $0.speaker == .overlap }
                .reduce(0) { $0 + $1.words.count },
            unknownWordCount: diarized.transcript
                .filter { $0.speaker == .unknown }
                .reduce(0) { $0 + $1.words.count },
            utteranceCount: utterances.count,
            resultsYielded: resultsYielded,
            firstFinalElapsedSeconds: firstFinalElapsedSeconds,
            endAudioCalledBeforeFirstFinal: endAudioCalledBeforeFirstFinal,
            minSegmentOffsetCovered: minSegmentOffsetCovered,
            maxSegmentOffsetCovered: maxSegmentOffsetCovered
        )
    }

    private struct SingleRequestRun {
        let finalResult: SFSpeechRecognitionResult
        let resultsYielded: Int
        let firstFinalElapsedSeconds: TimeInterval?
        let endAudioCalledBeforeFirstFinal: Bool
    }

    /// Thread-safe holder for `runSingleRequest`'s feeding `Task`, set once
    /// from the function's body and read from `onTermination`'s closure --
    /// which `AsyncThrowingStream` can invoke from a different, non-isolated
    /// context than where the task was created. A plain captured `var` here
    /// is exactly the pattern Swift 6 flags as a sendability error; same
    /// lock-protected-box fix as `LiveTapRequestBox` above.
    private final class FeedingTaskBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>) {
            lock.lock(); self.task = task; lock.unlock()
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            task?.cancel()
        }
    }

    /// Runs exactly one `SFSpeechAudioBufferRecognitionRequest` over `range`
    /// of `file` and waits for its first final result. Shared by `replay`
    /// (one request for the whole fed range) and `replayChunked` (one
    /// request per chunk) so both go through identical
    /// feed/cancel/timeout/instrumentation logic.
    @MainActor
    private static func runSingleRequest(
        file: AVAudioFile,
        range: Range<AVAudioFramePosition>,
        targetFormat: AVAudioFormat,
        recognizer: SFSpeechRecognizer,
        requiresOnDeviceRecognition: Bool,
        timeoutSeconds: TimeInterval,
        onCallback: ((RecognitionCallbackLogEntry) -> Void)? = nil
    ) async throws -> SingleRequestRun {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.requiresOnDeviceRecognition = requiresOnDeviceRecognition

        // Set once `appendAudio`'s feeding Task actually calls `request.endAudio()`
        // -- checked when the first final result arrives, to tell apart "the
        // recognizer finished after consuming everything we fed it" from
        // "the recognizer stopped listening well before we were done feeding it."
        // Both run on MainActor, so plain mutation here is safe without extra locking.
        var endAudioCalled = false
        let feedingTaskBox = FeedingTaskBox()

        let stream = AsyncThrowingStream<SFSpeechRecognitionResult, Error> { continuation in
            let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    continuation.yield(result)
                    if result.isFinal {
                        continuation.finish()
                        return
                    }
                }
                if let error {
                    continuation.finish(throwing: error)
                }
            }

            let timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(timeoutSeconds))
                    continuation.finish(throwing: FixtureReplayError.recognitionTimedOut)
                } catch {
                    // Stream completion cancels this watchdog.
                }
            }

            continuation.onTermination = { [feedingTaskBox] _ in
                timeoutTask.cancel()
                // Previously only the recognition task was cancelled here --
                // the feeding Task kept running `appendAudio` for the fed
                // range's *full* duration regardless of whether recognition
                // was still listening, which meant elapsed wall-clock time
                // never actually proved recognition had consumed the audio.
                feedingTaskBox.cancel()
                Task { @MainActor in recognitionTask.cancel() }
            }

            let feedingTask = Task { @MainActor in
                do {
                    try await appendAudio(from: file, range: range, to: request, targetFormat: targetFormat)
                    request.endAudio()
                    endAudioCalled = true
                } catch is CancellationError {
                    // Stream already terminated; nothing more to do.
                } catch {
                    request.endAudio()
                    endAudioCalled = true
                    continuation.finish(throwing: error)
                }
            }
            feedingTaskBox.set(feedingTask)
        }

        var finalResult: SFSpeechRecognitionResult?
        var resultsYielded = 0
        var firstFinalElapsedSeconds: TimeInterval?
        var endAudioCalledBeforeFirstFinal = false
        let streamStart = Date()
        for try await result in stream {
            if let onCallback {
                let segments = result.bestTranscription.segments
                onCallback(RecognitionCallbackLogEntry(
                    callbackIndex: resultsYielded,
                    elapsedSeconds: Date().timeIntervalSince(streamStart),
                    isFinal: result.isFinal,
                    transcriptLength: result.bestTranscription.formattedString.count,
                    segmentCount: segments.count,
                    minSegmentOffset: segments.map(\.timestamp).min(),
                    maxSegmentOffset: segments.map { $0.timestamp + $0.duration }.max()
                ))
            }
            resultsYielded += 1
            if result.isFinal {
                firstFinalElapsedSeconds = Date().timeIntervalSince(streamStart)
                endAudioCalledBeforeFirstFinal = endAudioCalled
                finalResult = result
                break
            }
        }
        guard let finalResult else { throw FixtureReplayError.missingFinalResult }

        return SingleRequestRun(
            finalResult: finalResult,
            resultsYielded: resultsYielded,
            firstFinalElapsedSeconds: firstFinalElapsedSeconds,
            endAudioCalledBeforeFirstFinal: endAudioCalledBeforeFirstFinal
        )
    }

    @MainActor
    private static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// Feeds exactly `range` (file-relative frame offsets) of `file`'s
    /// audio to `request` at roughly real playback pace, converting each
    /// buffer to `targetFormat` first if it doesn't already match the
    /// file's own format. Cooperatively cancellable (checked between
    /// buffers) so the caller can stop feeding the instant recognition
    /// itself has finished, rather than always running for the fed range's
    /// full real-time duration regardless of whether anything is still
    /// listening.
    @MainActor
    private static func appendAudio(
        from file: AVAudioFile,
        range: Range<AVAudioFramePosition>,
        to request: SFSpeechAudioBufferRecognitionRequest,
        targetFormat: AVAudioFormat
    ) async throws {
        let sourceFormat = file.processingFormat
        let converter = sourceFormat == targetFormat ? nil : AVAudioConverter(from: sourceFormat, to: targetFormat)
        let sampleRate = sourceFormat.sampleRate

        file.framePosition = range.lowerBound
        while file.framePosition < range.upperBound {
            try Task.checkCancellation()

            let remaining = range.upperBound - file.framePosition
            let frameCount = AVAudioFrameCount(min(Int64(16_384), remaining))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
                throw FixtureReplayError.couldNotAllocateAudioBuffer
            }
            try file.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }

            if let converter {
                let outputCapacity = AVAudioFrameCount(
                    (Double(buffer.frameLength) * (targetFormat.sampleRate / sourceFormat.sampleRate)).rounded(.up) + 16
                )
                guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
                    throw FixtureReplayError.couldNotAllocateAudioBuffer
                }
                var conversionError: NSError?
                converter.convert(to: converted, error: &conversionError) { _, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                if let conversionError { throw conversionError }
                request.append(converted)
            } else {
                request.append(buffer)
            }

            let bufferDuration = Double(buffer.frameLength) / sampleRate
            try await Task.sleep(for: .seconds(bufferDuration))
        }
    }

    /// E9's silence synthesis: explicitly zeroes every sample (not relying
    /// on `AVAudioPCMBuffer`'s allocator leaving fresh memory zeroed, which
    /// isn't a documented guarantee) so the silence arms are genuine
    /// silence, not whatever happened to be in that memory. Paced the same
    /// way `appendAudio` is, for the same real-time-feed reason.
    @MainActor
    private static func appendSilence(
        duration: TimeInterval,
        to request: SFSpeechAudioBufferRecognitionRequest,
        targetFormat: AVAudioFormat
    ) async throws {
        guard duration > 0 else { return }
        let sampleRate = targetFormat.sampleRate
        var remainingFrames = AVAudioFrameCount((duration * sampleRate).rounded(.up))

        while remainingFrames > 0 {
            try Task.checkCancellation()

            let frameCount = min(AVAudioFrameCount(16_384), remainingFrames)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                throw FixtureReplayError.couldNotAllocateAudioBuffer
            }
            buffer.frameLength = frameCount

            if let floatData = buffer.floatChannelData {
                for channel in 0..<Int(targetFormat.channelCount) {
                    let channelPointer = floatData[channel]
                    for frame in 0..<Int(frameCount) {
                        channelPointer[frame] = 0
                    }
                }
            } else if let int16Data = buffer.int16ChannelData {
                for channel in 0..<Int(targetFormat.channelCount) {
                    let channelPointer = int16Data[channel]
                    for frame in 0..<Int(frameCount) {
                        channelPointer[frame] = 0
                    }
                }
            }

            request.append(buffer)
            remainingFrames -= frameCount

            let bufferDuration = Double(frameCount) / sampleRate
            try await Task.sleep(for: .seconds(bufferDuration))
        }
    }
}

// MARK: - U4a-2 Channel B harvest (additive entry point)
//
// Added for U4a-2 (PROPOSALS/U4a-2-plan.md §3, Flag 2 — director-ratified as an
// additions-only edit). Nothing above this line was changed, so E1–E10 stay comparable.
// It lives in this file only because it must share the `private` feed helpers
// (`appendAudio`, `appendSilence`, `probeEngine`, `FeedingTaskBox`, `speechAuthorization`).

extension FixtureReplayHarness {
    /// Harvest-loop bookkeeping shared between the feeding task, the monitor and the
    /// consumer — all MainActor, so a plain class is enough.
    @MainActor
    private final class VoiceAnalyticsHarvestState {
        var lastFinalAt: Date?
        var feedItemsCompleted = 0
        var endAudioCalled = false
    }

    private enum VoiceAnalyticsEvent: Sendable {
        case callback(VoiceAnalyticsCallbackSnapshot)
        case error(domain: String, code: Int)
        case taskCompleted
        case graceElapsed
        case timedOut
        case feedFailed
    }

    /// U4a-2 Channel B: runs ONE recognition request over `feedPlan` (an ordered list of
    /// source-file sample ranges and synthesized silences) and returns the numbers-only
    /// harvest record. Differs from `runSingleRequest` exactly where §8.3/A7 require:
    ///
    /// - It keeps listening past the first final — until the task completes, or
    ///   `postFinalGraceSeconds` after the most recent final — so superseded finals can be
    ///   counted and the last one wins.
    /// - A recognition error (including 1110) does not throw: it is caught and recorded
    ///   as `chunkOutcome: .failed(domain, code)`; the caller continues (A7 error policy).
    /// - The §8.2 input mapping is fixed before the request exists.
    ///
    /// Request flags, session and submitted format come from the frozen A7 config and
    /// match this file's existing replay paths. Setup failures (permission, recognizer
    /// unavailable, unreadable file) still throw: they are not harvests.
    @MainActor
    static func harvestVoiceAnalytics(
        audioURL: URL,
        feedPlan: [VoiceAnalyticsFeedItem],
        sourceID: SourceID,
        requestIndex: Int,
        lifecycle: U4a2ChannelBConfig.RequestLifecycle
    ) async throws -> RequestHarvest {
        let authorization = await speechAuthorization()
        guard authorization == .authorized else {
            throw FixtureReplayError.speechPermissionNotGranted
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw FixtureReplayError.recognizerUnavailable
        }
        if lifecycle.requiresOnDeviceRecognition {
            guard recognizer.supportsOnDeviceRecognition else {
                throw FixtureReplayError.onDeviceRecognitionUnavailable
            }
        }

        let (category, mode, options) = try lifecycle.audioSession.resolved()
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(category, mode: mode, options: options)
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let file = try AVAudioFile(forReading: audioURL)
        let targetFormat: AVAudioFormat = lifecycle.matchLiveTapFormat
            ? Self.probeEngine.inputNode.outputFormat(forBus: 0)
            : file.processingFormat

        let submittedSampleFormat: SampleFormat
        switch targetFormat.commonFormat {
        case .pcmFormatFloat32: submittedSampleFormat = .float32
        case .pcmFormatInt16: submittedSampleFormat = .int16
        case .pcmFormatInt32: submittedSampleFormat = .int32
        default: submittedSampleFormat = .other
        }
        let mapping = RequestInputMapping.plan(
            sourceID: sourceID, requestIndex: requestIndex, feedPlan: feedPlan,
            sourceSampleRateHz: file.processingFormat.sampleRate,
            submittedSampleRateHz: targetFormat.sampleRate,
            submittedChannelCount: Int(targetFormat.channelCount),
            submittedSampleFormat: submittedSampleFormat)
        let timeoutSeconds = lifecycle.timeout(forFedSeconds: mapping.fedDurationSeconds)
        let graceSeconds = lifecycle.postFinalGraceSeconds

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = lifecycle.shouldReportPartialResults
        request.addsPunctuation = lifecycle.addsPunctuation
        request.requiresOnDeviceRecognition = lifecycle.requiresOnDeviceRecognition

        let state = VoiceAnalyticsHarvestState()
        let feedingTaskBox = FeedingTaskBox()
        let (events, continuation) = AsyncStream.makeStream(of: VoiceAnalyticsEvent.self)

        // The handler converts each result to a numbers-only snapshot on the spot; no
        // transcript text is read and no result object leaves the closure.
        let recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                continuation.yield(.callback(VoiceAnalyticsCapture.snapshot(result)))
            }
            if let error {
                let ns = error as NSError
                continuation.yield(.error(domain: ns.domain, code: ns.code))
            }
        }

        // Task completion, post-final grace and the overall timeout, polled. Completion is
        // re-posted through the recognizer's own queue so any handler call already queued
        // there (e.g. a last final) is delivered before the completion event.
        let monitor = Task { @MainActor in
            let started = Date()
            var completionPosted = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                if !completionPosted, recognitionTask.state == .completed {
                    completionPosted = true
                    recognizer.queue.addOperation { continuation.yield(.taskCompleted) }
                }
                if let last = state.lastFinalAt, Date().timeIntervalSince(last) >= graceSeconds {
                    continuation.yield(.graceElapsed)
                }
                if Date().timeIntervalSince(started) >= timeoutSeconds {
                    continuation.yield(.timedOut)
                }
            }
        }

        let feedingTask = Task { @MainActor in
            do {
                for item in feedPlan {
                    switch item {
                    case .source(let range):
                        try await appendAudio(from: file, range: range, to: request, targetFormat: targetFormat)
                    case .silence(let seconds):
                        try await appendSilence(duration: seconds, to: request, targetFormat: targetFormat)
                    }
                    state.feedItemsCompleted += 1
                }
                request.endAudio()
                state.endAudioCalled = true
            } catch is CancellationError {
                // Listening already stopped; nothing more to feed.
            } catch {
                request.endAudio()
                state.endAudioCalled = true
                continuation.yield(.feedFailed)
            }
        }
        feedingTaskBox.set(feedingTask)

        var callbacks: [CallbackAuditEntry] = []
        var finals: [FinalResultRecord] = []
        var segmentDiagnostics: [SegmentLevelDiagnostic] = []
        var outcome: ChunkOutcome = .succeeded
        var listeningEnd: ListeningEnd = .taskCompleted

        listening: for await event in events {
            switch event {
            case .callback(let snapshot):
                let index = callbacks.count
                callbacks.append(CallbackAuditEntry(callbackIndex: index, isFinal: snapshot.isFinal))
                guard snapshot.isFinal else { continue }
                let ordinal = finals.count
                finals.append(FinalResultRecord(finalOrdinal: ordinal, callbackIndex: index,
                                                metadata: snapshot.metadata,
                                                voiceAnalytics: snapshot.voiceAnalytics))
                for (segmentIndex, segment) in snapshot.segments.enumerated() {
                    segmentDiagnostics.append(SegmentLevelDiagnostic(
                        finalOrdinal: ordinal, segmentIndex: segmentIndex,
                        segmentTimestamp: segment.timestamp, segmentDuration: segment.duration,
                        voiceAnalytics: segment.analytics))
                }
                state.lastFinalAt = Date()
            case .error(let domain, let code):
                outcome = .failed(domain: .trusted(domain), code: code)
                listeningEnd = .errorReceived
                break listening
            case .taskCompleted:
                listeningEnd = .taskCompleted
                break listening
            case .graceElapsed:
                listeningEnd = .postFinalGraceElapsed
                break listening
            case .timedOut:
                outcome = .failed(domain: .trusted("u4a2.harness.timeout"), code: 0)
                listeningEnd = .timedOut
                break listening
            case .feedFailed:
                outcome = .failed(domain: .trusted("u4a2.harness.feedFailed"), code: 0)
                listeningEnd = .feedFailed
                break listening
            }
        }

        monitor.cancel()
        feedingTaskBox.cancel()
        continuation.finish()
        recognitionTask.cancel()

        let harvest = RequestHarvest.assemble(
            mapping: mapping, callbacks: callbacks, finals: finals,
            segmentDiagnostics: segmentDiagnostics, outcome: outcome, listeningEnd: listeningEnd,
            feedItemsCompleted: state.feedItemsCompleted, feedItemCount: feedPlan.count,
            endAudioCalled: state.endAudioCalled)
        return harvest
    }
}
