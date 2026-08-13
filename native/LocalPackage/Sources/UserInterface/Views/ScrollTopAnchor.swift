import AppKit
import SwiftUI

// Forces the tray panel's scroll view back to the top.
//
// The panel sizes itself to the dashboard's natural height, so a tab switch
// (or reopening the panel on a different tab) swaps in content of a different
// height and resizes the window underneath a clip view that keeps its old
// bounds origin. The result is the reported bug: the header and tab strip are
// scrolled out of sight and an equally tall empty band sits at the bottom —
// on content that isn't even scrollable any more.
//
// ScrollViewReader.scrollTo cannot fix that on its own: it runs in the same
// update pass that reports the new ContentHeightKey, and the AppKit window
// resize that follows re-applies the stale origin. So reach the underlying
// NSScrollView and clamp it directly, once now and once after the resize has
// landed.
struct ScrollTopAnchor: NSViewRepresentable {
    /// Any value change re-runs the reset (the active tab, in practice).
    var trigger: AnyHashable

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.lastTrigger = trigger
        context.coordinator.scheduleReset(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        context.coordinator.scheduleReset(from: view)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var lastTrigger: AnyHashable?

        /// Two passes: the first lands after SwiftUI's current update, the
        /// second after the panel has resized to the new content height.
        func scheduleReset(from view: NSView) {
            DispatchQueue.main.async { [weak view] in
                Self.scrollToTop(from: view)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak view] in
                    Self.scrollToTop(from: view)
                }
            }
        }

        private static func scrollToTop(from view: NSView?) {
            guard let scrollView = view?.enclosingScrollView else { return }
            let clip = scrollView.contentView
            // SwiftUI's document view is flipped, so the top is y == 0.
            let top = clip.documentView?.isFlipped == false
                ? (clip.documentView?.frame.height ?? 0) - clip.bounds.height
                : 0
            guard abs(clip.bounds.origin.y - top) > 0.5 else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: top))
            scrollView.reflectScrolledClipView(clip)
        }
    }
}
