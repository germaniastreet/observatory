import Foundation
import SpeakerKit
import WhisperKit // AudioProcessor.loadAudioAsFloatArray lives here, not in SpeakerKit itself

/// Runs after a reflection is stopped, using the raw audio file saved by
/// SpeechRecognitionManager to figure out which parts of the transcript came
/// from different speakers. Uses Argmax's open-source SpeakerKit (Pyannote
/// v4 community-1, on-device, MIT license -- see the multi-speaker capture
/// research this was built from) -- entirely separate from live
/// transcription, which SFSpeechRecognizer already finished producing by the
/// time this runs.
///
/// Honesty note (PROJECT_CONSTRAINTS.md #5, #9): this only ever tells voices
/// apart -- it has no way to know which voice is the phone's owner, so a
/// transcript stays entirely `.user` unless diarization actually finds more
/// than one *distinct* voice. When it does, every entry (including the
/// owner's) gets re-labeled as "Speaker 1", "Speaker 2", etc., since
/// asserting one of them is specifically "You" would be presenting a guess
/// as a fact.
///
/// IMPORTANT: this is the one file in Observatory built against a third-party
/// package's exact API without a compiler available here to verify it. If
/// Xcode reports a "has no member" or "cannot find type" error anywhere in
/// this file, that's expected -- the fix is almost certainly a one- or
/// two-line rename once the real member name is visible in the error.
enum SpeakerDiarizationEngine {
    static let engineVersion = "0.4"

    /// A speaker must account for at least this much total speaking time
    /// (summed across every RTTM segment attributed to them) before they
    /// count toward "more than one distinct speaker found."
    ///
    /// History: started at 2.0s, lowered to 0.5s to catch brief participants
    /// -- but 0.5s turned out to be far too permissive in practice: solo
    /// reflections were getting relabeled "Speaker A" because Pyannote
    /// briefly misread a breath, echo, or pitch shift in the *same* voice as
    /// a second speaker. An absolute floor alone can't tell "brief real
    /// second speaker" from "brief misattribution," so this was raised back
    /// up and paired with `minimumSpeakerProportion` below, which a
    /// momentary misattribution is much less likely to clear even if it
    /// happens to land above this duration floor.
    ///
    /// Still not enough: a genuinely solo, lengthy reflection came back as
    /// three labels ("You" plus two substantial "Speaker" clusters), both
    /// clearing 3.0s/0.15. A long monologue has more room for prosodic drift
    /// (pitch, energy, pacing shifting across minutes) to read as a second
    /// voice than the short clips this was originally tuned against, so both
    /// floors are raised again here.
    private static let minimumSpeakerDuration: TimeInterval = 8.0

    /// A speaker must ALSO account for at least this fraction of the total
    /// substantial speaking time (across every speaker that clears
    /// `minimumSpeakerDuration`) before they count as distinct. This is what
    /// actually distinguishes "someone else spoke for a while" from "the
    /// model briefly misattributed a few seconds of the same voice" -- a
    /// misattribution can clear an absolute duration floor on a long
    /// recording while still being a tiny sliver of the total, so duration
    /// alone (the only check before this) wasn't enough.
    private static let minimumSpeakerProportion: Double = 0.25

