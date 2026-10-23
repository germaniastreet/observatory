import Foundation
import SpeakerKit
import WhisperKit // AudioProcessor.loadAudioAsFloatArray lives here, not in SpeakerKit itself

/// Runs after a reflection is stopped, using the raw audio file saved by
/// SpeechRecognitionManager to figure out which parts of the transcript came
/// from different speakers. Uses Argmax's open-source SpeakerKit (Pyannote
/// v4 community-1, on-device, MIT license) -- entirely separate from live
/// transcription, which SFSpeechRecognizer already finished producing by the
/// time this runs.
///
/// Honesty note (PROJECT_CONSTRAINTS.md #5, #8): this only ever tells voices
/// apart -- it has no way to know which voice is the phone's owner, so a
/// transcript stays entirely `.user` unless diarization actually finds more
/// than one *distinct* voice. When it does, matched words get relabeled
/// "Speaker 1"/"Speaker 2"/etc; genuinely simultaneous speech becomes
/// `.overlap`, and speech that couldn't be matched to anyone becomes
/// `.unknown` -- never silently asserted as the phone owner's once multiple
/// voices are already known to exist in the session.
enum SpeakerDiarizationEngine {
    static let engineVersion = "0.5"

    /// A raw speaker ID must account for at least this much total speaking
    /// time (summed across every segment SpeakerKit attributed to it)
    /// before it counts toward "more than one distinct speaker found."
    ///
    /// History: started at 2.0s, lowered to 0.5s to catch brief participants
    /// -- too permissive: solo reflections were getting relabeled "Speaker
    /// A" because Pyannote briefly misread a breath, echo, or pitch shift in
    /// the *same* voice as a second speaker. Raised to 3.0s, paired with
    /// `minimumSpeakerProportion` below. Still not enough on a lengthy solo
    /// recording (prosodic drift over several minutes gave a momentary
    /// misattribution enough room to clear both floors), so raised again to
    /// 8.0s/0.25. Left unchanged in this version -- see
    /// STABILIZATION_AND_EXPRESSION_PLAN.md on why further anecdote-driven
    /// tuning isn't done here; `diarizationFilteringDecisions` below exists
    /// so a future retuning pass has real numbers to work from instead of
    /// another anecdote.
    private static let minimumSpeakerDuration: TimeInterval = 8.0

    /// A raw speaker ID must ALSO account for at least this fraction of the
    /// total substantial speaking time (across every ID that clears
    /// `minimumSpeakerDuration`) before it counts as distinct.
    private static let minimumSpeakerProportion: Double = 0.25

    /// Re-labels `session.transcript` by speaker, at word granularity where
    /// word-level audio offsets are available, using the session's saved
    /// audio file. `diarizationEngineVersion` is set whenever diarization
    /// actually completes -- regardless of whether it found more than one
    /// distinct speaker -- so it means "this session has been checked," not
    /// "this session's transcript got relabeled." Stays nil when diarization
    /// couldn't be attempted or failed: no audio file, missing audio file,
    /// audio known to be unreliable (see `ReflectionSession.audioRecordingReliable`),
    /// no parseable segments, or a thrown error.
    static func label(session: ReflectionSession) async -> ReflectionSession {
        guard let audioFileName = session.audioFileName else { return session }
        return await label(session: session, audioURL: Self.audioFileURL(named: audioFileName))
    }

