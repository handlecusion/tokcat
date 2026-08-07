// NOTICE: The CALayer animation technique in this file (CAKeyframeAnimation
// on "contents" with .discrete calculation, mask-layer template tinting, and
// the CALayer.speed time-rebase in setSpeed) is ported from RunCatNeo
// (RunnerLayer.swift) by Takuto Nakamura (Kyome22), Copyright 2026
// Takuto Nakamura, licensed under the Apache License, Version 2.0:
// http://www.apache.org/licenses/LICENSE-2.0
//
// Deviations from RunCatNeo:
//   - Frames are always template masks here (Tokcat ships alpha-only frame
//     PNGs), so the non-template branch (animating self.contents directly)
//     is dropped: the tint always lives in backgroundColor, masked by the
//     animated maskLayer.
//   - No BackgroundLayer / static-icon erase; the animateTray=off and
//     refresh-freeze states just pin the mask to the first frame.
//   - Adds the Tokcat refresh bounce (half-sine transform.translation.y,
//     period 0.42s, amplitude 5pt — mirrors spawn_bounce_loop in
//     src-tauri/src/lib.rs) and the RunCat-style load→speed mapping from
//     src-tauri/src/animation.rs.

import AppKit
import QuartzCore

// Animated menubar glyph. Sits as a sublayer of the NSStatusBarButton's
// backing layer inside the button's (empty placeholder) image rect. The
// layer's backgroundColor is the tint; the animated maskLayer punches the
// cat/parrot silhouette out of it, so appearance changes are a single
// setTint call — no per-frame recoloring.
//
// Main-thread only (CALayer + AppKit); not @MainActor because CALayer's
// designated initializers are nonisolated and Core Animation instantiates
// presentation copies via init(layer:).
public final class RunnerLayer: CALayer {
    /// At speed 1.0 a frame swap every 500ms — mirrors animation.rs's base
    /// interval (500ms / speed).
    public static let baseSecondsPerFrame: Double = 0.5
    /// Refresh bounce: one half-sine hop per period (lib.rs PERIOD_MS=420,
    /// AMPLITUDE_PX=5).
    static let bouncePeriod: Double = 0.42
    static let bounceAmplitude: Double = 5.0

    private static let runKey = "running"
    private static let bounceKey = "bounce"

    private let maskLayer = CALayer()
    private var frames: [NSImage] = []
    private var animating = true
    private var refreshing = false
    private var currentSpeed: Float = 1.0

    public override init() {
        super.init()
        contentsScale = 2.0
        maskLayer.contentsGravity = .center
        maskLayer.contentsScale = 2.0
        mask = maskLayer
    }

    // Core Animation creates presentation-tree copies through init(layer:)
    // whenever this layer itself animates (the bounce does).
    public override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API (main thread only)

    /// Swap the frame set (cat ↔ parrot). The mask layer's local time base
    /// (speed) is preserved so the switch doesn't glitch the pace; only the
    /// loop restarts, which is invisible for a cyclic run animation.
    public func setFrames(_ frames: [NSImage]) {
        self.frames = frames
        applyRunning()
    }

    /// true → run the frame loop; false → freeze on the first frame
    /// (animateTray off). Mirrors animation.rs, which pins idx 0 when
    /// animation is disabled rather than hiding the glyph.
    public func setAnimating(_ animating: Bool) {
        guard self.animating != animating else { return }
        self.animating = animating
        applyRunning()
    }

    /// While refreshing the spin freezes on frame 0 and the layer bobs with
    /// a repeating half-sine hop, exactly like the Rust animation/bounce
    /// loop pair.
    public func setRefreshing(_ refreshing: Bool) {
        guard self.refreshing != refreshing else { return }
        self.refreshing = refreshing
        applyRunning()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if refreshing {
            let bounce = CAKeyframeAnimation(keyPath: "transform.translation.y")
            let samples = 24
            // NSStatusBarButton's backing layer is flipped (origin top-left),
            // so negative y moves the glyph up — a real hop.
            bounce.values = (0...samples).map {
                -Self.bounceAmplitude * sin(.pi * Double($0) / Double(samples))
            }
            bounce.duration = Self.bouncePeriod
            bounce.calculationMode = .linear
            bounce.repeatCount = .infinity
            add(bounce, forKey: Self.bounceKey)
        } else {
            removeAnimation(forKey: Self.bounceKey)
        }
        CATransaction.commit()
    }

    /// Rebase the mask layer's local time so a speed change continues from
    /// the current frame instead of jumping (RunCatNeo's setSpeed).
    public func setSpeed(_ speed: Float) {
        guard currentSpeed != speed else { return }
        currentSpeed = speed
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.timeOffset = maskLayer.convertTime(CACurrentMediaTime(), from: nil)
        maskLayer.beginTime = CACurrentMediaTime()
        maskLayer.speed = speed
        CATransaction.commit()
    }

    /// RunCat-style load→speed mapping ported from animation.rs /
    /// AppState::current_load: load = min(100, rate/10_000);
    /// speed = max(1, load/5) — idle 2fps, full load 40fps.
    public func setRate(tokensPerMin: Double) {
        let load = min(100.0, max(0.0, tokensPerMin / 10_000.0))
        setSpeed(Float(max(1.0, load / 5.0)))
    }

    /// Tint (template) color; pass the resolved textColor for the button's
    /// effective appearance.
    public func setTint(_ color: CGColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backgroundColor = color
        CATransaction.commit()
    }

    // MARK: - Internals

    /// (Re)install the frame loop on the mask layer, or pin it to the first
    /// frame when the loop shouldn't run.
    private func applyRunning() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        maskLayer.frame = bounds
        maskLayer.removeAnimation(forKey: Self.runKey)
        if animating && !refreshing && frames.count > 1 {
            maskLayer.contents = nil
            let animation = CAKeyframeAnimation(keyPath: "contents")
            animation.values = frames
            animation.calculationMode = .discrete
            animation.duration = Double(frames.count) * Self.baseSecondsPerFrame
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            maskLayer.add(animation, forKey: Self.runKey)
            maskLayer.timeOffset = .zero
            maskLayer.beginTime = .zero
            maskLayer.speed = currentSpeed
        } else {
            maskLayer.speed = 1.0
            maskLayer.timeOffset = .zero
            maskLayer.beginTime = .zero
            maskLayer.contents = frames.first
        }
        CATransaction.commit()
    }
}
