import AppKit
import SwiftUI
import Testing

@testable import UserInterface

/// Issue #89, the check that can actually fail: render `TooltipSegmentRows` —
/// the view the tooltip draws, not a copy of it — with `ImageRenderer` and
/// read each column's right edge off the bitmap.
///
/// Method (the owner's, reproduced): render the rows at scale 8 inside the
/// tooltip's own box (`.padding(8).frame(width: 190)`), once per column with
/// the other two at `.opacity(0)` so each column's ink is unambiguous —
/// opacity changes no cell's size, so the columns measured are the ones the
/// app lays out. Every row then occupies its own horizontal band of the
/// bitmap, and the band's rightmost inked pixel is that row's right edge.
///
/// Measured on macOS 15 for the screenshot's four rows, x relative to the
/// 174 pt content box:
///
///     cost   173.12 173.12 173.12 173.12   spread 0.000
///     tokens 127.12 127.62 127.75 127.88   spread 0.750
///
/// Those x's were read with `TooltipMetrics.columnSpacing` at 6; it is 5 now
/// (the widest client name did not fit the label cell at 6), so the tokens
/// column sits one point further right — ~128.1 — while the cost column, which
/// is flush against the content box, does not move. Both budgets below are on
/// the spread within a column, so neither is affected; the run prints the x's.
///
/// The 0.75 pt on the tokens column is not misalignment: SF's digits are
/// proportional, so a number ending in `1` leaves more right side bearing
/// than one ending in `6`. The advances are aligned; the ink is ragged by
/// under a point. The single-string layout this replaced wandered 14.33 pt
/// (`TooltipColumnLayoutTests.singleStringRowsPutEveryNumberAtADifferentX`),
/// so the budgets below are ~19x tighter than the bug.
///
/// The suite is tied to the shipping view, not to a copy of it:
/// `TooltipSegmentRows` lives in `UsageBarChart.swift`, so reverting that file
/// takes the type with it and this stops compiling; putting the old
/// one-string-per-row layout back while keeping the type re-introduces the
/// wander and blows the budgets.
@Suite struct TooltipRenderMeasurementTests {
    /// 8x, so one pixel is 0.125 pt — an order finer than the budgets.
    private static let scale: CGFloat = 8

    /// The four rows in the issue's screenshot (Sep 5).
    private static let screenshot = [
        TooltipSegmentRows.Row(id: "aside", name: "Aside",
                               tokens: "599,788,471", cost: "$152.46", color: .black),
        TooltipSegmentRows.Row(id: "claude", name: "Claude",
                               tokens: "8,481,070", cost: "$20.22", color: .black),
        TooltipSegmentRows.Row(id: "codex", name: "Codex",
                               tokens: "4,092,946", cost: "$1.18", color: .black),
        TooltipSegmentRows.Row(id: "omp", name: "Oh My Pi",
                               tokens: "32,521,315", cost: "$21.24", color: .black),
    ]

    // MARK: - The measurements

    @MainActor
    @Test func renderedNumberColumnsShareOneRightEdge() throws {
        let tokens = try rightEdges(of: .tokens)
        let cost = try rightEdges(of: .cost)

        print("#89 rendered at \(Int(Self.scale))x, x from the content box's left edge")
        print(row("tokens", tokens))
        print(row("cost", cost))

        #expect(tokens.count == Self.screenshot.count,
                "expected one ink band per row in the tokens column, got \(tokens.count)")
        #expect(cost.count == Self.screenshot.count,
                "expected one ink band per row in the cost column, got \(cost.count)")

        // 14.33 pt of wander before the fix. What is left is side bearing.
        #expect(spread(tokens) <= 1.0,
                "tokens column spread \(fmt(spread(tokens))) pt")
        #expect(spread(cost) <= 0.3,
                "cost column spread \(fmt(spread(cost))) pt")
    }

    /// The other half of the fix: `Grid` hands the slack to the label cell —
    /// the one that ends in `Spacer(minLength: 0)` — so the number columns sit
    /// against the content box's right edge, where the total row's cost above
    /// them already is. If the slack went to the number columns instead, the
    /// columns would still agree with each other but the block would be
    /// left-shifted with a gap on the right. Measured at 173.12 of 174.
    @MainActor
    @Test func costColumnSitsAgainstTheContentBoxRightEdge() throws {
        let full = try rightEdges(of: nil)
        let right = try #require(full.max())

        print("#89 full render — ink right edge \(fmt(right)) of \(fmt(TooltipMetrics.contentWidth)) pt")
        #expect(TooltipMetrics.contentWidth - right <= 1.5,
                "the rows must be flush right, not left-shifted with a gap")
    }

    // MARK: - Rendering and pixel measurement

    /// Right edge of every ink band, in points from the content box's left
    /// edge, for a render showing only `column` (all three when `nil`).
    @MainActor
    private func rightEdges(of column: TooltipSegmentRows.Column?) throws -> [CGFloat] {
        let content = TooltipSegmentRows(rows: Self.screenshot, inkedColumn: column)
            .padding(TooltipMetrics.padding)
            .frame(width: TooltipMetrics.width)
        let renderer = ImageRenderer(content: content)
        renderer.scale = Self.scale
        let image = try #require(renderer.cgImage, "ImageRenderer produced no bitmap")
        return Self.inkBandRightEdges(image)
    }

    /// Scans the bitmap top to bottom for bands of inked pixel rows and
    /// returns each band's rightmost ink, converted to points relative to the
    /// content box. With one column showing, a band is exactly one row.
    private static func inkBandRightEdges(_ image: CGImage) -> [CGFloat] {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return [] }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base, width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }

        // Alpha over ~12 %: past the antialiasing haze at a glyph's edge.
        // Every column is read with the same threshold, so whatever it shaves
        // off one row's edge it shaves off all of them — and these tests
        // compare rows of one column against each other.
        let threshold: UInt8 = 32
        var edges: [CGFloat] = []
        var bandRight: Int?

        for y in 0..<h {
            var rowRight: Int?
            var x = w - 1
            while x >= 0 {
                if pixels[(y * w + x) * 4 + 3] >= threshold {
                    rowRight = x
                    break
                }
                x -= 1
            }
            switch (rowRight, bandRight) {
            case let (right?, current):
                bandRight = max(current ?? 0, right)
            case (nil, let current?):
                // Blank pixel row: the band ended.
                edges.append(point(current))
                bandRight = nil
            case (nil, nil):
                continue
            }
        }
        if let bandRight {
            edges.append(point(bandRight))
        }
        return edges
    }

    /// Far side of pixel column `x`, in points from the content box's left edge.
    private static func point(_ x: Int) -> CGFloat {
        CGFloat(x + 1) / scale - TooltipMetrics.padding
    }

    // MARK: - Reporting

    private func spread(_ values: [CGFloat]) -> CGFloat {
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }

    private func fmt(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func row(_ label: String, _ values: [CGFloat]) -> String {
        label.padding(toLength: max(8, label.count), withPad: " ", startingAt: 0)
            + values.map { String(format: "%8.2f", Double($0)) }.joined()
            + "   spread " + fmt(spread(values))
    }
}
