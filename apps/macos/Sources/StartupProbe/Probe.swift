import Foundation
import WorkbenchProtocol
import WorkbenchRuntime

@main
struct StartupProbe {
  private struct OperationLookup: Decodable, Sendable { let operation: WorkbenchOperation? }
  static func progress(_ message: String) {
    FileHandle.standardError.write(Data("startup: \(message)\n".utf8))
  }
  static func main() async throws {
    guard CommandLine.arguments.count == 5 else {
      fatalError("usage: workbench-startup-probe HELPER STORAGE RUNTIME REPOSITORY")
    }
    let helper =
      CommandLine.arguments[1] == "--bundled" ? nil : URL(fileURLWithPath: CommandLine.arguments[1])
    let storage = URL(fileURLWithPath: CommandLine.arguments[2])
    let runtimeDirectory = URL(fileURLWithPath: CommandLine.arguments[3])
    let repository = URL(fileURLWithPath: CommandLine.arguments[4])
    let runtime = WorkspaceRuntime(
      storageDirectory: storage, runtimeDirectory: runtimeDirectory, helperURL: helper)
    do {
      progress("open repository")
      async let firstOpen = runtime.openRepository(repository)
      async let concurrentOpen = runtime.openRepository(repository)
      let (session, sameSession) = try await (firstOpen, concurrentOpen)
      guard sameSession.recent.id == session.recent.id else { fatalError("Concurrent opens duplicated workspace") }
      guard session.socketPath.utf8.count < 104 else { fatalError("Long Unix socket") }
      let client = ServiceClient(socketPath: session.socketPath)
      let spaces: [WorkspaceInfo] = try await client.call("list_workspaces")
      guard let repo = spaces.first?.repositories.first else { fatalError("Missing repository") }
      let status: RepositoryStatus = try await client.call(
        "get_repo_status", params: ["repo_id": .string(repo.id)])
      guard status.path == repo.path else { fatalError("Wrong repository") }
      progress("reopen")
      let reopened = try await runtime.openRepository(URL(fileURLWithPath: repo.path))
      guard reopened.recent.id == session.recent.id, reopened.socketPath == session.socketPath
      else {
        fatalError("Reopening lost journal identity")
      }
      progress("stop idle engine")
      await runtime.stopIdleServices()
      progress("restart")
      let restarted = try await runtime.openRecent(session.recent)
      let afterRestart: [WorkspaceInfo] = try await ServiceClient(socketPath: restarted.socketPath)
        .call("list_workspaces")
      guard afterRestart.first?.id == spaces.first?.id else { fatalError("Restart failed") }
      progress("open example")
      async let firstExample = runtime.openExample()
      async let concurrentExample = runtime.openExample()
      let (example, sameExample) = try await (firstExample, concurrentExample)
      guard sameExample.recent.id == example.recent.id else { fatalError("Concurrent examples duplicated workspace") }
      let exampleClient = ServiceClient(socketPath: example.socketPath)
      let operations: [WorkbenchOperation] = try await exampleClient.call("list_operations")
      guard operations.count == 1, operations[0].status == "ready", operations[0].repos.count == 2
      else {
        fatalError("Example did not prepare real worktrees: \(operations.map(\.status))")
      }
      progress("reuse example")
      // A newer user operation must not become the welcome example's startup
      // dependency. Hold only this synthetic recipe, then cancel it explicitly.
      let gate = URL(fileURLWithPath: example.recent.repositoryPath).appendingPathComponent("api.sleep")
      try Data("synthetic delay".utf8).write(to: gate)
      let nextPlan: TaskPlan = try await exampleClient.call("plan_task", params: [
        "group_id": .string("ios-2-4"), "label": .string("Other startup smoke task"),
        "task_slug": .string("startup-other"), "mode": .string("materialize")])
      let next: WorkbenchOperation = try await exampleClient.call("execute_plan", params: [
        "plan_id": .string(nextPlan.id), "idempotency_key": .string("startup-other")])
      let reopenedAt = Date()
      let exampleAgain = try await runtime.openExample()
      guard Date().timeIntervalSince(reopenedAt) < 5 else { fatalError("Example waited for an unrelated newer operation") }
      let lookup: OperationLookup = try await exampleClient.call("get_operation_by_key", params: [
        "idempotency_key": .string("welcome-example-\(example.recent.id.uuidString)")])
      guard lookup.operation?.id == operations[0].id else { fatalError("Example lookup lost its operation identity") }
      let _: WorkbenchOperation = try await exampleClient.call("cancel_operation", params: ["op_id": .string(next.id)])
      try FileManager.default.removeItem(at: gate)
      for _ in 0..<100 {
        let current: WorkbenchOperation = try await exampleClient.call("get_operation", params: ["op_id": .string(next.id)])
        if !current.isRunning { break }
        try await Task.sleep(for: .milliseconds(50))
      }
      let unchanged: [WorkbenchOperation] = try await exampleClient.call("list_operations")
      guard exampleAgain.recent.id == example.recent.id, unchanged.count == 2,
        unchanged.allSatisfy({ !$0.isRunning }) else {
        fatalError("Duplicate example")
      }
      let history = try await runtime.recentWorkspaces()
      guard history.count == 2 else { fatalError("Recent history missing") }
      let secondInstance = WorkspaceRuntime(
        storageDirectory: storage, runtimeDirectory: runtimeDirectory, helperURL: helper)
      let persisted = try await secondInstance.recentWorkspaces()
      guard persisted.count == 2 else { fatalError("History did not persist") }
      progress("attach second instance")
      let borrowed = try await secondInstance.openRecent(session.recent)
      guard borrowed.socketPath == restarted.socketPath else {
        fatalError("Second instance did not attach")
      }
      // A non-Git folder must give a useful explanation, without requiring connection setup.
      let invalid = storage.appendingPathComponent("not a Git folder")
      try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
      do {
        _ = try await runtime.openRepository(invalid)
        fatalError("Accepted a non-Git directory")
      } catch StartupFailure.notRepository {}
      progress("stop engines")
      await runtime.stopIdleServices()
      let borrowedStillAlive: [WorkspaceInfo] = try await ServiceClient(socketPath: borrowed.socketPath).call("list_workspaces")
      guard !borrowedStillAlive.isEmpty else { fatalError("Owner exit disconnected another client") }
      await secondInstance.stopIdleServices()
      progress("recover missing example configuration")
      let missing = storage.appendingPathComponent("workspaces/\(example.recent.id.uuidString.lowercased())/workspace.json")
      try FileManager.default.removeItem(at: missing)
      let recovered = try await runtime.openExample()
      guard recovered.recent.id != example.recent.id,
        try await runtime.recentWorkspaces().count == 2
      else { fatalError("Missing example could not be recovered") }
      await runtime.stopIdleServices()
      progress("done")
      let report: [String: Any] = [
        "result": "passed", "socket_bytes": session.socketPath.utf8.count,
        "repository": repo.path, "files": status.files.count,
        "example_worktrees": operations[0].repos.count,
        "recent_count": history.count, "restart_and_second_instance": true,
        "plain_language_invalid_folder": true,
        "concurrent_open_coalesced": true, "borrowed_engine_preserved": true,
        "missing_example_recovered": true,
        "example_operation_key_ignores_newer_running_task": true,
      ]
      print(
        String(
          decoding: try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    } catch {
      await runtime.stopIdleServices()
      throw error
    }
  }
}
