import Foundation

enum SignalSource: String, Codable {
    case mock
    case liveWatch
    case healthKitBackfill
    case transcript
    case userMarker
    case acoustic
    case observationEngine
    case dynamicsEngine
    case correlationEngine
    case derived
}

enum SignalQuality: String, Codable, Hashable {
    case high
    case medium
    case low
    case unavailable
}

enum ReflectionState: String, Codable {
    case idle
    case recording
    case completed
}

enum ObservationCategory: String, Codable, CaseIterable, Hashable {
    case language = "Language"
    case voice = "Voice"
    case cognitive = "Cognitive"
    case behavior = "Behavior"
    case body = "Body"
    case environment = "Environment"
}

enum ObservationEventKind: String, Codable, Hashable {
    case pauseGap
    case breathCue
    case stressLanguage
    case conflictLanguage
    case uncertaintyLanguage
    case reflectiveQuestion
    case regulationAttempt
    case repetition
    case falseStart
    case selfCorrection
    case qualificationLanguage
    case certaintyLanguage
    case emotionSearch

    case outcomeConcern
    case verificationAttempt
    case selfMonitoring
    case relief
    case reorientation
    case planning
    case decisionPoint
}

struct ObservationEvent: Identifiable, Codable {
    var id = UUID()

    /// Internal source of truth. Keep this as Date. Do not convert to String for storage.
    var timestamp: Date

    var kind: ObservationEventKind
    var category: ObservationCategory
    var title: String
    var detail: String
    var source: SignalSource
    var confidence: SignalQuality
    var relatedText: String?
    var tags: [String]

    /// Other plausible readings of the same evidence, so a reflection never
    /// presents a single interpretation as the only possible one. Populated
    /// by whichever engine creates the event; empty means none were authored
    /// for this observation kind yet, not that none exist. See
    /// PROJECT_CONSTRAINTS.md #6 and PROJECT_ARCHITECTURE.md section 7.
    var alternativeExplanations: [String] = []

    /// The actual measured duration, for events where "how long" is
    /// meaningful (currently just `.pauseGap`). Only ever set at the moment
    /// the event is created, from a real measurement -- e.g.
    /// ReflectionSessionStore.recordSilenceGap's acoustic reading.
    ///
    /// This exists because the transcript view used to *infer* a pause's
    /// duration at render time from the gap between two transcript
    /// utterances, which quietly assumed exactly one pause happens between
    /// any two utterances. When SFSpeechRecognizer doesn't split speech into
    /// separate utterances around a pause (which turns out to be common --
    /// its segment timestamps don't reliably reflect real silence), that
    /// assumption breaks: multiple real, distinct pauses can land inside one
    /// utterance-to-utterance window, and inferring duration from window
    /// boundaries then produces nonsense (observed: five real pauses of a
    /// few seconds each, rendered as one "quiet · 53.6s" marker spanning
    /// from the first pause's start to the end of the whole recording).
    /// Storing the real, already-measured duration on the event itself and
    /// rendering that directly avoids re-deriving it from an assumption that
    /// doesn't hold. `nil` for events created before this existed, or for
    /// kinds where duration isn't meaningful.
    var duration: TimeInterval? = nil

    var engineVersion: String
}

enum DynamicsPatternKind: String, Codable, Hashable {
    case emotionalClarification
    case emotionalAmbivalence
    case regulationEffort
    case uncertaintyLoop
    case speechConstructionFriction
    case stressRegulationCluster
    case breathRegulationMarker
    case reflectiveSenseMaking

    case resolutionSeeking
    case activeChecking
    case unresolvedConcern
}

struct DynamicsPattern: Identifiable, Codable {
    var id = UUID()
    var title: String
    var kind: DynamicsPatternKind
    var detail: String
    var confidence: SignalQuality
    var supportingEventIDs: [UUID]
    var tags: [String]
    var engineVersion: String
}

enum ObservationCorrelationKind: String, Codable, Hashable {
    case emotionalClarification
    case reflectiveProcessing
    case possibleSelfRegulation
    case conflictRegulation
    case stressActivation
    case speechFriction
    case uncertaintyWithQualification
    case breathAfterConcern

    case concernVerification
    case verificationRelief
    case selfMonitoringReassurance
}

struct ObservationCorrelation: Identifiable, Codable {
    var id = UUID()
    var timestamp: Date
    var title: String
    var kind: ObservationCorrelationKind
    var summary: String
    var confidence: SignalQuality
    var sourceEventIDs: [UUID]
    var sourceEventTitles: [String]
    var tags: [String]
    var engineVersion: String
}

