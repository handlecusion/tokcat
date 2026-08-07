import Model
import SwiftUI

// SwiftUI shell of src/components/ContributionGraph3D.tsx: hosts the
// SceneKit canvas, the Fit/Reset buttons (top-right), and the hover tooltip
// that follows the cursor at +12/+12.
struct ContributionGraph3D: View {
    let grid: Model.GridLayout
    let graphLight: Color
    let graphDark: Color
    let accent: Color

    @EnvironmentObject private var store: DashboardStore
    @State private var hover: GraphHover?
    @State private var controller = GraphCameraController()

    private static let tooltipWidth: CGFloat = 150

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topTrailing) {
                ContributionSceneView(
                    grid: grid,
                    graphLight: graphLight,
                    graphDark: graphDark,
                    controller: controller,
                    loadPose: { store.loadOrbitPose() },
                    savePose: { store.saveOrbitPose($0) },
                    clearPose: { store.clearOrbitPose() },
                    onHover: { hover = $0 })

                HStack(spacing: 6) {
                    cameraButton("Fit", color: accent) { controller.fit?() }
                    cameraButton("Reset", color: .secondary) {
                        controller.reset?()
                    }
                }
                .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if let hover {
                    tooltip(hover)
                        .offset(
                            x: min(hover.location.x + 12,
                                   geo.size.width - Self.tooltipWidth - 4),
                            y: min(hover.location.y + 12, geo.size.height - 66))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func cameraButton(_ label: String, color: Color,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.thinMaterial)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(color.opacity(0.55), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func tooltip(_ hover: GraphHover) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(Formatters.formatMonthDay(hover.date))
                .font(.system(size: 11, weight: .semibold))
            Text("\(Formatters.humanizeTokens(hover.tokens)) tokens")
                .font(.system(size: 11))
            Text(Formatters.formatCost(hover.cost))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .frame(minWidth: 110, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.thickMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }
}
