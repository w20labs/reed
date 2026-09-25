// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Reed",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Reed", targets: ["Reed"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
        .package(url: "https://github.com/aptabase/aptabase-swift", from: "0.3.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
        // Runs the bundled FastEnhancer denoise model (Local Only pre-ASR
        // noise suppression) — see Sources/Reed/LocalASR/DenoiserModel.swift.
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.24.2"),
        // The speech model: NVIDIA Parakeet (CoreML on the ANE), the one
        // recognizer since P15 (2026-09-02). Apache 2.0, macOS 14+.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.1.0"),
    ],
    targets: [
        // Obj-C shim: Swift cannot catch NSExceptions, and AVAudioEngine
        // raises them for inherently racy conditions (see ObjCExceptionCatcher.h).
        .target(name: "ReedObjC", path: "Sources/ReedObjC"),
        .executableTarget(
            name: "Reed",
            dependencies: [
                "ReedObjC",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Aptabase", package: "aptabase-swift"),
                .product(name: "Sentry", package: "sentry-cocoa"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Reed"
        ),
        .testTarget(
            name: "ReedTests",
            dependencies: ["Reed"],
            path: "Tests/ReedTests"
        ),
    ]
)
