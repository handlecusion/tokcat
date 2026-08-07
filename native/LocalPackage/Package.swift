// swift-tools-version: 6.0

// Tokcat native core. Layering follows RunCatNeo's LUCA architecture
// (UserInterface → Model → DataSource, one-way), adapted to macOS 13:
// no @Observable, ObservableObject throughout.
//
// DataSource:  Sendable value types + system-API dependency clients.
// Collector:   the usage-data layer ported from src-tauri (parsers, pricing,
//              tailer, quota) — imported only by Model's composition root.
// Model:       app logic (ports of src/lib/*.ts), services, stores.
// UserInterface: SwiftUI views, no logic.
import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny")
]

let package = Package(
    name: "LocalPackage",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DataSource", targets: ["DataSource"]),
        .library(name: "Collector", targets: ["Collector"]),
        .library(name: "Model", targets: ["Model"]),
        .library(name: "UserInterface", targets: ["UserInterface"]),
        .executable(name: "tokcat-dump", targets: ["tokcat-dump"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "DataSource",
            swiftSettings: swiftSettings
        ),
        // The usage-data layer ported from src-tauri: parsers, pricing,
        // aggregation, tailer, quota providers. Only Model's composition
        // root and the parity CLI import it.
        .target(
            name: "Collector",
            dependencies: ["DataSource"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Model",
            dependencies: [
                "DataSource", "Collector",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources/TrayFrames")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "UserInterface",
            dependencies: ["DataSource", "Model"],
            resources: [
                .copy("Resources/AgentIcons"),
                .copy("Resources/tokcat-logo.png"),
            ],
            swiftSettings: swiftSettings
        ),
        // Parity CLI: dumps the collector output as deterministic JSON for
        // diffing against the Rust `usage_dump` bin (scripts/parity-check.sh).
        .executableTarget(
            name: "tokcat-dump",
            dependencies: ["Collector", "DataSource"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "CollectorTests",
            dependencies: ["Collector"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ModelTests",
            dependencies: ["Model"],
            resources: [.copy("Resources/golden.json")],
            swiftSettings: swiftSettings
        ),
    ]
)
