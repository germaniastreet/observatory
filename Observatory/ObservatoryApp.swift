import SwiftUI

@main
struct ObservatoryApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // ObservatoryTheme's colors are fixed RGB values, not adaptive
                // system colors, so the app was only ever designed for light
                // mode. Locking the scheme here prevents default-colored
                // text (e.g. transcript rows with no explicit foregroundStyle)
                // from silently flipping to white-on-white in system dark mode.
                .preferredColorScheme(.light)
        }
    }
}
