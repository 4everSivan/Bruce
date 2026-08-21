// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "BruceApp",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "BruceApp", targets: ["BruceApp"]),
    ],
    targets: [
        .target(
            name: "BruceOnboardingCore",
            path: "Sources/BruceOnboardingCore"
        ),
        .target(
            name: "BruceAppCore",
            dependencies: ["BruceOnboardingCore"],
            path: "Sources/BruceAppCore"
        ),
        .target(
            name: "BruceGlassSurfaceCore",
            dependencies: ["BruceOnboardingCore"],
            path: "Sources/BruceGlassSurfaceCore"
        ),
        .executableTarget(
            name: "BruceApp",
            dependencies: ["BruceAppCore", "BruceOnboardingCore", "BruceGlassSurfaceCore"]
        ),
        .executableTarget(
            name: "BruceOnboardingCoreHarness",
            dependencies: ["BruceOnboardingCore"],
            path: "Tests/BruceOnboardingCoreHarness"
        ),
        .executableTarget(
            name: "ArtifactStoreHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/ArtifactStoreHarness"
        ),
        .executableTarget(
            name: "CollectorRunnerHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/CollectorRunnerHarness"
        ),
        .executableTarget(
            name: "RefreshSchedulerHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/RefreshSchedulerHarness"
        ),
        .executableTarget(
            name: "NativeLifecycleHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/NativeLifecycleHarness"
        ),
        .executableTarget(
            name: "DiagnosticsHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/DiagnosticsHarness"
        ),
        .executableTarget(
            name: "LocalIntegrationHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/LocalIntegrationHarness"
        ),
        .executableTarget(
            name: "PanelViewModelHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/PanelViewModelHarness"
        ),
        .executableTarget(
            name: "DeepSeekUsageLedgerHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/DeepSeekUsageLedgerHarness"
        ),
        .executableTarget(
            name: "SubscriptionCredentialsHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/SubscriptionCredentialsHarness"
        ),
        .executableTarget(
            name: "GlobalHotkeyHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/GlobalHotkeyHarness"
        ),
        .executableTarget(
            name: "AppModelCacheHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/AppModelCacheHarness"
        ),
        .executableTarget(
            name: "DashboardGlassSurfaceHarness",
            dependencies: ["BruceGlassSurfaceCore"],
            path: "Tests/Harnesses/DashboardGlassSurfaceHarness"
        ),
        .executableTarget(
            name: "SubscriptionRefreshControlHarness",
            dependencies: ["BruceAppCore", "BruceOnboardingCore"],
            path: "Tests/Harnesses/SubscriptionRefreshControlHarness"
        ),
    ]
)
