import AppKit
import Testing

@testable import UserInterface

/// Issue #89: the chart tooltip drew each per-client row as one right-aligned
/// `"<tokens> · <cost>"` string, so the only fixed thing in the row was its
/// right edge — both numbers slid left by however wide that row's cost was.
///
/// The fix is a three-column `Grid` (dot+name | tokens | cost). This suite
/// models the two arrangements over the same rows and measures both with real
/// AppKit metrics, the way the issue's table was produced: `singleStringXs`
/// is what the view drew before, `columnXs` is what it asks `Grid` for now.
/// Asserting the old spread is wide and the new one is zero is the only
/// formulation that ties an assertion to the change; the rest of the suite
/// budgets the widths, which is the part that can regress as fonts, names or
/// magnitudes grow. What no measurement here can settle is whether `Grid`
/// hands the horizontal slack to the label cell — that is verification 2, in
/// the running app.
///
/// Two places sum substring widths, which ignores kerning across the join —
/// good to a fraction of a point, the resolution this budget needs.
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

    /// The widest label the tooltip can draw. `ClientStyle.shortName` strips
    /// only `" CLI" / " Code" / " IDE"`, so `grok`'s "Grok Build" survives
    /// whole and beats "Synthetic", "OpenClaw", "OpenCode", "KiloCode" and
    /// "Oh My Pi".
    private static let widestClientName = "Grok Build"

    /// A 12-digit token count against a 3-digit cost, per the issue's ask to
    /// verify a wide case rather than only the screenshot's numbers.
    private static let wide = [
        Row(name: widestClientName, tokens: "999,999,999,999", cost: "$152.46"),
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

    private func spread(_ xs: [CGFloat]) -> CGFloat { (xs.max() ?? 0) - (xs.min() ?? 0) }

    /// Where each row's numbers landed under the old arrangement: one
    /// right-aligned string, so both numbers are pushed left by that row's
    /// own cost width and by nothing else.
    private func singleStringXs(_ rows: [Row]) -> (tokensRight: [CGFloat], costLeft: [CGFloat]) {
        (rows.map { TooltipMetrics.contentWidth - width(" · " + $0.cost) },
         rows.map { TooltipMetrics.contentWidth - width($0.cost) })
    }

    /// Where each row's numbers land under the `Grid` arrangement: a column
    /// as wide as its widest cell, every cell in it trailing-aligned, both
    /// columns packed against the content box's right edge.
    private func columnXs(_ rows: [Row]) -> (tokensRight: [CGFloat], costLeft: [CGFloat]) {
        let l = layout(rows)
        return (rows.map { _ in l.tokensColumnRight }, rows.map { _ in l.costColumnLeft })
    }

    /// The resolved column geometry, as x from the content box's left edge.
    private struct Layout {
        let tokensColumnLeft: CGFloat
        let tokensColumnRight: CGFloat
        let costColumnLeft: CGFloat
        /// What is left for the dot + client name cell.
        let labelAvailable: CGFloat
    }

    private func layout(_ rows: [Row]) -> Layout {
        let tokensColumn = rows.map { width($0.tokens) }.max() ?? 0
        let costColumn = rows.map { width($0.cost) }.max() ?? 0
        let tokensRight = TooltipMetrics.contentWidth - costColumn - TooltipMetrics.columnSpacing
        let tokensLeft = tokensRight - tokensColumn
        return Layout(tokensColumnLeft: tokensLeft,
                      tokensColumnRight: tokensRight,
                      costColumnLeft: TooltipMetrics.contentWidth - costColumn,
                      labelAvailable: tokensLeft - TooltipMetrics.columnSpacing)
    }

    private func line(_ label: String, _ values: CGFloat...) -> String {
        label.padding(toLength: max(16, label.count), withPad: " ", startingAt: 0)
            + values.map { String(format: "%8.2f", Double($0)) }.joined()
    }

    // MARK: - The fix, against the bug

    /// The assertion this PR exists for: over the same rows, the old
    /// arrangement puts every number at its own x and the new one puts them
    /// all at a single x per column.
    @Test func theColumnsCollapseTheWanderToZero() {
        for (label, rows) in [("screenshot", Self.screenshot), ("wide", Self.wide)] {
            let old = singleStringXs(rows)
            let new = columnXs(rows)

            print("#89 \(label) — per-row x (tokens right, cost left):")
            for (i, row) in rows.enumerated() {
                print(line("  " + row.name, old.tokensRight[i], old.costLeft[i],
                           new.tokensRight[i], new.costLeft[i]))
            }
            print(line("  spread old/new",
                       spread(old.tokensRight), spread(old.costLeft),
                       spread(new.tokensRight), spread(new.costLeft)))

            // Measured at 14.33 pt in the issue. Loose lower bound so a font
            // metric change cannot fail the documentation half of this.
            #expect(spread(old.tokensRight) > 5, "the wander this issue is about")
            #expect(spread(old.costLeft) > 5)
            #expect(spread(new.tokensRight) == 0)
            #expect(spread(new.costLeft) == 0)

            // And the columns have to actually fit to reach those x — this is
            // the half that can regress.
            let l = layout(rows)
            #expect(l.tokensColumnLeft > 0)
            #expect(l.labelAvailable > 0)
        }
    }

    // MARK: - Width budget

    @Test func columnsFitTheTooltipAtTodaysWidth() {
        let l = layout(Self.screenshot)
        let widestInScreenshot = Self.screenshot.map { labelCellWidth($0.name) }.max() ?? 0
        let widestPossible = labelCellWidth(Self.widestClientName)

        print(line("#89 screenshot", l.labelAvailable, widestInScreenshot, widestPossible))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > widestInScreenshot,
                "the screenshot's rows must fit without truncating a client name")
        #expect(l.labelAvailable > widestPossible,
                "so must the widest name ClientRegistry can produce")
    }

    /// The wide case: a 12-digit token count next to a 3-digit cost. Here the
    /// numbers deliberately win — `"Grok Build"` does not fit beside them and
    /// truncates, which is this PR's chosen failure mode. What must still
    /// hold is that both number columns fit and the label keeps its dot and a
    /// short name.
    @Test func wideCaseStillFitsBothNumberColumns() {
        let l = layout(Self.wide)

        print(line("#89 wide", l.labelAvailable,
                   labelCellWidth("Amp"), labelCellWidth(Self.widestClientName)))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > labelCellWidth("Amp"),
                "the shortest client name must survive even the widest numbers")
    }

    @Test func metricsMatchTheTooltipBox() {
        #expect(TooltipMetrics.width == 190)
        #expect(TooltipMetrics.contentWidth == 174)
    }
}
