// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RequirementTracker",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RequirementCore", targets: ["RequirementCore"]),
        .executable(name: "RequirementTracker", targets: ["RequirementTracker"])
    ],
    targets: [
        .target(name: "RequirementCore"),
        .executableTarget(
            name: "RequirementTracker",
            dependencies: ["RequirementCore"],
            swiftSettings: [
                .define("DEVELOPMENT", .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "RequirementCoreChecks",
            dependencies: ["RequirementCore"],
            path: "Checks/RequirementCoreChecks"
        )
    ]
)
