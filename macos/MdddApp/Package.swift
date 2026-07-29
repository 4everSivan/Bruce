// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MdddApp",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "MdddApp", targets: ["MdddApp"]),
    ],
    targets: [
        .target(
            name: "MdddOnboardingCore",
            path: "Sources/MdddOnboardingCore"
        ),
        .executableTarget(
            name: "MdddApp",
            dependencies: ["MdddOnboardingCore"],
            resources: [
                .copy("Resources/Widgets"),
            ]
        ),
        .executableTarget(
            name: "MdddOnboardingCoreHarness",
            dependencies: ["MdddOnboardingCore"],
            path: "Tests/MdddOnboardingCoreHarness"
        ),
    ]
)
