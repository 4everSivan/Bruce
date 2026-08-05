// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "MdddApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MdddApp", targets: ["MdddApp"]),
    ],
    targets: [
        .target(
            name: "MdddOnboardingCore",
            path: "Sources/MdddOnboardingCore"
        ),
        .target(
            name: "MdddAppCore",
            dependencies: ["MdddOnboardingCore"],
            path: "Sources/MdddAppCore"
        ),
        .executableTarget(
            name: "MdddApp",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"]
        ),
        .executableTarget(
            name: "MdddOnboardingCoreHarness",
            dependencies: ["MdddOnboardingCore"],
            path: "Tests/MdddOnboardingCoreHarness"
        ),
        .executableTarget(
            name: "ArtifactStoreHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/ArtifactStoreHarness"
        ),
        .executableTarget(
            name: "CollectorRunnerHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/CollectorRunnerHarness"
        ),
        .executableTarget(
            name: "RefreshSchedulerHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/RefreshSchedulerHarness"
        ),
        .executableTarget(
            name: "NativeLifecycleHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/NativeLifecycleHarness"
        ),
        .executableTarget(
            name: "DiagnosticsHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/DiagnosticsHarness"
        ),
        .executableTarget(
            name: "LocalIntegrationHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/LocalIntegrationHarness"
        ),
        .executableTarget(
            name: "PanelViewModelHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/PanelViewModelHarness"
        ),
        .executableTarget(
            name: "DeepSeekUsageLedgerHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/DeepSeekUsageLedgerHarness"
        ),
        .executableTarget(
            name: "SubscriptionCredentialsHarness",
            dependencies: ["MdddAppCore", "MdddOnboardingCore"],
            path: "Tests/Harnesses/SubscriptionCredentialsHarness"
        ),
    ]
)
