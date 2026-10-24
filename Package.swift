// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Overdrive",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.16.1"),
    ],
    targets: [
        .executableTarget(name: "Overdrive", dependencies: [.product(name: "Logging", package: "swift-log")], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "OverdriveTests", dependencies: ["Overdrive"], resources: [.copy("Fixtures")]),
    ]
)
