import Foundation
import Testing

@testable import Model

// Port of tray.rs's tray-anchor resolution semantics: a status-item frame
// only anchors the panel when it sits inside some screen's menu-bar band;
// hidden/overflowed items (parked off-screen by AppKit — the notch-MacBook
// left-edge bug) must resolve to nil so show() takes the top-right fallback.
@MainActor
@Suite struct PanelAnchorTests {
    // 2560×1440 primary + notched 1512×982 laptop to its left.
    private let primary = NSRect(x: 0, y: 0, width: 2560, height: 1440)
    private let laptop = NSRect(x: -1512, y: -458, width: 1512, height: 982)
    private var frames: [NSRect] { [primary, laptop] }

    private func item(x: CGFloat, topInset: CGFloat, on screen: NSRect) -> NSRect {
        NSRect(x: x, y: screen.maxY - topInset - 22, width: 30, height: 22)
    }

    @Test func itemInPrimaryMenuBarResolves() {
        let rect = item(x: 2300, topInset: 1, on: primary)
        #expect(TrayPanelController.menuBarScreenIndex(for: rect, screenFrames: frames) == 0)
    }

    @Test func itemInLaptopMenuBarResolvesToLaptop() {
        let rect = item(x: -300, topInset: 8, on: laptop)  // taller notch menu bar
        #expect(TrayPanelController.menuBarScreenIndex(for: rect, screenFrames: frames) == 1)
    }

    @Test func offscreenParkedItemResolvesNil() {
        // AppKit parks hidden/overflowed status items far off-screen.
        let rect = NSRect(x: -8000, y: 10_000, width: 30, height: 22)
        #expect(TrayPanelController.menuBarScreenIndex(for: rect, screenFrames: frames) == nil)
    }

    @Test func midScreenRectResolvesNil() {
        // In a screen's x-range but nowhere near the menu-bar band.
        let rect = NSRect(x: 1200, y: 700, width: 30, height: 22)
        #expect(TrayPanelController.menuBarScreenIndex(for: rect, screenFrames: frames) == nil)
    }

    @Test func zeroWidthRectResolvesNil() {
        let rect = NSRect(x: 2300, y: primary.maxY - 23, width: 0, height: 22)
        #expect(TrayPanelController.menuBarScreenIndex(for: rect, screenFrames: frames) == nil)
    }

    @Test func bandToleranceMatchesRust() {
        // -4pt above the top edge and 2×24pt below are still in the band
        // (tray.rs: (-4.0..=MENU_BAR_H * 2).contains(below_top)).
        let slightlyAbove = NSRect(x: 100, y: primary.maxY - 22 + 4, width: 30, height: 22)
        #expect(TrayPanelController.menuBarScreenIndex(for: slightlyAbove, screenFrames: frames) == 0)
        let deep = NSRect(x: 100, y: primary.maxY - 22 - 48, width: 30, height: 22)
        #expect(TrayPanelController.menuBarScreenIndex(for: deep, screenFrames: frames) == 0)
        let tooDeep = NSRect(x: 100, y: primary.maxY - 22 - 49, width: 30, height: 22)
        #expect(TrayPanelController.menuBarScreenIndex(for: tooDeep, screenFrames: frames) == nil)
    }
}
