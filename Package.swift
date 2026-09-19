// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RequirementTracker",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "RequirementCore", targets: ["RequirementCore"]),
        .executable(name: "RequirementTracker", targets: ["RequirementTracker"]),
        .executable(name: "JiraRequirementNativeHost", targets: ["JiraRequirementNativeHost"]),
        .executable(name: "RequirementTrackerMCP", targets: ["RequirementTrackerMCP"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "RequirementCore", dependencies: ["CSQLite"]),
        .target(name: "RequirementCalendarCore"),
        .executableTarget(
            name: "RequirementTracker",
            dependencies: ["RequirementCore"],
            swiftSettings: [
                .define("DEVELOPMENT", .when(configuration: .debug))
            ]
        ),
        .executableTarget(
            name: "JiraRequirementNativeHost",
            dependencies: ["RequirementCore"]
        ),
        .executableTarget(
            name: "RequirementTrackerMCP",
            dependencies: ["RequirementCore"]
        ),
        .executableTarget(
            name: "RequirementDatabaseChecks",
            dependencies: ["RequirementCore"],
            path: "Checks/RequirementDatabaseChecks"
        ),
        .executableTarget(
            name: "RequirementCoreChecks",
            dependencies: ["RequirementCore", "RequirementCalendarCore"],
            path: "Checks/RequirementCoreChecks"
        )
    ]
)
