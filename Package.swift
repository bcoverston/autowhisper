// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "autowhisper",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "Events"),
        .executableTarget(
            name: "autowhisper",
            dependencies: ["Events"],
            path: "Sources/autowhisper"
        ),
        .executableTarget(name: "spike-tap", path: "Spikes/tap"),
        .executableTarget(name: "spike-encode", path: "Spikes/encode"),
        .executableTarget(name: "spike-shell", path: "Spikes/shell"),
        .binaryTarget(name: "whisper", path: ".deps/build-apple/whisper.xcframework"),
        .executableTarget(name: "spike-whisper", dependencies: ["whisper"], path: "Spikes/whisper"),
    ]
)
