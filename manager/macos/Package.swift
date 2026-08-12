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
    dependencies: [
        .package(
            url: "https://github.com/migueldeicaza/SwiftTerm.git",
            exact: "1.15.0"
        ),
    ],
    targets: [
        .target(name: "ByoriManagerCore"),
        .executableTarget(
            name: "ByoriManager",
            dependencies: [
                "ByoriManagerCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .executableTarget(
            name: "ByoriManagerSelfTest",
            dependencies: ["ByoriManagerCore"]
        ),
        .testTarget(
            name: "ByoriManagerCoreTests",
            dependencies: ["ByoriManagerCore"]
        ),
        .testTarget(
            name: "ByoriManagerTests",
            dependencies: ["ByoriManager"]
        ),
    ]
)
