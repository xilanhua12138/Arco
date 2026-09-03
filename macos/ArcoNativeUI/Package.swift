// swift-tools-version: 6.0
import Foundation
import PackageDescription

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let rustProfile = ProcessInfo.processInfo.environment["ARCO_RUST_PROFILE"] ?? "debug"
let rustLibraryDirectory = repositoryRoot
    .appendingPathComponent("rust/arco-core/target/\(rustProfile)")
    .path

let package = Package(
    name: "ArcoNativeUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArcoNativeUI", type: .static, targets: ["ArcoNativeUI"]),
        .executable(name: "Arco", targets: ["ArcoApp"]),
        .executable(name: "ArcoNativeUIContractTests", targets: ["ArcoNativeUIContractTests"]),
        .executable(name: "ArcoMarkdownContractTests", targets: ["ArcoMarkdownContractTests"]),
        .executable(name: "ArcoTopBarContractTests", targets: ["ArcoTopBarContractTests"]),
        .executable(name: "ArcoContentSourceParityContractTests", targets: ["ArcoContentSourceParityContractTests"]),
        .executable(name: "ArcoHistoryPerformanceContractTests", targets: ["ArcoHistoryPerformanceContractTests"]),
        .executable(name: "ArcoSettingsParityContractTests", targets: ["ArcoSettingsParityContractTests"]),
        .executable(name: "ArcoSetupSourceParityContractTests", targets: ["ArcoSetupSourceParityContractTests"]),
        .executable(name: "ArcoOverlaySourceParityContractTests", targets: ["ArcoOverlaySourceParityContractTests"]),
        .executable(name: "ArcoWindowChromeContractTests", targets: ["ArcoWindowChromeContractTests"]),
        .executable(name: "ArcoPreferencesContractTests", targets: ["ArcoPreferencesContractTests"]),
        .executable(name: "ArcoLocalizationContractTests", targets: ["ArcoLocalizationContractTests"]),
        .executable(name: "ArcoAppleDesignContractTests", targets: ["ArcoAppleDesignContractTests"]),
        .executable(name: "ArcoMeetingAwarenessContractTests", targets: ["ArcoMeetingAwarenessContractTests"]),
    ],
    targets: [
        .target(
            name: "ArcoNativeUI",
            linkerSettings: [
                .linkedFramework("Security"),
                .unsafeFlags(["-L", rustLibraryDirectory, "-larco_core"]),
            ]
        ),
        .executableTarget(name: "ArcoApp", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoNativeUIContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoMarkdownContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoTopBarContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoContentSourceParityContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoHistoryPerformanceContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoSettingsParityContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoSetupSourceParityContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoOverlaySourceParityContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoWindowChromeContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoPreferencesContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoLocalizationContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoAppleDesignContractTests", dependencies: ["ArcoNativeUI"]),
        .executableTarget(name: "ArcoMeetingAwarenessContractTests", dependencies: ["ArcoNativeUI"]),
    ]
)
