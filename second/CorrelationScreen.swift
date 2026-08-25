import SwiftUI

struct CorrelationScreen: View {
    @EnvironmentObject private var store: ReflectionSessionStore

    private var latestSession: ReflectionSession? {
        store.activeSession ?? store.completedSessions.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ObservatoryTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ScreenHeader(title: "Correlation", subtitle: "Observation relationships")

                        if let session = latestSession {
                            AppCard(title: "Latest Reflection") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(session.title)
                                        .font(.headline)

                                    Text("\(session.timeRangeText) • \(session.durationText)")
                                        .font(.caption)
                                        .foregroundStyle(ObservatoryTheme.secondaryText)

                                    Text(CorrelationEngine.summary(session.observationCorrelations))
                                        .font(.caption)
                                        .foregroundStyle(ObservatoryTheme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal)

                            AppCard(title: "Correlation Engine") {
                                VStack(spacing: 8) {
                                    MetricRow(label: "Engine version", value: session.correlationEngineVersion)
                                    MetricRow(label: "Correlations", value: "\(session.observationCorrelations.count)")
                                    MetricRow(label: "Source events", value: "\(session.observationEvents.count)")
                                }
                            }
                            .padding(.horizontal)

                            if session.observationCorrelations.isEmpty {
                                AppCard(title: "No Correlations Yet") {
                                    Text("Record a reflection with multiple observation events. Correlations appear when events such as uncertainty, pause gaps, breath cues, self-correction, stress, or conflict occur together.")
                                        .font(.subheadline)
                                        .foregroundStyle(ObservatoryTheme.secondaryText)
                                }
                                .padding(.horizontal)
                            } else {
                                ForEach(session.observationCorrelations) { correlation in
                                    AppCard(title: correlation.title) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(correlation.timestamp.displayTime)
                                                .font(.caption)
                                                .foregroundStyle(ObservatoryTheme.secondaryText)

                                            Text(correlation.summary)
                                                .font(.subheadline)

                                            MetricRow(label: "Confidence", value: correlation.confidence.rawValue.capitalized)
                                            MetricRow(label: "Engine", value: correlation.engineVersion)

                                            if !correlation.sourceEventTitles.isEmpty {
                                                Text("Based on")
                                                    .font(.caption)
                                                    .bold()
                                                    .padding(.top, 4)

                                                ForEach(correlation.sourceEventTitles, id: \.self) { title in
                                                    Text("• \(title)")
                                                        .font(.caption)
                                                        .foregroundStyle(ObservatoryTheme.secondaryText)
                                                }
                                            }

                                            if !correlation.tags.isEmpty {
                                                Text("Tags: \(correlation.tags.joined(separator: ", "))")
                                                    .font(.caption2)
                                                    .foregroundStyle(ObservatoryTheme.secondaryText)
                                                    .padding(.top, 4)
                                            }
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        } else {
                            AppCard(title: "No Reflection Available") {
                                Text("Create a reflection first. Correlations will appear after observation events are generated.")
                                    .font(.subheadline)
                                    .foregroundStyle(ObservatoryTheme.secondaryText)
                            }
                            .padding(.horizontal)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
    }
}

