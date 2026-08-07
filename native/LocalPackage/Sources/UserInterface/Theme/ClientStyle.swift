import AppKit
import SwiftUI

// Port of src/lib/clients.ts. Clients with a bundled SVG glyph get a drawn
// mark (see ClientIconView); the rest keep the colored disc with the display
// name's initial.

/// Mirrors `IconType` in clients.ts: 'mono' icons are single-color glyphs we
/// tint white over the brand-color disc; 'full' icons carry their own design
/// (background + colors) and fill the disc as-is.
public enum ClientIconType: Sendable {
    case mono
    case full
}

public struct ClientStyle: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let color: Color
    public let iconType: ClientIconType?

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
    private static let entries: [String: (name: String, hex: String, icon: ClientIconType?)] = [
        "claude": ("Claude Code", "#d97706", .mono),
        "openclaw": ("OpenClaw", "#dc2626", nil),
        "gemini": ("Gemini CLI", "#60a5fa", .mono),
        "opencode": ("OpenCode", "#1f2937", .full),
        "codex": ("Codex CLI", "#9ca3af", .full),
        "copilot": ("Copilot CLI", "#1f2937", .mono),
        "cursor": ("Cursor IDE", "#0ea5e9", .mono),
        "amp": ("Amp", "#10b981", .mono),
        "droid": ("Droid", "#22c55e", .full),
        "hermes": ("Hermes", "#a78bfa", nil),
        "grok": ("Grok Build", "#111827", .mono),
        "pi": ("Pi", "#f472b6", .mono),
        "kimi": ("Kimi CLI", "#fbbf24", nil),
        "qwen": ("Qwen CLI", "#7c3aed", .mono),
        "roocode": ("Roo Code", "#ef4444", nil),
        "kilocode": ("KiloCode", "#f97316", .full),
        "kilo": ("Kilo CLI", "#f59e0b", nil),
        "mux": ("Mux", "#06b6d4", nil),
        "crush": ("Crush", "#ec4899", nil),
        "synthetic": ("Synthetic", "#64748b", .full),
    ]

    public static func style(for id: String) -> ClientStyle {
        if let entry = entries[id] {
            // iconType is the registry's claim; ClientIconView still falls
            // back to the initial-letter disc when the SVG asset is missing
            // or fails to load.
            return ClientStyle(id: id, displayName: entry.name,
                               color: Color(hex: entry.hex), iconType: entry.icon)
        }
        // Fallback: title-case the id, neutral grey disc.
        let displayName = id.prefix(1).uppercased() + id.dropFirst()
        return ClientStyle(id: id, displayName: displayName,
                           color: Color(hex: "#6b7280"), iconType: nil)
    }
}

/// Loads the brand SVGs bundled with UserInterface (copies of
/// src/assets/agent-icons/*.svg). macOS 13's NSImage reads SVG natively;
/// images are cached because the marks re-render on every payload tick.
@MainActor
public enum ClientIconAssets {
    private static var cache: [String: NSImage?] = [:]

    public static func image(for id: String) -> NSImage? {
        if let cached = cache[id] { return cached }
        let loaded = load(id: id)
        cache[id] = loaded
        return loaded
    }

    private static func load(id: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: id, withExtension: "svg", subdirectory: "AgentIcons"
        ) else { return nil }
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        return image
    }
}
