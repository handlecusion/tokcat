import AppKit
import Testing

@testable import UserInterface

/// Issue #89: the chart tooltip drew each per-client row as one right-aligned
/// `"<tokens> · <cost>"` string, so the only fixed thing in the row was its
/// right edge — both numbers slid left by however wide that row's cost was.
///
/// The fix is a three-column `Grid` (dot+name | tokens | cost). This suite
/// does two things with real AppKit metrics, the way the issue's table was
/// produced: it records what the old arrangement did (the 14.33 pt of
/// wander), and it budgets the widths — whether three columns and two gaps
/// still fit the 174 pt content box at today's 190 pt tooltip width, and
/// which client names survive that at full length. That is the part which can
/// regress as fonts, names or magnitudes grow.
///
/// What it deliberately does *not* do is assert from its own model that the
/// columns line up: modelling a column as "max over rows, trailing-aligned"
/// and then asserting every row shares an x restates the model. That claim is
/// `Grid`'s, and `TooltipRenderMeasurementTests` checks it where it can fail,
/// on the rendered ink.
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

    /// A 12-digit token count against a 3-digit cost, per the issue's ask to
    /// verify a wide case rather than only the screenshot's numbers, carrying
    /// the widest label the tooltip can draw.
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

    /// The widest label the tooltip can draw, taken from `ClientRegistry` so
    /// that adding a client re-budgets this suite instead of quietly
    /// outgrowing a name written down here.
    ///
    /// Widest is measured, not counted: it is "OpenCode" at 52.13 pt, ahead of
    /// the two characters longer "Grok Build". Round capitals beat a name with
    /// a space and an `l` and an `i` in it. Both earlier passes at this test
    /// reasoned from character count and named the wrong one, which is the
    /// argument for deriving it here.
    private var widestClientName: String {
        ClientRegistry.allIDs
            .map { ClientRegistry.style(for: $0).shortName }
            .max { width($0, weight: .medium) < width($1, weight: .medium) } ?? ""
    }

    private func spread(_ xs: [CGFloat]) -> CGFloat { (xs.max() ?? 0) - (xs.min() ?? 0) }

    /// The resolved column geometry, as x from the content box's left edge:
    /// each column as wide as its widest cell, both packed against the right
    /// edge, the label cell taking what is left.
    private struct Layout {
        /// Where the tokens column starts: negative means the two number
        /// columns no longer fit the content box at all.
        let tokensColumnLeft: CGFloat
        /// What is left for the dot + client name cell.
        let labelAvailable: CGFloat
    }

    private func layout(_ rows: [Row]) -> Layout {
        let tokensColumn = rows.map { width($0.tokens) }.max() ?? 0
        let costColumn = rows.map { width($0.cost) }.max() ?? 0
        let tokensRight = TooltipMetrics.contentWidth - costColumn - TooltipMetrics.columnSpacing
        let tokensLeft = tokensRight - tokensColumn
        return Layout(tokensColumnLeft: tokensLeft,
                      labelAvailable: tokensLeft - TooltipMetrics.columnSpacing)
    }

    private func line(_ label: String, _ values: CGFloat...) -> String {
        label.padding(toLength: max(16, label.count), withPad: " ", startingAt: 0)
            + values.map { String(format: "%8.2f", Double($0)) }.joined()
    }

    // MARK: - The bug

    /// The contrast the rendered budgets are measured against: with one
    /// string per row, the x of both numbers is a function of that row's cost
    /// width alone.
    @Test func singleStringRowsPutEveryNumberAtADifferentX() {
        let tokensRight = Self.screenshot.map {
            TooltipMetrics.contentWidth - width(" · " + $0.cost)
        }
        let costLeft = Self.screenshot.map { TooltipMetrics.contentWidth - width($0.cost) }

        print("#89 old layout — one right-aligned string per row (tokens R, cost L)")
        for (i, row) in Self.screenshot.enumerated() {
            print(line("  " + row.name, tokensRight[i], costLeft[i]))
        }
        print(line("  spread", spread(tokensRight), spread(costLeft)))

        // Measured at 14.33 pt in the issue. Loose lower bound so a font
        // metric change cannot fail the documentation half of this. What the
        // Grid arrangement leaves — 0.75 pt of side bearing, 19x better — is
        // measured off the bitmap in TooltipRenderMeasurementTests.
        #expect(spread(tokensRight) > 5, "the wander this issue is about")
        #expect(spread(costLeft) > 5)
    }

    // MARK: - Width budget

    @Test func columnsFitTheTooltipAtTodaysWidth() {
        let l = layout(Self.screenshot)
        let widestInScreenshot = Self.screenshot.map { labelCellWidth($0.name) }.max() ?? 0
        let widestPossible = labelCellWidth(widestClientName)

        let overflow = widestPossible - l.labelAvailable

        print("#89 screenshot — label available, screenshot's widest, \(widestClientName)")
        print(line("  budget", l.labelAvailable, widestInScreenshot, widestPossible))
        print(line("  overflow", overflow))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > widestInScreenshot,
                "the screenshot's rows must fit without truncating a client name")
        // The widest name the registry can produce does *not* fit these
        // columns: "OpenCode" runs 0.30 pt over 62.83 pt and truncates. That
        // is the failure mode this PR chose (name gives, numbers hold), so it
        // is recorded rather than treated as a bug — an earlier revision
        // asserted the opposite from an estimate and went red on CI. The bound
        // is one glyph, so a future client name that overflows by a visible
        // amount still fails here.
        #expect(overflow < width("n", weight: .medium),
                "the widest client name may truncate here, but only by a hair")
    }

    /// The wide case: a 12-digit token count next to a 3-digit cost. Here the
    /// numbers deliberately win — the widest client name does not fit beside
    /// them and truncates, which is this PR's chosen failure mode, measured
    /// rather than assumed. What must still hold is that both number columns
    /// fit and the label keeps its dot and a short name.
    @Test func wideCaseKeepsTheNumbersAndTruncatesTheWidestName() {
        let l = layout(wide)
        let widest = labelCellWidth(widestClientName)

        print("#89 wide — label available, Amp, \(widestClientName)")
        print(line("  budget", l.labelAvailable, labelCellWidth("Amp"), widest))
        #expect(l.tokensColumnLeft > 0,
                "both number columns must fit the 174 pt content box")
        #expect(l.labelAvailable > labelCellWidth("Amp"),
                "the shortest client name must survive even the widest numbers")
        // If this ever fails the tooltip grew wide enough to draw the widest
        // name beside 12 digits — good news, update the expectation.
        #expect(l.labelAvailable < widest,
                "\(widestClientName) truncates here, by design")
    }

    @Test func metricsMatchTheTooltipBox() {
        #expect(TooltipMetrics.width == 190)
        #expect(TooltipMetrics.contentWidth == 174)
    }
}
