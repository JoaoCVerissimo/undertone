// swift-tools-version: 6.2
import Foundation
import PackageDescription

// Undertone builds with the Command Line Tools alone (no Xcode). The CLT keep Swift Testing in a framework
// directory SwiftPM does not search by default, so the self-test executable needs the search/rpath flags below.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingLib = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib" // lib_TestingInterop.dylib
let usingCLT: Bool = {
    let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
        ?? (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
        ?? "/Library/Developer/CommandLineTools"
    return developerDir.contains("CommandLineTools") && FileManager.default.fileExists(atPath: cltFrameworks + "/Testing.framework")
}()
let testingSwiftFlags: [SwiftSetting] = usingCLT ? [.unsafeFlags(["-F", cltFrameworks])] : []
let testingLinkFlags: [LinkerSetting] = usingCLT
    ? [.unsafeFlags(["-F", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltFrameworks, "-Xlinker", "-rpath", "-Xlinker", cltTestingLib])]
    : []

let package = Package(
    name: "Undertone",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Vendored + minimally patched so it builds with the Command Line Tools alone (see Vendor/README.md).
        .package(path: "Vendor/KeyboardShortcuts"),
    ],
    targets: [
        // Pure-Swift core: link parsing, yt-dlp models/client, queue, formatting. No AppKit, unit-tested.
        .target(
            name: "UndertoneCore",
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                // Lets the self-test executable use `@testable import UndertoneCore`.
                .unsafeFlags(["-enable-testing"], .when(configuration: .debug)),
            ]
        ),
        // The menu bar app. Everything here is main-actor by default (UI, AVPlayer, AppKit).
        .executableTarget(
            name: "Undertone",
            dependencies: [
                "UndertoneCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
            ]
        ),
        // `make test` runs this. It calls Swift Testing's own entry point, which `swift test` will not do
        // under the Command Line Tools. Runs every @Test in the target; honours flags like `--filter`.
        .executableTarget(
            name: "UndertoneSelfTest",
            dependencies: ["UndertoneCore"],
            swiftSettings: [.enableUpcomingFeature("NonisolatedNonsendingByDefault")] + testingSwiftFlags,
            linkerSettings: testingLinkFlags
        ),
    ]
)
