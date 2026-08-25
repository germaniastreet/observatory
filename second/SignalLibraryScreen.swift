import SwiftUI

struct SignalLibraryScreen: View {
    @StateObject private var registry = SignalLibraryRegistry()
    @State private var exportedJSONPreview: String = ""

    var body: some View {
        ZStack {
            ObservatoryTheme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    ScreenHeader(
                        title: "Signal Libraries",
                        subtitle: "Persistent local rule store"
                    )

                    AppCard(title: "Persistent Store", startsExpanded: true) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Signal libraries now persist locally on this device. The default Observatory Cognitive Core library is seeded into storage on first launch.")
                                .font(.subheadline)

                            Text("This is the first database-like foundation. Future versions can add import/export UI, authoring tools, validation, moderation, and third-party libraries.")
                                .font(.caption)
                                .foregroundStyle(ObservatoryTheme.secondaryText)

                            HStack {
                                Button("Export Preview") {
                                    exportedJSONPreview = exportPreview()
                                }

                                Spacer()

                                Button("Reset Defaults") {
                                    registry.resetToDefaults()
                                    exportedJSONPreview = ""
                                }
                            }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)

                    ForEach(registry.libraries) { library in
                        AppCard(title: library.name, startsExpanded: true) {
                            VStack(alignment: .leading, spacing: 12) {
                                Toggle(
                                    "Enabled",
                                    isOn: Binding(
                                        get: { library.isEnabledByDefault },
                                        set: { registry.setLibraryEnabled(id: library.id, isEnabled: $0) }
                                    )
                                )

                                MetricRow(label: "Library ID", value: library.id)
                                MetricRow(label: "Version", value: library.version)
                                MetricRow(label: "Author", value: "\(library.author) / \(library.authorType.rawValue)")
                                MetricRow(label: "Domain", value: library.domain.rawValue)
                                MetricRow(label: "Rules", value: "\(library.rules.count)")

                                Text(library.description)
                                    .font(.caption)
                                    .foregroundStyle(ObservatoryTheme.secondaryText)

                                Divider()

                                Text("Rules")
                                    .font(.subheadline)
                                    .bold()

                                ForEach(library.rules) { rule in
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(rule.name)
                                            .font(.caption)
                                            .bold()

                                        Text("\(rule.id) • \(rule.matchType.rawValue)")
                                            .font(.caption2)
                                            .foregroundStyle(ObservatoryTheme.secondaryText)

                                        Text("Event: \(rule.title)")
                                            .font(.caption2)
                                            .foregroundStyle(ObservatoryTheme.secondaryText)

                                        Text("Phrases: \(rule.phrases.prefix(5).joined(separator: ", "))")
                                            .font(.caption2)
                                            .foregroundStyle(ObservatoryTheme.secondaryText)
                                            .lineLimit(2)

                                        Text("Confidence: \(rule.confidence.rawValue.capitalized)")
                                            .font(.caption2)
                                            .foregroundStyle(ObservatoryTheme.secondaryText)
                                    }

                                    Divider()
                                }
                            }
                        }
                        .padding(.horizontal)
                    }

                    if !exportedJSONPreview.isEmpty {
                        AppCard(title: "Export Preview") {
                            Text(exportedJSONPreview)
                                .font(.caption2.monospaced())
                                .foregroundStyle(ObservatoryTheme.secondaryText)
                                .lineLimit(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal)
                    }

                    AppCard(title: "v114 Scope") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Implemented")
                                .font(.subheadline)
                                .bold()

                            Text("• Local persistent signal-library store")
                            Text("• First-launch seeding of default library")
                            Text("• Detection reads from persisted enabled libraries")
                            Text("• Enable/disable library control")
                            Text("• Export preview for inspection")

                            Text("Not yet implemented")
                                .font(.subheadline)
                                .bold()
                                .padding(.top, 6)

                            Text("• Import file picker")
                            Text("• Remote sync")
                            Text("• Library marketplace")
                            Text("• Clinical library validation")
                            Text("• Full migration of every detector")
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Libraries")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func exportPreview() -> String {
        do {
            let data = try registry.exportJSON()
            return String(data: data, encoding: .utf8) ?? "Unable to render JSON."
        } catch {
            return "Export failed: \(error.localizedDescription)"
        }
    }
}
