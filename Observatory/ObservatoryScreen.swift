import SwiftUI
import Combine
import UIKit

/// Observatory is now the single home for both recording a reflection and
/// browsing reflection history. It used to be split with ReflectionTimelineScreen
/// (separate tab, separate detail page reached by navigation) -- that produced
/// duplicated Summary/Arc/Evidence/Diagnostics content across two screens. Now
/// the full history lives here as an expandable list (tap a card to open it in
/// place), and the Timeline tab is a placeholder for something else later.
struct ObservatoryScreen: View {
    @EnvironmentObject private var store: ReflectionSessionStore

    /// Shared with AudioCaptureScreen (injected from ContentView) so starting
    /// or stopping a reflection from either tab controls the same recording.
    @EnvironmentObject private var speechManager: SpeechRecognitionManager
    @EnvironmentObject private var healthKitManager: HealthKitManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var pendingConsentConfirmation = false
    @State private var pendingDeleteSession: ReflectionSession?
    @State private var hapticTimer: Timer?

    var body: some View {
        NavigationStack {
            ZStack {
                ObservatoryTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ScreenHeader(
                            title: "Observatory",
                            subtitle: nil
                        )

                        lifecycleControls

                        if store.isRecording, let session = store.activeSession {
                            VStack(spacing: 8) {
                                Text("Recording Reflection")
                                    .font(.subheadline)
                                    .bold()
                                    .foregroundStyle(ObservatoryTheme.primaryText)

                                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                                    Text("\(session.timeRangeText) • \(durationText(for: session, now: context.date))")
                                        .font(.caption)
                                        .foregroundStyle(ObservatoryTheme.secondaryText)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                        }

                        if store.isRecording, let session = store.activeSession {
                            liveTranscriptCard(session)
                        }

                        if store.completedSessions.isEmpty {
                            emptyHistoryCard
                        } else {
                            reflectionListSection
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .confirmationDialog(
                "Before You Start",
                isPresented: $pendingConsentConfirmation,
                titleVisibility: .visible
            ) {
                Button("Start Recording") {
                    startReflectionAndSpeech()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If anyone besides you will be part of this reflection, make sure they know it's being recorded and have agreed to it.")
            }
            .confirmationDialog(
                "Delete This Reflection",
                isPresented: Binding(
                    get: { pendingDeleteSession != nil },
                    set: { isPresented in if !isPresented { pendingDeleteSession = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let session = pendingDeleteSession {
                        store.deleteReflection(session)
                    }
                    pendingDeleteSession = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingDeleteSession = nil
                }
            } message: {
                if let session = pendingDeleteSession {
                    Text("This permanently deletes \"\(session.title)\" and its audio recording. This can't be undone.")
                }
            }
        }
        .onChange(of: store.isRecording) { _, isRecording in
            if isRecording {
                startHapticFeedback()
            } else {
                stopHapticFeedback()
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Per ChatGPT's review (U6): becoming active again only asks
            // the manager to reconcile an interrupted session -- it never
            // independently starts capture on its own.
            if newPhase == .active {
                speechManager.reconcileAfterForeground()
            }
        }
    }

    private func startHapticFeedback() {
        // Initial haptic pulse when recording starts
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.prepare()
        feedback.impactOccurred()

        // Sharp haptic pulse every 60 seconds (1 minute)
        hapticTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { _ in
            let pulse = UIImpactFeedbackGenerator(style: .heavy)
            pulse.prepare()
            pulse.impactOccurred()
        }
    }

    private func stopHapticFeedback() {
        hapticTimer?.invalidate()
        hapticTimer = nil

        // Final haptic pulse when recording stops
        let feedback = UIImpactFeedbackGenerator(style: .medium)
        feedback.impactOccurred()
    }

    // MARK: - Controls

    private var lifecycleControls: some View {
        RecordingControlButton(
            isRecording: store.isRecording,
            // Temporarily bypassing the consent confirmation dialog during
            // testing -- startReflectionAndSpeech() still records a
            // consentAcknowledgedAt timestamp either way. Restore by setting
            // pendingConsentConfirmation = true here instead.
            onStart: { startReflectionAndSpeech() },
            onStop: {
                speechManager.stop()
                stopAndFetchBiometrics(finishAudioCapture: { await speechManager.finishAudioCapture() })
            }
        )
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    private func startReflectionAndSpeech() {
        // Captured at the moment consent was confirmed, not whenever
        // permissions/setup happen to finish, so this timestamp is an
        // honest record of when the person actually agreed to start.
        let consentTimestamp = Date()

        // Requested speculatively at reflection start (same pattern as
        // speechManager.requestPermissions() below) rather than only when
        // Stop is pressed, so the system prompt -- if this is the first time
        // -- happens before the person starts talking, not in the middle of
        // wrapping up. Not awaited against the recording start: a slow or
        // ignored HealthKit prompt shouldn't block speech capture, which is
        // the part of a reflection that actually can't be backfilled later.
        Task { await healthKitManager.requestAuthorization() }

        Task {
            let allowed = await speechManager.requestPermissions()
            guard allowed else { return }

            let audioFileName = store.startReflection(consentAcknowledgedAt: consentTimestamp)

            speechManager.start(
                audioFileName: audioFileName,
                onTranscript: { utterances in
                    store.updateLiveTranscript(utterances)
                },
                onSilenceGap: { start, duration in
                    store.recordSilenceGap(start: start, duration: duration)
                },
                onRecordingEnded: { reflectionID, reason in
                    store.handleRecordingEndedUnexpectedly(
                        reflectionID: reflectionID,
                        reason: reason,
                        finishAudioCapture: { await speechManager.finishAudioCapture() }
                    )
                }
            )
        }
    }

    /// Stops the reflection, then separately fetches this reflection's real
    /// HealthKit samples and patches them in once the query completes.
    /// `store.stopAndObserve()` runs synchronously and moves the session
    /// into `completedSessions` immediately (with an empty, `.unavailable`
    /// biometrics window as a placeholder -- see its doc comment); the
    /// HealthKit query is a real async round trip, so this can't be part of
    /// that same synchronous call. Captures the session's ID/time window
    /// right after stopping, before anything else can mutate `activeSession`.
    private func stopAndFetchBiometrics(finishAudioCapture: @escaping () async -> (isReliable: Bool, missingAudioIntervals: [AudioInterval], recognitionContinuityGaps: [Date], captureCompleteness: CaptureCompleteness)?) {
        let sessionID = store.activeSession?.id
        let reflectionStart = store.activeSession?.startedAt
        let reflectionEnd = store.activeSession?.endedAt ?? Date()

        store.stopAndObserve(finishAudioCapture: finishAudioCapture)

        guard let sessionID, let reflectionStart else { return }

        Task {
            // fetchSamples pads the search window on both sides of the
            // reflection's actual start/end (see HealthKitManager.queryPadding's
            // doc comment) -- applyBiometrics records the *actual* window
            // searched (result.queryStart/queryEnd), not the reflection's own
            // start/end, so "Body signals from X-Y" in the UI stays honest
            // about what was really queried.
            let result = await healthKitManager.fetchSamples(reflectionStart: reflectionStart, reflectionEnd: reflectionEnd)
            store.applyBiometrics(sessionID: sessionID, samples: result.samples, queryStart: result.queryStart, queryEnd: result.queryEnd)
        }
    }

    // MARK: - Live recording

    private func liveTranscriptCard(_ session: ReflectionSession) -> some View {
        AppCard(title: "Live Reflection") {
            VStack(alignment: .leading, spacing: 14) {
                // Previously wrapped in `TimelineView(.periodic(from: .now,
                // by: 1.0))` so an ongoing pause's duration would visibly
                // climb in real time rather than sitting frozen between
                // transcript updates. That's no longer necessary -- every
                // detected pause now gets its `duration` fixed at the moment
                // SilenceTracker actually confirms it ended (see
                // ObservationEvent.duration's doc comment), not derived live
                // from "now," so there's nothing left that needs a live
                // count-up. Worse, that periodic tick was rebuilding
                // inlineTranscriptText's entire word-by-word `Text`
                // concatenation from scratch every single second for as long
                // as the current utterance kept growing -- SwiftUI's `Text`
                // concatenation scales badly with tree size, and this was
                // confirmed to freeze the app partway into a real recording
                // once a single continuous utterance grew past roughly a
                // paragraph. A plain `Date()` re-renders naturally whenever
                // the transcript or a pause gap actually changes (both are
                // `@Published` on the store), which is the only time this
                // view needs to update at all.
                transcriptView(session, referenceEnd: Date())

                Text(speechManager.statusMessage)
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - History list

    private var emptyHistoryCard: some View {
        AppCard(title: "No Reflections Yet") {
            Text("Tap Start Reflection above to record your first one. Finished reflections are saved to your device and will appear here.")
                .font(.subheadline)
                .foregroundStyle(ObservatoryTheme.secondaryText)
        }
        .padding(.horizontal)
    }

    private var reflectionListSection: some View {
        VStack(spacing: 12) {
            ForEach(Array(store.completedSessions.enumerated()), id: \.element.id) { index, session in
                reflectionCard(session, startsExpanded: index == 0)
            }
        }
        .padding(.horizontal)
    }

    private func reflectionCard(_ session: ReflectionSession, startsExpanded: Bool) -> some View {
        AppCard(title: session.title, startsExpanded: startsExpanded) {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(session.timeRangeText) • \(session.durationText)")
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)

                summaryView(session)

                Divider()

                sectionTitle("Reflection Arc")
                arcView(session)

                Divider()

                sectionTitle("Transcript")
                // A completed reflection's last pause (if it ended mid-pause)
                // is measured against when the reflection actually ended,
                // not "now" -- otherwise reopening this card days later would
                // show the pause as having lasted until the moment you
                // reopened it.
                transcriptView(session, referenceEnd: session.endedAt ?? Date())

                Divider()

                sectionTitle("Evidence")
                evidenceView(session)

                Divider()

                sectionTitle("Diagnostics")
                diagnosticsView(session)

                Divider()

                Button(role: .destructive) {
                    pendingDeleteSession = session
                } label: {
                    Label("Delete This Reflection", systemImage: "trash")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func summaryView(_ session: ReflectionSession) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(primaryInsight(session))
                .font(.headline)
                .foregroundStyle(ObservatoryTheme.primaryText)

            Text(observationDetail(session, title: "Reflection Summary"))
                .font(.subheadline)
                .foregroundStyle(ObservatoryTheme.primaryText)

            if observationDetail(session, title: "Suggested Direction") != "Pending" {
                Text("Suggested direction: \(observationDetail(session, title: "Suggested Direction"))")
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }

            if observationDetail(session, title: "Key Signals") != "Pending" {
                Text("Key signals: \(observationDetail(session, title: "Key Signals"))")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arcView(_ session: ReflectionSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(observationDetail(session, title: "Arc Title"))
                .font(.title3)
                .bold()
                .foregroundStyle(ObservatoryTheme.primaryText)

            MetricRow(label: "Start", value: observationDetail(session, title: "Arc Start"))
            MetricRow(label: "Middle", value: observationDetail(session, title: "Arc Middle"))
            MetricRow(label: "End", value: observationDetail(session, title: "Arc End"))

            Text(observationDetail(session, title: "Reflection Arc"))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            let keyEvents = observationDetail(session, title: "Arc Key Events")
            if keyEvents != "Pending" && !keyEvents.isEmpty {
                Text("Evidence: \(keyEvents)")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
    }

    /// `referenceEnd` stands in for "whatever comes next" when a pause is
    /// the most recent thing in the transcript -- i.e. the person paused and
    /// hasn't spoken again yet, whether still recording or the reflection
    /// ended mid-pause. Previously this fell back to `Date.distantFuture`,
    /// which produced a nonsense multi-billion-minute duration (the actual
    /// bug behind a pause marker showing something like "quiet ·
    /// 1038448677m 4s" and never changing, since it's a fixed math error, not
    /// a real elapsed time). Callers pass `Date()` for a live session (so the
    /// pause duration reflects real elapsed time as of this render) or the
    /// session's actual `endedAt` for a completed one (so a reflection that
    /// ended on a pause shows the real duration up to when it was stopped,
    /// not "now").
    private func transcriptView(_ session: ReflectionSession, referenceEnd: Date) -> some View {
        let events = session.transcript.sorted { $0.timestamp < $1.timestamp }
        let gaps = session.observationEvents
            .filter { $0.kind == .pauseGap }
            .sorted { $0.timestamp < $1.timestamp }

        return VStack(alignment: .leading, spacing: 14) {
            if events.isEmpty {
                Text(store.isRecording ? "Listening..." : "No transcript captured.")
                    .font(.subheadline)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            } else {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    let windowEnd = index + 1 < events.count ? events[index + 1].timestamp : max(referenceEnd, event.timestamp)
                    let windowGaps = gaps.filter { $0.timestamp >= event.timestamp && $0.timestamp < windowEnd }

                    HStack(alignment: .top, spacing: 12) {
                        Text(event.timestamp.shortTimeWithSeconds)
                            .font(.caption2)
                            .foregroundStyle(ObservatoryTheme.secondaryText)
                            .frame(width: 78, alignment: .leading)

                        Text(event.speaker.rawValue)
                            .font(.caption)
                            .bold()
                            .foregroundStyle(ObservatoryTheme.primaryText)
                            .frame(width: 38, alignment: .leading)

                        inlineTranscriptText(event: event, gaps: windowGaps, windowEnd: windowEnd)
                    }
                }
            }
        }
    }

    /// Builds one wrapped paragraph for an utterance with pause markers
    /// embedded directly between the words they actually fell between.
    ///
    /// Built as a single `AttributedString` with styled runs, converted to
    /// one `Text` at the end -- NOT via SwiftUI `Text` concatenation (`+`),
    /// which this used originally. That version rebuilt an ever-growing tree
    /// of individually-styled `Text` values (two per word: the word plus a
    /// separator) from scratch on every transcript update, and SwiftUI's
    /// `Text` concatenation scales badly with tree size -- confirmed to
    /// freeze the app once a single continuous utterance (no long-enough
    /// pause to start a new one) grew past roughly a minute of speech.
    /// Removing an earlier per-second `TimelineView` tick around this (see
    /// `liveTranscriptCard`'s doc comment) only delayed the point this got
    /// expensive enough to freeze -- the transcript updates on every
    /// recognized word regardless of any timer, so the real fix has to be
    /// making a single render cheap at any length, not rendering less often.
    /// Building one `AttributedString` and handing SwiftUI one `Text` avoids
    /// the concatenation-tree cost entirely.
    ///
    /// Previously (before word-level timing existed at all) every pause in
    /// an utterance's window rendered as its own full-width row positioned
    /// after the *entire* utterance, regardless of which word it actually
    /// interrupted -- so a five-pause reflection showed all five pause
    /// markers clustered together at the end of the text block, not at the
    /// points in the sentence where they happened. Word-level timing
    /// (`TranscriptEvent.words`) is what makes placing each one correctly
    /// possible.
    private func inlineTranscriptText(event: TranscriptEvent, gaps: [ObservationEvent], windowEnd: Date) -> Text {
        guard !event.words.isEmpty else {
            // No word-level timing on this entry (older saved reflection, or
            // a non-transcript marker) -- fall back to showing every pause
            // in the window after the whole utterance, same as before word
            // timing existed.
            var attributed = plainRun(event.text)
            var lastShown: Date?
            for gap in gaps {
                if let lastShown, gap.timestamp.timeIntervalSince(lastShown) < 0.5 { continue }
                let duration = gap.duration ?? windowEnd.timeIntervalSince(gap.timestamp)
                guard duration > 0 else { continue }
                attributed += pauseSpan(duration)
                lastShown = gap.timestamp
            }
            return Text(attributed)
        }

        var attributed = AttributedString()
        var lastShownGapTimestamp: Date?

        for (index, word) in event.words.enumerated() {
            if index > 0 {
                attributed += AttributedString(" ")
            }
            attributed += plainRun(word.text)

            let nextWordStart = index + 1 < event.words.count ? event.words[index + 1].start : windowEnd

            for gap in gaps where gap.timestamp >= word.end && gap.timestamp < nextWordStart {
                // Two independent detectors (utterance-timestamp-based and
                // acoustic) can each record their own event for the same
                // real pause. Treat gaps starting within half a second of
                // the last one shown as the same physical pause rather than
                // showing two markers for one silence.
                if let lastShownGapTimestamp, gap.timestamp.timeIntervalSince(lastShownGapTimestamp) < 0.5 {
                    continue
                }

                // Use the duration actually measured when this pause was
                // detected (`ObservationEvent.duration`); only fall back to
                // inferring one from surrounding word timing for an older
                // event that predates that field.
                let duration = gap.duration ?? nextWordStart.timeIntervalSince(gap.timestamp)
                guard duration > 0 else { continue }
                attributed += pauseSpan(duration)
                lastShownGapTimestamp = gap.timestamp
            }
        }

        return Text(attributed)
    }

    private func plainRun(_ text: String) -> AttributedString {
        var run = AttributedString(text)
        run.font = .subheadline
        run.foregroundColor = ObservatoryTheme.primaryText
        return run
    }

    private func pauseSpan(_ duration: TimeInterval) -> AttributedString {
        let label = "  ···  \(formattedGapDuration(duration)) pause  ···  "
        var run = AttributedString(label)
        // Long pauses (10s+) stay visually distinct -- bold rather than a
        // separate full-width divider row, since a divider can't be part of
        // the same flowing paragraph as the surrounding words.
        if duration >= 10 {
            run.font = .caption.bold().italic()
            run.foregroundColor = ObservatoryTheme.secondaryText
        } else {
            run.font = .caption2.italic()
            run.foregroundColor = ObservatoryTheme.secondaryText.opacity(0.8)
        }
        return run
    }

    private func formattedGapDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
    }

    private func evidenceView(_ session: ReflectionSession) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Emotional Trajectory")
            Text(observationDetail(session, title: "Trajectory Title"))
                .font(.subheadline)
                .bold()
                .foregroundStyle(ObservatoryTheme.primaryText)

            Text(observationDetail(session, title: "Emotional Trajectory"))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            MetricRow(label: "Movement", value: observationDetail(session, title: "Trajectory Movement"))
            MetricRow(label: "Start", value: observationDetail(session, title: "Trajectory Start"))
            MetricRow(label: "End", value: observationDetail(session, title: "Trajectory End"))

            Divider()

            sectionTitle("Observation Events")
            Text(ObservationEventEngine.eventSummary(session.observationEvents))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            if session.observationEvents.isEmpty {
                Text("No micro-observation events recorded.")
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            } else {
                ForEach(ObservationEventEngine.groupedEvents(session.observationEvents), id: \.category) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(group.category.rawValue) (\(group.events.count))")
                            .font(.subheadline)
                            .bold()
                            .foregroundStyle(ObservatoryTheme.primaryText)

                        Text(ObservationEventEngine.categorySummary(group.category, events: group.events))
                            .font(.caption)
                            .foregroundStyle(ObservatoryTheme.secondaryText)

                        ForEach(group.events.prefix(5)) { event in
                            observationEventDetail(event)
                        }
                    }

                    Divider()
                }
            }

            sectionTitle("Dynamics")
            Text(DynamicsEngine.summary(session.dynamicsPatterns))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            ForEach(session.dynamicsPatterns) { pattern in
                VStack(alignment: .leading, spacing: 4) {
                    Text(pattern.title)
                        .font(.caption)
                        .bold()
                        .foregroundStyle(ObservatoryTheme.primaryText)

                    Text(pattern.detail)
                        .font(.caption2)
                        .foregroundStyle(ObservatoryTheme.secondaryText)
                }
            }

            Divider()

            sectionTitle("Correlations")
            Text(CorrelationEngine.summary(session.observationCorrelations))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            ForEach(session.observationCorrelations) { correlation in
                VStack(alignment: .leading, spacing: 4) {
                    Text(correlation.title)
                        .font(.caption)
                        .bold()
                        .foregroundStyle(ObservatoryTheme.primaryText)

                    Text(correlation.summary)
                        .font(.caption2)
                        .foregroundStyle(ObservatoryTheme.secondaryText)
                }
            }
        }
    }

    private func observationEventDetail(_ event: ObservationEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(event.timestamp.shortTimeWithSeconds) • \(event.title)")
                .font(.caption)
                .bold()
                .foregroundStyle(ObservatoryTheme.primaryText)

            Text(event.detail)
                .font(.caption2)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            if let related = event.relatedText, !related.isEmpty {
                Text("Related: \(related)")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
                    .lineLimit(2)
            }

            if !event.alternativeExplanations.isEmpty {
                Text("Other readings: " + event.alternativeExplanations.joined(separator: " · "))
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(ObservatoryTheme.secondaryText)
                    .lineLimit(3)
            }
        }
    }

    private func diagnosticsView(_ session: ReflectionSession) -> some View {
        VStack(spacing: 8) {
            MetricRow(label: "State", value: session.state.rawValue.capitalized)
            MetricRow(label: "Boundary", value: session.endedAt == nil ? "Open" : "Closed")
            MetricRow(
                label: "Consent acknowledged",
                value: session.consentAcknowledgedAt.map { $0.shortTimeWithSeconds } ?? "Not recorded"
            )
            MetricRow(
                label: "Speaker identification",
                value: session.diarizationEngineVersion.map { "v\($0)" } ?? "Not yet run"
            )
            MetricRow(label: "Duration", value: session.durationText)
            MetricRow(label: "Speech rate", value: session.voice.wordsPerMinute == 0 ? "Pending" : "\(session.voice.wordsPerMinute) WPM")
            MetricRow(label: "Pause gaps", value: session.voice.pauseCount == 0 ? "None detected" : "\(session.voice.pauseCount)")
            MetricRow(label: "Hesitation markers", value: session.voice.hesitationMarkers == 0 ? "None detected" : "\(session.voice.hesitationMarkers)")
            MetricRow(label: "Observation engine", value: session.observationEngineVersion)
            MetricRow(label: "Dynamics engine", value: session.dynamicsEngineVersion)
            MetricRow(label: "Correlation engine", value: session.correlationEngineVersion)
            MetricRow(label: "Summary engine", value: ReflectionSummaryEngine.engineVersion)
            MetricRow(label: "Trajectory engine", value: EmotionalTrajectoryEngine.engineVersion)
            MetricRow(label: "Arc engine", value: ReflectionArcEngine.engineVersion)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Body Signals")

                Text("Body signals from \(session.biometrics.queryStart.shortTimeWithSeconds)–\(session.biometrics.queryEnd.shortTimeWithSeconds)")
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)

                if session.biometrics.samples.isEmpty {
                    Text("No Health data was found for this reflection's time window -- either Health access hasn't been granted (see Settings), or there's no heart rate, HRV, or respiratory data recorded for this window.")
                        .font(.caption)
                        .foregroundStyle(ObservatoryTheme.secondaryText)
                } else {
                    MetricRow(
                        label: "Latest heart rate",
                        value: "\(Int(session.biometrics.latestHeartRate.rounded())) BPM"
                    )
                    MetricRow(
                        label: "Samples",
                        value: "\(session.biometrics.samples.count)"
                    )
                }

                MetricRow(label: "Data quality", value: session.biometrics.quality.rawValue.capitalized)
            }
        }
    }

    // MARK: - Helpers

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .bold()
            .foregroundStyle(ObservatoryTheme.primaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryInsight(_ session: ReflectionSession) -> String {
        let arcTitle = observationDetail(session, title: "Arc Title")
        if arcTitle != "Pending" && arcTitle != "No clear arc" {
            return arcTitle
        }

        let trajectoryTitle = observationDetail(session, title: "Trajectory Title")
        if trajectoryTitle != "Pending" && trajectoryTitle != "No clear trajectory" {
            return trajectoryTitle
        }

        let observedPattern = observationDetail(session, title: "Observed Pattern")
        if observedPattern != "Pending" {
            return observedPattern
        }

        return "No clear pattern detected yet."
    }

    private func observationDetail(_ session: ReflectionSession, title: String) -> String {
        session.observations.first(where: { $0.title == title })?.detail ?? "Pending"
    }

    private func durationText(for session: ReflectionSession, now: Date) -> String {
        if store.isRecording, let start = store.activeSession?.startedAt {
            let seconds = max(0, Int(now.timeIntervalSince(start)))
            return "\(seconds / 60)m \(seconds % 60)s"
        }

        return session.durationText
    }
}

/// Full-width rectangular control for starting and stopping a reflection.
/// Tap to start (no hold required), tap to stop. The entire button is hot
/// and clickable -- no need to hit a specific spot.
struct RecordingControlButton: View {
    let isRecording: Bool
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        Button(action: isRecording ? onStop : onStart) {
            VStack(spacing: 8) {
                Image(systemName: isRecording ? "stop.circle.fill" : "play.circle.fill")
                    .font(.system(size: 36, weight: .semibold))

                Text(isRecording ? "Stop Reflection" : "Start Reflection")
                    .font(.system(size: 16, weight: .bold))
            }
            .padding(.vertical, 20)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 110)
            .background(
                isRecording
                    ? LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 1.0, green: 0.2, blue: 0.2),
                            Color(red: 0.8, green: 0.0, blue: 0.0)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    : LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.1, green: 0.6, blue: 1.0),
                            Color(red: 0.0, green: 0.4, blue: 0.9)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
            )
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel(isRecording ? "Stop reflection" : "Start reflection")
    }
}
