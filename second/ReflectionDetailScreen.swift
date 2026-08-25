import SwiftUI

struct ReflectionDetailScreen: View {
    let session: ReflectionSession

    var body: some View {
        ZStack {
            ObservatoryTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    ScreenHeader(
                        title: session.title,
                        subtitle: "\(session.timeRangeText) • \(session.durationText)"
                    )

                    AppCard(title: "Summary") {
                        summaryView
                    }
                    .padding(.horizontal)

                    AppCard(title: "Reflection Arc") {
                        arcView
                    }
                    .padding(.horizontal)

                    AppCard(title: "Transcript") {
                        transcriptView
                    }
                    .padding(.horizontal)

                    AppCard(title: "Evidence", startsExpanded: false) {
                        evidenceView
                    }
                    .padding(.horizontal)

                    AppCard(title: "Diagnostics", startsExpanded: false) {
                        diagnosticsView
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Reflection")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(primaryInsight)
                .font(.headline)

            Text(observationDetail("Reflection Summary"))
                .font(.subheadline)

            if observationDetail("Suggested Direction") != "Pending" {
                Text("Suggested direction: \(observationDetail("Suggested Direction"))")
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }

            if observationDetail("Key Signals") != "Pending" {
                Text("Key signals: \(observationDetail("Key Signals"))")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var arcView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(observationDetail("Arc Title"))
                .font(.title3)
                .bold()

            MetricRow(label: "Start", value: observationDetail("Arc Start"))
            MetricRow(label: "Middle", value: observationDetail("Arc Middle"))
            MetricRow(label: "End", value: observationDetail("Arc End"))

            Text(observationDetail("Reflection Arc"))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            if observationDetail("Arc Key Events") != "Pending" && !observationDetail("Arc Key Events").isEmpty {
                Text("Evidence: \(observationDetail("Arc Key Events"))")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
    }

    /// A gap of this long or longer between two utterances is shown as a
    /// full-width "quiet" divider rather than a small inline marker -- the
    /// threshold that separates "normal conversational pause" from "you were
    /// just walking/not talking for a while." Every gap reaching this view
    /// is already >= ReflectionSessionStore.minimumObservablePause (1.5s),
    /// since that's the floor `.pauseGap` events are recorded at in the
    /// first place.
    private static let longPauseThreshold: TimeInterval = 10.0

    /// One row of the rendered transcript: either a spoken utterance, or a
    /// silence gap sitting between two utterances.
    private enum TranscriptRow: Identifiable {
        case utterance(TranscriptEvent)
        case pause(id: UUID, duration: TimeInterval)

        var id: UUID {
            switch self {
            case .utterance(let event): return event.id
            case .pause(let id, _): return id
            }
        }
    }

    /// Interleaves this session's already-recorded `.pauseGap` observation
    /// events (see ReflectionSessionStore.updateLiveTranscript) between the
    /// transcript entries they fall between, so pauses/silence read inline
    /// in the transcript instead of only showing up separately under
    /// Evidence -> Observation Events. A pause event's own timestamp is the
    /// *end* of the utterance right before the gap (see
    /// updateLiveTranscript), so the gap's duration is simply the time from
    /// there to the start of the next utterance -- no need to parse it back
    /// out of the event's description text.
    private var transcriptRows: [TranscriptRow] {
        let events = session.transcript.sorted { $0.timestamp < $1.timestamp }
        let gaps = session.observationEvents
            .filter { $0.kind == .pauseGap }
            .sorted { $0.timestamp < $1.timestamp }

        var rows: [TranscriptRow] = []
        var gapIndex = 0

        for (index, event) in events.enumerated() {
            rows.append(.utterance(event))

            let nextTimestamp = index + 1 < events.count ? events[index + 1].timestamp : Date.distantFuture
            while gapIndex < gaps.count,
                  gaps[gapIndex].timestamp >= event.timestamp,
                  gaps[gapIndex].timestamp < nextTimestamp {
                let gapEvent = gaps[gapIndex]
                let duration = nextTimestamp.timeIntervalSince(gapEvent.timestamp)
                if duration > 0 {
                    rows.append(.pause(id: gapEvent.id, duration: duration))
                }
                gapIndex += 1
            }
        }

        return rows
    }

    private var transcriptView: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.transcript.isEmpty {
                Text("No transcript captured.")
                    .font(.caption)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            } else {
                ForEach(transcriptRows) { row in
                    switch row {
                    case .utterance(let event):
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

                            Text(event.text)
                                .font(.subheadline)
                                .foregroundStyle(ObservatoryTheme.primaryText)
                        }
                    case .pause(_, let duration):
                        pauseIndicator(duration: duration)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pauseIndicator(duration: TimeInterval) -> some View {
        if duration >= Self.longPauseThreshold {
            HStack(spacing: 8) {
                VStack { Divider() }
                Text("quiet · \(Self.formattedGapDuration(duration))")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
                    .fixedSize()
                VStack { Divider() }
            }
            .padding(.vertical, 2)
        } else {
            HStack(spacing: 12) {
                Text("")
                    .frame(width: 78, alignment: .leading)

                Text("···  \(Self.formattedGapDuration(duration)) pause")
                    .font(.caption2)
                    .italic()
                    .foregroundStyle(ObservatoryTheme.secondaryText.opacity(0.8))

                Spacer()
            }
        }
    }

    private static func formattedGapDuration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let remainingSeconds = Int(seconds) % 60
        return remainingSeconds == 0 ? "\(minutes)m" : "\(minutes)m \(remainingSeconds)s"
    }

    private var evidenceView: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Emotional Trajectory")
            Text(observationDetail("Trajectory Title"))
                .font(.subheadline)
                .bold()

            Text(observationDetail("Emotional Trajectory"))
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)

            MetricRow(label: "Movement", value: observationDetail("Trajectory Movement"))
            MetricRow(label: "Start", value: observationDetail("Trajectory Start"))
            MetricRow(label: "End", value: observationDetail("Trajectory End"))

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

                        Text(ObservationEventEngine.categorySummary(group.category, events: group.events))
                            .font(.caption)
                            .foregroundStyle(ObservatoryTheme.secondaryText)

                        ForEach(group.events.prefix(5)) { event in
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(event.timestamp.shortTimeWithSeconds) • \(event.title)")
                                    .font(.caption)
                                    .bold()

                                Text(event.detail)
                                    .font(.caption2)
                                    .foregroundStyle(ObservatoryTheme.secondaryText)

                                if let related = event.relatedText {
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

                    Text(correlation.summary)
                        .font(.caption2)
                        .foregroundStyle(ObservatoryTheme.secondaryText)
                }
            }
        }
    }

    private var diagnosticsView: some View {
        VStack(spacing: 8) {
            MetricRow(label: "State", value: session.state.rawValue.capitalized)
            MetricRow(label: "Boundary", value: session.endedAt == nil ? "Open" : "Closed")
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
                        label: "Average heart rate",
                        value: "\(Int(session.biometrics.averageHeartRate.rounded())) BPM"
                    )
                    MetricRow(
                        label: "Samples",
                        value: "\(session.biometrics.samples.count)"
                    )
                    MetricRow(
                        label: "Source",
                        value: biometricSourceText
                    )
                }

                MetricRow(label: "Data quality", value: session.biometrics.quality.rawValue.capitalized)
            }
        }
    }

    /// `BiometricSample.source` is per-sample (`SignalSource`), not one flat
    /// label for the whole window -- in practice every sample in a given
    /// window currently comes from the same fetch (HealthKitManager stamps
    /// every sample `.healthKitBackfill`), but reading it from the actual
    /// samples rather than hardcoding a value keeps this honest if that ever
    /// changes (e.g. once a live Watch path exists alongside backfill).
    private var biometricSourceText: String {
        guard let source = session.biometrics.samples.first?.source else { return "Unknown" }
        switch source {
        case .healthKitBackfill: return "Health (backfill)"
        case .liveWatch: return "Apple Watch (live)"
        case .mock: return "Sample data"
        default: return source.rawValue.capitalized
        }
    }

    private var primaryInsight: String {
        let arcTitle = observationDetail("Arc Title")
        if arcTitle != "Pending" && arcTitle != "No clear arc" {
            return arcTitle
        }

        let trajectoryTitle = observationDetail("Trajectory Title")
        if trajectoryTitle != "Pending" && trajectoryTitle != "No clear trajectory" {
            return trajectoryTitle
        }

        let observedPattern = observationDetail("Observed Pattern")
        if observedPattern != "Pending" {
            return observedPattern
        }

        return "No clear pattern detected yet."
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .bold()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func observationDetail(_ title: String) -> String {
        session.observations.first(where: { $0.title == title })?.detail ?? "Pending"
    }
}

