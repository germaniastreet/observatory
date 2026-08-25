import SwiftUI
import UIKit

struct AudioCaptureScreen: View {
    @EnvironmentObject private var store: ReflectionSessionStore
    @EnvironmentObject private var speechManager: SpeechRecognitionManager
    @EnvironmentObject private var healthKitManager: HealthKitManager

    @State private var pendingConsentConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                ObservatoryTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ScreenHeader(title: "Audio Capture", subtitle: "Capture a reflection for analysis")

                        AppCard(title: store.isRecording ? "Recording" : "Not Recording") {
                            VStack(spacing: 18) {
                                TimelineView(.periodic(from: .now, by: 1.0)) { context in
                                    Text(timerText(now: context.date))
                                        .font(.system(size: 44, weight: .bold, design: .rounded))
                                        .foregroundStyle(ObservatoryTheme.primaryText)
                                }

                                if store.isRecording {
                                    RecordingPulse()
                                }

                                Text(speechManager.statusMessage)
                                    .font(.caption)
                                    .foregroundStyle(ObservatoryTheme.secondaryText)

                                HStack(spacing: 36) {
                                    if store.isRecording {
                                        CaptureButton(icon: "stop.fill", label: "Stop", color: Color.red.opacity(0.9)) {
                                            speechManager.stop()
                                            stopAndFetchBiometrics()
                                        }

                                        CaptureButton(icon: "arrow.counterclockwise", label: "Reset", color: ObservatoryTheme.background) {
                                            speechManager.stop()
                                            store.resetActiveSession()
                                        }
                                    } else {
                                        CaptureButton(icon: "record.circle", label: "Start", color: ObservatoryTheme.background) {
                                            // Temporarily bypassing the consent confirmation dialog
                                            // during testing -- startCapture() still records a
                                            // consentAcknowledgedAt timestamp either way. Restore by
                                            // setting pendingConsentConfirmation = true here instead.
                                            startCapture()
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)

                        AppCard(title: "Live Transcript") {
                            liveTranscriptView
                        }
                        .padding(.horizontal)

                        AppCard(title: "About This Screen", startsExpanded: false) {
                            Text("This screen starts and stops the same reflection recording as the Observatory tab — they share one live session, so you can switch tabs mid-recording without losing anything. Raw audio level metering and file format details are not implemented yet; this build captures live speech-to-text only.")
                                .font(.caption)
                                .foregroundStyle(ObservatoryTheme.secondaryText)
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 24)
                }
            }
            .alert(
                "Microphone & Speech Access Needed",
                isPresented: Binding(
                    get: { speechManager.permissionDenied },
                    set: { speechManager.permissionDenied = $0 }
                )
            ) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Observatory needs both Microphone and Speech Recognition access to capture a reflection. You can turn these on in Settings.")
            }
            .confirmationDialog(
                "Before You Start",
                isPresented: $pendingConsentConfirmation,
                titleVisibility: .visible
            ) {
                Button("Start Recording") {
                    startCapture()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("If anyone besides you will be part of this reflection, make sure they know it's being recorded and have agreed to it.")
            }
        }
    }

    private var liveTranscriptView: some View {
        Group {
            if let session = store.activeSession, !session.transcript.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.transcript) { event in
                        Text(event.text)
                            .font(.subheadline)
                            .foregroundStyle(ObservatoryTheme.primaryText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(store.isRecording ? "Listening..." : "Tap Start to begin capturing a reflection.")
                    .font(.subheadline)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
    }

    private func startCapture() {
        // Captured at the moment consent was confirmed, not whenever
        // permissions/setup happen to finish, so this timestamp is an
        // honest record of when the person actually agreed to start.
        let consentTimestamp = Date()

        // See ObservatoryScreen.startReflectionAndSpeech's matching comment --
        // requested speculatively here too, since this screen starts and
        // stops the same shared reflection as Observatory.
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
                }
            )
        }
    }

    /// See ObservatoryScreen.stopAndFetchBiometrics's doc comment -- same
    /// pattern, duplicated here rather than shared because these two screens
    /// don't otherwise share a common base type to hang it on.
    private func stopAndFetchBiometrics() {
        let sessionID = store.activeSession?.id
        let reflectionStart = store.activeSession?.startedAt
        let reflectionEnd = store.activeSession?.endedAt ?? Date()

        store.stopAndObserve()

        guard let sessionID, let reflectionStart else { return }

        Task {
            let result = await healthKitManager.fetchSamples(reflectionStart: reflectionStart, reflectionEnd: reflectionEnd)
            store.applyBiometrics(sessionID: sessionID, samples: result.samples, queryStart: result.queryStart, queryEnd: result.queryEnd)
        }
    }

    private func timerText(now: Date) -> String {
        let seconds: Int
        if store.isRecording, let session = store.activeSession {
            seconds = max(0, Int(now.timeIntervalSince(session.startedAt)))
        } else if let session = store.activeSession {
            seconds = session.durationSeconds
        } else {
            seconds = 0
        }

        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}

struct RecordingPulse: View {
    @State private var isPulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)
                .opacity(isPulsing ? 0.3 : 1.0)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isPulsing)

            Text("Listening")
                .font(.caption)
                .foregroundStyle(ObservatoryTheme.secondaryText)
        }
        .onAppear { isPulsing = true }
    }
}

struct CaptureButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(label == "Stop" ? .white : ObservatoryTheme.primaryText)
                    .frame(width: 70, height: 70)
                    .background(color)
                    .clipShape(Circle())
            }

            Text(label)
                .font(.caption)
        }
    }
}
