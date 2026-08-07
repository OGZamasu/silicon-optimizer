// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiliconOptimizer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SiliconOptimizer", targets: ["SiliconOptimizer"]),
        // The MCP bridge that lets Claude and ChatGPT drive the loaded model.
        .executable(name: "silicon-mcp", targets: ["SiliconMCP"]),
        .library(name: "SiliconKit", targets: [
            "SiliconCore", "SiliconHardware", "SiliconRuntime", "SiliconCatalog", "SiliconPlanner",
        ]),
    ],
    targets: [
        .target(name: "SiliconCore"),
        .target(name: "SiliconHardware", dependencies: ["SiliconCore"]),
        .target(name: "SiliconCatalog", dependencies: ["SiliconCore"]),
        .target(name: "SiliconPlanner", dependencies: ["SiliconCore", "SiliconHardware", "SiliconCatalog"]),
        .target(name: "SiliconRuntime", dependencies: ["SiliconCore", "SiliconCatalog", "SiliconPlanner"]),
        // Deliberately depends on nothing but Foundation and Network: the MCP bridge links it,
        // and that binary must stay small and independent of the app's domain layer.
        .target(name: "SiliconControl"),
        .target(name: "SiliconUI", dependencies: [
            "SiliconCore", "SiliconHardware", "SiliconRuntime", "SiliconCatalog", "SiliconPlanner",
            "SiliconControl",
        ]),
        .executableTarget(name: "SiliconMCP", dependencies: ["SiliconControl"]),
        .executableTarget(
            name: "SiliconOptimizer",
            dependencies: ["SiliconUI"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
                                           "-Xlinker", "__info_plist", "-Xlinker", "Resources/Info.plist"])]
        ),
        .testTarget(name: "SiliconTests", dependencies: [
            "SiliconCore", "SiliconHardware", "SiliconPlanner", "SiliconCatalog", "SiliconRuntime",
            "SiliconControl",
        ]),
    ],
    swiftLanguageModes: [.v6]
)
