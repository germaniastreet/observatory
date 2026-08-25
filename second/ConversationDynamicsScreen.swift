import SwiftUI

struct ConversationDynamicsScreen: View {
    @EnvironmentObject private var store: ReflectionSessionStore

    private var targetSession: ReflectionSession? {
        store.activeSession ?? store.completedSessions.first
    }

    private var dynamics: ConversationDynamics? {
        guard let session = targetSession else { return nil }
        return ConversationDynamicsEngine.analyze(session: session)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ObservatoryTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ScreenHeader(title: "Conversation Dynamics", subtitle: "Turn-taking and interaction flow")

                        if let session = targetSession, let d = dynamics {
                            speakingCard(d)
                            turnTakingCard(d)

                            if d.otherSpeakingPercent == 0 {
                                AppCard(title: "Single-Speaker Reflection") {
                                    Text("Only one speaker was detected in this reflection. Observatory currently transcribes your own speech only — identifying a second speaker hasn't been built yet (planned for a future version). This isn't a failed measurement; it's an accurate result for what the app can currently detect.")
                                        .font(.caption)
                                        .foregroundStyle(ObservatoryTheme.secondaryText)
                                }
                                .padding(.horizontal)
                            }

                            AppCard(title: "Session", startsExpanded: false) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(session.title)
                                        .font(.subheadline)
                                        .bold()

                                    Text("\(session.timeRangeText) • \(session.durationText)")
                                        .font(.caption)
                                        .foregroundStyle(ObservatoryTheme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal)
                        } else {
                            AppCard(title: "No Reflection Available") {
                                Text("Record a reflection first. Turn-taking and speaking-share data will appear here once a transcript is available.")
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

    private func speakingCard(_ d: ConversationDynamics) -> some View {
        AppCard(title: "Speaking Share") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("You")
                            .font(.caption)
                            .foregroundStyle(ObservatoryTheme.secondaryText)
                        Text("\(Int(d.userSpeakingPercent))%")
                            .font(.largeTitle)
                            .bold()
                            .foregroundStyle(ObservatoryTheme.heartRate)
                    }

                    Spacer()

                    RingPercentView(percent: d.userSpeakingPercent / 100, centerLabel: targetSession?.durationText ?? "")

                    Spacer()

                    VStack(alignment: .trailing) {
                        Text("They")
                            .font(.caption)
                            .foregroundStyle(ObservatoryTheme.secondaryText)
                        Text("\(Int(d.otherSpeakingPercent))%")
                            .font(.largeTitle)
                            .bold()
                            .foregroundStyle(ObservatoryTheme.respiration)
                    }
                }

                Text("Estimated from transcript word share, not timed audio.")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
        .padding(.horizontal)
    }

    private func turnTakingCard(_ d: ConversationDynamics) -> some View {
        AppCard(title: "Turn Taking") {
            HStack {
                SignalBadge(icon: "arrow.left.arrow.right", title: "Turns", value: "\(d.turnsTaken)", color: ObservatoryTheme.heartRate)
                Spacer()
                SignalBadge(icon: "timer", title: "Avg Turn", value: String(format: "%.0fs", d.averageTurnLength), color: ObservatoryTheme.amber)
                Spacer()
                SignalBadge(icon: "chart.bar", title: "Dominance", value: String(format: "%.2f", d.dominanceIndex), color: ObservatoryTheme.gold)
            }
        }
        .padding(.horizontal)
    }
}

struct RingPercentView: View {
    let percent: Double
    var centerLabel: String = ""

    var body: some View {
        ZStack {
            Circle().stroke(ObservatoryTheme.border, lineWidth: 16)
            Circle()
                .trim(from: 0, to: min(max(percent, 0), 1))
                .stroke(ObservatoryTheme.heartRate, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack {
                Text("Duration")
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
                Text(centerLabel)
                    .font(.headline)
                    .bold()
            }
        }
        .frame(width: 110, height: 110)
    }
}
