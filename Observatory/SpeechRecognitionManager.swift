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

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStoppingIntentionally = false

    private var pendingAudioFileURL: URL?
    private var audioWriter: AudioFileWriter?

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

    private final class AudioFileWriter: @unchecked Sendable {
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

        init(url: URL, format: AVAudioFormat) throws {
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
    private var wasRecordingBeforeInterruption = false
    private var interruptionObserver: NSObjectProtocol?

    /// Timestamps of recent auto-restarts triggered by a recognition error
    /// while still recording (not a routine ~1-minute rollover, not a
    /// stop, not an interruption). If these start happening faster than a
    /// person could possibly be causing on purpose, something is
    /// persistently failing -- better to stop and say so than spin forever.
    private var recentAutoRestarts: [Date] = []

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
        onSilenceGap: (@MainActor (Date, TimeInterval) -> Void)? = nil
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
        sealedUtterances = []
        currentSegmentUtterances = []
        segmentAudioStartDate = nil
        liveTranscript = ""
        isStoppingIntentionally = false
        wasRecordingBeforeInterruption = false
        audioWriter = nil
        pendingAudioFileURL = Self.audioFileURL(named: audioFileName)
        recentAutoRestarts = []
        silenceTracker.reset()

        beginListeningSegment()
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
    private func beginListeningSegment() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable."
            return
        }

        // SECURITY.md promises reflection content never leaves the device.
        // `request.requiresOnDeviceRecognition` below is what actually
        // enforces that -- without it, SFSpeechRecognizer may silently use
        // Apple's server-based recognition instead. If the device/locale
        // combination can't do on-device recognition at all, stop and say
        // so rather than silently falling back to a network request that
        // would make the privacy claim false.
        guard speechRecognizer.supportsOnDeviceRecognition else {
            statusMessage = "On-device speech recognition isn't available on this device -- stopping rather than send audio off-device."
            stop()
            return
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
                    audioWriter = try AudioFileWriter(url: pendingAudioFileURL, format: recordingFormat)
                } catch {
                    // Live transcription still works without this --
                    // diarization just won't have audio to work from.
                    print("Reflection audio recording failed to open: \(error.localizedDescription)")
                    audioWriter = nil
                }
            }

            let previousRequest = currentRequestBox.set(request: request)
            previousRequest?.endAudio()

            if isColdStart {
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [currentRequestBox, silenceTracker, generationBox, audioWriter] buffer, _ in
                    let capturedAt = Date()
                    currentRequestBox.append(buffer)
                    silenceTracker.process(buffer, at: capturedAt)
                    audioWriter?.enqueue(buffer, generation: generationBox.get(), capturedAt: capturedAt)
                }

                audioEngine.prepare()
                try audioEngine.start()
            }

            segmentAudioStartDate = Date()
            isRecording = true
            statusMessage = "Listening."

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    self?.handleRecognition(result: result, error: error, generation: generation)
                }
            }
        } catch {
            statusMessage = "Speech start failed: \(error.localizedDescription)"
            stop()
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

        if wasRecordingBeforeInterruption {
            // The system is mid-interruption (a call, Siri, or another app
            // just took the microphone). handleInterruption(type:optionsValue:)
            // already sealed this segment and will restart listening once
            // the interruption ends -- don't treat this as a failure.
            return
        }

        guard isRecording else {
            statusMessage = "Speech error: \(error?.localizedDescription ?? "unknown")"
            stop()
            return
        }

        guard !isRestartLoopDetected() else {
            statusMessage = "Speech recognition kept failing -- stopped."
            stop()
            return
        }

        // Not an interruption, not a stop, and not a loop -- most likely
        // Apple's speech engine ending this segment on its own after
        // continuous speech, or a transient recognition error. Seal what we
        // have and quietly keep going instead of stopping the reflection.
        sealCurrentSegment()
        statusMessage = "Listening (continuing)."
        beginListeningSegment()
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

    private func handleInterruption(type: AVAudioSession.InterruptionType, optionsValue: UInt?) {
        switch type {
        case .began:
            guard isRecording else { return }
            wasRecordingBeforeInterruption = true
            currentGenerationState = .sealed
            sealCurrentSegment()

            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            currentRequestBox.endAndClear()
            recognitionTask = nil
            isRecording = false
            statusMessage = "Paused — interrupted (call, Siri, or another app)."

            // The mic isn't capturing during an interruption, so whatever
            // silence state was mid-measurement is meaningless -- reset
            // rather than let it produce a bogus gap (or a bogus *missing*
            // gap) once the tap resumes.
            silenceTracker.reset()

        case .ended:
            guard wasRecordingBeforeInterruption else { return }
            wasRecordingBeforeInterruption = false

            var shouldResume = false
            if let optionsValue {
                let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                shouldResume = options.contains(.shouldResume)
            }

            if shouldResume {
                statusMessage = "Resuming after interruption..."
                beginListeningSegment()
            } else {
                statusMessage = "Paused by an interruption. Tap Start to resume."
            }

        @unknown default:
            break
        }
    }

    func stop() {
        isStoppingIntentionally = true
        wasRecordingBeforeInterruption = false
        currentGenerationState = .sealed

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        currentRequestBox.endAndClear()
        recognitionTask = nil
        isRecording = false
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
    /// writer, then returns a diagnostics snapshot and releases the writer
    /// so its `AVAudioFile` finalizes on disk. Callers (ReflectionSessionStore)
    /// must await this before treating this reflection's saved audio as
    /// complete -- in particular, before handing it to
    /// SpeakerDiarizationEngine. Returns `nil` if no audio was ever being
    /// written for this reflection.
    func finishAudioCapture() async -> (isReliable: Bool, missingAudioIntervals: [AudioInterval])? {
        guard let writer = audioWriter else { return nil }
        await writer.flush()
        let diagnostics = writer.diagnosticsSnapshot()
        audioWriter = nil
        return diagnostics
    }
}
