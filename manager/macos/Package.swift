// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ByoriManager",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "ByoriManagerCore", targets: ["ByoriManagerCore"]),
        .executable(name: "ByoriManager", targets: ["ByoriManager"]),
        .executable(name: "ByoriManagerSelfTest", targets: ["ByoriManagerSelfTest"]),
    ],
    targets: [
        .target(name: "ByoriManagerCore"),
        .executableTarget(
            name: "ByoriManager",
            dependencies: ["ByoriManagerCore"]
        ),
        .executableTarget(
            name: "ByoriManagerSelfTest",
            dependencies: ["ByoriManagerCore"]
        ),
        .testTarget(
            name: "ByoriManagerCoreTests",
            dependencies: ["ByoriManagerCore"]
        ),
    ]
)
