import Foundation
import SwiftUI
import Combine

@MainActor
final class ReflectionSessionStore: ObservableObject {
    @Published var activeSession: ReflectionSession?

    /// Persisted to disk on every change (see saveCompletedSessions()) so a
    /// finished reflection survives an app relaunch, phone restart, or the
    /// app being terminated in the background. Previously this was in-memory
    /// only, which meant completed reflections were silently lost the moment
    /// the app process ended -- see PROJECT_ARCHITECTURE.md section 5.
    @Published var completedSessions: [ReflectionSession] {
        didSet {
            saveCompletedSessions()
        }
    }

    /// Treat a gap this long or longer between two recognized utterances as
    /// a real pause worth recording as evidence. Utterance timing comes from
    /// SFSpeechRecognizer's own segment timestamps (real positions within
    /// its audio stream), not from when SpeechRecognitionManager's callback
    /// happened to run -- so unlike the previous implementation, this isn't
    /// measuring callback/scheduling jitter. It's still not true acoustic
    /// silence detection (no energy/VAD analysis of the raw waveform), so
    /// these are recorded at `.low`/`.medium` confidence rather than
    /// `.high` -- see PROJECT_CONSTRAINTS.md and the review this responds
    /// to (finding 2, "Pause gap observations do not measure acoustic
    /// pauses").
    private let minimumObservablePause: TimeInterval = 1.5

    init() {
        // One-time migration from the app's pre-rename storage folder name
        // ("WayReally") to the current one ("Observatory") -- see
        // migrateLegacyStorageIfNeeded's doc comment. Must run before
        // loadPersistedSessions() below, or a device that still has the old
        // folder would look empty on this first post-rename launch even
        // though its reflections are still on disk, just under the old name.
        Self.migrateLegacyStorageIfNeeded()

        // Start honestly empty when there's no saved history yet, rather
        // than showing fabricated demo content that looks indistinguishable
        // from real personal reflections (see PROJECT_CONSTRAINTS.md honesty
        // principle -- this was confusing/concerning to a real user in
        // practice once real data was lost and demo data resurfaced).
        completedSessions = Self.loadPersistedSessions() ?? []
    }

