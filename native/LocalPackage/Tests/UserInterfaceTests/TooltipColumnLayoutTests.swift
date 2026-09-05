import AppKit
import Testing

@testable import UserInterface

/// Issue #89: the chart tooltip drew each per-client row as one right-aligned
/// `"<tokens> · <cost>"` string, so the only fixed thing in the row was its
/// right edge — both numbers slid left by however wide that row's cost was.
///
/// The fix is a three-column `Grid` (dot+name | tokens | cost). `Grid` gives a
/// column the width of its widest cell and places every cell in it with the
/// column's alignment, so `Layout` below — column width = max over rows,
/// trailing-aligned, packed against the content box's right edge — is the
/// arrangement the view asks for.
///
/// This suite is the *width budget* only: whether three columns and two gaps
/// still fit the 174 pt content box at today's 190 pt tooltip width, for the
/// screenshot's rows and for a deliberately wide one, and which client names
/// survive that at full length. Asserting from `Layout` that the columns line
/// up would be circular — that claim is `Grid`'s to keep, and
/// `TooltipRenderMeasurementTests` checks it by rendering the real view and
/// measuring the ink.
///
/// Widths come from `NSAttributedString.size(withAttributes:)`, the way the
/// measurements in the issue were produced. Two places sum substring widths,
/// which ignores kerning across the join — good to a fraction of a point,
/// which is the resolution this budget needs.
@Suite struct TooltipColumnLayoutTests {
    private struct Row {
        let name: String
        let tokens: String
        let cost: String
    }

    /// The four rows in the issue's screenshot (Sep 5).
    private static let screenshot = [
        Row(name: "Aside", tokens: "599,788,471", cost: "$152.46"),
        Row(name: "Claude", tokens: "8,481,070", cost: "$20.22"),
        Row(name: "Codex", tokens: "4,092,946", cost: "$1.18"),
        Row(name: "Oh My Pi", tokens: "32,521,315", cost: "$21.24"),
    ]

    /// A 12-digit token count against a 3-digit cost, per the issue's ask to
    /// verify a wide case rather than only the screenshot's numbers, carrying
    /// the widest name the tooltip can draw.
    private var wide: [Row] {
        [
            Row(name: widestClientName, tokens: "999,999,999,999", cost: "$152.46"),
            Row(name: "Codex", tokens: "4,092,946", cost: "$1.18"),
        ]
    }

    // MARK: - Measurement

    private func width(_ string: String, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TooltipMetrics.segmentFontSize, weight: weight)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// Width the dot + client name cell wants before any truncation.
    private func labelCellWidth(_ name: String) -> CGFloat {
        TooltipMetrics.dotSize + TooltipMetrics.dotLabelSpacing + width(name, weight: .medium)
    }

    /// The widest label the tooltip can actually draw, derived from
    /// `ClientRegistry` so adding a client re-budgets this suite instead of
    /// silently outgrowing a hard-coded name. `shortName` strips only
    /// " CLI"/" Code"/" IDE", so today this is "Grok Build" — wider than
    /// "Synthetic", and wider than the longest *display* name.
    private var widestClientName: String {
        ClientRegistry.allIDs
            .map { ClientRegistry.style(for: $0).shortName }
            .max { width($0, weight: .medium) < width($1, weight: .medium) } ?? ""
    }

    /// The Grid arrangement, resolved for a set of rows. All x are measured
    /// from the left edge of the tooltip's content box.
    private struct Layout {
        let tokensColumnLeft: CGFloat
        let tokensColumnRight: CGFloat
        let costColumnLeft: CGFloat
        let costColumnRight: CGFloat
        /// What is left for the dot + client name cell.
        let labelAvailable: CGFloat
    }

