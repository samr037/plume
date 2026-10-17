// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Plume",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        // Silero VAD (et diarisation pour les réunions) en CoreML. 0.17.4 = 2026-09-25.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.4"),
    ],
    targets: [
        // Logique pure (FSM, post-traitement, filtres, prompts, stockage) : testable sans AppKit.
        .target(name: "PlumeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // Réunions : détenteurs du micro (CoreAudio), catalogue d'apps de visio, URL navigateur (AX),
        // capture micro + son système (process tap). Pas de dépendance à l'app : testable via wl-meeting-probe.
        .target(name: "MeetingKit", dependencies: ["PlumeCore"]),
        .executableTarget(name: "wl-meeting-probe", dependencies: ["MeetingKit"]),
        // App menubar : CGEventTap, audio, WhisperKit, AX, collage, UI.
        .executableTarget(
            name: "Plume",
            dependencies: [
                "PlumeCore",
                "MeetingKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        // Serveur MCP local (stdio) : expose dictées, réunions et todos de la base SQLite, en lecture seule.
        .executableTarget(name: "wl-mcp", dependencies: ["PlumeCore"]),
        .executableTarget(
            name: "wl-spike",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        .testTarget(name: "PlumeCoreTests", dependencies: ["PlumeCore"]),
        .testTarget(name: "MeetingKitTests", dependencies: ["MeetingKit"]),
    ]
)
