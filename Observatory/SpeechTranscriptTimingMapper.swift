import Foundation
import Speech

/// Shared conversion from Speech-framework segments to timed utterances.
/// The live microphone path and the fixture replay harness both use this
/// mapper so replay validation exercises the same text/timing logic.
enum SpeechTranscriptTimingMapper {
    static let utteranceGapThreshold: TimeInterval = 0.7

    static func utterances(
        from segments: [SFTranscriptionSegment],
        formattedString: String,
        audioOffset: (TimeInterval) -> TimeInterval?,
        wallClock: (TimeInterval) -> Date?,
        fallbackWallClockAnchor: Date?
    ) -> [SpeechRecognitionManager.Utterance] {
        var result: [SpeechRecognitionManager.Utterance] = []
        let formatted = formattedString as NSString

        for segment in segments {
            let range = segment.substringRange
            let rawText: String
            if range.location != NSNotFound, range.location + range.length <= formatted.length {
                rawText = formatted.substring(with: range)
            } else {
                rawText = segment.substring
            }

            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let audioStart = audioOffset(segment.timestamp)
            let audioEnd = audioStart.map { $0 + segment.duration }
            let wallStart = wallClock(segment.timestamp)
                ?? fallbackWallClockAnchor?.addingTimeInterval(segment.timestamp)
                ?? Date()
            let word = WordTiming(
                text: text,
                start: wallStart,
                end: wallStart.addingTimeInterval(segment.duration),
                audioStart: audioStart,
                audioEnd: audioEnd
            )

            if let lastIndex = result.indices.last,
               wordGap(from: result[lastIndex], to: word) < utteranceGapThreshold {
                result[lastIndex].text += " " + text
                result[lastIndex].end = word.end
                result[lastIndex].words.append(word)
            } else {
                result.append(
                    SpeechRecognitionManager.Utterance(
                        text: text,
                        start: word.start,
                        end: word.end,
                        words: [word]
                    )
                )
            }
        }

        return result
    }

    private static func wordGap(
        from previousUtterance: SpeechRecognitionManager.Utterance,
        to word: WordTiming
    ) -> TimeInterval {
        if let previousEnd = previousUtterance.words.last?.audioEnd,
           let wordStart = word.audioStart {
            return wordStart - previousEnd
        }
        return word.start.timeIntervalSince(previousUtterance.end)
    }
}
