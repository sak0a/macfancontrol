// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacFanControl",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacFanControl",       targets: ["MacFanControlApp"]),
        .executable(name: "MacFanControlHelper", targets: ["MacFanControlHelper"]),
    ],
    targets: [
        // ---- C shim: IOKit SMC access ----
        .target(
            name: "SMCShim",
            path: "Sources/SMCShim",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),

        // ---- Shared Swift library ----
        .target(
            name: "MacFanControlCore",
            dependencies: ["SMCShim"],
            path: "Sources/MacFanControlCore"
        ),

        // ---- SwiftUI GUI app ----
        .executableTarget(
            name: "MacFanControlApp",
            dependencies: ["MacFanControlCore"],
            path: "Sources/MacFanControlApp",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/MacFanControlApp/Resources/Info.plist",
                ])
            ]
        ),

        // ---- Privileged helper daemon ----
        .executableTarget(
            name: "MacFanControlHelper",
            dependencies: ["MacFanControlCore"],
            path: "Sources/MacFanControlHelper",
            exclude: ["Resources"]
        ),

        // ---- Tests ----
        .testTarget(
            name: "MacFanControlCoreTests",
            dependencies: ["MacFanControlCore"],
            path: "Tests/MacFanControlCoreTests"
        ),
    ]
)
