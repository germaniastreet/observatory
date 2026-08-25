import Foundation

enum SampleData {
    static let now = Date()

    static var sessionStart: Date {
        Calendar.current.date(byAdding: .minute, value: -27, to: now) ?? now
    }

    static var sessionEnd: Date { now }

    static var transcript: [TranscriptEvent] {
        [
            TranscriptEvent(timestamp: sessionStart.addingTimeInterval(60), speaker: .user, text: "I feel overwhelmed lately.", source: .transcript),
            TranscriptEvent(timestamp: sessionStart.addingTimeInterval(210), speaker: .other("They"), text: "Tell me more about that.", source: .transcript),
            TranscriptEvent(timestamp: sessionStart.addingTimeInterval(480), speaker: .user, text: "It has been hard to stay focused.", source: .transcript),
            TranscriptEvent(timestamp: sessionStart.addingTimeInterval(720), speaker: .other("They"), text: "That makes sense.", source: .transcript),
            TranscriptEvent(timestamp: sessionStart.addingTimeInterval(980), speaker: .user, text: "I just want some clarity.", source: .transcript)
        ]
    }

    static var biometricSamples: [BiometricSample] {
        var items: [BiometricSample] = []
        for index in 0..<90 {
            let t = sessionStart.addingTimeInterval(Double(index) * 18)
            let hr = 95 + sin(Double(index) / 4.0) * 8 + Double(index % 9)
            let resp = 15.2 + sin(Double(index) / 5.0) * 1.3 + Double(index % 4) * 0.12
            let hrv = 48 + cos(Double(index) / 4.5) * 8 - Double(index % 5)
            items.append(BiometricSample(timestamp: t, heartRate: hr, respiration: resp, hrv: hrv, source: .mock, quality: .medium))
        }
        return items
    }

    static var biometricWindow: BiometricWindow {
        BiometricWindow(queryStart: sessionStart, queryEnd: sessionEnd, samples: biometricSamples, quality: .medium)
    }

    static var observations: [Observation] {
        [
            Observation(title: "Observed Pattern", detail: "Self-critical language appeared alongside a desire for change and presence.", confidence: .medium),
            Observation(title: "Observatory Note", detail: "Activation appears to rise around moments involving focus, time pressure, and clarity.", confidence: .medium)
        ]
    }

    static var voiceSignals: VoiceSignals {
        VoiceSignals(wordsPerMinute: 132, pauseCount: 0, hesitationMarkers: 3, durationSeconds: 1634)
    }

    static var currentSession: ReflectionSession {
        ReflectionSession(
            title: "Live Reflection",
            startedAt: sessionStart,
            endedAt: sessionEnd,
            state: .completed,
            transcript: transcript,
            observations: observations,
            observationEvents: [],
            dynamicsPatterns: [],
            observationCorrelations: [],
            observationEngineVersion: ObservationEventEngine.engineVersion,
            dynamicsEngineVersion: DynamicsEngine.engineVersion,
            correlationEngineVersion: CorrelationEngine.engineVersion,
            biometrics: biometricWindow,
            voice: voiceSignals
        )
    }

    static var sessions: [ReflectionSession] {
        [
            currentSession,
            ReflectionSession(title: "Seeking clarity", startedAt: daysAgo(1, hour: 20), endedAt: daysAgo(1, hour: 20).addingTimeInterval(1680), state: .completed, transcript: transcript, observations: observations, observationEvents: [], dynamicsPatterns: [], observationCorrelations: [], observationEngineVersion: ObservationEventEngine.engineVersion, dynamicsEngineVersion: DynamicsEngine.engineVersion, correlationEngineVersion: CorrelationEngine.engineVersion, biometrics: biometricWindow, voice: VoiceSignals(wordsPerMinute: 118, pauseCount: 0, hesitationMarkers: 4, durationSeconds: 1680)),
            ReflectionSession(title: "Processing frustration", startedAt: daysAgo(2, hour: 10), endedAt: daysAgo(2, hour: 10).addingTimeInterval(1580), state: .completed, transcript: transcript, observations: observations, observationEvents: [], dynamicsPatterns: [], observationCorrelations: [], observationEngineVersion: ObservationEventEngine.engineVersion, dynamicsEngineVersion: DynamicsEngine.engineVersion, correlationEngineVersion: CorrelationEngine.engineVersion, biometrics: biometricWindow, voice: VoiceSignals(wordsPerMinute: 125, pauseCount: 0, hesitationMarkers: 5, durationSeconds: 1580)),
            ReflectionSession(title: "Reflecting on relationships", startedAt: daysAgo(3, hour: 19), endedAt: daysAgo(3, hour: 19).addingTimeInterval(1620), state: .completed, transcript: transcript, observations: observations, observationEvents: [], dynamicsPatterns: [], observationCorrelations: [], observationEngineVersion: ObservationEventEngine.engineVersion, dynamicsEngineVersion: DynamicsEngine.engineVersion, correlationEngineVersion: CorrelationEngine.engineVersion, biometrics: biometricWindow, voice: VoiceSignals(wordsPerMinute: 111, pauseCount: 0, hesitationMarkers: 2, durationSeconds: 1620))
        ]
    }

    static var dynamics: ConversationDynamics {
        ConversationDynamics(userSpeakingPercent: 58, otherSpeakingPercent: 42, turnsTaken: 38, averageTurnLength: 21.6, interruptions: 2, dominanceIndex: 0.16)
    }

    private static func daysAgo(_ days: Int, hour: Int) -> Date {
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: now)
        comps.day = (comps.day ?? 1) - days
        comps.hour = hour
        comps.minute = 0
        return Calendar.current.date(from: comps) ?? now
    }
}

