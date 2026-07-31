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
        // Objective-C `@try`/`@catch` around the AVAudioEngine graph calls that raise an
        // NSException instead of returning an error — see
        // Sources/ObjCExceptionBridge/include/ObjCExceptionBridge.h.
        .target(name: "ObjCExceptionBridge"),
        // Regenerates Sources/FreeTalker/Update/UpdatePublicKey.swift from
        // keys/release-public-key.base64 on every build — see Plugins/GenerateUpdatePublicKey
        // and scripts/lib/public-key-data-file.sh for why the key lives in a plain data file
        // instead of being hand-maintained Swift source.
        .plugin(
            name: "GenerateUpdatePublicKey",
            capability: .buildTool()
        ),
        .executableTarget(
            name: "FreeTalker",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "CSQLite",
                "ObjCExceptionBridge"
            ],
            resources: [.process("Resources")],
            plugins: ["GenerateUpdatePublicKey"]
        ),
        .testTarget(
            name: "FreeTalkerTests",
            dependencies: ["FreeTalker", "ObjCExceptionBridge"],
            resources: [.copy("Fixtures")]
        )
    ]
)
