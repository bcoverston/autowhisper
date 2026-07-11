// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "autowhisper",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
    ],
    targets: [
        .target(name: "Events"),
        .executableTarget(
            name: "autowhisper",
            dependencies: ["Events", "whisper", .product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/autowhisper"
        ),
        .executableTarget(name: "spike-tap", path: "Spikes/tap"),
        .executableTarget(name: "spike-encode", path: "Spikes/encode"),
        .executableTarget(name: "spike-shell", path: "Spikes/shell"),
        .executableTarget(name: "spike-diarize", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")], path: "Spikes/diarize"),
        .binaryTarget(name: "whisper", path: ".deps/build-apple/whisper.xcframework"),
        .executableTarget(name: "spike-whisper", dependencies: ["whisper"], path: "Spikes/whisper"),
    ]
)
