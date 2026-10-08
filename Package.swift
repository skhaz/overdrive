// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Overdrive",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(name: "Overdrive", swiftSettings: [.defaultIsolation(MainActor.self)])
    ]
)
