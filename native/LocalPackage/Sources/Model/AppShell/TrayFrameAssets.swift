import AppKit
import DataSource

// Loads the bundled menubar animation frames. The PNGs are generated from
// src-tauri/icons/anim-cat2 and anim-parrot (see that repo's build.rs):
// black-on-transparent template silhouettes, square-fit onto a 44x44px
// canvas — 2x backing for the 22pt drawing box the tray layer uses
// (RunnerLayer contentsScale 2.0 + kCAGravityCenter, mirroring
// native_tray.rs TARGET_SIZE = 44).
enum TrayFrameAssets {
    /// Logical point size a 44px frame maps to at contentsScale 2.0.
    static let framePointSize = NSSize(width: 22, height: 22)

    static func frames(for style: AnimationStyle) -> [NSImage] {
        let subdirectory: String
        switch style {
        case .cat: subdirectory = "TrayFrames/cat"
        case .parrot: subdirectory = "TrayFrames/parrot"
        }
        guard let urls = Bundle.module.urls(
            forResourcesWithExtension: "png", subdirectory: subdirectory)
        else { return [] }
        return urls
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let image = NSImage(contentsOf: url) else { return nil }
                image.size = framePointSize
                image.isTemplate = true
                return image
            }
    }
}