struct ReflectionSession: Identifiable, Codable {
    var id = UUID()
    var title: String

    /// Internal source of truth. Keep these as Date. Display format belongs in Date extension/UI only.
    var startedAt: Date
    var endedAt: Date?

    var state: ReflectionState
    var transcript: [TranscriptEvent]
    var observations: [Observation]
    var observationEvents: [ObservationEvent]
    var dynamicsPatterns: [DynamicsPattern]
    var observationCorrelations: [ObservationCorrelation]
    var observationEngineVersion: String
    var dynamicsEngineVersion: String
    var correlationEngineVersion: String
    var biometrics: BiometricWindow
    var voice: VoiceSignals

    /// Set when the person recording confirmed, before this reflection
    /// started, that anyone else being recorded knows about it and agreed.
    /// Part of the same evidence trail as everything else on this session --
    /// see PROJECT_CONSTRAINTS.md and the consent-law research behind this.
    var consentAcknowledgedAt: Date? = nil

    /// Filename (not a full path) of this reflection's raw audio recording
    /// under Application Support/Observatory/Audio/, if one was captured.
    /// Kept separate from the JSON session store so a large audio file isn't
    /// duplicated into every session-list read/write. nil for reflections
    /// recorded before this existed, or if writing the file failed.
    var audioFileName: String? = nil

    /// Set once SpeakerDiarizationEngine has actually run diarization against
    /// this session's audio and gotten a real result back -- regardless of
    /// whether it found more than one distinct speaker. This means "checked,"
    /// not "transcript got relabeled": a solo reflection is supposed to come
    /// back with this set but the transcript untouched (still all `.user`).
    /// nil means diarization hasn't run yet, or couldn't be attempted, or
    /// failed (no audio file, missing audio, or a thrown error) -- see
    /// SpeakerDiarizationEngine.label's doc comment.
    var diarizationEngineVersion: String? = nil

    /// Whether the background audio writer (SpeechRecognitionManager.AudioFileWriter)
    /// finished this reflection's `.caf` file without any lost/failed
    /// writes. `nil` means unknown -- either this reflection predates the
    /// writer reporting this at all, or no audio was ever being written.
    /// `false` means SpeakerDiarizationEngine should not be trusted to run
    /// against this file; see `missingAudioIntervals` for where it's short.
    var audioRecordingReliable: Bool? = nil

    /// Spans of the saved audio file known to be missing or unreliable.
    /// Empty (not nil) when recording finished cleanly; nil only for
    /// reflections that predate this field.
    var missingAudioIntervals: [AudioInterval]? = nil

    /// Wall-clock moments a recognition-continuity gap was recovered from
    /// during this session -- i.e. the recognition task errored, went
    /// silent, or was interrupted while the audio writer confirms capture
    /// itself continued. Deliberately NOT an `AudioInterval`: there is no
    /// missing audio span to report (D-05's file timeline has no "hole"
    /// when every buffer still wrote successfully), only the moments
    /// recovery was attempted -- no duration is claimed. Empty (not nil)
    /// when no such gap occurred; nil only for reflections that predate
    /// this field. See `missingAudioIntervals` for the separate,
    /// unrelated audio-loss signal this does not overload.
    var recognitionContinuityGaps: [Date]? = nil

    /// Whole-session capture-completeness evidence, established from
    /// LIFECYCLE signals (capture ceased via an interruption's `.began`
    /// teardown, recovery did not restore it before the session ended) --
    /// NEVER from a session-duration/file-duration mismatch alone, which
    /// is corroboration/detection only, never the sole basis. `nil` means
    /// unknown -- predates this field, or was never determined -- and
    /// must NEVER be treated as `.complete` by any consumer. A later
    /// successful recovery does not erase an earlier outage: this
    /// describes WHOLE-SESSION completeness, not "is capture healthy
    /// right now." Separate from, and not a replacement for,
    /// `audioRecordingReliable` (write-failure integrity) or
    /// `recognitionContinuityGaps` (recognition-only gaps while capture
    /// continued) -- see `SpeechRecognitionManager.hadCaptureOutage`'s doc
    /// comment for the establishment rule.
    var captureCompleteness: CaptureCompleteness? = nil

    /// Every raw segment SpeakerKit returned for this session, independent
    /// of filtering -- see `RawDiarizationSegment`'s doc comment. nil if
    /// diarization hasn't run (same meaning as `diarizationEngineVersion == nil`).
    var diarizationRawSegments: [RawDiarizationSegment]? = nil

