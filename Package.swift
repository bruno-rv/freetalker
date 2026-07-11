// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FreeTalker",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "FreeTalker", targets: ["FreeTalker"])
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
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CSQLite"
            ]
        ),
        .testTarget(name: "FreeTalkerTests", dependencies: ["FreeTalker"])
    ]
)
