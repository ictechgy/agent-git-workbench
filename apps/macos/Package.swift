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
  ],
  targets: [
    .target(name: "WorkbenchProtocol"),
    .target(name: "WorkbenchRuntime", dependencies: ["WorkbenchProtocol"]),
    .target(name: "WorkbenchUI", dependencies: ["WorkbenchProtocol", "WorkbenchRuntime"]),
    .executableTarget(name: "AgentGitWorkbench", dependencies: ["WorkbenchUI"]),
    .executableTarget(name: "NativeProbe", dependencies: ["WorkbenchProtocol"]),
    .executableTarget(name: "NativePreview", dependencies: ["WorkbenchUI"]),
    .executableTarget(name: "StartupProbe", dependencies: ["WorkbenchRuntime"]),
    .testTarget(name: "WorkbenchProtocolTests", dependencies: ["WorkbenchProtocol"]),
    .testTarget(name: "WorkbenchUITests", dependencies: ["WorkbenchUI"]),
    .testTarget(name: "WorkbenchRuntimeTests", dependencies: ["WorkbenchRuntime"]),
  ]
)
