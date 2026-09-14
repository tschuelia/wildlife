// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Wildlife",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Wildlife", targets: ["Wildlife"]),
        .executable(name: "wildlife-hook", targets: ["WildlifeHook"]),
        .executable(name: "WildlifeCoreChecks", targets: ["WildlifeCoreChecks"]),
        .library(name: "WildlifeCore", targets: ["WildlifeCore"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "WildlifeCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Wildlife", dependencies: ["WildlifeCore"]),
        .executableTarget(name: "WildlifeHook", dependencies: ["WildlifeCore"]),
        .executableTarget(
            name: "WildlifeCoreChecks",
            dependencies: ["WildlifeCore", "CSQLite"],
            path: "Checks/WildlifeCoreChecks"
        ),
    ]
)