    /// Same as `label(session:)`, but against an explicit audio URL instead
    /// of resolving `session.audioFileName` against the production
    /// `Application Support/Observatory/Audio` directory. Exists so tests
    /// (the fixture replay harness) can exercise this exact diarization
    /// logic against test-bundle audio without ever touching, copying into,
    /// or depending on the live production audio directory -- writing a
    /// test fixture into that directory is what caused real reflection
    /// audio to be lost. Production code only ever calls the convenience
    /// overload above; this is the one and only diarization implementation.
    static func label(session: ReflectionSession, audioURL: URL) async -> ReflectionSession {
        var session = session

        guard FileManager.default.fileExists(atPath: audioURL.path) else { return session }

        // The background audio writer flagged this file as missing or
        // incomplete relative to what was actually recognized -- diarizing
        // it would silently present speaker attribution against data known
        // to be short of the truth. `nil` (unknown/legacy) is still allowed
        // through; only an explicit `false` blocks this.
        guard session.audioRecordingReliable != false else { return session }

        do {
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            let speakerKit = try await SpeakerKit()
            let result = try await speakerKit.diarize(audioArray: audioArray)

            let segments = result.segments
            guard !segments.isEmpty else { return session }

            // Diarization genuinely ran and produced real segments -- mark
            // this session as checked now, before the distinct-speaker
            // filtering below, so a single-speaker result (which correctly
            // leaves the transcript untouched) still reads as "checked," not
            // "never attempted."
            session.diarizationEngineVersion = engineVersion
            session.diarizationRawSegments = segments.map {
                RawDiarizationSegment(
                    startTime: TimeInterval($0.startTime),
                    endTime: TimeInterval($0.endTime),
                    speakerDescription: Self.describe($0.speaker)
                )
            }

            let singleSpeakerSegments: [(id: Int, start: TimeInterval, end: TimeInterval)] = segments.compactMap { segment in
                guard case .speakerId(let id) = segment.speaker else { return nil }
                return (id, TimeInterval(segment.startTime), TimeInterval(segment.endTime))
            }
            let multiSpeakerSegments: [(start: TimeInterval, end: TimeInterval)] = segments.compactMap { segment in
                guard case .multiple = segment.speaker else { return nil }
                return (TimeInterval(segment.startTime), TimeInterval(segment.endTime))
            }

            // What actually matters is whether more than one *distinct*
            // speaker ID represents real, sustained speech from a genuinely
            // separate person, not a momentary misattribution within one
            // person's voice -- see minimumSpeakerDuration/Proportion above.
            let totalDurationByID = Dictionary(grouping: singleSpeakerSegments, by: \.id)
                .mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
            let totalSubstantialDuration = totalDurationByID.values
                .filter { $0 >= minimumSpeakerDuration }
                .reduce(0, +)

            var filteringDecisions: [DiarizationFilteringDecision] = []
            var substantialIDs: Set<Int> = []
            for (id, duration) in totalDurationByID.sorted(by: { $0.key < $1.key }) {
                let proportion = totalSubstantialDuration > 0 ? duration / totalSubstantialDuration : 0
                let passed = duration >= minimumSpeakerDuration && proportion >= minimumSpeakerProportion
                if passed { substantialIDs.insert(id) }
                filteringDecisions.append(
                    DiarizationFilteringDecision(
                        speakerDescription: "speaker \(id)",
                        totalDuration: duration,
                        proportionOfSubstantialTotal: proportion,
                        passed: passed
                    )
                )
            }
            session.diarizationFilteringDecisions = filteringDecisions

            guard substantialIDs.count >= 2 else { return session }

            let sortedIDs = substantialIDs.sorted()
            let displayLabel: [Int: String] = Dictionary(
                uniqueKeysWithValues: sortedIDs.enumerated().map { index, id in (id, "Speaker \(index + 1)") }
            )

            session.transcript = session.transcript.flatMap {
                Self.splitAndRelabel(
                    $0,
                    singleSpeakerSegments: singleSpeakerSegments,
                    multiSpeakerSegments: multiSpeakerSegments,
                    displayLabel: displayLabel,
                    sessionStart: session.startedAt
                )
            }
        } catch {
            print("Speaker diarization failed: \(error.localizedDescription)")
        }

        return session
    }

