import AppKit
import Model
import SceneKit
import simd
import SwiftUI

// SceneKit port of the render/interaction core of
// src/components/ContributionGraph3D.tsx: a 53×7 grid of extruded boxes on
// an orthographic orbit camera, with custom drag/scroll/pinch controls
// (allowsCameraControl is deliberately OFF) and hover hit-testing.

// What the SwiftUI layer needs to draw a tooltip: the hovered cell plus the
// cursor location in SwiftUI (top-left origin) coordinates of the wrap.
struct GraphHover: Equatable {
    var date: String
    var tokens: Int64
    var cost: Double
    var location: CGPoint
}

// Command proxy so the SwiftUI Fit/Reset buttons can reach the coordinator.
@MainActor
final class GraphCameraController {
    var fit: (() -> Void)?
    var reset: (() -> Void)?
}

struct ContributionSceneView: NSViewRepresentable {
    let grid: Model.GridLayout
    let graphLight: Color
    let graphDark: Color
    let controller: GraphCameraController
    let loadPose: () -> OrbitPose?
    let savePose: (OrbitPose) -> Void
    let clearPose: () -> Void
    let onHover: (GraphHover?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveSCNView {
        let view = InteractiveSCNView(frame: .zero, options: nil)
        context.coordinator.attach(view: view)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: InteractiveSCNView, context: Context) {
        let c = context.coordinator
        c.savePose = savePose
        c.clearPose = clearPose
        c.loadPose = loadPose
        c.onHover = onHover
        controller.fit = { [weak c] in c?.fitView(persist: true) }
        controller.reset = { [weak c] in c?.resetView() }
        c.rebuildIfNeeded(grid: grid,
                          light: NSColor(graphLight),
                          dark: NSColor(graphDark))
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        // Mirrors the tsx constants.
        static let cell: CGFloat = 1
        static let gap: CGFloat = 0.15
        static let step: CGFloat = cell + gap
        static let baseHeight: CGFloat = 0.05
        static let maxHeight: CGFloat = 4.0
        static let minScale: Double = 1.5   // ≈ three.js maxZoom 80
        static let maxScale: Double = 120   // ≈ three.js minZoom 1
        static let orbitSpeed: Double = 0.012
        static let defaultAzimuth = Double.pi / 4
        // atan2(0.45, 0.7·√2) — the tsx default camera diagonal.
        static let defaultElevation = atan2(0.45, 0.7 * 2.0.squareRoot())

        var savePose: ((OrbitPose) -> Void)?
        var clearPose: (() -> Void)?
        var loadPose: (() -> OrbitPose?)?
        var onHover: ((GraphHover?) -> Void)?

        private weak var view: InteractiveSCNView?
        private let scene = SCNScene()
        private let barsNode = SCNNode()
        private let rigNode = SCNNode()      // pan target (OrbitControls target)
        private let yawNode = SCNNode()
        private let pitchNode = SCNNode()
        private let cameraNode = SCNNode()

        private var pose = OrbitPose(
            azimuth: Coordinator.defaultAzimuth,
            elevation: Coordinator.defaultElevation,
            scale: 40, panX: 0, panY: 0, panZ: 0)
        private var didInitialFit = false

        private var cellByNode: [ObjectIdentifier: GridCell] = [:]
        private var builtGrid: Model.GridLayout?
        private var builtLight: NSColor?
        private var builtDark: NSColor?
        // Active-cell footprints for fitView: (x, z, height).
        private var activeBoxes: [(x: CGFloat, z: CGFloat, height: CGFloat)] = []
        private var totalWidth: CGFloat = 0
        private var totalDepth: CGFloat = 0

        func attach(view: InteractiveSCNView) {
            self.view = view
            view.scene = scene
            view.backgroundColor = .clear
            view.antialiasingMode = .multisampling4X
            view.rendersContinuously = false
            view.preferredFramesPerSecond = 60
            view.allowsCameraControl = false

            let camera = SCNCamera()
            camera.usesOrthographicProjection = true
            camera.automaticallyAdjustsZRange = true
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0, 150)
            pitchNode.addChildNode(cameraNode)
            yawNode.addChildNode(pitchNode)
            rigNode.addChildNode(yawNode)
            scene.rootNode.addChildNode(rigNode)
            scene.rootNode.addChildNode(barsNode)
            view.pointOfView = cameraNode
            addLights()

            if let saved = loadPose?() {
                pose = clamped(saved)
                didInitialFit = true
            }
            applyPose()

            view.onOrbit = { [weak self] dx, dy in self?.orbit(dx: dx, dy: dy) }
            view.onPan = { [weak self] dx, dy in self?.pan(dx: dx, dy: dy) }
            view.onZoom = { [weak self] factor in self?.zoom(by: factor) }
            view.onHoverPoint = { [weak self] point in self?.hover(at: point) }
            view.onFirstLayout = { [weak self] in
                guard let self, !self.didInitialFit else { return }
                self.didInitialFit = true
                self.fitView(persist: false)
            }
        }

        // MARK: Lights (ambient 0.7 + two directionals, as in the tsx)

        private func addLights() {
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.color = NSColor(white: 0.7, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            for (position, brightness) in [
                (SCNVector3(20, 30, 15), 0.8),
                (SCNVector3(-15, 20, -10), 0.25),
            ] {
                let node = SCNNode()
                node.light = SCNLight()
                node.light?.type = .directional
                node.light?.color = NSColor(white: brightness, alpha: 1)
                node.position = position
                node.look(at: SCNVector3(0, 0, 0))
                scene.rootNode.addChildNode(node)
            }
        }

        // MARK: Grid geometry

        func rebuildIfNeeded(grid: Model.GridLayout, light: NSColor, dark: NSColor) {
            guard grid != builtGrid || light != builtLight || dark != builtDark
            else { return }
            builtGrid = grid
            builtLight = light
            builtDark = dark

            barsNode.childNodes.forEach { $0.removeFromParentNode() }
            cellByNode.removeAll()
            activeBoxes.removeAll()

            totalWidth = CGFloat(grid.cols) * Self.step
            totalDepth = CGFloat(grid.rows) * Self.step
            let offsetX = -totalWidth / 2
            let offsetZ = -totalDepth / 2
            let maxTokens = Double(max(grid.maxTokens, 1))

            // All inactive in-year cells share one geometry (same height,
            // same colors); active cells get per-cell boxes.
            let inactiveGeometry = boxGeometry(
                height: Self.baseHeight,
                top: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                side: NSColor(srgbRed: 0xEA / 255, green: 0xED / 255,
                              blue: 0xF2 / 255, alpha: 1))
            let srgbLight = light.usingColorSpace(.sRGB) ?? light
            let srgbDark = dark.usingColorSpace(.sRGB) ?? dark

            for cell in grid.cells {
                guard cell.inYear else { continue }  // tsx renders nothing
                let x = offsetX + CGFloat(cell.col) * Self.step + Self.step / 2
                let z = offsetZ + CGFloat(cell.row) * Self.step + Self.step / 2

                let node: SCNNode
                var height = Self.baseHeight
                if cell.active {
                    let ratio = Double(cell.tokens) / maxTokens
                    height = Self.baseHeight
                        + CGFloat(pow(ratio, 0.6)) * Self.maxHeight
                    let t = min(1, max(0, pow(ratio, 0.5)))
                    let top = lerp(srgbLight, srgbDark, t)
                    node = SCNNode(geometry: boxGeometry(
                        height: height, top: top, side: darken(top, 0.78)))
                    cellByNode[ObjectIdentifier(node)] = cell
                    activeBoxes.append((x: x, z: z, height: height))
                } else {
                    node = SCNNode(geometry: inactiveGeometry)
                }
                node.position = SCNVector3(x, height / 2, z)
                barsNode.addChildNode(node)
            }
        }

        /// A CELL×height×CELL box with a lighter top face than the sides
        /// (SCNBox material order: front, right, back, left, top, bottom).
        private func boxGeometry(height: CGFloat, top: NSColor,
                                 side: NSColor) -> SCNBox {
            let box = SCNBox(width: Self.cell, height: height,
                             length: Self.cell, chamferRadius: 0)
            let sideMaterial = flatMaterial(side)
            box.materials = [
                sideMaterial, sideMaterial, sideMaterial, sideMaterial,
                flatMaterial(top), sideMaterial,
            ]
            return box
        }

        private func flatMaterial(_ color: NSColor) -> SCNMaterial {
            let m = SCNMaterial()
            m.lightingModel = .lambert
            m.diffuse.contents = color
            m.locksAmbientWithDiffuse = true
            return m
        }

        private func lerp(_ a: NSColor, _ b: NSColor, _ t: Double) -> NSColor {
            NSColor(srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
                    green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                    blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
                    alpha: 1)
        }

        private func darken(_ c: NSColor, _ factor: Double) -> NSColor {
            NSColor(srgbRed: c.redComponent * factor,
                    green: c.greenComponent * factor,
                    blue: c.blueComponent * factor, alpha: 1)
        }

        // MARK: Camera pose

        private func applyPose() {
            rigNode.position = SCNVector3(pose.panX, pose.panY, pose.panZ)
            yawNode.eulerAngles = SCNVector3(0, pose.azimuth, 0)
            pitchNode.eulerAngles = SCNVector3(-pose.elevation, 0, 0)
            cameraNode.camera?.orthographicScale = pose.scale
        }

        private func clamped(_ p: OrbitPose) -> OrbitPose {
            var p = p
            // Keep elevation shy of the poles so orbiting never flips.
            p.elevation = min(max(p.elevation, -1.53), 1.53)
            p.scale = min(max(p.scale, Self.minScale), Self.maxScale)
            return p
        }

        private func poseChanged() {
            pose = clamped(pose)
            applyPose()
            savePose?(pose)
        }

        /// Camera-space basis in world coordinates for the current angles.
        private func cameraBasis(azimuth: Double, elevation: Double)
            -> (right: simd_double3, up: simd_double3)
        {
            let q = simd_quatd(angle: azimuth, axis: [0, 1, 0])
                * simd_quatd(angle: -elevation, axis: [1, 0, 0])
            return (q.act([1, 0, 0]), q.act([0, 1, 0]))
        }

        // MARK: Interaction

        private func orbit(dx: CGFloat, dy: CGFloat) {
            pose.azimuth -= Double(dx) * Self.orbitSpeed
            pose.elevation += Double(dy) * Self.orbitSpeed
            poseChanged()
        }

        private func pan(dx: CGFloat, dy: CGFloat) {
            guard let view, view.bounds.height > 0 else { return }
            // World units per screen point at the current zoom.
            let perPoint = 2 * pose.scale / Double(view.bounds.height)
            let basis = cameraBasis(azimuth: pose.azimuth,
                                    elevation: pose.elevation)
            let move = basis.right * (-Double(dx) * perPoint)
                + basis.up * (Double(dy) * perPoint)
            pose.panX += move.x
            pose.panY += move.y
            pose.panZ += move.z
            poseChanged()
        }

        private func zoom(by factor: CGFloat) {
            pose.scale *= Double(factor)
            poseChanged()
        }

        // MARK: Fit / Reset (ports the spirit of the tsx fitView)

        func fitView(persist: Bool) {
            pose.azimuth = Self.defaultAzimuth
            pose.elevation = Self.defaultElevation
            pose.panX = 0
            pose.panY = 0
            pose.panZ = 0

            // Frame the active bars when any exist; fall back to the full
            // grid AABB (matches the tsx comment about the empty future).
            var corners: [simd_double3] = []
            if !activeBoxes.isEmpty {
                let half = Double(Self.cell) / 2
                for box in activeBoxes {
                    for dx in [-half, half] {
                        for dz in [-half, half] {
                            for y in [0.0, Double(box.height)] {
                                corners.append([Double(box.x) + dx, y,
                                                Double(box.z) + dz])
                            }
                        }
                    }
                }
            } else {
                let hx = Double(totalWidth) / 2
                let hz = Double(totalDepth) / 2
                for sx in [-hx, hx] {
                    for sz in [-hz, hz] {
                        for sy in [0.0, Double(Self.maxHeight)] {
                            corners.append([sx, sy, sz])
                        }
                    }
                }
            }
            guard !corners.isEmpty else { return }

            let basis = cameraBasis(azimuth: pose.azimuth,
                                    elevation: pose.elevation)
            var minX = Double.infinity, maxX = -Double.infinity
            var minY = Double.infinity, maxY = -Double.infinity
            for c in corners {
                let sx = simd_dot(c, basis.right)
                let sy = simd_dot(c, basis.up)
                minX = min(minX, sx); maxX = max(maxX, sx)
                minY = min(minY, sy); maxY = max(maxY, sy)
            }

            let padding = 0.85
            let halfW = max((maxX - minX) / 2, 0.0001)
            let halfH = max((maxY - minY) / 2, 0.0001)
            var aspect = 1.0
            if let view, view.bounds.height > 0 {
                aspect = Double(view.bounds.width / view.bounds.height)
            }
            // orthographicScale is the visible half-height in world units.
            pose.scale = max(halfH, halfW / max(aspect, 0.0001)) / padding

            // Re-center the rig (the orbit target) on the AABB center.
            let center = basis.right * ((minX + maxX) / 2)
                + basis.up * ((minY + maxY) / 2)
            pose.panX = center.x
            pose.panY = center.y
            pose.panZ = center.z

            if persist {
                poseChanged()
            } else {
                pose = clamped(pose)
                applyPose()
            }
        }

        func resetView() {
            clearPose?()
            fitView(persist: true)
        }

        // MARK: Hover

        private func hover(at point: CGPoint?) {
            guard let view, let point else {
                onHover?(nil)
                return
            }
            let hits = view.hitTest(point, options: [
                .boundingBoxOnly: true,
                .searchMode: SCNHitTestSearchMode.closest.rawValue,
            ])
            // Only active bars are in the map, so base tiles clear the
            // tooltip just like the tsx (inactive pointerOver does nothing).
            guard let node = hits.first?.node,
                  let cell = cellByNode[ObjectIdentifier(node)]
            else {
                onHover?(nil)
                return
            }
            // SCNView is bottom-left origin; SwiftUI overlays are top-left.
            let location = CGPoint(x: point.x,
                                   y: view.bounds.height - point.y)
            onHover?(GraphHover(date: cell.date, tokens: cell.tokens,
                                cost: cell.cost, location: location))
        }
    }
}

// SCNView subclass owning the raw AppKit input: left-drag orbits,
// option/right/middle-drag pans, scroll & pinch zoom, mouseMoved drives the
// hover hit-test through an NSTrackingArea.
final class InteractiveSCNView: SCNView {
    var onOrbit: ((CGFloat, CGFloat) -> Void)?
    var onPan: ((CGFloat, CGFloat) -> Void)?
    /// Multiplier applied to orthographicScale (>1 zooms out).
    var onZoom: ((CGFloat) -> Void)?
    /// Cursor location in view coords (bottom-left origin); nil on exit.
    var onHoverPoint: ((CGPoint?) -> Void)?
    var onFirstLayout: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var didFirstLayout = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = hoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways,
                      .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func layout() {
        super.layout()
        if !didFirstLayout, bounds.width > 0, bounds.height > 0 {
            didFirstLayout = true
            onFirstLayout?()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onHoverPoint?(nil)
        if event.modifierFlags.contains(.option) {
            onPan?(event.deltaX, event.deltaY)
        } else {
            onOrbit?(event.deltaX, event.deltaY)
        }
    }

    override func rightMouseDragged(with event: NSEvent) {
        onHoverPoint?(nil)
        onPan?(event.deltaX, event.deltaY)
    }

    override func otherMouseDragged(with event: NSEvent) {
        onHoverPoint?(nil)
        onPan?(event.deltaX, event.deltaY)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY
            : event.scrollingDeltaY * 10
        guard dy != 0 else { return }
        // Scroll up = zoom in (smaller orthographicScale).
        onZoom?(exp(-dy * 0.01))
    }

    override func magnify(with event: NSEvent) {
        let denominator = 1 + event.magnification
        guard denominator > 0.01 else { return }
        onZoom?(1 / denominator)
    }

    override func mouseMoved(with event: NSEvent) {
        onHoverPoint?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onHoverPoint?(nil)
    }
}
