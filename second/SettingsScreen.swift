import SwiftUI

struct SettingsScreen: View {
    @EnvironmentObject private var store: ReflectionSessionStore
    @EnvironmentObject private var healthKitManager: HealthKitManager

    @State private var exportURL: URL?
    @State private var pendingDeleteAllConfirmation = false

    var body: some View {
        NavigationStack {
            ZStack {
                ObservatoryTheme.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        ScreenHeader(title: "Settings", subtitle: "Privacy, data, and future integrations")

                        AppCard(title: "Data Mode") {
                            VStack(spacing: 10) {
                                MetricRow(label: "Current build", value: "iPhone-only")
                                MetricRow(label: "Watch integration", value: "Planned")
                                MetricRow(label: "HealthKit", value: healthKitStatusText)
                                MetricRow(label: "Cloud sync", value: "Off")
                                MetricRow(label: "Storage", value: "Local-first")

                                if healthKitManager.isHealthDataAvailable && !healthKitManager.isAuthorized {
                                    Button {
                                        Task { await healthKitManager.requestAuthorization() }
                                    } label: {
                                        Label("Grant Health Access", systemImage: "heart.text.square")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)

                        AppCard(title: "Your Data") {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("Export includes every reflection's transcript, observations, and consent/provenance metadata as JSON. Raw audio recordings are not included in the export file.")
                                    .font(.caption)
                                    .foregroundStyle(ObservatoryTheme.secondaryText)

                                if let exportURL {
                                    ShareLink(item: exportURL) {
                                        Label("Share Export File", systemImage: "square.and.arrow.up")
                                    }
                                } else {
                                    Button {
                                        exportURL = store.exportAllReflectionsJSON()
                                    } label: {
                                        Label("Prepare Export", systemImage: "doc.text")
                                    }
                                    .disabled(store.completedSessions.isEmpty)
                                }

                                Divider()

                                Button(role: .destructive) {
                                    pendingDeleteAllConfirmation = true
                                } label: {
                                    Label("Delete All Reflections & Audio", systemImage: "trash")
                                }
                                .disabled(store.completedSessions.isEmpty)
                            }
                        }
                        .padding(.horizontal)

                        AppCard(title: "Architecture Notes") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("HealthKit backfill (heart rate, HRV, respiratory rate) is implemented -- HealthKitManager, engine v\(HealthKitManager.engineVersion). Each reflection's real time window is queried after Stop & Observe and attached to that reflection's Body Signals.")
                                Text("Live biometric data during a recording should still come from Apple Watch using HKLiveWorkoutBuilder -- not implemented; this build has no watchOS target yet.")
                                Text("WatchConnectivity should send source timestamps, not arrival timestamps, once the live path exists.")
                                Text("Sleep and workout metrics are also still planned -- they're HealthKit category/workout samples, not point-in-time vitals, so they need their own normalized model rather than reusing BiometricSample as-is.")
                            }
                            .font(.caption)
                            .foregroundStyle(ObservatoryTheme.secondaryText)
                        }
                        .padding(.horizontal)

                        AppCard(title: "Security") {
                            VStack(spacing: 10) {
                                MetricRow(label: "HIPAA compliant", value: "No")
                                MetricRow(label: "Medical diagnosis", value: "No")
                                MetricRow(label: "Camera capture", value: "No")
                                MetricRow(label: "Data export", value: "Available")
                                MetricRow(label: "Delete all data", value: "Available")
                            }
                        }
                        .padding(.horizontal)
                    }
                    .padding(.bottom, 24)
                }
            }
            .confirmationDialog(
                "Delete All Data",
                isPresented: $pendingDeleteAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Everything", role: .destructive) {
                    store.deleteAllData()
                    exportURL = nil
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes every saved reflection and its audio recording. This can't be undone.")
            }
        }
    }

    private var healthKitStatusText: String {
        if !healthKitManager.isHealthDataAvailable {
            return "Unavailable on this device"
        } else if healthKitManager.isAuthorized {
            // HealthKit never reveals per-type grant/deny status to the
            // requesting app (see HealthKitManager.isAuthorized's doc
            // comment) -- "Access requested," not "Connected," since this
            // app genuinely can't tell whether every type was granted.
            return "Access requested"
        } else if healthKitManager.authorizationUnavailable {
            return "Request failed"
        } else {
            return "Not connected"
        }
    }
}