    /// Re-labels `session.transcript` by speaker, using the session's saved
    /// audio file. `diarizationEngineVersion` is set whenever diarization
    /// actually completes (successfully processed real audio into segments)
    /// -- regardless of whether it found more than one distinct speaker --
    /// so it means "this session has been checked," not "this session's
    /// transcript got relabeled." Those are different things: a solo
    /// reflection (the common case) is *supposed* to come back unrelabeled,
    /// and before this it looked identical in Diagnostics to a reflection
    /// where diarization never ran at all -- both showed "Not yet run,"
    /// which made it impossible to tell "diarization is broken" from
    /// "diarization worked and correctly found only one speaker." Stays nil
    /// only for the cases where diarization genuinely couldn't be attempted
    /// or failed: no audio file, missing audio file, no parseable segments,
    /// or a thrown error.
    static func label(session: ReflectionSession) async -> ReflectionSession {
        var session = session

        guard let audioFileName = session.audioFileName else { return session }
        let audioURL = Self.audioFileURL(named: audioFileName)
        guard FileManager.default.fileExists(atPath: audioURL.path) else { return session }

        do {
            let audioArray = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioURL.path)
            let speakerKit = try await SpeakerKit()
            let result = try await speakerKit.diarize(audioArray: audioArray)

            let segments = Self.parseSegments(from: result, fileName: audioFileName)
            guard !segments.isEmpty else { return session }

            // Diarization genuinely ran and produced real segments -- mark
            // this session as checked now, before the distinct-speaker
            // filtering below, so a single-speaker result (which correctly
            // leaves the transcript untouched) still reads as "checked,"
            // not "never attempted."
            session.diarizationEngineVersion = engineVersion

            // A recording with exactly one voice can still produce more than
            // one RTTM segment (the same speaker turning on and off) -- so
            // checking segment *count* alone (the previous behavior) could
            // relabel a single-speaker session away from `.user` just
            // because diarization emitted multiple same-speaker segments.
            // What actually matters is whether more than one *distinct*
            // speaker identifier was found -- and, per minimumSpeakerDuration
            // and minimumSpeakerProportion above, whether that identifier
            // represents real, sustained speech from a genuinely separate
            // person rather than a momentary misattribution within one
            // person's voice.
            let totalDurationByLabel = Dictionary(grouping: segments, by: \.label)
                .mapValues { $0.reduce(0) { $0 + ($1.end - $1.start) } }
            let totalSubstantialDuration = totalDurationByLabel.values
                .filter { $0 >= minimumSpeakerDuration }
                .reduce(0, +)
            let substantialSegments = segments.filter { segment in
                let labelDuration = totalDurationByLabel[segment.label] ?? 0
                guard labelDuration >= minimumSpeakerDuration else { return false }
                guard totalSubstantialDuration > 0 else { return false }
                return (labelDuration / totalSubstantialDuration) >= minimumSpeakerProportion
            }
            let distinctSpeakers = Set(substantialSegments.map(\.label))
            guard distinctSpeakers.count >= 2 else { return session }

            session.transcript = session.transcript.map { event in
                var event = event
                let offset = event.timestamp.timeIntervalSince(session.startedAt)
                if let match = substantialSegments.first(where: { offset >= $0.start && offset <= $0.end }) {
                    event.speaker = .other(match.label)
                }
                return event
            }
        } catch {
            print("Speaker diarization failed: \(error.localizedDescription)")
        }

        return session
    }

    private struct ParsedSegment {
        let start: Double
        let end: Double
        let label: String
    }

    /// SpeakerKit.generateRTTM produces the standard, industry-wide RTTM
    /// text format (`SPEAKER <file> <channel> <start> <duration> <NA> <NA>
    /// <speaker-id> <NA> <NA>`) -- parsed here directly rather than reading
    /// DiarizationResult's own Swift properties, since RTTM's field layout
    /// is a stable, documented format independent of this package's exact
    /// internal API (which this codebase can't fully verify without a
    /// compiler available).
    private static func parseSegments(from result: DiarizationResult, fileName: String) -> [ParsedSegment] {
        let rttmLines = SpeakerKit.generateRTTM(from: result, fileName: fileName)

        return rttmLines.compactMap { line -> ParsedSegment? in
            let fields = line.description.split(separator: " ").map(String.init)
            guard fields.count >= 8, fields[0] == "SPEAKER",
                  let start = Double(fields[3]), let duration = Double(fields[4]) else {
                return nil
            }

            let token = fields[7]
            let normalized = token
                .replacingOccurrences(of: "speaker_", with: "", options: .caseInsensitive)
                .replacingOccurrences(of: "speaker", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: "_ "))
            let label = normalized.isEmpty ? "Speaker (\(token))" : "Speaker \(normalized)"

            return ParsedSegment(start: start, end: start + duration, label: label)
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
