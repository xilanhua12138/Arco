// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ArcoLocalTranscriber",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ArcoTranscriptionCore", targets: ["ArcoTranscriptionCore"]),
        .executable(name: "arco-local-transcriber", targets: ["ArcoLocalTranscriber"]),
        .executable(name: "arco-transcription-selftest", targets: ["ArcoTranscriptionSelfTest"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            exact: "0.15.5"
        ),
        .package(
            url: "https://github.com/exPHAT/SwiftWhisper.git",
            revision: "c340197966ebd264f3135d3955874b40f8ed58bc"
        ),
    ],
    targets: [
        .target(
            name: "ArcoTranscriptionCore",
            dependencies: ["FluidAudio", "SwiftWhisper"]
        ),
        .executableTarget(
            name: "ArcoLocalTranscriber",
            dependencies: ["ArcoTranscriptionCore"]
        ),
        .executableTarget(
            name: "ArcoTranscriptionSelfTest",
            dependencies: ["ArcoTranscriptionCore"]
        ),
    ]
)
