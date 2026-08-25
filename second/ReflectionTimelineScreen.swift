import SwiftUI

/// Reflection history now lives on the Observatory tab as an expandable
/// list, so this tab no longer shows it (that used to duplicate the same
/// content across two tabs). Kept as its own tab, as a placeholder, until
/// it's repurposed for something new.
struct ReflectionTimelineScreen: View {
    var body: some View {
        NavigationStack {
            ZStack {
                ObservatoryTheme.background.ignoresSafeArea()

                VStack(spacing: 16) {
                    Spacer()

                    Image(systemName: "hourglass")
                        .font(.system(size: 56))
                        .foregroundStyle(ObservatoryTheme.secondaryText)

                    Text("Coming Soon")
                        .font(.title2)
                        .bold()
                        .foregroundStyle(ObservatoryTheme.primaryText)

                    Text("This tab is being reworked into something new. Your reflection history now lives on the Observatory tab.")
                        .font(.subheadline)
                        .foregroundStyle(ObservatoryTheme.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    Spacer()
                }
            }
            .navigationTitle("Timeline")
        }
    }
}
