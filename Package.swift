// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "anf",
    platforms: [.macOS("26.0")],
    dependencies: [],
    targets: [
        .target(
            name: "PTYHelper",
            path: "Sources/PTYHelper",
            publicHeadersPath: "."
        ),
        .executableTarget(
            name: "anf",
            dependencies: ["PTYHelper"],
            path: "Sources/anf",
            resources: [
                .copy("Resources/xterm")
            ],
            swiftSettings: [
                .unsafeFlags(["-Onone"], .when(configuration: .debug))
            ]
        )
    ]
)