    /// Moves the app's entire Application Support storage folder from its
    /// pre-rename name ("WayReally") to its current one ("Observatory") --
    /// this app was renamed from WayReally to Observatory, but a device that
    /// already has saved reflections has them sitting in a folder still
    /// literally named "WayReally" on disk (completed_reflections_v1.json,
    /// the Audio/ subfolder, everything `storeURL()` and
    /// `deleteAllAudioFiles()` read from). Without this, those reflections
    /// would silently stop appearing the moment this rename shipped -- not
    /// because they were deleted, but because every code path now only ever
    /// looks under the new "Observatory" folder name. Moves the whole folder
    /// in one step (JSON store and Audio/ together, since both already live
    /// under the same base folder) rather than migrating file-by-file.
    ///
    /// Safe to call on every launch: no-ops immediately if there's no legacy
    /// folder (a fresh install, or a device that already migrated), and
    /// deliberately does NOT overwrite an existing "Observatory" folder if
    /// one somehow already exists (leaves the legacy folder in place rather
    /// than risk clobbering newer data with older data).
    private static func migrateLegacyStorageIfNeeded() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let legacyURL = baseURL.appendingPathComponent("WayReally", isDirectory: true)
        let currentURL = baseURL.appendingPathComponent("Observatory", isDirectory: true)

        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }
        guard !FileManager.default.fileExists(atPath: currentURL.path) else { return }

        do {
            try FileManager.default.moveItem(at: legacyURL, to: currentURL)
        } catch {
            print("Legacy storage migration (WayReally -> Observatory) failed: \(error.localizedDescription)")
        }
    }

    var isRecording: Bool {
        activeSession?.state == .recording
    }

    /// Starts a new reflection. `consentAcknowledgedAt` is the moment the
    /// person confirmed (via the confirmation prompt) that anyone else being
    /// recorded knows about it and agreed -- stored on the session as part
    /// of its evidence trail. Returns the filename SpeechRecognitionManager
    /// should record this reflection's raw audio to, so both sides agree on
    /// where it lives without any extra round trip after stopping.
    @discardableResult
    func startReflection(consentAcknowledgedAt: Date) -> String {
        let start = Date()

        let emptyWindow = BiometricWindow(queryStart: start, queryEnd: start, samples: [], quality: .unavailable)

        var session = ReflectionSession(
            title: "Live Reflection",
            startedAt: start,
            endedAt: nil,
            state: .recording,
            transcript: [],
            observations: [],
            observationEvents: [],
            dynamicsPatterns: [],
            observationCorrelations: [],
            observationEngineVersion: ObservationEventEngine.engineVersion,
            dynamicsEngineVersion: DynamicsEngine.engineVersion,
            correlationEngineVersion: CorrelationEngine.engineVersion,
            biometrics: emptyWindow,
            voice: VoiceSignals(wordsPerMinute: 0, pauseCount: 0, hesitationMarkers: 0, durationSeconds: 0),
            consentAcknowledgedAt: consentAcknowledgedAt
        )

        let audioFileName = "\(session.id.uuidString).caf"
        session.audioFileName = audioFileName
        activeSession = session
        return audioFileName
    }

    /// Reconciles the live utterance list (delivered in full, from
    /// SpeechRecognitionManager, on every speech callback) against this
    /// session's transcript. Earlier utterances are done growing --
    /// SFSpeechRecognizer only ever revises the most recent one -- so only
    /// the final entry's text/timestamp actually needs to keep updating in
    /// place; anything new past the current count is appended. Each
    /// utterance keeps its own real, stable start time (see
    /// SpeechRecognitionManager.Utterance), which is what makes per-speaker
    /// diarization mapping meaningful afterwards -- previously this method
    /// collapsed an entire reflection into one transcript event whose
    /// timestamp kept sliding forward to "now," so diarization could only
    /// ever assign one speaker label to the whole conversation (review
    /// finding 1).
    func updateLiveTranscript(_ utterances: [SpeechRecognitionManager.Utterance]) {
        guard var session = activeSession, session.state == .recording else { return }
        guard !utterances.isEmpty else { return }

        var transcriptIndices = session.transcript.indices.filter { session.transcript[$0].source == .transcript }

        // Emit a pause-gap observation for any newly-visible gap between
        // consecutive utterances that's long enough to be meaningful. Only
        // gaps at or past `transcriptIndices.count` are new -- earlier ones
        // were already recorded on a previous call, since this whole
        // utterance list is re-delivered every time.
        //
        // `startIndex` can land at or past `utterances.count` -- e.g. if a
        // segment rollover ever re-delivers a shorter utterance list than a
        // previous call already recorded against -- in which case there are
        // no new gaps to emit, not a backwards range. `startIndex..<utterances.count`
        // would otherwise trap with "Range requires lowerBound <= upperBound"
        // in exactly that case, which is what crashed a lengthy reflection.
        let startIndex = max(1, transcriptIndices.count)
        if utterances.count > 1, startIndex < utterances.count {
            for index in startIndex..<utterances.count {
                let gap = utterances[index].start.timeIntervalSince(utterances[index - 1].end)
                guard gap >= minimumObservablePause else { continue }

                session.observationEvents.append(
                    ObservationEvent(
                        timestamp: utterances[index - 1].end,
                        kind: .pauseGap,
                        category: .voice,
                        title: "Pause gap",
                        detail: String(format: "Possible pause or silence gap of %.1f seconds before speech resumed.", gap),
                        source: .acoustic,
                        confidence: gap >= 2.5 ? .medium : .low,
                        relatedText: utterances[index - 1].text,
                        tags: ["pause", "silence", "speech-timing"],
                        duration: gap,
                        engineVersion: ObservationEventEngine.engineVersion
                    )
                )
            }
        }

        for (i, utterance) in utterances.enumerated() {
            if i < transcriptIndices.count {
                let idx = transcriptIndices[i]
                session.transcript[idx].text = utterance.text
                session.transcript[idx].timestamp = utterance.start
                session.transcript[idx].words = utterance.words
            } else {
                session.transcript.append(
                    TranscriptEvent(timestamp: utterance.start, speaker: .user, text: utterance.text, source: .transcript, words: utterance.words)
                )
                transcriptIndices.append(session.transcript.count - 1)
            }
        }

        activeSession = session
    }

    /// Records a pause detected directly from raw microphone audio (RMS-based
    /// silence, from SpeechRecognitionManager.SilenceTracker) rather than
    /// inferred from gaps between recognized-speech timestamps. This is the
    /// primary pause-detection path -- see SilenceTracker's doc comment for
    /// why the timestamp-based approach in updateLiveTranscript above wasn't
    /// reliably catching real pauses. Kept as a separate method (rather than
    /// folded into updateLiveTranscript) since it's driven by an independent
    /// callback on its own timing, not by the utterance list.
    func recordSilenceGap(start: Date, duration: TimeInterval) {
        guard var session = activeSession, session.state == .recording else { return }

        session.observationEvents.append(
            ObservationEvent(
                timestamp: start,
                kind: .pauseGap,
                category: .voice,
                title: "Pause gap",
                detail: String(format: "Acoustic silence of %.1f seconds detected in the raw audio.", duration),
                source: .acoustic,
                confidence: duration >= 4.0 ? .high : .medium,
                relatedText: nil,
                tags: ["pause", "silence", "speech-timing", "acoustic"],
                duration: duration,
                engineVersion: ObservationEventEngine.engineVersion
            )
        )

        activeSession = session
    }

    /// `finishAudioCapture` lets the caller (which holds the
    /// `SpeechRecognitionManager` this store never references directly)
    /// supply a way to flush the background audio writer and collect its
    /// reliability diagnostics. It's only awaited inside the diarization
    /// `Task` below, not here -- this method still returns synchronously
    /// and moves the session into `completedSessions` immediately, exactly
    /// as before. The flush only needs to finish before diarization opens
    /// the file, not before the UI shows the reflection as complete.
    func stopAndObserve(
        finishAudioCapture: @escaping () async -> (isReliable: Bool, missingAudioIntervals: [AudioInterval], recognitionContinuityGaps: [Date], captureCompleteness: CaptureCompleteness)? = { nil }
    ) {
        guard var session = activeSession else { return }

        let end = Date()
        session.endedAt = end
        session.state = .completed
        session.title = "Reflection at \(session.startedAt.displayTime)"
        session.observationEngineVersion = ObservationEventEngine.engineVersion
        session.dynamicsEngineVersion = DynamicsEngine.engineVersion
        session.correlationEngineVersion = CorrelationEngine.engineVersion

        session.transcript = session.transcript.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if session.transcript.isEmpty {
            session.transcript.append(
                TranscriptEvent(timestamp: session.startedAt, speaker: .user, text: "No speech was captured for this reflection.", source: .userMarker)
            )
        }

        // Placeholder until applyBiometrics (below) patches in whatever
        // HealthKitManager actually finds -- that fetch is async (a real
        // HealthKit query), so it can't complete before this synchronous
        // method returns. Mirrors how diarizationEngineVersion/transcript
        // speaker labels are patched in after the fact, a few lines down.
        session.biometrics = BiometricWindow(queryStart: session.startedAt, queryEnd: end, samples: [], quality: .unavailable)

        session.observationEvents = ObservationEventEngine.enrich(session: session)
        session.dynamicsPatterns = DynamicsEngine.analyze(session: session)
        session.observationCorrelations = CorrelationEngine.analyze(session: session)

        let analysis = ReflectionAnalyzer.analyze(session: session)
        let summary = ReflectionSummaryEngine.analyze(session: session)
        let trajectory = EmotionalTrajectoryEngine.analyze(session: session)
        let arc = ReflectionArcEngine.analyze(session: session)

        let enhancedSummary: String
        if arc.title != "No clear arc" {
            enhancedSummary = "\(summary.summary) Reflection arc: \(arc.detail)"
        } else if trajectory.title != "No clear trajectory" {
            enhancedSummary = "\(summary.summary) Emotional trajectory: \(trajectory.detail)"
        } else {
            enhancedSummary = summary.summary
        }

        session.observations = [
            Observation(title: "Reflection Summary", detail: enhancedSummary, confidence: summary.confidence),
            Observation(title: "Reflection Arc", detail: arc.detail, confidence: arc.confidence),
            Observation(title: "Arc Title", detail: arc.title, confidence: arc.confidence),
            Observation(title: "Arc Sequence", detail: arc.sequence, confidence: arc.confidence),
            Observation(title: "Arc Start", detail: arc.startPhase, confidence: arc.confidence),
            Observation(title: "Arc Middle", detail: arc.middlePhase, confidence: arc.confidence),
            Observation(title: "Arc End", detail: arc.endPhase, confidence: arc.confidence),
            Observation(title: "Arc Key Events", detail: arc.keyEvents.joined(separator: ", "), confidence: arc.confidence),
            Observation(title: "Emotional Trajectory", detail: trajectory.detail, confidence: trajectory.confidence),
            Observation(title: "Trajectory Title", detail: trajectory.title, confidence: trajectory.confidence),
            Observation(title: "Trajectory Movement", detail: trajectory.movement, confidence: trajectory.confidence),
            Observation(title: "Trajectory Start", detail: trajectory.startState, confidence: trajectory.confidence),
            Observation(title: "Trajectory End", detail: trajectory.endState, confidence: trajectory.confidence),
            Observation(title: "Trajectory Phrases", detail: trajectory.keyPhrases.joined(separator: ", "), confidence: trajectory.confidence),
            Observation(title: "Observed Pattern", detail: summary.observedPattern, confidence: summary.confidence),
            Observation(title: "Suggested Direction", detail: summary.suggestedDirection, confidence: summary.confidence),
            Observation(title: "Key Signals", detail: summary.keySignals.joined(separator: ", "), confidence: summary.confidence),
            Observation(title: "Observatory Note", detail: analysis.observatoryNote, confidence: analysis.confidence),
            Observation(title: "Emotional Tone", detail: analysis.emotionalTone, confidence: analysis.confidence),
            Observation(title: "Cognitive Load", detail: analysis.cognitiveLoad, confidence: analysis.confidence),
            Observation(title: "Focus Signal", detail: analysis.focusSignal, confidence: analysis.confidence)
        ]

        // Two independent detectors can each record a pauseGap event for the
        // same real pause (see recordSilenceGap's doc comment) -- the
        // acoustic one (tagged "acoustic") is the reliable source, so count
        // from that alone rather than risk double-counting every pause.
        let pauseCount = session.observationEvents.filter { $0.kind == .pauseGap && $0.tags.contains("acoustic") }.count

        session.voice = VoiceSignals(
            wordsPerMinute: analysis.wordsPerMinute,
            pauseCount: pauseCount,
            hesitationMarkers: analysis.hesitationMarkers,
            durationSeconds: session.durationSeconds
        )

        completedSessions.insert(session, at: 0)
        activeSession = session

        // Speaker identification runs after the fact, on the audio file
        // SpeechRecognitionManager saved alongside the transcript -- it can
        // take a moment (on-device ML inference), so it happens here as a
        // background step rather than blocking Stop & Observe. Every
        // transcript entry starts as `.user`; this only changes that if
        // diarization actually finds more than one voice.
        var sessionForDiarization = session
        Task {
            // Must finish before SpeakerDiarizationEngine ever opens the
            // file below -- otherwise it could read a file shorter than
            // what the background writer was still in the middle of
            // accepting, even though every buffer would have eventually
            // written successfully.
            if let diagnostics = await finishAudioCapture() {
                sessionForDiarization.audioRecordingReliable = diagnostics.isReliable
                sessionForDiarization.missingAudioIntervals = diagnostics.missingAudioIntervals
                sessionForDiarization.recognitionContinuityGaps = diagnostics.recognitionContinuityGaps
                sessionForDiarization.captureCompleteness = diagnostics.captureCompleteness
            }
            let labeled = await SpeakerDiarizationEngine.label(session: sessionForDiarization)
            self.applyDiarizedTranscript(labeled)
        }
    }

    /// Wired to `SpeechRecognitionManager`'s `onRecordingEnded` callback
    /// (via the owning screen, which holds both the manager and this
    /// store) so a reflection that ends WITHOUT an explicit user `stop()`
    /// -- recovery exhausted, or on-device recognition became unsupported
    /// mid-reflection -- still gets finalized through the same completion
    /// mechanics `stopAndObserve()` uses, instead of staying stuck in
    /// `.recording` forever with no further updates and no UI path to end
    /// it. Ignores a callback that doesn't match the currently active
    /// session (a stale trigger from an already-superseded reflection) and
    /// is exactly-once per session: once `stopAndObserve()` below has
    /// already flipped `state` away from `.recording`, a second call for
    /// the same `reflectionID` is a safe no-op.
    func handleRecordingEndedUnexpectedly(
        reflectionID: UUID,
        reason: SpeechRecognitionManager.RecordingEndReason,
        finishAudioCapture: @escaping () async -> (isReliable: Bool, missingAudioIntervals: [AudioInterval], recognitionContinuityGaps: [Date], captureCompleteness: CaptureCompleteness)? = { nil }
    ) {
        guard let session = activeSession, session.id == reflectionID, session.state == .recording else { return }
        stopAndObserve(finishAudioCapture: finishAudioCapture)
    }

    /// Patches in speaker labels found by SpeakerDiarizationEngine after the
    /// fact. Only ever touches transcript speaker tags and the diarization
    /// engine version -- never re-runs the analysis engines, which already
    /// ran against the transcript at Stop time.
    private func applyDiarizedTranscript(_ labeled: ReflectionSession) {
        if let index = completedSessions.firstIndex(where: { $0.id == labeled.id }) {
            completedSessions[index].transcript = labeled.transcript
            completedSessions[index].diarizationEngineVersion = labeled.diarizationEngineVersion
            completedSessions[index].audioRecordingReliable = labeled.audioRecordingReliable
            completedSessions[index].missingAudioIntervals = labeled.missingAudioIntervals
            completedSessions[index].recognitionContinuityGaps = labeled.recognitionContinuityGaps
            completedSessions[index].captureCompleteness = labeled.captureCompleteness
            completedSessions[index].diarizationRawSegments = labeled.diarizationRawSegments
            completedSessions[index].diarizationFilteringDecisions = labeled.diarizationFilteringDecisions
        }

        if activeSession?.id == labeled.id {
            activeSession?.transcript = labeled.transcript
            activeSession?.diarizationEngineVersion = labeled.diarizationEngineVersion
            activeSession?.audioRecordingReliable = labeled.audioRecordingReliable
            activeSession?.missingAudioIntervals = labeled.missingAudioIntervals
            activeSession?.recognitionContinuityGaps = labeled.recognitionContinuityGaps
            activeSession?.captureCompleteness = labeled.captureCompleteness
            activeSession?.diarizationRawSegments = labeled.diarizationRawSegments
            activeSession?.diarizationFilteringDecisions = labeled.diarizationFilteringDecisions
        }
    }

    /// Patches real HealthKit samples (or an honest empty result) into a
    /// session's `biometrics` after the fact, once
    /// `HealthKitManager.fetchSamples` -- a real async query -- completes.
    /// Called from the recording screen, not from inside `stopAndObserve()`
    /// itself: `HealthKitManager` is a vendor-specific adapter owned by the
    /// screen layer (same pattern as `SpeechRecognitionManager`), not
    /// something this store instantiates or depends on directly, per
    /// PROJECT_CONSTRAINTS.md #11 ("no engine should depend on a specific
    /// device/vendor unless it is an adapter") and PROJECT_ARCHITECTURE.md's
    /// "no UI screen should own durable business logic" -- the screen
    /// triggers the fetch, but the store is still the only thing that
    /// mutates session state. `quality` reflects whether HealthKit actually
    /// returned anything: `.unavailable` for a genuine empty result (no
    /// Watch, no data in this window, or access declined) stays visually and
    /// semantically distinct from `.medium` (real samples present) rather
    /// than presenting silence as evidence.
    func applyBiometrics(sessionID: UUID, samples: [BiometricSample], queryStart: Date, queryEnd: Date) {
        let window = BiometricWindow(
            queryStart: queryStart,
            queryEnd: queryEnd,
            samples: samples,
            quality: samples.isEmpty ? .unavailable : .medium
        )

        if let index = completedSessions.firstIndex(where: { $0.id == sessionID }) {
            completedSessions[index].biometrics = window
        }

        if activeSession?.id == sessionID {
            activeSession?.biometrics = window
        }
    }

    func resetActiveSession() {
        activeSession = nil
    }

    // MARK: - Deletion & export (PROJECT_CONSTRAINTS.md #12: users must be
    // able to understand, control, export, and remove their data)

    /// Deletes one completed reflection and its associated raw audio file,
    /// if it has one. Safe to call even if the audio file is already
    /// missing.
    func deleteReflection(_ session: ReflectionSession) {
        completedSessions.removeAll { $0.id == session.id }
        if let audioFileName = session.audioFileName {
            Self.deleteAudioFile(named: audioFileName)
        }
    }

    /// Wipes every completed reflection this app knows about, plus every
    /// file in the reflection Audio directory -- including any orphaned
    /// `.caf` left behind by a past crash or bug, which per-reflection
    /// deletion above can't reach since it only knows about files a
    /// still-referenced session points to. This is an explicit, confirmed,
    /// all-or-nothing action; there is no soft/partial version.
    func deleteAllData() {
        completedSessions = []
        Self.deleteAllAudioFiles()
    }

    /// Builds one JSON export covering every completed reflection's
    /// transcript, observations, evidence, and consent/provenance metadata.
    /// Raw audio is intentionally not included -- it would make the export
    /// file large and is also the most sensitive part of a reflection;
    /// exporting the record of what was said and observed doesn't require
    /// exporting the recording itself.
    func exportAllReflectionsJSON() -> URL? {
        do {
            let data = try JSONEncoder.reflectionSessionEncoder.encode(completedSessions)
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Observatory-Export-\(Int(Date().timeIntervalSince1970)).json")
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            print("Reflection export failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func deleteAudioFile(named fileName: String) {
        let url = SpeechRecognitionManager.audioFileURL(named: fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private static func deleteAllAudioFiles() {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let audioDirectory = baseURL
            .appendingPathComponent("Observatory", isDirectory: true)
            .appendingPathComponent("Audio", isDirectory: true)
        try? FileManager.default.removeItem(at: audioDirectory)
    }

    // MARK: - Persistence

    private func saveCompletedSessions() {
        do {
            let url = Self.storeURL()
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            let data = try JSONEncoder.reflectionSessionEncoder.encode(completedSessions)
            try data.write(to: url, options: [.atomic])
        } catch {
            print("Reflection session store save failed: \(error.localizedDescription)")
        }
    }

    private static func loadPersistedSessions() -> [ReflectionSession]? {
        let url = storeURL()

        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder.reflectionSessionDecoder.decode([ReflectionSession].self, from: data)
            return decoded.isEmpty ? nil : decoded
        } catch {
            print("Reflection session store load failed: \(error.localizedDescription)")
            return nil
        }
    }

    private static func storeURL() -> URL {
        let baseURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory

        return baseURL
            .appendingPathComponent("Observatory", isDirectory: true)
            .appendingPathComponent("completed_reflections_v1.json")
    }
}

private extension JSONEncoder {
    static var reflectionSessionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var reflectionSessionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
