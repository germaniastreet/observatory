import Foundation

/// Computes ConversationDynamics from a real session's transcript.
///
/// Important honesty constraint (see PROJECT_CONSTRAINTS.md #5, #9): this app
/// does not yet time-align individual utterances, and live capture only ever
/// produces `.user` speaker entries (there is no speaker diarization yet —
/// that is planned for a later version, per VERSION_HISTORY v116). So this
/// engine estimates each speaker's share by transcript word count, not by
/// timed audio, and returns nil when there isn't enough transcript to say
/// anything. Screens should treat a single-speaker result as a valid,
/// non-failure outcome rather than force a fake 50/50 split.
enum ConversationDynamicsEngine {
    static let engineVersion = "1.1"

    static func analyze(session: ReflectionSession) -> ConversationDynamics? {
        let events = session.transcript
        guard !events.isEmpty else { return nil }

        // Speaker is open-ended now (diarization can label more than one
        // "other" voice), but ConversationDynamics itself is still a binary
        // you-vs-everyone-else breakdown -- redesigning it for N distinct
        // speakers is a separate, bigger feature. Every non-`.user` voice
        // (however many diarization found) counts toward "other" here.
        var userWords = 0
        var otherWords = 0
        var turns: [Speaker] = []

        for event in events {
            let words = event.text.split { $0.isWhitespace || $0.isNewline }.count
            guard words > 0 else { continue }

            if event.speaker == .user {
                userWords += words
            } else {
                otherWords += words
            }

            if turns.last != event.speaker {
                turns.append(event.speaker)
            }
        }

        let totalWords = userWords + otherWords
        guard totalWords > 0 else { return nil }

        let userPercent = Double(userWords) / Double(totalWords) * 100
        let otherPercent = Double(otherWords) / Double(totalWords) * 100

        let turnsTaken = turns.count
        let averageTurnLength = turnsTaken > 0
            ? Double(session.durationSeconds) / Double(turnsTaken)
            : 0

        // A simple, defensible imbalance measure: 0 means an even split
        // between speakers, 1 means only one speaker had any words.
        let dominanceIndex = abs(userPercent - otherPercent) / 100

        return ConversationDynamics(
            userSpeakingPercent: userPercent,
            otherSpeakingPercent: otherPercent,
            turnsTaken: turnsTaken,
            averageTurnLength: averageTurnLength,
            interruptions: 0,
            dominanceIndex: dominanceIndex
        )
    }
}
