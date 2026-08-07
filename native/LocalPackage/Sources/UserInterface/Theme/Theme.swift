import SwiftUI

// Port of src/lib/themes.ts — six accent palettes, each with a light and a
// dark mode. graphLight/graphDark are kept for the future 3D graph.

public extension Color {
    /// "#RRGGBB" hex initializer (the only form themes.ts uses).
    init(hex: String, opacity: Double = 1.0) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

public struct ThemeMode: Equatable, Sendable {
    public let accent: Color
    public let soft: Color
    public let chipBg: Color
    public let chipBorder: Color
    public let chipColor: Color
}

public struct ThemePalette: Identifiable, Equatable, Sendable {
    public let name: String
    public let light: ThemeMode
    public let dark: ThemeMode
    public let graphLight: Color
    public let graphDark: Color

    public var id: String { name }

    public func mode(for colorScheme: ColorScheme) -> ThemeMode {
        colorScheme == .dark ? dark : light
    }
}

public enum Themes {
    public static let all: [ThemePalette] = [
        ThemePalette(
            name: "Blue",
            light: ThemeMode(
                accent: Color(hex: "#007aff"),
                soft: Color(hex: "#007aff", opacity: 0.16),
                chipBg: Color(hex: "#007aff", opacity: 0.14),
                chipBorder: Color(hex: "#007aff", opacity: 0.28),
                chipColor: Color(hex: "#0a66d6")),
            dark: ThemeMode(
                accent: Color(hex: "#0a84ff"),
                soft: Color(hex: "#0a84ff", opacity: 0.22),
                chipBg: Color(hex: "#0a84ff", opacity: 0.22),
                chipBorder: Color(hex: "#0a84ff", opacity: 0.45),
                chipColor: Color(hex: "#6cb2ff")),
            graphLight: Color(hex: "#bfdbfe"),
            graphDark: Color(hex: "#1e3a8a")),
        ThemePalette(
            name: "Purple",
            light: ThemeMode(
                accent: Color(hex: "#af52de"),
                soft: Color(hex: "#af52de", opacity: 0.16),
                chipBg: Color(hex: "#af52de", opacity: 0.14),
                chipBorder: Color(hex: "#af52de", opacity: 0.30),
                chipColor: Color(hex: "#8a39c0")),
            dark: ThemeMode(
                accent: Color(hex: "#bf5af2"),
                soft: Color(hex: "#bf5af2", opacity: 0.24),
                chipBg: Color(hex: "#bf5af2", opacity: 0.22),
                chipBorder: Color(hex: "#bf5af2", opacity: 0.46),
                chipColor: Color(hex: "#d59bf6")),
            graphLight: Color(hex: "#e9d5ff"),
            graphDark: Color(hex: "#5b21b6")),
        ThemePalette(
            name: "Pink",
            light: ThemeMode(
                accent: Color(hex: "#ff2d55"),
                soft: Color(hex: "#ff2d55", opacity: 0.16),
                chipBg: Color(hex: "#ff2d55", opacity: 0.14),
                chipBorder: Color(hex: "#ff2d55", opacity: 0.30),
                chipColor: Color(hex: "#d62049")),
            dark: ThemeMode(
                accent: Color(hex: "#ff375f"),
                soft: Color(hex: "#ff375f", opacity: 0.24),
                chipBg: Color(hex: "#ff375f", opacity: 0.22),
                chipBorder: Color(hex: "#ff375f", opacity: 0.46),
                chipColor: Color(hex: "#ff8ea3")),
            graphLight: Color(hex: "#fbcfe8"),
            graphDark: Color(hex: "#9d174d")),
        ThemePalette(
            name: "Orange",
            light: ThemeMode(
                accent: Color(hex: "#ff9500"),
                soft: Color(hex: "#ff9500", opacity: 0.16),
                chipBg: Color(hex: "#ff9500", opacity: 0.16),
                chipBorder: Color(hex: "#ff9500", opacity: 0.32),
                chipColor: Color(hex: "#c97400")),
            dark: ThemeMode(
                accent: Color(hex: "#ff9f0a"),
                soft: Color(hex: "#ff9f0a", opacity: 0.24),
                chipBg: Color(hex: "#ff9f0a", opacity: 0.22),
                chipBorder: Color(hex: "#ff9f0a", opacity: 0.46),
                chipColor: Color(hex: "#ffc463")),
            graphLight: Color(hex: "#fed7aa"),
            graphDark: Color(hex: "#9a3412")),
        ThemePalette(
            name: "Green",
            light: ThemeMode(
                accent: Color(hex: "#34c759"),
                soft: Color(hex: "#34c759", opacity: 0.16),
                chipBg: Color(hex: "#34c759", opacity: 0.16),
                chipBorder: Color(hex: "#34c759", opacity: 0.32),
                chipColor: Color(hex: "#1d8939")),
            dark: ThemeMode(
                accent: Color(hex: "#30d158"),
                soft: Color(hex: "#30d158", opacity: 0.22),
                chipBg: Color(hex: "#30d158", opacity: 0.22),
                chipBorder: Color(hex: "#30d158", opacity: 0.46),
                chipColor: Color(hex: "#7fe698")),
            graphLight: Color(hex: "#bbf7d0"),
            graphDark: Color(hex: "#14532d")),
        ThemePalette(
            name: "Graphite",
            light: ThemeMode(
                accent: Color(hex: "#6e6e73"),
                soft: Color(hex: "#6e6e73", opacity: 0.14),
                chipBg: Color(hex: "#6e6e73", opacity: 0.12),
                chipBorder: Color(hex: "#6e6e73", opacity: 0.28),
                chipColor: Color(hex: "#3a3a3c")),
            dark: ThemeMode(
                accent: Color(hex: "#98989d"),
                soft: Color(hex: "#98989d", opacity: 0.22),
                chipBg: Color(hex: "#98989d", opacity: 0.18),
                chipBorder: Color(hex: "#98989d", opacity: 0.36),
                chipColor: Color(hex: "#d1d1d6")),
            graphLight: Color(hex: "#d1d5db"),
            graphDark: Color(hex: "#1f2937")),
    ]

    public static func theme(named name: String) -> ThemePalette {
        all.first { $0.name == name } ?? all[0]
    }
}
