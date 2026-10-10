// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HeadroomPrototype",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Headroom", targets: ["Headroom"]),
        .executable(name: "HeadroomLab", targets: ["HeadroomLab"]),
        .executable(name: "DisplayGuardian", targets: ["DisplayGuardian"])
    ],
    targets: [
        .target(name: "DisplayCore"),
        .target(name: "DisplayActivation", resources: [.process("Resources")]),
        .executableTarget(name: "Headroom", dependencies: ["DisplayCore", "DisplayActivation"]),
        .executableTarget(name: "HeadroomLab", dependencies: ["DisplayCore"]),
        .executableTarget(name: "DisplayGuardian", dependencies: ["DisplayCore"]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"])
    ]
)