    /// Per-raw-speaker-ID record of whether it cleared the distinct-speaker
    /// floors, and the actual duration/proportion numbers behind that call.
    var diarizationFilteringDecisions: [DiarizationFilteringDecision]? = nil

    var durationSeconds: Int {
        let end = endedAt ?? Date()
        return max(0, Int(end.timeIntervalSince(startedAt)))
    }

    var durationText: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return "\(minutes)m \(seconds)s"
    }

    var timeRangeText: String {
        if let endedAt {
            return "\(startedAt.displayTime) – \(endedAt.displayTime)"
        } else {
            return "\(startedAt.displayTime) – now"
        }
    }
}

struct TranscriptEvent: Identifiable, Codable {
    var id = UUID()

    /// Internal source of truth. Keep this as Date. Do not convert to String for storage.
    var timestamp: Date

    var speaker: Speaker
    var text: String
    var source: SignalSource

    /// Per-word timing within this utterance, from
    /// SpeechRecognitionManager.Utterance.words. Lets the transcript view
    /// place a pause marker between the specific two words it actually fell
    /// between, instead of only between whole utterances -- which used to
    /// mean every pause in a long stretch of un-split speech (common; see
    /// SilenceTracker's doc comment on SFSpeechRecognizer's segment timing)
    /// rendered clustered at the end of that entire block rather than where
    /// it actually happened. Empty for text with no word-level timing
    /// available (older saved reflections, or non-transcript entries like
    /// the "no speech captured" marker) -- the transcript view falls back to
    /// showing pauses after the whole utterance in that case.
    var words: [WordTiming] = []
}

/// One raw SpeakerKit segment, kept for audit independent of whether it
/// survived SpeakerDiarizationEngine's duration/proportion filtering --
/// counts alone ("Speaker A: 27 entries") can't explain *why* a voice was
/// missed or a boundary misplaced, the actual segments can.
struct RawDiarizationSegment: Codable, Hashable {
    var startTime: TimeInterval
    var endTime: TimeInterval

    /// Human-readable form of SpeakerKit's `SpeakerInfo` for this segment --
    /// a raw speaker ID, "multiple(...)" for model-reported overlap, or
    /// "noMatch".
    var speakerDescription: String
}

/// Whether one raw speaker ID's segments cleared SpeakerDiarizationEngine's
/// `minimumSpeakerDuration`/`minimumSpeakerProportion` floors to count as a
/// distinct person, and the actual numbers behind that decision.
struct DiarizationFilteringDecision: Codable, Hashable {
    var speakerDescription: String
    var totalDuration: TimeInterval
    var proportionOfSubstantialTotal: Double
    var passed: Bool
}

/// A span of audio, in seconds relative to the start of a saved `.caf`
/// file, that's known to be missing or unreliable -- e.g. the background
/// audio writer dropped or failed to write a buffer for that span. Used to
/// honestly gate diarization/acoustic analysis rather than silently running
/// them against a file known to be incomplete.
struct AudioInterval: Codable, Hashable {
    var start: TimeInterval
    var end: TimeInterval
}

/// Whole-session capture-completeness status -- see
/// `ReflectionSession.captureCompleteness`'s doc comment for the full
/// establishment rule and what this does/doesn't claim.
enum CaptureCompleteness: Codable, Equatable {
    case complete
    /// `endpointAudioSeconds`, when known, is the saved file's own
    /// audio-file-relative ENDPOINT (its last successfully-written
    /// frame) -- it marks ONLY where the saved audio ends. It does NOT
    /// mean "known-good through this point" (nothing here vouches for
    /// every second before it being continuous), does NOT establish WHEN
    /// capture actually stopped, and does NOT measure how much wall-clock
    /// time is missing. `nil` here means the endpoint itself isn't known,
    /// not that capture was complete.
    case incomplete(endpointAudioSeconds: TimeInterval?)
}

/// One recognized word (or short phrase segment) with its own real timing,
/// straight from SFTranscriptionSegment via SpeechRecognitionManager.
struct WordTiming: Codable, Hashable {
    var text: String
    var start: Date
    var end: Date

    /// Position within the saved `.caf` audio file, in seconds -- the
    /// coordinate system SpeakerDiarizationEngine's RTTM-derived segments
    /// already use. `nil` means "not available," never "zero": a reflection
    /// saved before this existed has no way to know its words' real audio
    /// offsets, and treating that as 0 would wrongly place every one of its
    /// words at the very start of the file. SpeakerDiarizationEngine's
    /// word-level matcher skips words with a `nil` offset entirely rather
    /// than guessing.
    var audioStart: TimeInterval?
    var audioEnd: TimeInterval?

