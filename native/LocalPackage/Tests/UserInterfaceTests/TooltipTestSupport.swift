import AppKit

@testable import UserInterface

/// Shared by the tooltip's two suites so "the widest name the registry can
/// draw" has exactly one definition. Both suites budget against it — one from
/// AppKit metrics, one from the rendered bitmap — and a disagreement between
/// them is a finding, not a fixture drift.
enum TooltipTestSupport {
    static func width(_ string: String, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TooltipMetrics.segmentFontSize, weight: weight)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// Width the dot + client name cell wants before any truncation: the dot,
    /// the one `HStack` gap after it, and the name. There is no trailing gap —
    /// the name itself is the cell's flexible element, so this is the whole
    /// cell, which is the correction that made this budget agree with the
    /// render (a trailing `Spacer` used to add a second 5 pt gap the model
    /// never counted).
    static func labelCellWidth(_ name: String) -> CGFloat {
        TooltipMetrics.dotSize + TooltipMetrics.dotLabelSpacing + width(name, weight: .medium)
    }

    /// The widest label the tooltip can draw, taken from `ClientRegistry` so
    /// that adding a client re-budgets both suites instead of quietly
    /// outgrowing a name written down here.
    ///
    /// Widest is measured, not counted: "OpenCode" at 52.13 pt, ahead of the
    /// two characters longer "Grok Build". Round capitals beat a name with a
    /// space, an `l` and an `i` in it. Two earlier passes at this reasoned from
    /// character count and named the wrong one, which is the argument for
    /// deriving it. The tests print whichever it is.
    static var widestClientName: String {
        ClientRegistry.allIDs
            .map { ClientRegistry.style(for: $0).shortName }
            .max { width($0, weight: .medium) < width($1, weight: .medium) } ?? ""
    }
}
