import Foundation
import Speech
import AVFoundation
import Combine

@MainActor
final class SpeechRecognitionManager: ObservableObject {
    @Published var isRecording = false
    @Published var liveTranscript = ""
    @Published var statusMessage = "Speech not started."
    @Published var permissionDenied = false

    /// One chunk of recognized speech.
    ///
    /// `start`/`end` are derived from each word's `SFTranscriptionSegment.timestamp`/
    /// `.duration` (seconds since this segment's recognition request began
    /// receiving audio), anchored to that request's *actual first
    /// successfully-written* audio buffer -- not to callback-arrival time,
    /// and not to `engine.start()`/request-swap time, neither of which
    /// reliably coincides with when audio actually started flowing. See
    /// `AudioFileWriter`. Each `WordTiming` also carries an audio-file-
    /// relative offset (`audioStart`/`audioEnd`) in the same coordinate
    /// system SpeakerDiarizationEngine's diarization segments use, so the
    /// two can be matched directly instead of through a wall-clock proxy.
    struct Utterance {
        var text: String
        var start: Date
        var end: Date

        /// Per-word timing that made up this utterance, in order. Preserved
        /// (rather than discarded once merged into `text`) so the transcript
        /// view can place a pause marker between the exact two words it
        /// actually fell between, and so diarization can match at word
        /// granularity instead of one timestamp per whole utterance.
        var words: [WordTiming] = []
    }

    /// Why a reflection ended without an explicit user `stop()` --
    /// delivered via `onRecordingEnded` so the caller (ReflectionSessionStore,
    /// through the owning screen) can finalize a session that would
    /// otherwise stay stuck in `.recording` forever, with no further
    /// updates and no UI path to end it.
    enum RecordingEndReason {
        case recoveryExhausted
        case unsupported
    }

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStoppingIntentionally = false

    private var pendingAudioFileURL: URL?
    private var audioWriter: AudioFileWriter?

    /// The only way `audioWriter` should ever be assigned -- keeps
    /// `audioWriterBox` (read by the realtime tap) in lockstep with this
    /// `@MainActor` property. See `AudioWriterBox`'s doc comment.
    ///
    /// Internal rather than private, matching this file's existing
    /// testability precedent (e.g. `SpeakerDiarizationEngine`'s exposed
    /// static helpers): lets tests inject a writer directly without going
    /// through `beginListeningSegment()`'s live `AVAudioEngine`/
    /// `SFSpeechRecognizer` setup, which this simulator environment can't
    /// exercise without a granted microphone/speech permission.
    func setAudioWriter(_ writer: AudioFileWriter?) {
        audioWriter = writer
        audioWriterBox.set(writer)
    }

    /// Detaches whatever writer is currently referenced (if any) from both
    /// `audioWriter` and `audioWriterBox` immediately -- so the running
    /// tap's very next buffer callback can no longer reach it -- then
    /// asynchronously flushes it and keeps or deletes its file based on
    /// whether it ever received a single successfully-written frame
    /// (verified by frame count, not file size). Used wherever a writer is
    /// abandoned outside the normal `finishAudioCapture()` path: a fresh
    /// `start()` discarding whatever a prior reflection's failure left
    /// behind, and `finishWithFailure(_:)` terminating the current one.
    ///
    /// Internal (see `setAudioWriter`'s doc comment) and returns the
    /// spawned cleanup `Task` so a test can `await` it deterministically
    /// instead of guessing a sleep duration; every production call site
    /// ignores the return value, unchanged fire-and-forget behavior.
    @discardableResult
    func discardCurrentAudioWriterIfAny() -> Task<Void, Never>? {
        guard let orphan = audioWriter else { return nil }
        setAudioWriter(nil)
        return Task {
            await orphan.flush()
            guard !orphan.hasWrittenAnyFrames else { return }
            do {
                try FileManager.default.removeItem(at: orphan.url)
            } catch {
                print("Failed to remove a zero-write orphaned recording: \(error.localizedDescription)")
            }
        }
    }

    /// Monotonically increasing for the lifetime of this manager instance --
    /// never reset in `start()`. A stale callback from an already-superseded
    /// segment (routine rollover, interruption, or an entirely different,
    /// already-stopped reflection) always carries a generation strictly less
    /// than `requestGeneration` by the time it's checked, so monotonicity
    /// alone is what prevents an old reflection's late callback from ever
    /// mutating a new one.
    private var requestGeneration = 0

    private enum SegmentState {
        case active
        case sealed
    }
    private var currentGenerationState: SegmentState = .sealed

