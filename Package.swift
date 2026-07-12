// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FreeTalker",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FreeTalker", targets: ["FreeTalker"]),
        .executable(name: "VoiceProfileCalibration", targets: ["VoiceProfileCalibration"]),
        .library(name: "VoiceProfileCore", targets: ["VoiceProfileCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: nil),
        .executableTarget(
            name: "FreeTalker",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                "VoiceProfileCore",
                "VoiceProfileFluidAudio",
                "CSQLite"
            ]
        ),
        .testTarget(
            name: "FreeTalkerTests",
            dependencies: ["FreeTalker"],
            resources: [.copy("Fixtures")]
        ),
        .target(name: "VoiceProfileCore"),
        .testTarget(
            name: "VoiceProfileCoreTests",
            dependencies: ["VoiceProfileCore"]
        ),
        .target(
            name: "VoiceProfileFluidAudio",
            dependencies: [
                "VoiceProfileCore",
                .product(name: "FluidAudio", package: "FluidAudio")
            ]
        ),
        .testTarget(
            name: "VoiceProfileFluidAudioTests",
            dependencies: ["VoiceProfileFluidAudio"]
        ),
        .executableTarget(
            name: "VoiceProfileCalibration",
            dependencies: ["VoiceProfileCore", "VoiceProfileFluidAudio"]
        ),
        .testTarget(
            name: "VoiceProfileCalibrationTests",
            dependencies: ["VoiceProfileCalibration"]
        )
    ]
)
