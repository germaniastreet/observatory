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
import AVFoundation
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

    @Test("A session flagged with unreliable audio is returned unchanged, skipping diarization entirely")
    func unreliableAudioSkipsDiarization() async throws {
        let fileName = "unreliable-\(UUID().uuidString).caf"
        let url = SpeechRecognitionManager.audioFileURL(named: fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }

        var original = makeSession(
            transcript: [TranscriptEvent(timestamp: Date(), speaker: .user, text: "Hello", source: .transcript)],
            audioFileName: fileName
        )
        original.audioRecordingReliable = false

        let result = await SpeakerDiarizationEngine.label(session: original)

        #expect(result.diarizationEngineVersion == nil)
        #expect(result.transcript.map(\.speaker) == original.transcript.map(\.speaker))
    }
}

// MARK: - SpeakerDiarizationEngine word-level matching

@MainActor
@Suite("SpeakerDiarizationEngine word-level matching")
struct SpeakerDiarizationEngineMatchingTests {

    @Test("A word falling inside a single speaker's segment is attributed to that speaker")
    func wordInsideSingleSpeakerSegmentIsAttributed() {
        let word = WordTiming(text: "hi", start: Date(), end: Date(), audioStart: 1.0, audioEnd: 1.5)
        let speaker = SpeakerDiarizationEngine.speaker(
            for: word,
            singleSpeakerSegments: [(id: 7, start: 0, end: 3)],
            multiSpeakerSegments: [],
            displayLabel: [7: "Speaker 1"]
        )
        #expect(speaker == .other("Speaker 1"))
    }

    @Test("A word with no audio offset available is unknown, never defaulted to any speaker")
    func wordWithoutOffsetIsUnknown() {
        let word = WordTiming(text: "hi", start: Date(), end: Date())
        let speaker = SpeakerDiarizationEngine.speaker(
            for: word,
            singleSpeakerSegments: [(id: 1, start: 0, end: 10)],
            multiSpeakerSegments: [],
            displayLabel: [1: "Speaker 1"]
        )
        #expect(speaker == .unknown)
    }

    @Test("A word mostly covered by a model-reported overlap segment is marked overlapping, not attributed to one speaker")
    func wordInOverlapSegmentIsMarkedOverlap() {
        let word = WordTiming(text: "hi", start: Date(), end: Date(), audioStart: 1.0, audioEnd: 2.0)
        let speaker = SpeakerDiarizationEngine.speaker(
            for: word,
            singleSpeakerSegments: [(id: 1, start: 0, end: 10)],
            multiSpeakerSegments: [(start: 0.5, end: 2.5)],
            displayLabel: [1: "Speaker 1"]
        )
        #expect(speaker == .overlap)
    }

    @Test("A word straddling two adjacent single-speaker segments is attributed by majority overlap, not marked overlapping")
    func wordStraddlingBoundaryUsesMajorityOverlap() {
        // Word spans 1.0-2.0; segment 1 covers 0-1.8 (0.8s overlap), segment 2 covers 1.8-3 (0.2s overlap).
        let word = WordTiming(text: "hi", start: Date(), end: Date(), audioStart: 1.0, audioEnd: 2.0)
        let speaker = SpeakerDiarizationEngine.speaker(
            for: word,
            singleSpeakerSegments: [(id: 1, start: 0, end: 1.8), (id: 2, start: 1.8, end: 3)],
            multiSpeakerSegments: [],
            displayLabel: [1: "Speaker 1", 2: "Speaker 2"]
        )
        #expect(speaker == .other("Speaker 1"))
    }

    @Test("An event whose words cross a speaker boundary is split into separate events per speaker")
    func eventSplitsAtSpeakerBoundary() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let wordA = WordTiming(text: "hello", start: base, end: base.addingTimeInterval(1), audioStart: 0, audioEnd: 1)
        let wordB = WordTiming(text: "world", start: base.addingTimeInterval(1), end: base.addingTimeInterval(2), audioStart: 1, audioEnd: 2)
        let event = TranscriptEvent(timestamp: base, speaker: .user, text: "hello world", source: .transcript, words: [wordA, wordB])

        let split = SpeakerDiarizationEngine.splitAndRelabel(
            event,
            singleSpeakerSegments: [(id: 1, start: 0, end: 1), (id: 2, start: 1, end: 2)],
            multiSpeakerSegments: [],
            displayLabel: [1: "Speaker 1", 2: "Speaker 2"],
            sessionStart: base
        )

