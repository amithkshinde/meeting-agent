// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [.macOS("15.0")],
    dependencies: [
        // Parakeet speech recognition, run on this Mac with Core ML. The version is pinned on purpose:
        // update it only after trying a build.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3"),
    ],
    targets: [
        .executableTarget(
            name: "MeetingAgent",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/MeetingAgent"
        ),
        .testTarget(
            name: "MeetingAgentTests",
            dependencies: ["MeetingAgent"],
            path: "Tests/MeetingAgentTests"
        ),
    ]
)
