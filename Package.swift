// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChorographOpenCodeServerPlugin",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "ChorographOpenCodeServerPlugin",
            type: .dynamic,
            targets: ["ChorographOpenCodeServerPlugin"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/aorgcorn/chorograph-plugin-sdk.git",
            from: "1.0.0"
        ),
    ],
    targets: [
        .target(
            name: "ChorographOpenCodeServerPlugin",
            dependencies: [
                .product(name: "ChorographPluginSDK", package: "chorograph-plugin-sdk"),
            ],
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path"]),
            ]
        ),
    ]
)
