import SwiftUI

// The client mark used by the tab strip and the agent-limits card. Mirrors
// the React ClientMark/mark() spans (DashboardTabs.tsx, AgentLimitsCard.tsx):
//  - mono glyph: tinted white, ~60% of the disc, over the brand-color disc
//  - full glyph: fills the disc as-is (it brings its own background)
//  - no/unloadable glyph: brand-color disc with the display name's initial
struct ClientIconView: View {
    let style: ClientStyle
    let size: CGFloat
    /// Corner radius of the disc; nil draws a circle (the tab strip's shape).
    var cornerRadius: CGFloat?

    var body: some View {
        Group {
            if let iconType = style.iconType,
               let image = ClientIconAssets.image(for: style.id) {
                switch iconType {
                case .mono:
                    disc.fill(style.color)
                        .overlay(
                            Image(nsImage: image)
                                .resizable()
                                .renderingMode(.template)
                                .scaledToFit()
                                .foregroundStyle(.white)
                                .frame(width: size * 0.6, height: size * 0.6)
                        )
                case .full:
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipShape(disc)
                }
            } else {
                disc.fill(style.color)
                    .overlay(
                        Text(style.initial)
                            .font(.system(size: size * 0.5, weight: .heavy))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
    }

    private var disc: AnyShape {
        if let cornerRadius {
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        return AnyShape(Circle())
    }
}
