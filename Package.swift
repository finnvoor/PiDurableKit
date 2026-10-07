// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PiDurableKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .visionOS(.v1),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "PiDurableKit", targets: ["PiDurableKit"]),
    ],
    targets: [
        .target(
            name: "PiDurableKit",
            resources: [
                .copy("Resources/pi-durable.js"), .copy("Resources/Documentation"), .copy("Resources/ThirdPartyNotices.txt"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "PiDurableKitTests",
            dependencies: ["PiDurableKit"]
        ),
    ]
)
