// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "Wildlife",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Wildlife", targets: ["Wildlife"]),
        .executable(name: "wildlife-hook", targets: ["WildlifeHook"]),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "WildlifeDomain"),
        .target(
            name: "WildlifeInfrastructure",
            dependencies: ["WildlifeDomain", "CSQLite"]
        ),
        .executableTarget(name: "Wildlife", dependencies: ["WildlifeDomain", "WildlifeInfrastructure"]),
        .executableTarget(name: "WildlifeHook", dependencies: ["WildlifeDomain", "WildlifeInfrastructure"]),
        .testTarget(name: "WildlifeDomainTests", dependencies: ["WildlifeDomain"]),
        .testTarget(name: "WildlifeInfrastructureTests", dependencies: ["WildlifeDomain", "WildlifeInfrastructure", "CSQLite"]),
    ]
)
