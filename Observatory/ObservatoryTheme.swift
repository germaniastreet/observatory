import SwiftUI

enum ObservatoryTheme {
    static let background = Color(red: 0.92, green: 0.91, blue: 0.89)
    static let card = Color.white
    static let border = Color(red: 0.84, green: 0.82, blue: 0.78)
    static let primaryText = Color(red: 0.08, green: 0.10, blue: 0.14)
    static let secondaryText = Color(red: 0.40, green: 0.39, blue: 0.36)
    static let heartRate = Color(hex: "#2E4B83")
    static let respiration = Color(hex: "#50A154")
    static let hrv = Color(hex: "#3070C7")
    static let gold = Color(hex: "#FDC731")
    static let amber = Color(hex: "#DC731C")
}

extension Color {
    init(hex: String) {
        let cleaned = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }
}
