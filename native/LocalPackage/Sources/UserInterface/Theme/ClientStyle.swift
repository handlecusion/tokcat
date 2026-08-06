import SwiftUI

// Port of src/lib/clients.ts minus the SVG icons — until the drawn glyphs
// land, client marks are colored discs with the display name's initial.

public struct ClientStyle: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let color: Color

    /// Display name without the trailing CLI/Code/IDE qualifier, as the
    /// tabs/legends show it ("Claude Code" → "Claude").
    public var shortName: String {
        for suffix in [" CLI", " Code", " IDE"] where displayName.hasSuffix(suffix) {
            return String(displayName.dropLast(suffix.count))
        }
        return displayName
    }

    public var initial: String {
        displayName.first.map { String($0).uppercased() } ?? "?"
    }
}

public enum ClientRegistry {
    private static let entries: [String: (name: String, hex: String)] = [
        "claude": ("Claude Code", "#d97706"),
        "openclaw": ("OpenClaw", "#dc2626"),
        "gemini": ("Gemini CLI", "#60a5fa"),
        "opencode": ("OpenCode", "#1f2937"),
        "codex": ("Codex CLI", "#9ca3af"),
        "copilot": ("Copilot CLI", "#1f2937"),
        "cursor": ("Cursor IDE", "#0ea5e9"),
        "amp": ("Amp", "#10b981"),
        "droid": ("Droid", "#22c55e"),
        "hermes": ("Hermes", "#a78bfa"),
        "grok": ("Grok Build", "#111827"),
        "pi": ("Pi", "#f472b6"),
        "kimi": ("Kimi CLI", "#fbbf24"),
        "qwen": ("Qwen CLI", "#7c3aed"),
        "roocode": ("Roo Code", "#ef4444"),
        "kilocode": ("KiloCode", "#f97316"),
        "kilo": ("Kilo CLI", "#f59e0b"),
        "mux": ("Mux", "#06b6d4"),
        "crush": ("Crush", "#ec4899"),
        "synthetic": ("Synthetic", "#64748b"),
    ]

    public static func style(for id: String) -> ClientStyle {
        if let entry = entries[id] {
            return ClientStyle(id: id, displayName: entry.name,
                               color: Color(hex: entry.hex))
        }
        // Fallback: title-case the id, neutral grey disc.
        let displayName = id.prefix(1).uppercased() + id.dropFirst()
        return ClientStyle(id: id, displayName: displayName,
                           color: Color(hex: "#6b7280"))
    }
}