    /// Splits one transcript event at every speaker change found within its
    /// own words, using each word's audio-file-relative offset -- rather
    /// than assigning the whole event from a single stored timestamp, which
    /// can only ever be right for the one speaker whose segment happens to
    /// contain that one timestamp. Events with no word-level timing at all
    /// (legacy reflections saved before `WordTiming.audioStart` existed, or
    /// non-transcript entries like the "no speech captured" marker) fall
    /// back to the old whole-event matching rather than being silently
    /// skipped or mismatched against invalid timing.
    // `internal` (not `private`), deliberately, so ObservatoryTests can
    // exercise this core matching logic directly with synthetic segments --
    // a real SpeakerKit result needs on-device ML inference against real
    // audio, which a unit test can't produce.
    static func splitAndRelabel(
        _ event: TranscriptEvent,
        singleSpeakerSegments: [(id: Int, start: TimeInterval, end: TimeInterval)],
        multiSpeakerSegments: [(start: TimeInterval, end: TimeInterval)],
        displayLabel: [Int: String],
        sessionStart: Date
    ) -> [TranscriptEvent] {
        guard event.source == .transcript else { return [event] }

        guard !event.words.isEmpty else {
            var event = event
            let offset = event.timestamp.timeIntervalSince(sessionStart)
            if let matchID = singleSpeakerSegments.first(where: { offset >= $0.start && offset <= $0.end })?.id,
               let label = displayLabel[matchID] {
                event.speaker = .other(label)
            } else {
                event.speaker = .unknown
            }
            return [event]
        }

        var runs: [(speaker: Speaker, words: [WordTiming])] = []
        for word in event.words {
            let speaker = Self.speaker(
                for: word,
                singleSpeakerSegments: singleSpeakerSegments,
                multiSpeakerSegments: multiSpeakerSegments,
                displayLabel: displayLabel
            )
            if let lastIndex = runs.indices.last, runs[lastIndex].speaker == speaker {
                runs[lastIndex].words.append(word)
            } else {
                runs.append((speaker, [word]))
            }
        }

        return runs.map { run in
            TranscriptEvent(
                timestamp: run.words.first?.start ?? event.timestamp,
                speaker: run.speaker,
                text: run.words.map(\.text).joined(separator: " "),
                source: event.source,
                words: run.words
            )
        }
    }

    /// `.overlap` only when the raw diarization result itself reported
    /// simultaneous speech (`SpeakerInfo.multiple`) for most of this word's
    /// duration -- distinct from a word that merely straddles the boundary
    /// between two adjacent single-speaker segments, which is attributed by
    /// majority overlap instead. `.unknown` when the word's audio offset
    /// isn't available at all, or no segment overlaps it.
    static func speaker(
        for word: WordTiming,
        singleSpeakerSegments: [(id: Int, start: TimeInterval, end: TimeInterval)],
        multiSpeakerSegments: [(start: TimeInterval, end: TimeInterval)],
        displayLabel: [Int: String]
    ) -> Speaker {
        guard let wordStart = word.audioStart, let wordEnd = word.audioEnd, wordEnd > wordStart else {
            return .unknown
        }

        func overlapDuration(_ segmentStart: TimeInterval, _ segmentEnd: TimeInterval) -> TimeInterval {
            max(0, min(wordEnd, segmentEnd) - max(wordStart, segmentStart))
        }

        let wordDuration = wordEnd - wordStart
        let multiOverlap = multiSpeakerSegments.reduce(0) { $0 + overlapDuration($1.start, $1.end) }
        if multiOverlap > wordDuration / 2 {
            return .overlap
        }

        var bestID: Int?
        var bestOverlap: TimeInterval = 0
        for segment in singleSpeakerSegments {
            let overlap = overlapDuration(segment.start, segment.end)
            if overlap > bestOverlap {
                bestOverlap = overlap
                bestID = segment.id
            }
        }

        guard bestOverlap > 0, let bestID, let label = displayLabel[bestID] else {
            return .unknown
        }
        return .other(label)
    }

    private static func describe(_ info: SpeakerInfo) -> String {
        switch info {
        case .speakerId(let id):
            return "speaker \(id)"
        case .multiple(let ids):
            return "multiple(\(ids.map(String.init).joined(separator: ",")))"
        case .noMatch:
            return "noMatch"
        @unknown default:
            return "unknown"
        }
    }

    private static func audioFileURL(named fileName: String) -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return baseURL
            .appendingPathComponent("Observatory", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
