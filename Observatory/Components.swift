import SwiftUI

struct AppCard<Content: View>: View {
    let title: String
    let content: Content
    @State private var isExpanded: Bool

    init(title: String, startsExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self._isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(ObservatoryTheme.primaryText)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(ObservatoryTheme.secondaryText)
                }
            }
            .buttonStyle(.plain)

            if isExpanded {
                content
            }
        }
        .padding()
        .background(ObservatoryTheme.card)
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(ObservatoryTheme.border.opacity(0.7)))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.04), radius: 10, x: 0, y: 4)
    }
}

struct MetricRow: View {
    let label: String
    let value: String
    var color: Color = ObservatoryTheme.secondaryText

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(ObservatoryTheme.primaryText)

            Spacer()

            Text(value)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

struct MiniLineChart: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { g in
            let minV = values.min() ?? 0
            let maxV = values.max() ?? 1
            let range = max(maxV - minV, 1)

            Path { p in
                for i in values.indices {
                    let x = g.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1))
                    let y = g.size.height - g.size.height * CGFloat((values[i] - minV) / range)

                    i == values.startIndex
                        ? p.move(to: CGPoint(x: x, y: y))
                        : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(color, lineWidth: 2)
        }
        .frame(height: 46)
    }
}

struct ScreenHeader: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.largeTitle)
                .bold()
                .foregroundStyle(ObservatoryTheme.primaryText)

            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(ObservatoryTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 12)
    }
}

struct SignalBadge: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)

            VStack(alignment: .leading) {
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(ObservatoryTheme.secondaryText)

                Text(value)
                    .font(.headline)
                    .foregroundStyle(color)
            }
        }
    }
}

extension Date {
    /// Normal user-facing time. Keeps seconds visible, but not milliseconds.
    var displayTime: String {
        Self.displayFormatter.string(from: self)
    }

    /// Developer/debug time. Keeps milliseconds visible for future audio/watch correlation testing.
    var debugTime: String {
        Self.debugFormatter.string(from: self)
    }

    /// Audit/export time. Uses ISO 8601 with fractional seconds.
    /// Useful later for SaMD-style audit trails, exports, validation, and event reconstruction.
    var auditTimeISO8601: String {
        Self.auditFormatter.string(from: self)
    }

    /// Existing app property. Now intentionally includes seconds.
    var shortTime: String {
        displayTime
    }

    /// Existing app property. Same as displayTime to keep all visible times consistent.
    var shortTimeWithSeconds: String {
        displayTime
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss a"
        return formatter
    }()

    private static let debugFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss.SSS a"
        return formatter
    }()

    private static let auditFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds
        ]
        return formatter
    }()
}

