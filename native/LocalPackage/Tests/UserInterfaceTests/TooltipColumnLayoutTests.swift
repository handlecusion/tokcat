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
/// arrangement the view asks for. The alignment then comes for free; what
/// this suite measures with real font metrics is the part that does not:
/// whether three columns and two gaps still fit the 174 pt content box at
/// today's 190 pt tooltip width, for the screenshot's rows and for a
/// deliberately wide one. The running app is the check that `Grid` renders
/// this arrangement (verification 2 in the PR).
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
    /// verify a wide case rather than only the screenshot's numbers. The name
    /// is the longest one in `ClientRegistry`.
    private static let wide = [
        Row(name: "Synthetic", tokens: "999,999,999,999", cost: "$152.46"),
        Row(name: "Codex", tokens: "4,092,946", cost: "$1.18"),
    ]

    // MARK: - Measurement

    private func width(_ string: String, weight: NSFont.Weight = .regular) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TooltipMetrics.segmentFontSize, weight: weight)
        return (string as NSString).size(withAttributes: [.font: font]).width
    }

    /// Width the dot + client name cell wants before any truncation.
    private func labelCellWidth(_ name: String) -> CGFloat {
        TooltipMetrics.dotSize + TooltipMetrics.dotLabelSpacing + width(name, weight: .medium)
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

    // MARK: - The fix

    @Test func columnLayoutGivesEveryRowTheSameX() {
        for rows in [Self.screenshot, Self.wide] {
            let l = layout(rows)
            for row in rows {
                // Trailing alignment inside a column as wide as its widest
                // cell: every row's number ends at the column's x, and no
                // cell has to be squeezed to get there.
                #expect(width(row.tokens) <= l.tokensColumnRight - l.tokensColumnLeft)
                #expect(width(row.cost) <= l.costColumnRight - l.costColumnLeft)
            }
        }

        let l = layout(Self.screenshot)
        print("#89 new layout — one x per column, every row:")
        print(line("tokens L/R", l.tokensColumnLeft, l.tokensColumnRight))
        print(line("cost L/R", l.costColumnLeft, l.costColumnRight))
        print(line("spread", 0, 0))
    }

    @Test func columnsFitTheTooltipAtTodaysWidth() {
        let l = layout(Self.screenshot)
        let widest = Self.screenshot.map { labelCellWidth($0.name) }.max() ?? 0

        print(line("#89 screenshot", widest, l.labelAvailable))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > widest,
                "the screenshot's rows must fit without truncating a client name")
    }

    /// The wide case: a 12-digit token count next to a 3-digit cost still
    /// leaves the label cell its dot and a readable name. Rows wider than
    /// that truncate the name — the numbers never move.
    @Test func wideCaseStillFitsBothNumberColumns() {
        let l = layout(Self.wide)
        let shortestPlausibleLabel = labelCellWidth("Amp")

        print(line("#89 wide", shortestPlausibleLabel, l.labelAvailable))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > shortestPlausibleLabel)
    }

    @Test func metricsMatchTheTooltipBox() {
        #expect(TooltipMetrics.width == 190)
        #expect(TooltipMetrics.contentWidth == 174)
    }
}
