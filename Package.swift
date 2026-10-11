// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "swift-sample-chopper",
    platforms: [
        .macOS("27.0"),
    ],
    products: [
        .library(name: "SampleChopper", targets: ["SampleChopper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/arraypress/swift-music-transcriber.git", from: "0.6.0"),   // Beat This! bar grid, audio I/O
        .package(url: "https://github.com/arraypress/swift-sample-search.git", from: "0.1.1"),       // CLAP: naming drum hits
        .package(url: "https://github.com/arraypress/swift-pitch-tracker.git", from: "0.1.1"),       // CREPE: naming bass notes
        .package(url: "https://github.com/arraypress/swift-music-analysis.git", from: "0.3.0"),      // key
        .package(url: "https://github.com/arraypress/swift-midi-file.git", from: "0.5.0"),           // drum-pattern MIDI
    ],
    targets: [
        .target(
            name: "SampleChopper",
            dependencies: [
                .product(name: "MusicTranscriber", package: "swift-music-transcriber"),
                .product(name: "SampleSearch", package: "swift-sample-search"),
                .product(name: "PitchTracker", package: "swift-pitch-tracker"),
                .product(name: "MusicAnalysis", package: "swift-music-analysis"),
                .product(name: "MIDIFileKit", package: "swift-midi-file"),
            ]
        ),
        .testTarget(name: "SampleChopperTests", dependencies: ["SampleChopper"], resources: [.copy("Fixtures")]),
    ]
)

// Swift 7's import rule, today: a file must import every module whose members
// it uses, rather than leaning on another file's imports.
for target in package.targets where target.type != .system && target.type != .binary && target.type != .plugin {
    target.swiftSettings = (target.swiftSettings ?? []) + [.enableUpcomingFeature("MemberImportVisibility")]
}
