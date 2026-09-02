// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Quota",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "QuotaCore", targets: ["QuotaCore"]),
        .executable(name: "Quota", targets: ["Quota"])
    ],
    targets: [
        .target(
            name: "QuotaCore",
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .executableTarget(
            name: "Quota",
            dependencies: ["QuotaCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Charts"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "QuotaCoreTests",
            dependencies: ["QuotaCore"]
        )
    ]
)
