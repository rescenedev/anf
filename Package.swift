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
        // All app logic — built as a library so the test runner can link and
        // `@testable import` it. (Internal symbols of an executable target aren't
        // linkable from another target.)
        .target(
            name: "anf",
            dependencies: ["PTYHelper"],
            path: "Sources/anf",
            resources: [
                .copy("Resources/xterm"),
                .copy("Resources/l10n")
            ],
            swiftSettings: [
                .unsafeFlags(["-Onone"], .when(configuration: .debug)),
                // `@testable import anf` from the test runner needs testability.
                // Debug-only, so the release app (build.sh) is unaffected.
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug))
            ]
        ),
        // Thin executable: just calls `anfMain()` in the library.
        .executableTarget(
            name: "anfapp",
            dependencies: ["anf"],
            path: "Sources/anfapp"
        ),
        // Test runner. XCTest/Swift-Testing aren't available with Command Line
        // Tools (Xcode-only), so tests use a tiny built-in harness and run via
        // `swift run anfTests` (exit code 0 = pass).
        .executableTarget(
            name: "anfTests",
            dependencies: ["anf"],
            path: "Tests/anfTests"
        )
    ]
)
