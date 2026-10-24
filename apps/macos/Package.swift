// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentGitWorkbench",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "AgentGitWorkbench", targets: ["AgentGitWorkbench"]),
    .executable(name: "workbench-native-probe", targets: ["NativeProbe"]),
    .executable(name: "workbench-native-preview", targets: ["NativePreview"]),
    .executable(name: "workbench-startup-probe", targets: ["StartupProbe"]),
    .executable(name: "workbench-update-probe", targets: ["UpdateProbe"]),
  ],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
  ],
  targets: [
    .target(name: "WorkbenchProtocol"),
    .target(name: "WorkbenchRuntime", dependencies: ["WorkbenchProtocol"]),
    .target(name: "WorkbenchUI", dependencies: ["WorkbenchProtocol", "WorkbenchRuntime"]),
    .target(name: "WorkbenchUpdates", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    .executableTarget(name: "AgentGitWorkbench", dependencies: ["WorkbenchUI", "WorkbenchUpdates"]),
    .executableTarget(name: "NativeProbe", dependencies: ["WorkbenchProtocol"]),
    .executableTarget(name: "NativePreview", dependencies: ["WorkbenchUI"]),
    .executableTarget(name: "StartupProbe", dependencies: ["WorkbenchRuntime"]),
    .executableTarget(name: "UpdateProbe", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
    .testTarget(name: "WorkbenchProtocolTests", dependencies: ["WorkbenchProtocol"]),
    .testTarget(name: "WorkbenchUITests", dependencies: ["WorkbenchUI"]),
    .testTarget(name: "WorkbenchRuntimeTests", dependencies: ["WorkbenchRuntime"]),
    .testTarget(name: "WorkbenchUpdatesTests", dependencies: ["WorkbenchUpdates"]),
  ]
)
