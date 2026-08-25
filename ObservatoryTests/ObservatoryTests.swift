//
//  secondTests.swift
//  secondTests
//
//  Covers: ReflectionSessionStore.updateLiveTranscript's utterance/pause-gap
//  reconciliation, Speaker's legacy-vs-new Codable decoding, ReflectionSession
//  JSON round-tripping, and SpeakerDiarizationEngine's early-return guards.
//

import Testing
import Foundation
@testable import Observatory

// MARK: - Shared test fixtures

/// Builds a minimal-but-valid ReflectionSession for tests that don't care
/// about most of its fields. Mirrors the shape ReflectionSessionStore itself
/// constructs in startReflection(consentAcknowledgedAt:).
private func makeSession(
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    endedAt: Date? = nil,
    state: ReflectionState = .completed,
    transcript: [TranscriptEvent] = [],
    audioFileName: String? = nil
) -> ReflectionSession {
    let window = BiometricWindow(queryStart: startedAt, queryEnd: startedAt, samples: [], quality: .unavailable)
    var session = ReflectionSession(
        title: "Test Reflection",
        startedAt: startedAt,
        endedAt: endedAt,
        state: state,
        transcript: transcript,
        observations: [],
        observationEvents: [],
        dynamicsPatterns: [],
        observationCorrelations: [],
        observationEngineVersion: "test",
        dynamicsEngineVersion: "test",
        correlationEngineVersion: "test",
        biometrics: window,
        voice: VoiceSignals(wordsPerMinute: 0, pauseCount: 0, hesitationMarkers: 0, durationSeconds: 0)
    )
    session.audioFileName = audioFileName
    return session
}

private func utterance(_ text: String, start: Date, end: Date) -> SpeechRecognitionManager.Utterance {
    SpeechRecognitionManager.Utterance(text: text, start: start, end: end)
}

// MARK: - ReflectionSessionStore.updateLiveTranscript

@MainActor
@Suite("Live transcript reconciliation")
struct TranscriptReconciliationTests {

    @Test("A gap shorter than the minimum observable pause is not recorded")
    func shortGapIsIgnored() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let utterances = [
            utterance("First thing I said", start: base, end: base.addingTimeInterval(2)),
            utterance("Right after", start: base.addingTimeInterval(3), end: base.addingTimeInterval(4)) // 1s gap
        ]

        store.updateLiveTranscript(utterances)

        #expect(store.activeSession?.transcript.count == 2)
        #expect(store.activeSession?.observationEvents.isEmpty == true)
    }

    @Test("A gap at or past the threshold but under 2.5s is recorded at low confidence")
    func borderlineGapIsLowConfidence() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let utterances = [
            utterance("Before the pause", start: base, end: base.addingTimeInterval(2)),
            // Gap of exactly 1.5s -- the documented minimumObservablePause.
            utterance("After the pause", start: base.addingTimeInterval(3.5), end: base.addingTimeInterval(4.5))
        ]

        store.updateLiveTranscript(utterances)

        let events = store.activeSession?.observationEvents ?? []
        #expect(events.count == 1)
        #expect(events.first?.kind == .pauseGap)
        #expect(events.first?.confidence == .low)
    }

    @Test("A gap of 2.5s or more is recorded at medium confidence")
    func longGapIsMediumConfidence() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let utterances = [
            utterance("Before the long pause", start: base, end: base.addingTimeInterval(2)),
            utterance("After the long pause", start: base.addingTimeInterval(5), end: base.addingTimeInterval(6)) // 3s gap
        ]

        store.updateLiveTranscript(utterances)

        let events = store.activeSession?.observationEvents ?? []
        #expect(events.count == 1)
        #expect(events.first?.confidence == .medium)
    }

    @Test("Revising the most recent utterance updates it in place rather than appending")
    func revisingLastUtteranceUpdatesInPlace() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())

        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // SFSpeechRecognizer delivers the full list on every callback; the
        // final entry keeps revising until a new utterance starts.
        store.updateLiveTranscript([
            utterance("Partial wor", start: base, end: base.addingTimeInterval(1))
        ])
        #expect(store.activeSession?.transcript.count == 1)

        store.updateLiveTranscript([
            utterance("Partial words now complete", start: base, end: base.addingTimeInterval(1.2))
        ])

        #expect(store.activeSession?.transcript.count == 1)
        #expect(store.activeSession?.transcript.first?.text == "Partial words now complete")
        // No pause-gap event should appear yet -- there's still only one utterance.
        #expect(store.activeSession?.observationEvents.isEmpty == true)
    }

    @Test("A pause gap is only emitted once, even across repeated deliveries of the same utterance list")
    func pauseGapIsNotDuplicatedOnRedelivery() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let utterances = [
            utterance("First", start: base, end: base.addingTimeInterval(1)),
            utterance("Second, after a long gap", start: base.addingTimeInterval(4), end: base.addingTimeInterval(5))
        ]

        store.updateLiveTranscript(utterances)
        // The whole list is re-delivered verbatim on the next callback, as
        // SpeechRecognitionManager actually does.
        store.updateLiveTranscript(utterances)

        #expect(store.activeSession?.transcript.count == 2)
        #expect(store.activeSession?.observationEvents.count == 1)
    }

    @Test("Calling with no active recording session is a no-op")
    func noActiveSessionIsNoOp() {
        let store = ReflectionSessionStore()
        #expect(store.activeSession == nil)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        store.updateLiveTranscript([
            utterance("Should be ignored", start: base, end: base.addingTimeInterval(1))
        ])

        #expect(store.activeSession == nil)
    }

    @Test("Calling with an empty utterance list is a no-op")
    func emptyUtterancesIsNoOp() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())

        store.updateLiveTranscript([])

        #expect(store.activeSession?.transcript.isEmpty == true)
    }
}