    /// Thread-safe mirror of `requestGeneration`, readable from the
    /// realtime audio-tap thread (which can't touch this @MainActor class's
    /// stored properties directly). Updated every time `beginListeningSegment()`
    /// advances the generation, including routine rollovers past the
    /// persistent tap/engine.
    private final class GenerationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func set(_ newValue: Int) {
            lock.lock(); value = newValue; lock.unlock()
        }
        func get() -> Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }
    private let generationBox = GenerationBox()

    /// Thread-safe target for the audio tap's buffer callback, which fires
    /// on a real-time audio thread outside this class's `@MainActor`
    /// isolation. The tap itself is installed exactly once (in the first
    /// call to `beginListeningSegment()`) and is never torn down at a
    /// routine segment boundary -- only the request underneath changes.
    /// That's what keeps the mic capturing continuously across Apple's ~1
    /// minute segment limit instead of stopping and restarting the engine,
    /// which previously left a real gap during which speech at the seam was
    /// silently dropped.
    private final class CurrentRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?

        /// Swaps in the new request and returns whatever was previously
        /// set, under the same lock `append()` uses -- so by the time this
        /// returns, no in-flight `append()` can still be holding the old
        /// reference, and it's safe for the caller to call `endAudio()` on
        /// the returned previous request right after.
        @discardableResult
        func set(request: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
            lock.lock(); defer { lock.unlock() }
            let previous = self.request
            self.request = request
            return previous
        }

        /// Called from the audio tap on a real-time thread for every buffer.
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); defer { lock.unlock() }
            request?.append(buffer)
        }

        /// Ends and clears the request under the *same* lock `append()`
        /// uses. Previously, stop/interruption called `endAudio()` via a
        /// separate, unlocked `recognitionRequest` property while the
        /// realtime tap thread could concurrently call `append()` via this
        /// box on the very same object -- a genuine data race on the
        /// request, independent of anything generation-related. Routing
        /// every `endAudio()` through this one method closes it.
        func endAndClear() {
            lock.lock(); defer { lock.unlock() }
            request?.endAudio()
            request = nil
        }
    }

    private let currentRequestBox = CurrentRequestBox()

    /// Thread-safe mirror of `audioWriter`, readable from the realtime
    /// audio-tap thread. The cold-start tap closure captures THIS box (an
    /// immutable `let`, safe to capture by value) instead of snapshotting
    /// `audioWriter` itself -- an explicit capture-list reference to
    /// `audioWriter` freezes whatever writer was live when the tap was
    /// installed, so later replacing `audioWriter` (a failed resume's
    /// writer being discarded, a new reflection's writer taking over)
    /// would leave the still-running tap silently feeding a writer nothing
    /// else holds. Every assignment to `audioWriter` goes through
    /// `setAudioWriter(_:)` below, which keeps this box and the
    /// `@MainActor` property in lockstep -- there is never a moment,
    /// however short, where they can disagree.
    private final class AudioWriterBox: @unchecked Sendable {
        private let lock = NSLock()
        private var writer: AudioFileWriter?
        func set(_ newWriter: AudioFileWriter?) {
            lock.lock(); writer = newWriter; lock.unlock()
        }
        func get() -> AudioFileWriter? {
            lock.lock(); defer { lock.unlock() }
            return writer
        }
    }
    private let audioWriterBox = AudioWriterBox()

    /// Detects real silence gaps by measuring RMS amplitude on every audio
    /// buffer from the tap, independent of speech recognition. Called from
    /// the same real-time audio thread as `CurrentRequestBox.append`, so it
    /// has its own lock rather than sharing that one -- there's no ordering
    /// requirement between the two, and keeping them separate avoids
    /// widening `CurrentRequestBox`'s lock scope to cover unrelated work.
    private final class SilenceTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var isSilent = false
        private var silenceStart: Date?
        private var onGap: (@Sendable (Date, TimeInterval) -> Void)?
        private var nonSilentStreakStart: Date?

        /// RMS amplitude (0...1 scale, Float32 PCM) below this is treated as
        /// silence. This is a heuristic, not a calibrated measurement --
        /// tuned for a phone at normal talking distance in a quiet-to-
        /// moderate room.
        private let silenceRMSThreshold: Float = 0.02

        /// A single buffer is ~20-25ms at typical sample rates -- far
        /// shorter than a real word. Requiring louder audio to be sustained
        /// this long before ending a silence makes a brief blip (a breath,
        /// a click) not count, while real resumed speech still ends the
        /// silence promptly.
        private let resumeDebounce: TimeInterval = 0.3

        /// Matches ReflectionSessionStore.minimumObservablePause -- gaps
        /// shorter than this aren't recorded as evidence.
        private let minimumGapDuration: TimeInterval = 1.5

        func setCallback(_ callback: @escaping @Sendable (Date, TimeInterval) -> Void) {
            lock.lock(); defer { lock.unlock() }
            onGap = callback
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            isSilent = false
            silenceStart = nil
            nonSilentStreakStart = nil
        }

        func process(_ buffer: AVAudioPCMBuffer, at date: Date) {
            guard let channelData = buffer.floatChannelData else { return }
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { return }

            let samples = channelData[0]
            var sumSquares: Float = 0
            for i in 0..<frameCount {
                let sample = samples[i]
                sumSquares += sample * sample
            }
            let rms = (sumSquares / Float(frameCount)).squareRoot()

            lock.lock()
            var firedCallback: (@Sendable (Date, TimeInterval) -> Void)?
            var firedArgs: (Date, TimeInterval)?

            if rms < silenceRMSThreshold {
                nonSilentStreakStart = nil
                if !isSilent {
                    isSilent = true
                    silenceStart = date
                }
            } else if isSilent {
                if nonSilentStreakStart == nil {
                    nonSilentStreakStart = date
                }

                if let streakStart = nonSilentStreakStart,
                   date.timeIntervalSince(streakStart) >= resumeDebounce {
                    if let silenceStart {
                        let duration = streakStart.timeIntervalSince(silenceStart)
                        if duration >= minimumGapDuration {
                            firedCallback = onGap
                            firedArgs = (silenceStart, duration)
                        }
                    }
                    isSilent = false
                    silenceStart = nil
                    nonSilentStreakStart = nil
                }
            }
            lock.unlock()

            if let firedCallback, let firedArgs {
                firedCallback(firedArgs.0, firedArgs.1)
            }
        }
    }

    private let silenceTracker = SilenceTracker()

    /// Owns the saved `.caf` file and is the single source of truth for
    /// where a moment in time sits within it. Writes happen on a dedicated
    /// background queue, never on the realtime audio-tap thread -- a
    /// synchronous disk write there risked audio glitches, and errors were
    /// previously swallowed with `try?`. `writtenFrames` only ever advances
    /// on a confirmed successful write, never on admission to the queue --
    /// recognition (which appends independently, synchronously, via
    /// `CurrentRequestBox`) and the saved file could otherwise silently
    /// disagree about how much audio actually exists.
    /// `AVAudioPCMBuffer` isn't `Sendable`. Wraps a buffer that's been
    /// verified safe to hand across a queue boundary (a private, freshly-
    /// allocated copy nothing else holds a reference to) so it can be
    /// captured by a `@Sendable` closure such as `DispatchQueue.async`'s.
    private struct SendableBufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    /// Internal rather than private (see `setAudioWriter`'s doc comment) --
    /// lets tests construct a writer directly and drive `enqueue`/`flush`
    /// without any live `AVAudioEngine`/`SFSpeechRecognizer` dependency,
    /// since this type's own logic (frame accounting, loss recording) is
    /// pure and file-I/O-only.
    final class AudioFileWriter: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "Observatory.AudioFileWriter", qos: .utility)
        private let audioFile: AVAudioFile

        /// Bounds how much work can be outstanding on `queue` at once.
        /// Without this, a sustained stall in `AVAudioFile.write` could grow
        /// unboundedly on top of the (already buffer-copy-owned) memory.
        private static let maxOutstanding = 200
        private var outstanding = 0

        private var writtenFrames: Int64 = 0

        /// One entry per detected sample-rate change -- the overwhelming
        /// majority of recordings have exactly one. `baseFrames`/`baseSeconds`
        /// are the cumulative totals *before* this epoch began, so
        /// converting a frame count to seconds is piecewise, never a single
        /// cumulative-frames-divided-by-current-rate division, which would
        /// be wrong for any frame written under an earlier rate.
        private struct Epoch {
            var baseFrames: Int64
            var baseSeconds: TimeInterval
            var sampleRate: Double
        }
        private var epochs: [Epoch]

        private struct GenerationAnchor {
            var frameOffset: Int64
            var wallClockAnchor: Date
        }
        private var generationAnchors: [Int: GenerationAnchor] = [:]

        private(set) var missingAudioIntervals: [AudioInterval] = []
        private(set) var isReliable = true

        /// Wall-clock moment of the most recent `enqueue` call, successful
        /// or not -- i.e. "did the tap deliver a buffer recently," not "did
        /// a write succeed recently." Used by the manager's watchdog to
        /// tell a genuinely dead tap/engine apart from a recognition task
        /// that went silent while capture itself continued (see U6 /
        /// PLAN.md's audio-energy forensics on the smoke-test session).
        private var lastEnqueueAt: Date?

        /// Kept alongside `audioFile` so a caller can delete this writer's
        /// file without needing to reach into `audioFile` itself.
        let url: URL

        init(url: URL, format: AVAudioFormat) throws {
            self.url = url
            audioFile = try AVAudioFile(forWriting: url, settings: format.settings)
            epochs = [Epoch(baseFrames: 0, baseSeconds: 0, sampleRate: format.sampleRate)]
        }

        /// Called from the realtime audio-tap thread. Deep-copies `buffer`
        /// (engine-owned buffers aren't safe to retain past the callback)
        /// and hands the copy to the background queue together with the
        /// real capture-time metadata -- `capturedAt` is read on the tap
        /// thread at the actual moment this buffer arrived, never inferred
        /// later from queue admission or drain time.
        func enqueue(_ buffer: AVAudioPCMBuffer, generation: Int, capturedAt: Date) {
            lock.lock()
            lastEnqueueAt = capturedAt
            guard outstanding < Self.maxOutstanding else {
                lock.unlock()
                recordLoss(frameCount: Int64(buffer.frameLength))
                return
            }
            outstanding += 1
            lock.unlock()

            guard let copy = Self.copyBuffer(buffer) else {
                lock.lock(); outstanding -= 1; lock.unlock()
                recordLoss(frameCount: Int64(buffer.frameLength))
                return
            }

            let sampleRate = buffer.format.sampleRate
            // `AVAudioPCMBuffer` isn't `Sendable`, but `copy` is a private,
            // just-allocated deep copy that nothing else touches before
            // this closure consumes it -- safe to cross the queue boundary,
            // same manually-verified-safety rationale as this class's own
            // `@unchecked Sendable` conformance.
            let boxedCopy = SendableBufferBox(buffer: copy)
            queue.async { [weak self] in
                self?.write(boxedCopy.buffer, generation: generation, capturedAt: capturedAt, sampleRate: sampleRate)
            }
        }

        private func write(_ buffer: AVAudioPCMBuffer, generation: Int, capturedAt: Date, sampleRate: Double) {
            lock.lock()
            if generationAnchors[generation] == nil {
                if let lastEpoch = epochs.last, lastEpoch.sampleRate != sampleRate {
                    epochs.append(Epoch(baseFrames: writtenFrames, baseSeconds: audioSecondsLocked(for: writtenFrames), sampleRate: sampleRate))
                }
                generationAnchors[generation] = GenerationAnchor(frameOffset: writtenFrames, wallClockAnchor: capturedAt)
            }
            lock.unlock()

            do {
                try audioFile.write(from: buffer)
                lock.lock()
                writtenFrames += Int64(buffer.frameLength)
                outstanding -= 1
                lock.unlock()
            } catch {
                lock.lock(); outstanding -= 1; lock.unlock()
                recordLoss(frameCount: Int64(buffer.frameLength))
            }
        }

        private func recordLoss(frameCount: Int64) {
            lock.lock()
            let start = audioSecondsLocked(for: writtenFrames)
            let end = audioSecondsLocked(for: writtenFrames + frameCount)
            missingAudioIntervals.append(AudioInterval(start: start, end: end))
            isReliable = false
            lock.unlock()
        }

        private func audioSecondsLocked(for frames: Int64) -> TimeInterval {
            let epoch = epochs.last(where: { $0.baseFrames <= frames }) ?? epochs[0]
            return epoch.baseSeconds + Double(frames - epoch.baseFrames) / epoch.sampleRate
        }

        /// Audio-file-relative offset for a word reported at
        /// `segmentTimestamp` (seconds since `generation`'s recognition
        /// request began receiving audio). `nil` if this generation never
        /// got a single successfully-written buffer -- e.g. every buffer
        /// for it was lost -- rather than guessing an offset of 0.
        func audioOffset(forGeneration generation: Int, segmentTimestamp: TimeInterval) -> TimeInterval? {
            lock.lock(); defer { lock.unlock() }
            guard let anchor = generationAnchors[generation] else { return nil }
            return audioSecondsLocked(for: anchor.frameOffset) + segmentTimestamp
        }

        /// Wall-clock equivalent of the above, anchored to this
        /// generation's first *actually captured* buffer.
        func wallClock(forGeneration generation: Int, segmentTimestamp: TimeInterval) -> Date? {
            lock.lock(); defer { lock.unlock() }
            guard let anchor = generationAnchors[generation] else { return nil }
            return anchor.wallClockAnchor.addingTimeInterval(segmentTimestamp)
        }

        /// Waits for every write already accepted onto `queue` to finish.
        /// Diarization and any future acoustic-feature extraction must
        /// never open this file before this returns.
        func flush() async {
            await withCheckedContinuation { continuation in
                queue.async {
                    continuation.resume()
                }
            }
        }

        func diagnosticsSnapshot() -> (isReliable: Bool, missingAudioIntervals: [AudioInterval]) {
            lock.lock(); defer { lock.unlock() }
            return (isReliable, missingAudioIntervals)
        }

        /// Verified by frame count, never by file size -- a writer that
        /// never received a single successfully-written buffer still
        /// creates a bare-header `.caf` file on disk (observed: 4096
        /// bytes), which a byte-size check could confuse with a short but
        /// genuine recording.
        var hasWrittenAnyFrames: Bool {
            lock.lock(); defer { lock.unlock() }
            return writtenFrames > 0
        }

        /// Where the saved file currently ends, in audio-file-relative
        /// seconds -- a plain reading of `writtenFrames` via the same
        /// `audioSecondsLocked(for:)` math every other offset in this class
        /// already uses (D-05's existing semantics: file-time only
        /// advances on successful writes). Answers ONLY "where does the
        /// file end," never "when did capture stop" or "was everything
        /// before this point continuous" -- see
        /// `CaptureCompleteness.incomplete`'s doc comment.
        var endpointAudioSeconds: TimeInterval {
            lock.lock(); defer { lock.unlock() }
            return audioSecondsLocked(for: writtenFrames)
        }

        /// Whether the tap delivered a buffer (successfully written or
        /// not) at or after `cutoff`. Used only to confirm the tap/engine
        /// itself is still alive -- deliberately independent of whether
        /// any of those buffers actually made it to disk.
        func hasReceivedBuffer(since cutoff: Date) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard let lastEnqueueAt else { return false }
            return lastEnqueueAt >= cutoff
        }

        private static func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
            copy.frameLength = buffer.frameLength
            guard let src = buffer.floatChannelData, let dst = copy.floatChannelData else { return copy }
            let channelCount = Int(buffer.format.channelCount)
            for channel in 0..<channelCount {
                dst[channel].update(from: src[channel], count: Int(buffer.frameLength))
            }
            return copy
        }
    }

    private var currentOnSilenceGap: (@MainActor (Date, TimeInterval) -> Void)?

    /// Utterances finalized from earlier listening segments in this
    /// recording. Apple's speech engine ends a "segment" (an
    /// SFSpeechRecognitionTask) on its own after roughly a minute of
    /// continuous speech, and an interruption (call, Siri, another app) also
    /// forcibly ends a segment. Rather than treating either as the end of
    /// the reflection, we seal whatever utterances that segment produced in
    /// here and quietly start a new segment, so the transcript reads as one
    /// continuous recording to the user.
    private var sealedUtterances: [Utterance] = []

    /// Utterances recognized so far in the *current* segment, recomputed in
    /// full from `SFSpeechRecognitionResult.bestTranscription.segments`
    /// every time a new result arrives (that array only ever grows within a
    /// segment, and each segment's own `timestamp`/`duration` never changes
    /// once reported, so recomputing from scratch every call is cheap and
    /// always consistent -- no separate "already stamped" cache needed).
    private var currentSegmentUtterances: [Utterance] = []

    /// Non-nil once the current segment's audio has actually started. Used
    /// only as a "has recognition actually begun" gate in `handleRecognition`,
    /// and as a last-resort wall-clock fallback if `AudioFileWriter` never
    /// got a successfully-written buffer for this generation.
    private var segmentAudioStartDate: Date?

    private var currentOnTranscript: (@MainActor ([Utterance]) -> Void)?
    // Internal (see the testability-seam note on the properties above) --
    // lets tests assert exactly what finishWithFailure's callback fired
    // with, without a full start()/hardware-backed session.
    var currentOnRecordingEnded: (@MainActor (UUID, RecordingEndReason) -> Void)?
    private var interruptionObserver: NSObjectProtocol?

    /// True from the moment `AVAudioSession.interruptionNotification`
    /// reports `.began` until its matching `.ended` -- distinct from
    /// `lifecycleState` below, which also covers recovery triggered by the
    /// watchdog or a recognition error with no OS interruption involved at
    /// all. While this is true, the watchdog intentionally does not also
    /// try to restart recognition: the OS already has the microphone, and
    /// we're waiting specifically for its `.ended` signal rather than
    /// burning a recovery attempt already expected to fail.
    // The properties below (through recognitionContinuityGaps) are
    // `internal` rather than `private`, matching this file's existing
    // testability precedent (e.g. `SpeakerDiarizationEngine`'s exposed
    // static helpers). Driving this state machine through the public
    // `start()` API in a test would require a live AVAudioEngine/
    // SFSpeechRecognizer with granted microphone/speech permission, which
    // this simulator environment doesn't have (see
    // AudioFixtureReplayTests' own device-only diagnostics) -- these
    // internal seams let tests set up and inspect recovery-path state
    // directly instead.
    var interruptionInProgress = false

    enum LifecycleState: Equatable {
        case idle
        case active
        case recovering
        case stopped
    }

    /// Mirrored into the `@Published isRecording` above on every change --
    /// `.recovering` counts as "recording" from the UI's perspective (the
    /// reflection is still live and expected to resume on its own) so a
    /// person is never shown an indefinite "tap Start to resume" state
    /// that the Start button can't actually honor (see R1.4's copy fix).
    var lifecycleState: LifecycleState = .idle {
        didSet { isRecording = (lifecycleState == .active || lifecycleState == .recovering) }
    }

    /// Identifies one `start()` call's entire lifecycle. Every async
    /// trigger (watchdog, foreground reconciliation, the interruption
    /// notification's `.ended` case) captures this at the moment it's
    /// scheduled and re-checks it before acting, so a trigger that fires
    /// late -- after an explicit Stop, or after a brand-new reflection has
    /// already started under a new `reflectionID` -- is a safe no-op
    /// instead of reviving or corrupting the wrong reflection.
    var reflectionID: UUID?

    /// Whether the *person* still wants this reflection running,
    /// independent of whether the engine/recognition task is currently
    /// active. Set `true` in `start()`; set `false` ONLY by an explicit
    /// user `stop()` -- never by a transient failure -- so recovery logic
    /// can always ask "does the person still want this running?"
    /// separately from "is the engine currently running?"
    var recordingIntent = false

    /// Count of CONSECUTIVE failures to establish a new recognition
    /// request (`beginListeningSegment()` returning `false`) across this
    /// reflection's lifetime, regardless of which trigger caused the
    /// attempt. Reset to 0 on every SUCCESSFUL attempt -- this is NOT a
    /// count of attempts or triggers, so a reflection can accumulate any
    /// number of successful watchdog-triggered rollovers across a long
    /// quiet stretch without ever moving this off zero. Exhausting this
    /// budget is "fails for good," alongside the rate-window guard below.
    var consecutiveRecoveryFailures = 0
    static let maxConsecutiveRecoveryFailures = 5

    /// Timestamps of recent recovery ATTEMPTS (successful or not) --
    /// unchanged from before U6. `isRestartLoopDetected()` below (also
    /// unchanged) catches a DIFFERENT pathology than
    /// `consecutiveRecoveryFailures` above: a tight loop where
    /// `beginListeningSegment()` keeps SUCCEEDING (setup is fine) but the
    /// recognition task immediately errors again and again, which would
    /// never trip the consecutive-FAILURE budget since every individual
    /// setup call succeeds. U6 adds the new budget alongside this; it does
    /// not replace it.
    var recentAutoRestarts: [Date] = []

    /// Wall-clock moment of the most recent recognition callback (partial,
    /// final, or error) -- updated at the top of `handleRecognition`. The
    /// watchdog compares this against `Date()` to detect a recognition
    /// task that has gone silent (neither a final result nor an error)
    /// while capture itself continues -- the failure mode the smoke test
    /// actually exposed (see PLAN.md's audio-energy forensics).
    var lastRecognitionCallbackAt: Date?

    /// Every wall-clock moment a non-routine recovery was attempted
    /// (error, watchdog stall, interruption-ended resume, or foreground
    /// reconciliation) -- NOT a routine isFinal rollover. Deliberately
    /// plain `Date` instants, not an `AudioInterval`: see Models.swift's
    /// `recognitionContinuityGaps` doc comment for why no duration is
    /// claimed here.
    var recognitionContinuityGaps: [Date] = []

    /// True the moment capture (the engine/tap) ever ceases mid-reflection
    /// outside of a user-initiated Stop -- set in `handleInterruption(.began)`,
    /// the one and only place that happens. NEVER reset back to `false`
    /// during the same reflection, not even by a later successful
    /// recovery -- `captureCompleteness` describes WHOLE-SESSION
    /// completeness, so one outage makes the rest of the session's
    /// completeness status `.incomplete` regardless of what happens
    /// afterward (see Models.swift's `CaptureCompleteness` doc comment and
    /// PROPOSALS/U6-proposal.md R5.2 for the full establishment rule).
    /// Internal rather than private, matching this file's existing
    /// testability-seam precedent.
    var hadCaptureOutage = false

    private var watchdogTimer: Timer?
    private static let watchdogInterval: TimeInterval = 20
    private static let recognitionStaleThreshold: TimeInterval = 25

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt

            Task { @MainActor [weak self] in
                self?.handleInterruption(type: type, optionsValue: optionsValue)
            }
        }

        silenceTracker.setCallback { [weak self] start, duration in
            Task { @MainActor [weak self] in
                self?.currentOnSilenceGap?(start, duration)
            }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    func requestPermissions() async -> Bool {
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            statusMessage = "Speech recognition permission not granted."
            permissionDenied = true
            return false
        }

        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard microphoneGranted else {
            statusMessage = "Microphone permission not granted."
            permissionDenied = true
            return false
        }

        permissionDenied = false
        statusMessage = "Speech permissions ready."
        return true
    }

    private static let hasPromptedMicModeKey = "SpeechRecognitionManager.hasPromptedMicMode"

    func start(
        audioFileName: String,
        onTranscript: @escaping @MainActor ([Utterance]) -> Void,
        onSilenceGap: (@MainActor (Date, TimeInterval) -> Void)? = nil,
        onRecordingEnded: (@MainActor (UUID, RecordingEndReason) -> Void)? = nil
    ) {
        // This app wants exactly one speaker -- the person reflecting --
        // and nothing else. Single-speaker isolation is left entirely to
        // system Mic Mode (Control Center) rather than also applying the
        // audio engine's own voice-processing unit -- doing both stacked
        // double-processed the signal and measurably hurt
        // SFSpeechRecognizer's accuracy. Mic Mode is user-owned and
        // read-only to apps, so this can only ask once, not force it.
        if AVCaptureDevice.preferredMicrophoneMode != .voiceIsolation,
           !UserDefaults.standard.bool(forKey: Self.hasPromptedMicModeKey) {
            UserDefaults.standard.set(true, forKey: Self.hasPromptedMicModeKey)
            AVCaptureDevice.showSystemUserInterface(.microphoneModes)
        }

        currentOnTranscript = onTranscript
        currentOnSilenceGap = onSilenceGap
        currentOnRecordingEnded = onRecordingEnded
        sealedUtterances = []
        currentSegmentUtterances = []
        segmentAudioStartDate = nil
        liveTranscript = ""
        isStoppingIntentionally = false
        interruptionInProgress = false
        // Discards (flush, then keep-or-delete by frame count) whatever a
        // prior reflection's unrecovered failure left behind, rather than
        // a bare `audioWriter = nil` that would silently orphan it -- see
        // discardCurrentAudioWriterIfAny's doc comment.
        discardCurrentAudioWriterIfAny()
        pendingAudioFileURL = Self.audioFileURL(named: audioFileName)
        recentAutoRestarts = []
        consecutiveRecoveryFailures = 0
        recognitionContinuityGaps = []
        hadCaptureOutage = false
        lastRecognitionCallbackAt = nil
        silenceTracker.reset()

        reflectionID = UUID()
        recordingIntent = true
        lifecycleState = .recovering

        if beginListeningSegment() {
            lifecycleState = .active
            scheduleWatchdogIfNeeded()
        } else {
            finishWithFailure(.unsupported)
        }
    }

    static func audioFileURL(named fileName: String) -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return baseURL
            .appendingPathComponent("Observatory", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Starts (or continues into) one listening segment. Used for the
    /// initial start, for resuming after an interruption, and for quietly
    /// continuing past Apple's ~1 minute segment limit.
    ///
    /// Whenever the audio engine is already running -- the routine case of
    /// continuing past the ~1 minute limit -- this does NOT stop it, touch
    /// its tap, or reconfigure the audio session. It only swaps in a fresh
    /// `SFSpeechAudioBufferRecognitionRequest` so the mic never stops
    /// capturing and no audio at the segment seam is lost, and advances the
    /// generation so word timing anchors to the right request.
    /// Returns `true` if this call actually started listening (a working
    /// recognition request is now in flight), `false` if it failed for any
    /// reason -- callers (`start()`, `attemptRecovery(trigger:forReflection:)`)
    /// decide what a `false` means for them (unsupported-on-first-call vs.
    /// one more count against the shared recovery budget).
    @discardableResult
    private func beginListeningSegment() -> Bool {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable."
            print("[u6-recovery] beginListeningSegment failed: speechRecognizer unavailable (nilRecognizer=\(speechRecognizer == nil))")
            return false
        }

        // SECURITY.md promises reflection content never leaves the device.
        // `request.requiresOnDeviceRecognition` below is what actually
        // enforces that -- without it, SFSpeechRecognizer may silently use
        // Apple's server-based recognition instead. If the device/locale
        // combination can't do on-device recognition at all, this fails
        // rather than silently falling back to a network request that
        // would make the privacy claim false; the caller is responsible
        // for ending the reflection honestly (see `RecordingEndReason.unsupported`).
        guard speechRecognizer.supportsOnDeviceRecognition else {
            statusMessage = "On-device speech recognition isn't available on this device -- stopping rather than send audio off-device."
            print("[u6-recovery] beginListeningSegment failed: on-device recognition not supported")
            return false
        }

        currentSegmentUtterances = []
        segmentAudioStartDate = nil

        requestGeneration += 1
        let generation = requestGeneration
        generationBox.set(generation)
        currentGenerationState = .active

        do {
            let audioSession = AVAudioSession.sharedInstance()
            let isColdStart = !audioEngine.isRunning

            // Only reconfigure the session on a true cold start (first
            // segment, or resuming after an interruption tore the engine
            // down) -- reconfiguring an already-active, already-correct
            // session on every routine ~1-minute rollover was redundant
            // work and the leading cause of the repeated main-thread
            // AVAudioSession responsiveness warning seen in the console.
            if isColdStart {
                // `.measurement`, not `.default`: matches Apple's own
                // SFSpeechRecognizer sample code. `.default`'s automatic
                // gain adjustment measurably hurt recognition accuracy on
                // top of whatever the system Mic Mode already applies.
                try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
                try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            // Without this, SFSpeechRecognizer returns one unbroken run-on
            // phrase with no periods/commas at all.
            request.addsPunctuation = true
            // Enforces the on-device-only privacy claim in SECURITY.md --
            // already confirmed available via supportsOnDeviceRecognition
            // above, but the request itself has to opt in or recognition
            // can still use Apple's server-based path.
            request.requiresOnDeviceRecognition = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            if audioWriter == nil, let pendingAudioFileURL {
                do {
                    try FileManager.default.createDirectory(
                        at: pendingAudioFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    setAudioWriter(try AudioFileWriter(url: pendingAudioFileURL, format: recordingFormat))
                } catch {
                    // Live transcription still works without this --
                    // diarization just won't have audio to work from.
                    print("Reflection audio recording failed to open: \(error.localizedDescription)")
                    setAudioWriter(nil)
                }
            }

            let previousRequest = currentRequestBox.set(request: request)
            previousRequest?.endAudio()

            if isColdStart {
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [currentRequestBox, silenceTracker, generationBox, audioWriterBox] buffer, _ in
                    let capturedAt = Date()
                    currentRequestBox.append(buffer)
                    silenceTracker.process(buffer, at: capturedAt)
                    audioWriterBox.get()?.enqueue(buffer, generation: generationBox.get(), capturedAt: capturedAt)
                }

                audioEngine.prepare()
                try audioEngine.start()
            }

            segmentAudioStartDate = Date()
            statusMessage = "Listening."

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.handleRecognition(result: result, error: error, generation: generation)
                }
            }
            return true
        } catch {
            // A writer may already have been created (and, on a cold
            // start, already tap-captured via `audioWriterBox`) before
            // this throw -- e.g. `audioEngine.start()` failing. The
            // caller's `finishWithFailure(_:)` (on first-call failure) or
            // the next `start()` (on a mid-reflection retry failure, via
            // `discardCurrentAudioWriterIfAny()`) is responsible for
            // flushing and keeping-or-deleting it; this function doesn't
            // need to duplicate that here.
            statusMessage = "Speech start failed: \(error.localizedDescription)"
            let nsError = error as NSError
            print("[u6-recovery] beginListeningSegment failed: domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)")
            return false
        }
    }

    /// Groups a result's word/phrase-level segments into utterances,
    /// splitting wherever the audio-relative gap since the previous word is
    /// at least `utteranceGapThreshold`.
    ///
    /// Text for each segment comes from `formattedString` (via
    /// `segment.substringRange`), not `segment.substring` -- the latter is
    /// SFSpeechRecognizer's raw per-word text with none of the
    /// capitalization, punctuation, and smart-formatting Apple normally
    /// applies to `bestTranscription.formattedString`. `substringRange` is
    /// the documented way to map a segment back onto its formatted text.
    private func utterances(from segments: [SFTranscriptionSegment], formattedString: String, generation: Int) -> [Utterance] {
        let writer = audioWriter
        return SpeechTranscriptTimingMapper.utterances(
            from: segments,
            formattedString: formattedString,
            audioOffset: { timestamp in
                writer?.audioOffset(forGeneration: generation, segmentTimestamp: timestamp)
            },
            wallClock: { timestamp in
                writer?.wallClock(forGeneration: generation, segmentTimestamp: timestamp)
            },
            fallbackWallClockAnchor: segmentAudioStartDate
        )
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?, generation: Int) {
        // Rejects any callback still in flight from a request that's
        // already been superseded -- a routine rollover, an interruption,
        // a stop, or (since `requestGeneration` is never reset in `start()`)
        // an entirely different, already-stopped reflection.
        guard generation == requestGeneration else { return }

        // Marks "recognition is still alive" regardless of what this
        // callback contains -- the watchdog compares this against `Date()`
        // to detect a recognition task that has gone silent (neither a
        // final result nor an error) while capture itself continues.
        lastRecognitionCallbackAt = Date()

        if let result, segmentAudioStartDate != nil {
            let segments = result.bestTranscription.segments
            if !segments.isEmpty {
                currentSegmentUtterances = utterances(
                    from: segments,
                    formattedString: result.bestTranscription.formattedString,
                    generation: generation
                )
            }

            let combined = sealedUtterances + currentSegmentUtterances
            if !combined.isEmpty {
                liveTranscript = combined.map(\.text).joined(separator: " ")
                statusMessage = result.isFinal ? "Final transcript received." : "Listening."
                currentOnTranscript?(combined)
            }
        }

        // Apple's resultHandler can deliver a final result *and* an error
        // in the same callback -- computing this once and guarding on
        // `currentGenerationState` (set to `.sealed` immediately below,
        // before any of the branches that might call `beginListeningSegment()`,
        // which advances to a new, `.active` generation) ensures this
        // segment only ever rolls over once, even if both conditions are
        // true at once.
        if let error {
            // Privacy rule: domain/code/generation only, never transcript
            // text. Lets a device run's console log show exactly which
            // error (e.g. kAFAssistantErrorDomain 1110, "No speech
            // detected") preceded a recovery attempt.
            let nsError = error as NSError
            print("[u6-recovery] recognition error domain=\(nsError.domain) code=\(nsError.code) generation=\(generation)")
        }

        let shouldRollover = (result?.isFinal == true) || (error != nil)
        guard shouldRollover, currentGenerationState != .sealed else { return }
        currentGenerationState = .sealed

        if isStoppingIntentionally {
            statusMessage = "Speech capture stopped."
            let combined = sealedUtterances + currentSegmentUtterances
            if !combined.isEmpty {
                currentOnTranscript?(combined)
            }
            return
        }

        if interruptionInProgress {
            // The system is mid-interruption (a call, Siri, or another app
            // just took the microphone). handleInterruption(type:optionsValue:)
            // already sealed this segment and will trigger recovery once
            // the interruption ends -- don't treat this as a failure.
            return
        }

        guard lifecycleState == .active || lifecycleState == .recovering, let reflectionID else {
            statusMessage = "Speech error: \(error?.localizedDescription ?? "unknown")"
            return
        }

        // Not an interruption and not a stop -- most likely Apple's speech
        // engine ending this segment on its own after continuous speech,
        // or a transient recognition error. Seal what we have and route
        // through the shared recovery path, which checks the rate-window
        // guard and the consecutive-failure budget (both unchanged by this
        // routing -- see attemptRecovery's doc comment) before quietly
        // continuing.
        sealCurrentSegment()
        attemptRecovery(trigger: error != nil ? .recognitionError : .routineRollover, forReflection: reflectionID)
    }

    /// Returns `true` if recent auto-restarts (triggered by a recognition
    /// error while still recording) are happening faster than a person
    /// could plausibly be causing on purpose -- a sign something is
    /// persistently failing rather than Apple's normal ~1-minute rollover.
    private func isRestartLoopDetected() -> Bool {
        let now = Date()
        recentAutoRestarts.removeAll { now.timeIntervalSince($0) > 10 }
        recentAutoRestarts.append(now)
        return recentAutoRestarts.count > 5
    }

    private func sealCurrentSegment() {
        sealedUtterances.append(contentsOf: currentSegmentUtterances)
        currentSegmentUtterances = []
    }

    // Internal rather than private (see the interruptionInProgress/
    // lifecycleState block's doc comment above) so tests can drive the
    // shared recovery path directly.
    enum RecoveryTrigger: Equatable {
        case routineRollover
        case recognitionError
        case watchdogStall
        case interruptionEnded
        case foregroundReconciliation
    }

    /// The single owner of every attempt to (re)start listening after
    /// anything other than a fresh `start()` -- a routine rollover, a
    /// recognition error, a stale-recognition watchdog stall, an
    /// interruption's `.ended`, or a foreground reconciliation check. Every
    /// trigger funnels through here so the rate-window guard
    /// (`isRestartLoopDetected()`, unchanged) and the consecutive-failure
    /// budget both see every attempt, regardless of source, instead of
    /// each trigger mutating state and calling `beginListeningSegment()`
    /// independently.
    func attemptRecovery(trigger: RecoveryTrigger, forReflection triggerReflectionID: UUID) {
        // A trigger scheduled for an already-superseded reflection (Stop
        // was pressed, or a brand-new reflection already started under a
        // new reflectionID) is a safe no-op, not a chance to revive or
        // corrupt the wrong session.
        guard recordingIntent, reflectionID == triggerReflectionID, lifecycleState != .stopped else { return }

        if trigger == .foregroundReconciliation || trigger == .watchdogStall {
            // Per ChatGPT's review: foreground activation requests
            // reconciliation, it does not independently start capture --
            // and the watchdog (R1.2 trigger 4) is a stall DETECTOR, not an
            // unconditional periodic rollover. Two independent conditions
            // justify acting:
            //
            // Mode A -- recognition alone went silent while capture
            // continued (isRecognitionStale()'s stale-callback +
            // buffers-flowing check).
            //
            // Mode B (R4.1, found by the 2026-10-23 device smoke test) --
            // a previous restart attempt already left us short of
            // `.active`. Buffers structurally CANNOT be flowing until a
            // FUTURE restart succeeds, so Mode A's buffers-flowing
            // requirement can never be satisfied here -- requiring it
            // anyway made a dead engine permanently unrecoverable
            // (consecutiveRecoveryFailures frozen below the terminal
            // budget forever, since beginListeningSegment() was never
            // reached again). `lifecycleState == .recovering` at the
            // moment a trigger fires already means exactly this: every
            // call to this function runs synchronously to completion
            // (MainActor-serialized), so there's no intermediate state to
            // distinguish "actively retrying right now" from "stuck after
            // a failed attempt." Excludes `interruptionInProgress` for the
            // same reason Mode A does -- don't thrash against a restart
            // while the OS still legitimately owns the microphone, waiting
            // on its own `.ended`.
            //
            // Without this gate (either half), every healthy recording
            // would get a forced rollover (and a phantom
            // recognitionContinuityGaps entry) every watchdogInterval
            // regardless of whether anything is wrong.
            let modeBStuckAfterFailedRestart = (lifecycleState == .recovering && !interruptionInProgress)
            guard isRecognitionStale() || modeBStuckAfterFailedRestart else { return }
        }

        // Moved here (after the gate, not unconditionally at entry) so a
        // watchdog/foreground trigger that's correctly gated out during
        // healthy operation doesn't spam the console every watchdogInterval
        // -- only an attempt that's actually proceeding logs. Counts/
        // timings/identifiers only, per the privacy rule: never transcript
        // text.
        let secondsSinceLastCallback = lastRecognitionCallbackAt.map { Date().timeIntervalSince($0) }
        print("[u6-recovery] attemptRecovery proceeding trigger=\(trigger) lifecycleState=\(lifecycleState) secondsSinceLastCallback=\(secondsSinceLastCallback.map { String(format: "%.1f", $0) } ?? "nil") generation=\(requestGeneration)")

        // Recorded for every NON-routine trigger -- see Models.swift's
        // `recognitionContinuityGaps` doc comment for why a routine
        // isFinal rollover doesn't count as a "gap."
        if trigger != .routineRollover {
            recognitionContinuityGaps.append(Date())
        }

        guard !isRestartLoopDetected() else {
            statusMessage = "Speech recognition kept failing -- stopped."
            finishWithFailure(.recoveryExhausted)
            return
        }

        lifecycleState = .recovering
        statusMessage = (trigger == .routineRollover) ? "Listening (continuing)." : "Recovering..."

        if beginListeningSegment() {
            consecutiveRecoveryFailures = 0
            lifecycleState = .active
            print("[u6-recovery] recovery succeeded, new segment started generation=\(requestGeneration)")
        } else {
            consecutiveRecoveryFailures += 1
            if consecutiveRecoveryFailures >= Self.maxConsecutiveRecoveryFailures {
                finishWithFailure(.recoveryExhausted)
            }
            // Otherwise stays `.recovering` -- the next trigger (the
            // watchdog, most likely) tries again.
        }
    }

    /// Mode A only (see `attemptRecovery`'s doc comment for Mode B, handled
    /// separately there). True only when recognition has genuinely gone
    /// silent while capture continues: no recognition callback (partial,
    /// final, or error) in over `recognitionStaleThreshold`, while the
    /// writer confirms the tap is still delivering buffers. Deliberately
    /// requires both -- a stale callback with NO buffers either just means
    /// the engine itself is quiet (e.g. backgrounded with capture
    /// legitimately paused, or -- Mode B -- a prior restart attempt
    /// already failed and buffers structurally cannot be flowing), neither
    /// of which this function alone can tell apart, which is why Mode B is
    /// a separate, additional condition at the call site rather than a
    /// change to this function.
    private func isRecognitionStale() -> Bool {
        guard lifecycleState == .active || lifecycleState == .recovering else { return false }
        guard !interruptionInProgress else { return false }
        let now = Date()
        let callbackIsStale = now.timeIntervalSince(lastRecognitionCallbackAt ?? .distantPast) > Self.recognitionStaleThreshold
        guard callbackIsStale else { return false }
        return audioWriter?.hasReceivedBuffer(since: now.addingTimeInterval(-Self.recognitionStaleThreshold)) ?? false
    }

    /// D3 (2026-10-23 smoke test): two `watchdogStall` recovery attempts
    /// were logged ~0.1s apart despite this being the only call site and
    /// its own `watchdogTimer == nil` guard. Not yet root-caused -- these
    /// token logs are diagnostic, not a fix: if a future run shows two
    /// DIFFERENT tokens firing near-simultaneously, that proves two
    /// `Timer` instances exist despite the nil guard (a real bug to chase
    /// next); if the SAME token fires twice, the bug is in `Timer`
    /// delivery/run-loop behavior, not this scheduling logic.
    private func scheduleWatchdogIfNeeded() {
        guard watchdogTimer == nil else {
            print("[u6-recovery] scheduleWatchdogIfNeeded no-op, timer already scheduled")
            return
        }
        let token = UUID()
        print("[u6-recovery] watchdog scheduled token=\(token)")
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: Self.watchdogInterval, repeats: true) { [weak self] _ in
            print("[u6-recovery] watchdog fired token=\(token)")
            Task { @MainActor [weak self] in
                guard let self, let reflectionID = self.reflectionID else { return }
                self.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)
            }
        }
    }

    /// Called when the app becomes active again (SwiftUI `scenePhase ==
    /// .active`). Per ChatGPT's review, this does NOT independently start
    /// capture -- it only asks the shared recovery path to check whether
    /// recognition looks stalled (the same test the watchdog uses) and, if
    /// so, attempt the same bounded recovery. A safe no-op if nothing
    /// looks wrong.
    func reconcileAfterForeground() {
        guard let reflectionID else { return }
        attemptRecovery(trigger: .foregroundReconciliation, forReflection: reflectionID)
    }

    /// Terminates the current reflection for good -- recovery exhausted,
    /// or recognition unsupported on this device/locale -- and tells the
    /// caller via `onRecordingEnded` so it can finalize a session that
    /// would otherwise stay stuck in `.recording` forever. Idempotent:
    /// a second call (e.g. a stale trigger racing a prior failure) is a
    /// no-op once `lifecycleState` is already `.stopped`.
    private func finishWithFailure(_ reason: RecordingEndReason) {
        guard lifecycleState != .stopped else { return }
        let endedReflectionID = reflectionID
        print("[u6-recovery] finishWithFailure reason=\(reason) reflectionID=\(endedReflectionID?.uuidString ?? "nil")")
        lifecycleState = .stopped
        recordingIntent = false
        interruptionInProgress = false
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        currentRequestBox.endAndClear()
        recognitionTask = nil
        silenceTracker.reset()

        // R5.3: only discard eagerly if nothing will ever ask for it.
        // When a listener IS wired (both production screens always wire
        // one via `onRecordingEnded`), leave the writer alone -- the
        // callback below leads to `finishAudioCapture()` shortly after,
        // which is now the single, unified place that flushes, reads
        // diagnostics (including `captureCompleteness`), and discards.
        // Discarding here unconditionally (the pre-R5 behavior) meant
        // `finishAudioCapture()` always saw `audioWriter == nil` by the
        // time the callback chain reached it, so every terminal-failure
        // session -- exactly the ones this unit exists to diagnose --
        // silently lost its reliability/completeness diagnostics.
        if currentOnRecordingEnded == nil {
            discardCurrentAudioWriterIfAny()
        }

        switch reason {
        case .recoveryExhausted:
            statusMessage = "Recording ended — recovery didn't succeed."
        case .unsupported:
            statusMessage = "On-device speech recognition isn't available on this device -- stopping rather than send audio off-device."
        }

        if let endedReflectionID {
            currentOnRecordingEnded?(endedReflectionID, reason)
        }
    }

    private func handleInterruption(type: AVAudioSession.InterruptionType, optionsValue: UInt?) {
        switch type {
        case .began:
            let guardPassed = (lifecycleState == .active || lifecycleState == .recovering)
            print("[u6-recovery] interruption .began received, guardPassed=\(guardPassed)")
            guard guardPassed else { return }
            interruptionInProgress = true
            // The one and only mid-reflection capture-ceases event (see
            // hadCaptureOutage's doc comment) -- never reset back to
            // false during this reflection, even if this interruption
            // resolves cleanly.
            hadCaptureOutage = true
            currentGenerationState = .sealed
            sealCurrentSegment()

            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            currentRequestBox.endAndClear()
            recognitionTask = nil
            lifecycleState = .recovering
            statusMessage = "Paused — interrupted (call, Siri, or another app)."

            // The mic isn't capturing during an interruption, so whatever
            // silence state was mid-measurement is meaningless -- reset
            // rather than let it produce a bogus gap (or a bogus *missing*
            // gap) once the tap resumes.
            silenceTracker.reset()

        case .ended:
            let shouldResume = optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) }
            print("[u6-recovery] interruption .ended received, shouldResume=\(shouldResume.map(String.init) ?? "nil")")
            guard interruptionInProgress else { return }
            interruptionInProgress = false

            // `.shouldResume` is known-unreliable across compound/chained
            // interruptions (confirmed: PLAN.md's audio-energy forensics
            // show capture surviving a Siri->Maps chain this bit was never
            // reliably observed for) -- always attempt to resume through
            // the shared recovery path rather than gating on it. A
            // genuinely unresumable session fails honestly through the
            // shared budget instead of leaving the person in an indefinite
            // "tap Start to resume" state that the Start button can't
            // actually honor.
            guard let reflectionID else { return }
            attemptRecovery(trigger: .interruptionEnded, forReflection: reflectionID)

        @unknown default:
            break
        }
    }

    func stop() {
        isStoppingIntentionally = true
        recordingIntent = false
        interruptionInProgress = false
        currentGenerationState = .sealed
        watchdogTimer?.invalidate()
        watchdogTimer = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        currentRequestBox.endAndClear()
        recognitionTask = nil
        lifecycleState = .stopped
        silenceTracker.reset()
        currentOnSilenceGap = nil
        pendingAudioFileURL = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Safe to ignore for prototype.
        }
    }

    /// Flushes every write already accepted by the background audio
    /// writer, then returns a diagnostics snapshot (including this
    /// reflection's recognition-continuity gaps -- see Models.swift's
    /// `recognitionContinuityGaps` doc comment -- and whole-session
    /// `captureCompleteness`, computed from `hadCaptureOutage` plus the
    /// writer's own endpoint once known-incomplete -- see R5.2) and
    /// releases the writer so its `AVAudioFile` finalizes on disk. This is
    /// now the single, unified place that reads these diagnostics for
    /// BOTH a normal Stop and a terminal-failure end (`finishWithFailure`
    /// deliberately leaves the writer alone for this to handle when a
    /// listener is wired -- see R5.3). Callers (ReflectionSessionStore)
    /// must await this before treating this reflection's saved audio as
    /// complete -- in particular, before handing it to
    /// SpeakerDiarizationEngine. Returns `nil` if no audio was ever being
    /// written for this reflection.
    func finishAudioCapture() async -> (isReliable: Bool, missingAudioIntervals: [AudioInterval], recognitionContinuityGaps: [Date], captureCompleteness: CaptureCompleteness)? {
        guard let writer = audioWriter else { return nil }
        await writer.flush()
        let diagnostics = writer.diagnosticsSnapshot()
        let gaps = recognitionContinuityGaps
        // Read before flush/discard decisions could race it -- doesn't
        // matter here since this function already owns the only reference,
        // but kept adjacent to the writer-dependent reading for clarity.
        let completeness: CaptureCompleteness = hadCaptureOutage
            ? .incomplete(endpointAudioSeconds: writer.endpointAudioSeconds)
            : .complete
        setAudioWriter(nil)
        return (diagnostics.isReliable, diagnostics.missingAudioIntervals, gaps, completeness)
    }
}
