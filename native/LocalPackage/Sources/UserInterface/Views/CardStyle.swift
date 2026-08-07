import SwiftUI

// Translucent card treatment over the panel's vibrancy, mirroring the
// --card / --card-border variables in src/styles.css.

struct CardBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    var cornerRadius: CGFloat = 14

    private var fill: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 58 / 255, green: 58 / 255, blue: 60 / 255, opacity: 0.65)
            : Color.white.opacity(0.78)
    }

    private var border: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
    }
}

extension View {
    func cardBackground(cornerRadius: CGFloat = 14) -> some View {
        modifier(CardBackground(cornerRadius: cornerRadius))
    }
}

// Section heading inside a card (".usage-heading" / ".streaks-heading").
struct CardHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

enum NumberText {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()

    /// `toLocaleString('en-US')` equivalent for exact token counts.
    static func exactTokens(_ n: Int64) -> String {
        grouped.string(from: NSNumber(value: n)) ?? String(n)
    }
}