        #expect(split.count == 2)
        #expect(split[0].speaker == .other("Speaker 1"))
        #expect(split[0].text == "hello")
        #expect(split[1].speaker == .other("Speaker 2"))
        #expect(split[1].text == "world")
    }

    @Test("A non-transcript event (e.g. the 'no speech captured' marker) is passed through untouched")
    func nonTranscriptEventPassesThrough() {
        let event = TranscriptEvent(timestamp: Date(), speaker: .user, text: "No speech was captured for this reflection.", source: .userMarker)
        let result = SpeakerDiarizationEngine.splitAndRelabel(
            event,
            singleSpeakerSegments: [(id: 1, start: 0, end: 100)],
            multiSpeakerSegments: [],
            displayLabel: [1: "Speaker 1"],
            sessionStart: Date()
        )
        #expect(result.count == 1)
        #expect(result[0].speaker == .user)
    }
}

// MARK: - WordTiming legacy decode / Speaker overlap & unknown

@MainActor
@Suite("WordTiming and Speaker additions")
struct WordTimingAndSpeakerTests {

    @Test("WordTiming decodes missing audioStart/audioEnd as nil, never 0")
    func wordTimingLegacyDecodeIsNilNotZero() throws {
        let legacyJSON = """
        {"text":"hello","start":"2023-11-14T22:13:20Z","end":"2023-11-14T22:13:21Z"}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let word = try decoder.decode(WordTiming.self, from: Data(legacyJSON.utf8))
        #expect(word.audioStart == nil)
        #expect(word.audioEnd == nil)
    }

    @Test("WordTiming round-trips real audioStart/audioEnd values")
    func wordTimingAudioOffsetsRoundTrip() throws {
        let word = WordTiming(text: "hi", start: Date(), end: Date(), audioStart: 1.5, audioEnd: 2.25)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WordTiming.self, from: try encoder.encode(word))
        #expect(decoded.audioStart == 1.5)
        #expect(decoded.audioEnd == 2.25)
    }

    @Test(".overlap and .unknown round-trip and have distinct, non-placeholder rawValues")
    func overlapAndUnknownRoundTrip() throws {
        for speaker in [Speaker.overlap, Speaker.unknown] {
            let encoded = try JSONEncoder().encode(speaker)
            let decoded = try JSONDecoder().decode(Speaker.self, from: encoded)
            #expect(decoded == speaker)
        }
        #expect(Speaker.overlap.rawValue != Speaker.unknown.rawValue)
        #expect(Speaker.overlap != Speaker.unknown)
    }
}

// MARK: - recognitionContinuityGaps (U6) Codable compatibility
//
// Mirrors WordTimingAndSpeakerTests's pattern for the other D-07-style
// optional field this unit adds. `missingAudioIntervals`/`audioRecordingReliable`
// are NOT touched by U6 (see PROPOSALS/U6-proposal.md R2.1) and already have
// their own coverage elsewhere in this suite -- these two fields are tested
// here specifically to confirm they stay independent of each other.

@MainActor
@Suite("recognitionContinuityGaps Codable compatibility")
struct RecognitionContinuityGapsCodableTests {

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

    @Test("A session predating this field decodes recognitionContinuityGaps as nil, never an empty array")
    func missingFieldDecodesAsNil() throws {
        let session = makeSession()
        #expect(session.recognitionContinuityGaps == nil)

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)
        #expect(decoded.recognitionContinuityGaps == nil)
    }

    @Test("A real list of gap timestamps round-trips intact, independent of missingAudioIntervals")
    func gapsRoundTripIndependentlyOfMissingAudioIntervals() throws {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        var session = makeSession(startedAt: started, endedAt: started.addingTimeInterval(120), state: .completed)
        session.audioRecordingReliable = true
        session.missingAudioIntervals = []
        session.recognitionContinuityGaps = [
            started.addingTimeInterval(46),
            started.addingTimeInterval(108)
        ]

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)

        #expect(decoded.recognitionContinuityGaps == session.recognitionContinuityGaps)
        // Capture was reliable (no write-failure gap) even though two
        // recognition-continuity gaps were recorded -- confirms the two
        // fields represent genuinely separate signals, not two views of
        // the same thing.
        #expect(decoded.audioRecordingReliable == true)
        #expect(decoded.missingAudioIntervals?.isEmpty == true)
    }

    @Test("An empty (not nil) list round-trips as empty -- a clean session with no recognition-continuity gaps")
    func emptyGapsRoundTripsAsEmpty() throws {
        var session = makeSession(state: .completed)
        session.recognitionContinuityGaps = []

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)

        #expect(decoded.recognitionContinuityGaps != nil)
        #expect(decoded.recognitionContinuityGaps?.isEmpty == true)
    }
}

// MARK: - ReflectionSessionStore.handleRecordingEndedUnexpectedly (U6)
//
// This is the one piece of U6's recovery design that's pure Swift logic
// testable without a live AVAudioEngine/SFSpeechRecognizer session --
// everything else new in SpeechRecognitionManager (the lifecycle state
// machine, attemptRecovery's shared budget, the watchdog, AudioWriterBox)
// is `private` and tightly coupled to those system frameworks, exactly
// like this file's pre-existing recording-lifecycle code, none of which
// any test in this suite drives directly either. That logic's verification
// is the device smoke-test re-run (U6's actual exit criterion per
// PLAN.md), not a simulator unit test -- noted here rather than claimed
// as covered.

@MainActor
@Suite("ReflectionSessionStore.handleRecordingEndedUnexpectedly")
struct RecordingEndedUnexpectedlyTests {

    // `ReflectionSessionStore` persists `completedSessions` to a real file
    // under Application Support (see its `didSet`/`loadPersistedSessions`),
    // and Swift Testing runs tests concurrently by default -- so a fresh
    // `ReflectionSessionStore()` in one test can observe sessions a
    // DIFFERENT, concurrently-running test just wrote to that same file.
    // Every assertion below is scoped to THIS test's own `reflectionID` (or
    // a before/after delta) specifically so it stays correct regardless of
    // what other tests are concurrently doing to the shared store --
    // asserting an absolute `completedSessions.count`/`.isEmpty` is not
    // reliable here no matter how this particular run happened to behave.

    @Test("A terminal-failure callback matching the active session finalizes it honestly")
    func matchingCallbackFinalizesSession() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())
        let reflectionID = try! #require(store.activeSession?.id)

        store.handleRecordingEndedUnexpectedly(reflectionID: reflectionID, reason: .recoveryExhausted)

        #expect(store.activeSession?.state == .completed)
        #expect(store.completedSessions.filter { $0.id == reflectionID }.count == 1)
    }

    @Test("A terminal-failure callback for a different (stale) reflection is ignored")
    func mismatchedCallbackIsIgnored() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())
        let reflectionID = try! #require(store.activeSession?.id)

        store.handleRecordingEndedUnexpectedly(reflectionID: UUID(), reason: .unsupported)

        #expect(store.activeSession?.id == reflectionID)
        #expect(store.activeSession?.state == .recording)
        #expect(!store.completedSessions.contains { $0.id == reflectionID })
    }

    @Test("A second callback for an already-finalized session is a no-op, not a duplicate completion")
    func secondCallbackForSameSessionIsNoOp() {
        let store = ReflectionSessionStore()
        store.startReflection(consentAcknowledgedAt: Date())
        let reflectionID = try! #require(store.activeSession?.id)

        store.handleRecordingEndedUnexpectedly(reflectionID: reflectionID, reason: .recoveryExhausted)
        #expect(store.completedSessions.filter { $0.id == reflectionID }.count == 1)

        store.handleRecordingEndedUnexpectedly(reflectionID: reflectionID, reason: .recoveryExhausted)
        #expect(store.completedSessions.filter { $0.id == reflectionID }.count == 1)
    }

    @Test("A callback arriving with no active session at all is a no-op")
    func noActiveSessionIsNoOp() {
        let store = ReflectionSessionStore()
        #expect(store.activeSession == nil)
        let countBefore = store.completedSessions.count

        store.handleRecordingEndedUnexpectedly(reflectionID: UUID(), reason: .recoveryExhausted)

        #expect(store.completedSessions.count == countBefore)
    }
}

// MARK: - SpeechRecognitionManager's shared recovery path (U6)
//
// Driven through the `internal` seams documented at each property/method's
// declaration (lifecycleState, reflectionID, recordingIntent,
// lastRecognitionCallbackAt, recognitionContinuityGaps,
// recentAutoRestarts, attemptRecovery, setAudioWriter,
// discardCurrentAudioWriterIfAny, AudioFileWriter) rather than through the
// public start()/stop() API, which requires a live AVAudioEngine session
// with granted microphone/speech permission -- unavailable on this
// simulator (see AudioFixtureReplayTests' own device-only diagnostics,
// which fail here with "Speech permission is not already authorized").
// `AudioFileWriter`'s own logic (frame counting, file I/O) has no such
// dependency, so it's exercised directly and for real.
//
// Test 2 pre-seeds `recentAutoRestarts` to deliberately trip the existing
// rate-window guard on the call under test, so `attemptRecovery` reaches
// `finishWithFailure` instead of `beginListeningSegment()` -- keeping this
// test free of any live AVAudioEngine/AVAudioSession interaction (whose
// behavior on this permission-less simulator is exactly what's
// undetermined) while still exercising the real gate-then-append sequence
// the regression is about. `finishWithFailure`'s own cleanup is pure
// in-memory/file-I/O, matching this suite's existing safe pattern.

@MainActor
@Suite("SpeechRecognitionManager recovery path")
struct RecoveryPathTests {

    @Test("The watchdog does not force recovery or append a continuity gap while recognition callbacks are fresh")
    func watchdogDoesNothingWhileCallbacksAreFresh() {
        let manager = SpeechRecognitionManager()
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .active
        manager.lastRecognitionCallbackAt = Date()

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        #expect(manager.recognitionContinuityGaps.isEmpty)
        #expect(manager.lifecycleState == .active)
    }

    @Test("The watchdog forces recovery and appends exactly one gap entry when callbacks are stale while buffers keep flowing")
    func watchdogForcesRecoveryWhenStaleWithBuffersFlowing() throws {
        let manager = SpeechRecognitionManager()
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .active
        // Stale: well past recognitionStaleThreshold (25s).
        manager.lastRecognitionCallbackAt = Date().addingTimeInterval(-30)
        // Trips isRestartLoopDetected() on the very next attempt, so this
        // call reaches finishWithFailure rather than beginListeningSegment()
        // -- see this suite's header comment.
        manager.recentAutoRestarts = Array(repeating: Date(), count: 5)

        let fileName = "watchdog-stale-\(UUID().uuidString).caf"
        let url = SpeechRecognitionManager.audioFileURL(named: fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let writer = try SpeechRecognitionManager.AudioFileWriter(url: url, format: format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        // Confirms the tap/engine is still alive "now" -- the other half
        // of isRecognitionStale()'s gate, independent of the stale
        // recognition callback above.
        writer.enqueue(buffer, generation: 0, capturedAt: Date())
        manager.setAudioWriter(writer)

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        #expect(manager.recognitionContinuityGaps.count == 1)
    }

    @Test("A stale trigger carrying an old reflectionID after a new reflection has started is a no-op")
    func staleReflectionIDTriggerIsIgnored() {
        let manager = SpeechRecognitionManager()
        let oldReflectionID = UUID()
        manager.reflectionID = oldReflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .active
        // Deliberately stale, to confirm the reflectionID guard is what's
        // rejecting this, not the staleness gate incidentally saving us.
        manager.lastRecognitionCallbackAt = Date().addingTimeInterval(-30)

        // Simulates a brand-new start() having already run for a
        // different reflection by the time this trigger fires.
        let newReflectionID = UUID()
        manager.reflectionID = newReflectionID

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: oldReflectionID)

        #expect(manager.recognitionContinuityGaps.isEmpty)
        #expect(manager.lifecycleState == .active)
        #expect(manager.reflectionID == newReflectionID)
    }

    @Test("A writer that never received a successfully-written frame is deleted when discarded")
    func zeroWriteWriterIsDeletedOnDiscard() async throws {
        let manager = SpeechRecognitionManager()
        let fileName = "zero-write-\(UUID().uuidString).caf"
        let url = SpeechRecognitionManager.audioFileURL(named: fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let writer = try SpeechRecognitionManager.AudioFileWriter(url: url, format: format)
        manager.setAudioWriter(writer)

        // AVAudioFile(forWriting:) creates the bare-header file immediately
        // on init, before any buffer is ever written -- matching the
        // 4096-byte orphan the smoke test found.
        #expect(FileManager.default.fileExists(atPath: url.path))

        let cleanupTask = manager.discardCurrentAudioWriterIfAny()
        await cleanupTask?.value

        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("A writer with at least one successfully-written frame is kept, not deleted, when discarded")
    func partialWriteWriterIsKeptOnDiscard() async throws {
        let manager = SpeechRecognitionManager()
        let fileName = "partial-write-\(UUID().uuidString).caf"
        let url = SpeechRecognitionManager.audioFileURL(named: fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let writer = try SpeechRecognitionManager.AudioFileWriter(url: url, format: format)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        writer.enqueue(buffer, generation: 0, capturedAt: Date())
        manager.setAudioWriter(writer)

        let cleanupTask = manager.discardCurrentAudioWriterIfAny()
        await cleanupTask?.value

        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Mode B (R4.1): stuck in .recovering after a failed restart,
    // the zombie condition the 2026-10-23 device smoke test actually hit.
    // `lastRecognitionCallbackAt` is deliberately kept FRESH in these tests
    // (not stale) so Mode A's own gate is definitely false -- isolating
    // Mode B as the only possible reason a call proceeds.

    @Test("The watchdog retries when stuck in .recovering with no buffers flowing and no interruption in progress -- the exact zombie condition from the failed device run")
    func watchdogRetriesWhenStuckAfterFailedRestartWithNoBuffersFlowing() {
        let manager = SpeechRecognitionManager()
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date() // fresh -- rules out Mode A
        // No audioWriter assigned at all: buffers cannot be flowing.

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        // Proceeding past the gate is observable via the gap entry --
        // Mode A alone would have blocked this (fresh callback), so this
        // can only have happened via Mode B.
        #expect(manager.recognitionContinuityGaps.count == 1)
    }

    @Test("The watchdog does not retry while an OS interruption is still in progress, even when stuck in .recovering")
    func watchdogDoesNotRetryWhileInterruptionInProgress() {
        let manager = SpeechRecognitionManager()
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = true // OS still owns the microphone
        manager.lastRecognitionCallbackAt = Date()

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        #expect(manager.recognitionContinuityGaps.isEmpty)
        #expect(manager.lifecycleState == .recovering)
    }

    @Test("Repeated retries through attemptRecovery keep the state machine internally consistent, whichever way beginListeningSegment() actually resolves")
    func repeatedRetriesReachAnInternallyConsistentOutcome() {
        // Empirically determined by running this test: in THIS simulator
        // environment, beginListeningSegment()'s real AVAudioSession/
        // AVAudioEngine/SFSpeechRecognizer calls SUCCEED (confirmed: a
        // first version of this test asserting guaranteed failure got
        // lifecycleState == .active, consecutiveRecoveryFailures == 0 --
        // the opposite of what was assumed). Forcing a real, deterministic
        // *failure* out of beginListeningSegment() isn't possible from a
        // test without dependency-injecting AVAudioEngine/SFSpeechRecognizer,
        // which is out of scope here -- flagged to the director rather
        // than silently left as a flaky/wrong assertion. This test instead
        // asserts the invariant that must hold for EITHER real outcome,
        // so it's deterministic regardless of environment: if the budget
        // is reached, termination fires correctly with the right id/
        // reason; if a retry succeeds first, state reverts cleanly with
        // no spurious callback.
        let manager = SpeechRecognitionManager()
        // U6b: this loop can now leave a real, unawaited fast-retry Task
        // scheduled (2-16s out) if the final iteration fails but stays
        // under the budget -- harmless (weak self, local `manager`) but
        // avoidable stray async work during the rest of the suite's run.
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()

        var capturedID: UUID?
        var capturedReason: SpeechRecognitionManager.RecordingEndReason?
        manager.currentOnRecordingEnded = { id, reason in
            capturedID = id
            capturedReason = reason
        }

        for _ in 0..<SpeechRecognitionManager.maxConsecutiveRecoveryFailures {
            guard manager.lifecycleState == .recovering else { break }
            manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)
        }

        switch manager.lifecycleState {
        case .stopped:
            #expect(manager.consecutiveRecoveryFailures == SpeechRecognitionManager.maxConsecutiveRecoveryFailures)
            #expect(capturedID == reflectionID)
            #expect(capturedReason == .recoveryExhausted)
        case .active:
            #expect(manager.consecutiveRecoveryFailures == 0)
            #expect(capturedID == nil)
        default:
            Issue.record("Unexpected lifecycleState \(manager.lifecycleState) after \(SpeechRecognitionManager.maxConsecutiveRecoveryFailures) attempts")
        }
    }

    @Test("A successful retry's resulting state (.active, counter reset) reverts the gate to Mode-A-only behavior")
    func postSuccessStateRevertsGateToModeAOnly() {
        // Exercises the gate's state-dependent logic for the state a
        // successful beginListeningSegment() call leaves behind (verified
        // by reading attemptRecovery's success branch: lifecycleState =
        // .active, consecutiveRecoveryFailures = 0), rather than depending
        // on that call actually succeeding against live hardware in this
        // permission-less test-bundle process -- see the previous test's
        // comment. `attemptRecovery`'s own "recovery succeeded" log line
        // and this file's zero/non-zero-frame writer tests already cover
        // what happens on either side of that one hardware-dependent call.
        let manager = SpeechRecognitionManager()
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .active
        manager.consecutiveRecoveryFailures = 0
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date() // fresh -- Mode A false, Mode B false (not .recovering)

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        // Neither mode applies post-success: Mode A needs a stale
        // callback; Mode B needs lifecycleState == .recovering. Gated out
        // exactly as a healthy recording should be.
        #expect(manager.recognitionContinuityGaps.isEmpty)
        #expect(manager.lifecycleState == .active)
    }

    // MARK: - Fast-backoff restart retry (U6b)
    //
    // Tests that need beginListeningSegment() to actually fail (1, 2, 3, 7,
    // 8) follow this suite's existing precedent (see
    // repeatedRetriesReachAnInternallyConsistentOutcome's comment): that
    // call's real AVAudioSession/AVAudioEngine/SFSpeechRecognizer outcome is
    // environment-dependent on this permission-less simulator, so each
    // branches on whichever way it actually resolves rather than assuming
    // failure. Tests that only need "a fast retry is currently pending" as
    // a precondition (4, 5, 9) assign a dummy Task directly to the internal
    // `pendingFastRetryTask` seam instead, sidestepping that
    // indeterminacy entirely since they're testing cancellation, not
    // scheduling.

    @Test("A single attemptRecovery call either succeeds (no retry scheduled) or fails and schedules a fast retry under the budget")
    func attemptRecoveryEitherSucceedsOrSchedulesFastRetry() {
        let manager = SpeechRecognitionManager()
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()
        manager.consecutiveRecoveryFailures = 0

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        switch manager.lifecycleState {
        case .active:
            #expect(manager.consecutiveRecoveryFailures == 0)
            #expect(manager.pendingFastRetryTask == nil)
        case .recovering:
            #expect(manager.consecutiveRecoveryFailures == 1)
            #expect(manager.pendingFastRetryTask != nil)
        default:
            Issue.record("Unexpected lifecycleState \(manager.lifecycleState) after a single attempt")
        }
    }

    @Test("A failed recovery attempt does not schedule a fast retry once the budget is exhausted")
    func budgetExhaustionDoesNotScheduleFastRetry() {
        let manager = SpeechRecognitionManager()
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()
        manager.consecutiveRecoveryFailures = SpeechRecognitionManager.maxConsecutiveRecoveryFailures - 1

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        switch manager.lifecycleState {
        case .stopped:
            #expect(manager.consecutiveRecoveryFailures == SpeechRecognitionManager.maxConsecutiveRecoveryFailures)
            #expect(manager.pendingFastRetryTask == nil)
        case .active:
            #expect(manager.consecutiveRecoveryFailures == 0)
            #expect(manager.pendingFastRetryTask == nil)
        default:
            Issue.record("Unexpected lifecycleState \(manager.lifecycleState) at the budget boundary")
        }
    }

    @Test("A pending fast retry actually fires and attempts recovery again after its backoff delay")
    func pendingFastRetryFiresAfterBackoffDelay() async throws {
        let manager = SpeechRecognitionManager()
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()
        manager.consecutiveRecoveryFailures = 0

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        guard manager.lifecycleState == .recovering, manager.pendingFastRetryTask != nil else {
            // beginListeningSegment() succeeded outright this run -- nothing
            // was scheduled, nothing to await.
            return
        }
        let failuresBeforeFiring = manager.consecutiveRecoveryFailures
        #expect(failuresBeforeFiring == 1)

        // Slightly longer than fastRetryBackoffSeconds[0] (2s) -- the real,
        // un-mocked delay this chain actually schedules.
        try await Task.sleep(nanoseconds: 2_500_000_000)

        // The pending retry fired on its own and attempted recovery again --
        // observable regardless of whether THAT attempt also failed (counter
        // advances) or happened to succeed (counter resets, state active).
        switch manager.lifecycleState {
        case .active:
            #expect(manager.consecutiveRecoveryFailures == 0)
        case .recovering:
            #expect(manager.consecutiveRecoveryFailures == failuresBeforeFiring + 1)
        default:
            Issue.record("Unexpected lifecycleState \(manager.lifecycleState) after the fast retry should have fired")
        }
    }

    @Test("Stop cancels a pending fast retry")
    func stopCancelsPendingFastRetry() {
        let manager = SpeechRecognitionManager()
        manager.reflectionID = UUID()
        manager.recordingIntent = true
        manager.lifecycleState = .recovering

        // A dummy stand-in for a retry an earlier failed attempt would have
        // scheduled -- avoids depending on beginListeningSegment()'s
        // environment-dependent outcome for a test that's only about
        // cancellation.
        let dummy = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        manager.pendingFastRetryTask = dummy

        manager.stop()

        #expect(dummy.isCancelled)
        #expect(manager.pendingFastRetryTask == nil)
    }

    @Test("A different trigger winning the race cancels the pending fast retry before proceeding")
    func racingTriggerCancelsPendingFastRetry() {
        let manager = SpeechRecognitionManager()
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()

        let dummy = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        manager.pendingFastRetryTask = dummy

        // .interruptionEnded always proceeds (not gated by Mode A/B), so
        // this deterministically reaches the cancellation point regardless
        // of whether beginListeningSegment() itself then succeeds or fails.
        manager.attemptRecovery(trigger: .interruptionEnded, forReflection: reflectionID)

        #expect(dummy.isCancelled)
    }

    @Test("A fired fast retry carrying a stale reflectionID after a new reflection has started is a no-op")
    func staleFastRetryReflectionIDIsIgnored() {
        let manager = SpeechRecognitionManager()
        let oldReflectionID = UUID()
        manager.reflectionID = oldReflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .active
        manager.consecutiveRecoveryFailures = 0

        let newReflectionID = UUID()
        manager.reflectionID = newReflectionID

        manager.attemptRecovery(trigger: .scheduledFastRetry, forReflection: oldReflectionID)

        #expect(manager.lifecycleState == .active)
        #expect(manager.reflectionID == newReflectionID)
        #expect(manager.consecutiveRecoveryFailures == 0)
    }

    @Test("Backoff-spaced attempts stay under the rate guard's trip threshold")
    func backoffSpacedAttemptsDoNotTripRateGuard() {
        let manager = SpeechRecognitionManager()
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()
        manager.consecutiveRecoveryFailures = 0

        // The densest 10-second cluster the fast-retry schedule (plus one
        // independent trigger) can produce, per PROPOSALS/U6b-proposal.md
        // R1.1(b): three prior attempts already landed at these offsets,
        // mirroring the schedule's own {0, 2, 6} cluster.
        let now = Date()
        manager.recentAutoRestarts = [now.addingTimeInterval(-6), now.addingTimeInterval(-4), now]

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        // Must advance via the normal failure/success path, not the rate
        // guard's branch (which also reaches .stopped, but by jumping
        // straight there instead of incrementing the budget counter
        // normally -- distinguished here by confirming the counter moved
        // by exactly one rather than the attempt being rejected outright).
        switch manager.lifecycleState {
        case .active:
            #expect(manager.consecutiveRecoveryFailures == 0)
        case .recovering:
            #expect(manager.consecutiveRecoveryFailures == 1)
        default:
            Issue.record("Rate guard tripped prematurely -- lifecycleState \(manager.lifecycleState), consecutiveRecoveryFailures \(manager.consecutiveRecoveryFailures)")
        }
    }

    @Test("Once the backoff schedule's entries are used up, no further fast retry is scheduled but the reflection stays .recovering, not terminated")
    func scheduleExhaustionDoesNotTerminateTheReflection() {
        let manager = SpeechRecognitionManager()
        defer { manager.pendingFastRetryTask?.cancel() }
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false
        manager.lastRecognitionCallbackAt = Date()
        // The next failure's index (consecutiveRecoveryFailures) into
        // fastRetryBackoffSeconds is exactly out of bounds.
        manager.consecutiveRecoveryFailures = SpeechRecognitionManager.fastRetryBackoffSeconds.count

        manager.attemptRecovery(trigger: .watchdogStall, forReflection: reflectionID)

        switch manager.lifecycleState {
        case .active:
            #expect(manager.consecutiveRecoveryFailures == 0)
        case .recovering:
            #expect(manager.consecutiveRecoveryFailures == SpeechRecognitionManager.fastRetryBackoffSeconds.count + 1)
            #expect(manager.pendingFastRetryTask == nil)
        default:
            Issue.record("Schedule exhaustion was confused with budget exhaustion -- lifecycleState \(manager.lifecycleState)")
        }
    }

    @Test("A new interruption .began cancels a pending fast retry and blocks it from firing while in progress")
    func interruptionBeganCancelsAndBlocksPendingFastRetry() {
        let manager = SpeechRecognitionManager()
        let reflectionID = UUID()
        manager.reflectionID = reflectionID
        manager.recordingIntent = true
        manager.lifecycleState = .recovering
        manager.interruptionInProgress = false

        let dummy = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        manager.pendingFastRetryTask = dummy

        manager.handleInterruption(type: .began, optionsValue: nil)

        #expect(dummy.isCancelled)
        #expect(manager.pendingFastRetryTask == nil)
        #expect(manager.interruptionInProgress == true)

        // Defense-in-depth (fix 2b): even if a stale fast-retry trigger
        // fires anyway, it must no-op while interruptionInProgress is
        // true, not burn another step of the budget.
        manager.consecutiveRecoveryFailures = 0
        manager.attemptRecovery(trigger: .scheduledFastRetry, forReflection: reflectionID)
        #expect(manager.consecutiveRecoveryFailures == 0)
    }
}

// MARK: - CaptureCompleteness (D2/R5): whole-session capture-completeness,
// established from lifecycle evidence (hadCaptureOutage), never from a
// duration/file-length mismatch alone. Driven through
// SpeechRecognitionManager.finishAudioCapture() using the same internal
// testability seams as RecoveryPathTests (setAudioWriter, the internal
// AudioFileWriter, hadCaptureOutage, lifecycleState) -- no live hardware
// needed, since finishAudioCapture() only touches the writer and
// in-memory state once a writer already exists.

@MainActor
@Suite("SpeechRecognitionManager capture-completeness (D2)")
struct CaptureCompletenessTests {

    private func makeWriter(fileName: String) throws -> (writer: SpeechRecognitionManager.AudioFileWriter, url: URL, format: AVAudioFormat) {
        let url = SpeechRecognitionManager.audioFileURL(named: fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let writer = try SpeechRecognitionManager.AudioFileWriter(url: url, format: format)
        return (writer, url, format)
    }

    private func buffer(format: AVAudioFormat, frames: AVAudioFrameCount = 1024) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        return buffer
    }

    @Test("A normal session with no capture outage finalizes as .complete")
    func normalStopFinalizesAsComplete() async throws {
        let manager = SpeechRecognitionManager()
        let (writer, url, format) = try makeWriter(fileName: "completeness-complete-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        writer.enqueue(try buffer(format: format), generation: 0, capturedAt: Date())
        manager.setAudioWriter(writer)
        // hadCaptureOutage defaults to false -- explicit here for clarity.
        manager.hadCaptureOutage = false

        let diagnostics = try #require(await manager.finishAudioCapture())

        #expect(diagnostics.captureCompleteness == .complete)
    }

    @Test("An unrecovered capture outage finalizes as .incomplete with the position matching the file's actual endpoint")
    func unrecoveredOutageFinalizesAsIncompleteWithEndpoint() async throws {
        let manager = SpeechRecognitionManager()
        let (writer, url, format) = try makeWriter(fileName: "completeness-incomplete-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        writer.enqueue(try buffer(format: format, frames: 1024), generation: 0, capturedAt: Date())
        manager.setAudioWriter(writer)
        manager.hadCaptureOutage = true

        let diagnostics = try #require(await manager.finishAudioCapture())

        guard case .incomplete(let endpoint) = diagnostics.captureCompleteness else {
            Issue.record("Expected .incomplete, got \(diagnostics.captureCompleteness)")
            return
        }
        let actualEndpoint = try #require(endpoint)
        #expect(abs(actualEndpoint - (1024.0 / 48000.0)) < 0.001)
    }

    @Test("An outage followed by a successful recovery still finalizes as .incomplete -- a later success doesn't erase it")
    func outageThenSuccessfulRecoveryStillFinalizesAsIncomplete() async throws {
        let manager = SpeechRecognitionManager()
        let (writer, url, format) = try makeWriter(fileName: "completeness-recovered-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        writer.enqueue(try buffer(format: format), generation: 0, capturedAt: Date())
        manager.setAudioWriter(writer)

        manager.hadCaptureOutage = true // the earlier outage
        manager.lifecycleState = .active // simulating the later successful recovery

        let diagnostics = try #require(await manager.finishAudioCapture())

        guard case .incomplete = diagnostics.captureCompleteness else {
            Issue.record("A later successful recovery incorrectly erased an earlier outage")
            return
        }
    }

    @Test("The completeness status is unaffected by how long the writer's internal queue takes to drain")
    func statusNotCorruptedByDelayedWriterDraining() async throws {
        let manager = SpeechRecognitionManager()
        let (writer, url, format) = try makeWriter(fileName: "completeness-drain-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        // Several buffers enqueued back-to-back, immediately followed by
        // finishAudioCapture() with no artificial wait -- the status (set
        // from hadCaptureOutage, a plain flag never derived from drain
        // timing) must come back correct regardless of whether the queue
        // had actually finished draining before this call started.
        for _ in 0..<5 {
            writer.enqueue(try buffer(format: format), generation: 0, capturedAt: Date())
        }
        manager.setAudioWriter(writer)
        manager.hadCaptureOutage = true

        let diagnostics = try #require(await manager.finishAudioCapture())

        guard case .incomplete(let endpoint) = diagnostics.captureCompleteness else {
            Issue.record("Expected .incomplete regardless of drain timing")
            return
        }
        // finishAudioCapture() awaits flush() before reading the endpoint,
        // so all 5 buffers' frames must be reflected regardless of how
        // long the queue actually took to drain them.
        let actualEndpoint = try #require(endpoint)
        #expect(abs(actualEndpoint - (5.0 * 1024.0 / 48000.0)) < 0.001)
    }
}

// MARK: - CaptureCompleteness Codable compatibility

@MainActor
@Suite("CaptureCompleteness Codable compatibility")
struct CaptureCompletenessCodableTests {

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

    @Test("A legacy session JSON missing captureCompleteness decodes as nil, never .complete")
    func legacySessionDecodesCaptureCompletenessAsNil() throws {
        let session = makeSession()
        #expect(session.captureCompleteness == nil)

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(ReflectionSession.self, from: data)

        #expect(decoded.captureCompleteness == nil)
    }

    @Test(".complete and .incomplete(with/without a known endpoint) all round-trip intact")
    func statusesRoundTrip() throws {
        var session = makeSession(state: .completed)

        session.captureCompleteness = .complete
        var decoded = try decoder.decode(ReflectionSession.self, from: try encoder.encode(session))
        #expect(decoded.captureCompleteness == .complete)

        session.captureCompleteness = .incomplete(endpointAudioSeconds: 53.2)
        decoded = try decoder.decode(ReflectionSession.self, from: try encoder.encode(session))
        #expect(decoded.captureCompleteness == .incomplete(endpointAudioSeconds: 53.2))

        session.captureCompleteness = .incomplete(endpointAudioSeconds: nil)
        decoded = try decoder.decode(ReflectionSession.self, from: try encoder.encode(session))
        #expect(decoded.captureCompleteness == .incomplete(endpointAudioSeconds: nil))
    }
}
