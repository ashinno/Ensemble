import SwiftUI

/// Dark modular theme (matches the "Modular v3" design canvas).
enum Theme {
    static let bg = Color(red: 0.039, green: 0.039, blue: 0.039)        // #0a0a0a
    static let card = Color(red: 0.075, green: 0.075, blue: 0.075)      // #131313
    static let cardRaised = Color(red: 0.090, green: 0.090, blue: 0.090)
    static let border = Color(red: 0.122, green: 0.122, blue: 0.122)    // #1f1f1f
    static let borderStrong = Color(red: 0.165, green: 0.165, blue: 0.165)
    static let text = Color(red: 0.925, green: 0.925, blue: 0.925)      // #ececec
    static let title = Color(red: 0.66, green: 0.66, blue: 0.66)        // #a8a8a8
    static let dim = Color(red: 0.48, green: 0.48, blue: 0.48)          // #7a7a7a
    static let label = Color(red: 0.42, green: 0.42, blue: 0.42)        // #6a6a6a
    static let stroke = Color(red: 0.83, green: 0.83, blue: 0.83)       // #d4d4d4
    static let strokeDim = Color(red: 0.35, green: 0.35, blue: 0.35)
    static let ledIdle = Color(red: 0.23, green: 0.23, blue: 0.23)
    static let pending = Color(red: 1.0, green: 0.70, blue: 0.28)       // amber, never an accent preset

    static let cardRadius: CGFloat = 16
    static let gap: CGFloat = 12
    static let cardHeight: CGFloat = 186

    struct Preset: Identifiable {
        let id: String
        let name: String
        var color: Color { Color(hex: id) }
    }

    static let accentPresets: [Preset] = [
        Preset(id: "FF4D1F", name: "Orange"),
        Preset(id: "39FF88", name: "Phosphor"),
        Preset(id: "5EF2FF", name: "Cyan"),
        Preset(id: "FF7AE0", name: "Magenta")
    ]

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
    static func sans(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
}

extension Color {
    init(hex: String) {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: h).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// Accent colour, persisted; read through the environment.
private struct AccentKey: EnvironmentKey { static let defaultValue = Color(hex: "FF4D1F") }
extension EnvironmentValues {
    var accent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}
