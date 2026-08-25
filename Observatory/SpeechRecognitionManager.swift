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
    /// `start`/`end` used to be derived from SFSpeechRecognizer's own
    /// `SFTranscriptionSegment.timestamp`/`.duration`. That turned out to be
    /// a mistake this codebase already learned from once: those segment
    /// timestamps don't reliably track real elapsed time -- deliberate 10s+
    /// pauses were confirmed (empirically, via the "Pause gaps: None
    /// detected" bug) not to reliably show up as timestamp gaps at all,
    /// which is exactly why SilenceTracker exists as an independent,
    /// acoustic (RMS-based, real `Date()`) pause detector instead of trusting
    /// this recognizer-internal clock.
    ///
    /// That fix didn't go far enough, though: once acoustic pauses needed to
    /// be placed *inline*, between the specific two words they fell between,
    /// this struct's `start`/`end` were still on the old recognizer-internal
    /// clock while `SilenceTracker`'s pause timestamps are on the real wall
    /// clock. Comparing a real pause `Date` against a `start`/`end` boundary
    /// computed from segment.timestamp -- a clock that doesn't advance
    /// through real silence the way real time does -- meant the pause's
    /// `Date` almost never actually fell inside any word's window, so inline
    /// markers silently stopped appearing.
    ///
    /// `start`/`end` are now stamped from the real `Date()` of the callback
    /// that first reported each word (see `SpeechRecognitionManager.utterances`),
    /// same clock as `SilenceTracker`, so gap placement actually lines up.
    struct Utterance {
        var text: String
        var start: Date
        var end: Date

        /// Per-word timing that made up this utterance, in order. Preserved
        /// (rather than discarded once merged into `text`) so the transcript
        /// view can place a pause marker between the exact two words it fell
        /// between -- see TranscriptEvent.words' doc comment.
        var words: [WordTiming] = []
    }

    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStoppingIntentionally = false

    /// This reflection's raw audio, written alongside the live speech-to-text
    /// so a later step (speaker diarization) has real audio to work from --
    /// SFSpeechRecognizer only ever gives us text back, never the audio.
    private var audioFile: AVAudioFile?
    private var pendingAudioFileURL: URL?

    /// Thread-safe target for the audio tap's buffer callback, which fires on
    /// a real-time audio thread outside this class's `@MainActor` isolation.
    /// The tap itself is installed exactly once (in the first call to
    /// `beginListeningSegment()`) and is never torn down at a routine segment
    /// boundary -- only this box's contents change, atomically under a lock,
    /// when a new segment's request replaces the previous one. That's what
    /// keeps the mic capturing continuously across Apple's ~1 minute segment
    /// limit instead of stopping and restarting the engine, which previously
    /// left a real gap (stop → remove tap → reconfigure session → reinstall
    /// tap → start) during which speech at the seam was silently dropped --
    /// the leading suspect for transcript quality degrading right around the
    /// one-minute mark.
    private final class CurrentRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var audioFile: AVAudioFile?

        /// Swaps in the new request/file and returns whatever was previously
        /// set, still under the same lock the tap callback uses -- so by the
        /// time this returns, no in-flight tap callback can still be holding
        /// a reference to the old request. That guarantees it's safe for the
        /// caller to call `endAudio()` on the returned previous request right
        /// after this returns, without racing a concurrent `append(_:)` on
        /// the audio thread (which would throw).
        @discardableResult
        func set(request: SFSpeechAudioBufferRecognitionRequest?, audioFile: AVAudioFile?) -> SFSpeechAudioBufferRecognitionRequest? {
            lock.lock()
            defer { lock.unlock() }
            let previous = self.request
            self.request = request
            self.audioFile = audioFile
            return previous
        }

        /// Called from the audio tap on a real-time thread for every buffer.
        /// Appending and the raw-audio file write both happen under the same
        /// lock `set(request:audioFile:)` uses, so a segment swap can never
        /// interleave with an in-progress append.
        func append(_ buffer: AVAudioPCMBuffer) {
            lock.lock()
            defer { lock.unlock() }
            request?.append(buffer)
            if let audioFile {
                try? audioFile.write(from: buffer)
            }
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            request = nil
            audioFile = nil
        }
    }

    /// Detects real silence gaps by measuring RMS amplitude on every audio
    /// buffer from the tap, independent of speech recognition. Called from
    /// the same real-time audio thread as `CurrentRequestBox.append`, so it
    /// has its own lock rather than sharing that one -- there's no ordering
    /// requirement between the two, and keeping them separate avoids
    /// widening `CurrentRequestBox`'s lock scope (and its append-after-
    /// endAudio safety guarantee) to cover unrelated work.
    private final class SilenceTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var isSilent = false
        private var silenceStart: Date?
        private var onGap: (@Sendable (Date, TimeInterval) -> Void)?

        /// Wall-clock instant a louder-than-threshold buffer first showed up
        /// during an ongoing silence, or nil if the most recent buffer was
        /// itself quiet. Used to require *sustained* louder audio (see
        /// `resumeDebounce`) before treating a silence as over.
        private var nonSilentStreakStart: Date?

        /// RMS amplitude (0...1 scale, Float32 PCM) below this is treated as
        /// silence. This is a heuristic, not a calibrated measurement --
        /// tuned for a phone at normal talking distance in a quiet-to-
        /// moderate room. Erring toward "misses a real but very quiet pause"
        /// is preferable to erring toward "flags normal quiet speech as
        /// silence."
        private let silenceRMSThreshold: Float = 0.02

        /// A single buffer is ~20-25ms at typical sample rates -- far
        /// shorter than a real word. Without this, one buffer of incidental
        /// noise during a real multi-second pause (a breath, the phone
        /// shifting, a background click) ends the silence measurement right
        /// there, fragmenting one real pause into several shorter ones and
        /// silently losing whatever didn't individually clear
        /// `minimumGapDuration`. In testing this was the actual cause of a
        /// deliberate ~10s pause showing up as two separate 1.6s pauses
        /// instead of one accurate ~10s one. Requiring louder audio to be
        /// sustained this long before ending a silence makes a brief blip
        /// not count, while real resumed speech (which lasts far longer than
        /// this) still ends the silence promptly.
        private let resumeDebounce: TimeInterval = 0.3

        /// Matches ReflectionSessionStore.minimumObservablePause -- gaps
        /// shorter than this aren't recorded as evidence.
        private let minimumGapDuration: TimeInterval = 1.5

        func setCallback(_ callback: @escaping @Sendable (Date, TimeInterval) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            onGap = callback
        }

        func reset() {
            lock.lock()
            defer { lock.unlock() }
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
                // Quiet buffer -- cancel any not-yet-confirmed "speech
                // resumed" streak (it was just a blip) and, if this is the
                // start of a new silence, mark it.
                nonSilentStreakStart = nil
                if !isSilent {
                    isSilent = true
                    silenceStart = date
                }
            } else if isSilent {
                // A louder buffer during an ongoing silence. Don't end the
                // silence yet -- only once louder audio has been sustained
                // for `resumeDebounce` is this treated as speech actually
                // resuming, so a single brief noise blip can't fragment a
                // real pause.
                if nonSilentStreakStart == nil {
                    nonSilentStreakStart = date
                }

                if let streakStart = nonSilentStreakStart,
                   date.timeIntervalSince(streakStart) >= resumeDebounce {
                    // Confirmed: speech actually resumed. The silence
                    // genuinely ended when the louder audio first started
                    // (`streakStart`), not now -- `date` also includes the
                    // debounce window itself, which is real audio, not
                    // silence.
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

    private let currentRequestBox = CurrentRequestBox()

    /// Tracks real acoustic silence directly from the raw microphone
    /// buffers, entirely independent of SFSpeechRecognizer's own segment
    /// timestamps.
    ///
    /// Why this exists: pause detection originally relied on gaps between
    /// SFTranscriptionSegment timestamps (see the old `Utterance`-gap
    /// approach still used below for utterance *splitting*). In testing,
    /// deliberate multi-second silences produced no usable timestamp gap --
    /// "Pause gaps: None detected" on a reflection that had several 10s
    /// pauses. The likely explanation is that the on-device recognizer's
    /// segment timestamps track recognized-speech time, not raw wall-clock
    /// buffer time, so silence between words doesn't reliably show up as a
    /// timestamp jump the way true acoustic silence would. Measuring RMS
    /// directly on the same buffers already flowing through the audio tap
    /// sidesteps that entirely -- it doesn't depend on anything
    /// SFSpeechRecognizer decides to report.
    private let silenceTracker = SilenceTracker()

    private var currentOnSilenceGap: (@MainActor (Date, TimeInterval) -> Void)?

    /// Utterances finalized from earlier listening segments in this
    /// recording. Apple's speech engine ends a "segment" (an
    /// SFSpeechRecognitionTask) on its own after roughly a minute of
    /// continuous speech, and an interruption (call, Siri, another app) also
    /// forcibly ends a segment. Rather than treating either as the end of
    /// the reflection, we seal whatever utterances that segment produced in
    /// here and quietly start a new segment, so the transcript reads as one
    /// continuous recording to the user.
    ///
    /// Known limitation: while a segment is paused for an interruption, the
    /// raw .caf audio file also isn't being written to (the mic tap is torn
    /// down), so the file itself has no gap for that pause -- but these
    /// utterance timestamps are wall-clock and DO include it. For a
    /// recording with no interruptions (the common case) this doesn't
    /// matter; for one that was interrupted, diarization's audio-relative
    /// segment offsets and these wall-clock utterance offsets can drift
    /// apart by roughly the interruption's length. Not fixed here -- it's a
    /// separate, second-order issue from the one this rewrite addresses.
    private var sealedUtterances: [Utterance] = []

    /// Utterances recognized so far in the *current* segment, recomputed in
    /// full from `SFSpeechRecognitionResult.bestTranscription.segments`
    /// every time a new result arrives (that array only ever grows within a
    /// segment, so this is cheap and always consistent).
    private var currentSegmentUtterances: [Utterance] = []

    /// Non-nil once the current segment's audio has actually started (right
    /// after `audioEngine.start()` succeeds, or immediately after a
    /// mid-stream segment swap that doesn't restart the engine). Used only
    /// as a "has recognition actually begun" gate in `handleRecognition` --
    /// word/utterance timestamps no longer derive from this (see
    /// `Utterance`'s doc comment for why).
    private var segmentAudioStartDate: Date?

    /// Real wall-clock time each already-recognized word was first reported
    /// by SFSpeechRecognizer, indexed by its position among all non-empty
    /// words seen so far in the current segment. `utterances(from:...)`
    /// consults this on every call (which re-delivers the *entire*
    /// transcript-so-far, not just what's new) so an already-stamped word
    /// keeps its original real timestamp instead of being re-stamped with a
    /// later "now" on every subsequent partial-result callback.
    private var lastRealWords: [WordTiming] = []

    /// Treat a gap this long or longer between two recognized utterances as
    /// a separate utterance rather than a continuation of the same one.
    private static let utteranceGapThreshold: TimeInterval = 0.7

    private var currentOnTranscript: (@MainActor ([Utterance]) -> Void)?
    private var wasRecordingBeforeInterruption = false
    private var interruptionObserver: NSObjectProtocol?

    init() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { notification in
            // Pulled out here, before crossing into the Task below, since
            // Notification itself isn't Sendable -- only these two plain
            // values (an enum and a UInt) need to cross that boundary.
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

    func start(
        audioFileName: String,
        onTranscript: @escaping @MainActor ([Utterance]) -> Void,
        onSilenceGap: (@MainActor (Date, TimeInterval) -> Void)? = nil
    ) {
        currentOnTranscript = onTranscript
        currentOnSilenceGap = onSilenceGap
        sealedUtterances = []
        currentSegmentUtterances = []
        segmentAudioStartDate = nil
        liveTranscript = ""
        isStoppingIntentionally = false
        wasRecordingBeforeInterruption = false
        audioFile = nil
        pendingAudioFileURL = Self.audioFileURL(named: audioFileName)
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
    /// continuing past the ~1 minute limit -- this does NOT stop it or touch
    /// its tap. It only swaps in a fresh `SFSpeechAudioBufferRecognitionRequest`
    /// (via `currentRequestBox`) and starts a new recognition task against
    /// it, so the mic never stops capturing and no audio at the segment seam
    /// is lost. The engine and tap are only started fresh here when they
    /// aren't already running -- the very first segment, or resuming after an
    /// interruption tore them down.
    private func beginListeningSegment() {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable."
            return
        }

        currentSegmentUtterances = []
        segmentAudioStartDate = nil

        // A new recognition request starts SFSpeechRecognizer's own segment
        // array back at empty, so word-index-based lookups into the
        // previous segment's real timestamps would line up with the wrong
        // words if this weren't cleared too.
        lastRealWords = []

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)

            if audioFile == nil, let pendingAudioFileURL {
                do {
                    try FileManager.default.createDirectory(
                        at: pendingAudioFileURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    audioFile = try AVAudioFile(forWriting: pendingAudioFileURL, settings: recordingFormat.settings)
                } catch {
                    // Live transcription still works without this -- diarization
                    // just won't have audio to work from for this reflection.
                    print("Reflection audio recording failed to open: \(error.localizedDescription)")
                    audioFile = nil
                }
            }

            // Atomically swap this segment's request (and the unchanging
            // audio file reference) into the box, then end the *previous*
            // request only after the swap completes. Because `set` and
            // `append` share one lock, this guarantees no tap callback can
            // still be appending to the old request by the time we call
            // `endAudio()` on it below -- avoiding the "append after
            // endAudio" exception that a naive swap could hit.
            let previousRequest = currentRequestBox.set(request: request, audioFile: audioFile)
            recognitionRequest = request

            if audioEngine.isRunning {
                // Routine continuation past the ~1 minute segment limit --
                // the engine and tap stay exactly as they are; only the
                // request/task underneath changes. No stop/start gap.
                previousRequest?.endAudio()
            } else {
                // First segment, or resuming after an interruption tore the
                // engine down -- (re)install the tap and start fresh.
                previousRequest?.endAudio()
                inputNode.removeTap(onBus: 0)
                inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [currentRequestBox, silenceTracker] buffer, _ in
                    currentRequestBox.append(buffer)
                    silenceTracker.process(buffer, at: Date())
                }

                audioEngine.prepare()
                try audioEngine.start()
            }

            segmentAudioStartDate = Date()

            isRecording = true
            statusMessage = "Listening."

            recognitionTask = speechRecognizer.recognitionTask(with: request) { result, error in
                Task { @MainActor [weak self] in
                    self?.handleRecognition(result: result, error: error)
                }
            }
        } catch {
            statusMessage = "Speech start failed: \(error.localizedDescription)"
            stop()
        }
    }

    /// Groups a result's word/phrase-level segments into utterances,
    /// splitting wherever the gap since the previous word's real timestamp
    /// is at least `utteranceGapThreshold`. `result.bestTranscription.segments`
    /// only ever grows within one recognition request, and each already-seen
    /// word keeps the real timestamp it was first stamped with (via
    /// `lastRealWords`), so re-running this on every partial-result callback
    /// reproduces the same grouping for previously-seen words and only adds
    /// new ones -- it's not idempotent in the sense of being independent of
    /// *when* it's called (it depends on real elapsed time between calls),
    /// but it is stable in the sense that already-placed words and pause
    /// windows don't get rewritten underneath the UI.
    ///
    /// Text for each segment comes from `formattedString` (via
    /// `segment.substringRange`), not `segment.substring` -- the latter is
    /// SFSpeechRecognizer's raw per-word text with none of the
    /// capitalization, punctuation, and smart-formatting Apple normally
    /// applies to `bestTranscription.formattedString`. Reconstructing the
    /// transcript from raw substrings (an earlier version of this function
    /// did this) reads as noticeably lower quality even when every word was
    /// recognized correctly. `substringRange` is the documented way to map a
    /// segment back onto its formatted text.
    private func utterances(from segments: [SFTranscriptionSegment], formattedString: String, now: Date) -> [Utterance] {
        var result: [Utterance] = []
        var flatWords: [WordTiming] = []
        let formatted = formattedString as NSString

        for segment in segments {
            let range = segment.substringRange
            let rawText: String
            if range.location != NSNotFound, range.location + range.length <= formatted.length {
                rawText = formatted.substring(with: range)
            } else {
                // Fallback for the rare case a range doesn't line up with
                // the current formattedString -- still correct, just not
                // formatted.
                rawText = segment.substring
            }
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            // Position among non-empty words seen so far this call -- lines
            // up with how `lastRealWords` was built on the previous call, so
            // a word already stamped keeps its real timestamp instead of
            // being overwritten with a later "now" every time this whole
            // (re-delivered) transcript is recomputed.
            let wordIndex = flatWords.count
            let word: WordTiming
            if wordIndex < lastRealWords.count, lastRealWords[wordIndex].text == text {
                word = lastRealWords[wordIndex]
            } else {
                // Newly reported this call -- `now` (this callback's real
                // Date) is the only honest anchor available: SFSpeechRecognizer
                // doesn't tell us when the word was actually *spoken*, only
                // when it finished being *recognized*, which is close enough
                // for placing pause markers and lines up with SilenceTracker's
                // clock, unlike segment.timestamp (see Utterance's doc comment).
                word = WordTiming(text: text, start: now, end: now)
            }
            flatWords.append(word)

            if let lastIndex = result.indices.last,
               word.start.timeIntervalSince(result[lastIndex].end) < Self.utteranceGapThreshold {
                result[lastIndex].text += " " + text
                result[lastIndex].end = word.end
                result[lastIndex].words.append(word)
            } else {
                result.append(Utterance(text: text, start: word.start, end: word.end, words: [word]))
            }
        }

        lastRealWords = flatWords
        return result
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result, segmentAudioStartDate != nil {
            let segments = result.bestTranscription.segments
            if !segments.isEmpty {
                currentSegmentUtterances = utterances(
                    from: segments,
                    formattedString: result.bestTranscription.formattedString,
                    now: Date()
                )
            }

            let combined = sealedUtterances + currentSegmentUtterances
            if !combined.isEmpty {
                liveTranscript = combined.map(\.text).joined(separator: " ")
                statusMessage = result.isFinal ? "Final transcript received." : "Listening."
                currentOnTranscript?(combined)
            }
        }

        guard let error else { return }

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
            // just took the microphone). This segment ending is expected —
            // handleInterruption(type:optionsValue:) will restart listening once the
            // interruption ends, so don't treat this as a failure.
            return
        }

        if isRecording {
            // Not an interruption — most likely Apple's speech engine ending
            // this segment on its own after continuous speech. Seal what we
            // have and quietly keep going instead of stopping the reflection.
            sealCurrentSegment()
            statusMessage = "Listening (continuing)."
            beginListeningSegment()
        } else {
            statusMessage = "Speech error: \(error.localizedDescription)"
            stop()
        }
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
            sealCurrentSegment()

            if audioEngine.isRunning {
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            recognitionRequest?.endAudio()
            currentRequestBox.clear()
            recognitionRequest = nil
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

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest?.endAudio()
        currentRequestBox.clear()

        recognitionRequest = nil
        recognitionTask = nil
        isRecording = false
        silenceTracker.reset()
        currentOnSilenceGap = nil

        // AVAudioFile has no explicit close() -- releasing it finalizes the
        // file on disk.
        audioFile = nil
        pendingAudioFileURL = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Safe to ignore for prototype.
        }
    }
}
