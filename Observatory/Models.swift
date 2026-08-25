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

/// One recognized word (or short phrase segment) with its own real timing,
/// straight from SFTranscriptionSegment via SpeechRecognitionManager.
struct WordTiming: Codable, Hashable {
    var text: String
    var start: Date
    var end: Date
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

    /// Kept as a computed property (rather than RawRepresentable) so every
    /// existing `.rawValue` call site across the app keeps compiling exactly
    /// as before.
    var rawValue: String {
        switch self {
        case .user: return "You"
        case .other(let label): return label
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
        if kind == "user" {
            self = .user
        } else {
            self = .other(try container.decode(String.self, forKey: .label))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .user:
            try container.encode("user", forKey: .kind)
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