    private func layout(_ rows: [Row]) -> Layout {
        let tokensColumn = rows.map { width($0.tokens) }.max() ?? 0
        let costColumn = rows.map { width($0.cost) }.max() ?? 0
        let costRight = TooltipMetrics.contentWidth
        let tokensRight = costRight - costColumn - TooltipMetrics.columnSpacing
        let tokensLeft = tokensRight - tokensColumn
        return Layout(tokensColumnLeft: tokensLeft,
                      tokensColumnRight: tokensRight,
                      costColumnLeft: costRight - costColumn,
                      costColumnRight: costRight,
                      labelAvailable: tokensLeft - TooltipMetrics.columnSpacing)
    }

    private func line(_ label: String, _ values: CGFloat...) -> String {
        label.padding(toLength: max(14, label.count), withPad: " ", startingAt: 0)
            + values.map { String(format: "%8.2f", Double($0)) }.joined()
    }

    // MARK: - The bug

    /// Documents the cause: with one string per row, the x of both numbers is
    /// a function of that row's cost width alone.
    @Test func singleStringRowsPutEveryNumberAtADifferentX() {
        var tokensRight: [CGFloat] = []
        var costLeft: [CGFloat] = []

        print("#89 old layout — one right-aligned string per row")
        print("                tokens R  cost L")
        for row in Self.screenshot {
            let right = TooltipMetrics.contentWidth - width(" · " + row.cost)
            let left = TooltipMetrics.contentWidth - width(row.cost)
            tokensRight.append(right)
            costLeft.append(left)
            print(line(row.name, right, left))
        }

        let tokensSpread = (tokensRight.max() ?? 0) - (tokensRight.min() ?? 0)
        let costSpread = (costLeft.max() ?? 0) - (costLeft.min() ?? 0)
        print(line("spread", tokensSpread, costSpread))

        // Measured at 14.33 pt in the issue. Asserted loosely so a future
        // font-metric change cannot fail this bit of documentation.
        #expect(tokensSpread > 5, "the wander this issue is about")
        #expect(costSpread > 5)
    }

    // MARK: - The width budget

    @Test func columnsFitTheTooltipAtTodaysWidth() {
        let l = layout(Self.screenshot)
        let widestInScreenshot = Self.screenshot.map { labelCellWidth($0.name) }.max() ?? 0
        let widestInRegistry = labelCellWidth(widestClientName)

        print("#89 screenshot columns — available \(String(format: "%.2f", l.labelAvailable)) pt for the label")
        print(line("screenshot", widestInScreenshot))
        print(line(widestClientName, widestInRegistry))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > widestInScreenshot,
                "the screenshot's rows must fit without truncating a client name")
        // Not the screenshot's names but the registry's: this is what the fix
        // changed the failure mode of, so it is worth locking the margin.
        #expect(l.labelAvailable > widestInRegistry,
                "the widest name ClientRegistry can draw (\(widestClientName)) must fit the screenshot's columns")
    }

    /// The wide case: a 12-digit token count next to a 3-digit cost. Both
    /// number columns still fit, and what gives is the name — measured here
    /// rather than assumed, because that is the trade the fix chose.
    @Test func wideCaseKeepsTheNumbersAndTruncatesTheName() {
        let l = layout(wide)
        let widest = labelCellWidth(widestClientName)
        let dotAndEllipsis = TooltipMetrics.dotSize + TooltipMetrics.dotLabelSpacing
            + width("…", weight: .medium)

        print(line("#89 wide", widest, l.labelAvailable))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > dotAndEllipsis,
                "the label cell keeps its dot and at least an ellipsis")
        // The numbers win: at this width the widest name cannot be drawn in
        // full and truncates with `.truncationMode(.tail)`. If this ever
        // fails, the tooltip grew wide enough to hold it — update the
        // expectation, nothing is broken.
        #expect(l.labelAvailable < widest,
                "\(widestClientName) truncates in the wide case, by design")
    }

    @Test func metricsMatchTheTooltipBox() {
        #expect(TooltipMetrics.width == 190)
        #expect(TooltipMetrics.contentWidth == 174)
    }
}