// MARK: - Speaker Codable (legacy string vs. new keyed format)

@MainActor
@Suite("Speaker Codable compatibility")
struct SpeakerCodableTests {

    @Test("Legacy plain-string \"You\" decodes to .user")
    func legacyYouDecodesToUser() throws {
        let data = Data("\"You\"".utf8)
        let speaker = try JSONDecoder().decode(Speaker.self, from: data)
        #expect(speaker == .user)
    }

    @Test("Legacy plain-string \"They\" decodes to .other(\"They\")")
    func legacyTheyDecodesToOther() throws {
        let data = Data("\"They\"".utf8)
        let speaker = try JSONDecoder().decode(Speaker.self, from: data)
        #expect(speaker == .other("They"))
    }

    @Test("Any other legacy label decodes to .other with that exact label")
    func arbitraryLegacyLabelDecodesToOther() throws {
        let data = Data("\"Speaker 2\"".utf8)
        let speaker = try JSONDecoder().decode(Speaker.self, from: data)
        #expect(speaker == .other("Speaker 2"))
    }

    @Test(".user round-trips through the new keyed encoding")
    func userRoundTrips() throws {
        let encoded = try JSONEncoder().encode(Speaker.user)
        let decoded = try JSONDecoder().decode(Speaker.self, from: encoded)
        #expect(decoded == .user)
    }

    @Test(".other(label) round-trips through the new keyed encoding")
    func otherRoundTrips() throws {
        let original = Speaker.other("Speaker 3")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Speaker.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("rawValue reflects the underlying case")
    func rawValueMatchesCase() {
        #expect(Speaker.user.rawValue == "You")
        #expect(Speaker.other("Speaker 1").rawValue == "Speaker 1")
    }
}

// MARK: - ReflectionSession JSON round-tripping

@MainActor
@Suite("ReflectionSession JSON round-tripping")
struct ReflectionSessionCodableTests {

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test("A completed session with transcript and observations round-trips intact")
    func completedSessionRoundTrips() throws {
        // iso8601 truncates to whole seconds, so use whole-second dates to
        // make the round trip exact rather than approximate.
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let ended = started.addingTimeInterval(180)

        var session = makeSession(startedAt: started, endedAt: ended, state: .completed)
        session.transcript = [
            TranscriptEvent(timestamp: started, speaker: .user, text: "Hello", source: .transcript),
            TranscriptEvent(timestamp: started.addingTimeInterval(5), speaker: .other("Speaker 2"), text: "Hi back", source: .transcript)
        ]
        session.consentAcknowledgedAt = started.addingTimeInterval(-10)
        session.audioFileName = "\(session.id.uuidString).caf"
        session.diarizationEngineVersion = "0.2"

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)

        #expect(decoded.id == session.id)
        #expect(decoded.title == session.title)
        #expect(decoded.startedAt == session.startedAt)
        #expect(decoded.endedAt == session.endedAt)
        #expect(decoded.state == session.state)
        #expect(decoded.transcript.count == 2)
        #expect(decoded.transcript.first?.speaker == .user)
        #expect(decoded.transcript.last?.speaker == .other("Speaker 2"))
        #expect(decoded.consentAcknowledgedAt == session.consentAcknowledgedAt)
        #expect(decoded.audioFileName == session.audioFileName)
        #expect(decoded.diarizationEngineVersion == session.diarizationEngineVersion)
    }

    @Test("Optional fields that were never set decode back as nil")
    func unsetOptionalFieldsStayNil() throws {
        let session = makeSession()
        #expect(session.consentAcknowledgedAt == nil)
        #expect(session.audioFileName == nil)
        #expect(session.diarizationEngineVersion == nil)

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)

        #expect(decoded.consentAcknowledgedAt == nil)
        #expect(decoded.audioFileName == nil)
        #expect(decoded.diarizationEngineVersion == nil)
        #expect(decoded.endedAt == nil)
    }

    @Test("A still-recording session (nil endedAt) round-trips correctly")
    func recordingSessionRoundTrips() throws {
        let session = makeSession(state: .recording)

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)

        #expect(decoded.state == .recording)
        #expect(decoded.endedAt == nil)
    }
}

// MARK: - SpeakerDiarizationEngine early-return guards

@MainActor
@Suite("SpeakerDiarizationEngine guards")
struct SpeakerDiarizationEngineGuardTests {

    @Test("A session with no audio file name is returned unchanged")
    func noAudioFileNameReturnsUnchanged() async {
        let original = makeSession(
            transcript: [TranscriptEvent(timestamp: Date(), speaker: .user, text: "Hello", source: .transcript)],
            audioFileName: nil
        )

        let result = await SpeakerDiarizationEngine.label(session: original)

        #expect(result.diarizationEngineVersion == nil)
        #expect(result.transcript.map(\.text) == original.transcript.map(\.text))
        #expect(result.transcript.map(\.speaker) == original.transcript.map(\.speaker))
    }

    @Test("A session whose audio file doesn't exist on disk is returned unchanged")
    func missingAudioFileReturnsUnchanged() async {
        let original = makeSession(
            transcript: [TranscriptEvent(timestamp: Date(), speaker: .user, text: "Hello", source: .transcript)],
            audioFileName: "does-not-exist-\(UUID().uuidString).caf"
        )

        let result = await SpeakerDiarizationEngine.label(session: original)

        #expect(result.diarizationEngineVersion == nil)
        #expect(result.transcript.map(\.text) == original.transcript.map(\.text))
        #expect(result.transcript.map(\.speaker) == original.transcript.map(\.speaker))
    }
}