    init(text: String, start: Date, end: Date, audioStart: TimeInterval? = nil, audioEnd: TimeInterval? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.audioStart = audioStart
        self.audioEnd = audioEnd
    }

    private enum CodingKeys: String, CodingKey {
        case text, start, end, audioStart, audioEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decode(String.self, forKey: .text)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decode(Date.self, forKey: .end)
        // Both absent in every reflection saved before this field existed --
        // decodeIfPresent already yields nil in that case, but spelled out
        // explicitly since that nil is load-bearing, not an oversight.
        audioStart = try container.decodeIfPresent(TimeInterval.self, forKey: .audioStart)
        audioEnd = try container.decodeIfPresent(TimeInterval.self, forKey: .audioEnd)
    }
}

/// Not a fixed two-party enum -- `.other` carries a label (e.g. "Speaker 2",
/// "Speaker 3") so a reflection can capture more than one other person, once
/// SpeakerDiarizationEngine has told the voices apart. `.user` still
/// specifically means "you, the device owner" -- diarization only tells
/// voices apart, it doesn't know which one is the phone's owner, so a
/// transcript stays entirely `.user` until diarization actually finds more
/// than one voice in the recording.
enum Speaker: Codable, Hashable {
    case user
    case other(String)

    /// Diarization reported this span as more than one speaker's voice at
    /// once (SpeakerKit's `SpeakerInfo.multiple`) -- genuinely simultaneous
    /// speech, not a word that merely spans two adjacent segments' boundary.
    /// Deliberately distinct from `.unknown`: this is positive evidence of
    /// overlap, not an absence of evidence.
    case overlap

    /// Diarization reported no speaker match for this span at all
    /// (SpeakerKit's `SpeakerInfo.noMatch`), or the word's audio offset
    /// wasn't available to attempt a match. Distinct from defaulting to
    /// `.user` -- once multiple voices are already known to exist in a
    /// session, silently asserting ownership of unmatched speech would be a
    /// guess presented as a fact.
    case unknown

    /// Kept as a computed property (rather than RawRepresentable) so every
    /// existing `.rawValue` call site across the app keeps compiling exactly
    /// as before.
    var rawValue: String {
        switch self {
        case .user: return "You"
        case .other(let label): return label
        case .overlap: return "Overlapping speech"
        case .unknown: return "Unknown speaker"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, label
    }

    init(from decoder: Decoder) throws {
        // Backward compatible with reflections saved before this changed --
        // Speaker used to be a plain String-backed enum ("You"/"They").
        if let single = try? decoder.singleValueContainer(),
           let legacy = try? single.decode(String.self) {
            self = (legacy == "You") ? .user : .other(legacy)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "user":
            self = .user
        case "overlap":
            self = .overlap
        case "unknown":
            self = .unknown
        default:
            self = .other(try container.decode(String.self, forKey: .label))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .kind)
        case .overlap:
            try container.encode("overlap", forKey: .kind)
        case .unknown:
            try container.encode("unknown", forKey: .kind)
        case .other(let label):
            try container.encode("other", forKey: .kind)
            try container.encode(label, forKey: .label)
        }
    }
}

struct BiometricSample: Identifiable, Codable {
    var id = UUID()

    /// Internal source of truth. Keep this as Date. Do not convert to String for storage.
    var timestamp: Date

    var heartRate: Double?
    var respiration: Double?
    var hrv: Double?
    var source: SignalSource
    var quality: SignalQuality
}

struct BiometricWindow: Codable {
    var queryStart: Date
    var queryEnd: Date
    var samples: [BiometricSample]
    var quality: SignalQuality

    var latestHeartRate: Double {
        samples.compactMap { $0.heartRate }.last ?? 0
    }

    var averageHeartRate: Double {
        let values = samples.compactMap { $0.heartRate }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    var averageRespiration: Double {
        let values = samples.compactMap { $0.respiration }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    var averageHRV: Double {
        let values = samples.compactMap { $0.hrv }
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}

struct Observation: Identifiable, Codable {
    var id = UUID()
    var title: String
    var detail: String
    var confidence: SignalQuality
}

struct VoiceSignals: Codable {
    var wordsPerMinute: Int
    var pauseCount: Int
    var hesitationMarkers: Int
    var durationSeconds: Int
}

struct CorrelationScore: Identifiable {
    var id = UUID()
    var label: String
    var value: Double
    var signalColorName: String
}

struct ConversationDynamics {
    var userSpeakingPercent: Double
    var otherSpeakingPercent: Double
    var turnsTaken: Int
    var averageTurnLength: Double
    var interruptions: Int
    var dominanceIndex: Double
}


