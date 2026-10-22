import Foundation
import WorkbenchProtocol

@main
struct NativeProbe {
  static func main() async throws {
    guard CommandLine.arguments.count == 2 else { throw ProbeFailure.usage }
    let client = ServiceClient(socketPath: CommandLine.arguments[1])
    let spaces: [WorkspaceInfo] = try await client.call("list_workspaces")
    guard let workspace = spaces.first, workspace.repositories.count == 2 else {
      throw ProbeFailure.workspace
    }
    var originals: [String: String] = [:]
    var stashCounts: [String: Int] = [:]
    for repo in workspace.repositories {
      let view: RepositoryStatus = try await client.call(
        "get_repo_status", params: ["repo_id": .string(repo.id)])
      originals[repo.id] = view.snapshotHash
      let branches: [GitBranch] = try await client.call(
        "list_branches", params: ["repo_id": .string(repo.id)])
      guard let branch = branches.first else { throw ProbeFailure.workspace }
      let branchCommits: [HistoryCommit] = try await client.call(
        "get_branch_history",
        params: [
          "repo_id": .string(repo.id), "branch_ref": .string(branch.fullRef),
          "tip_oid": .string(branch.tipOid),
        ])
      guard branchCommits.first?.oid == branch.tipOid else { throw ProbeFailure.diff }
      let stashes: [GitStash] = try await client.call(
        "list_stashes", params: ["repo_id": .string(repo.id)])
      stashCounts[repo.id] = stashes.count
      if let stash = stashes.first {
        let detail: StashDetail = try await client.call(
          "get_stash", params: ["repo_id": .string(repo.id), "stash_oid": .string(stash.oid)])
        guard detail.oid == stash.oid, let file = detail.files.first else {
          throw ProbeFailure.diff
        }
        let saved: FileDiff = try await client.call(
          "get_stash_diff",
          params: [
            "repo_id": .string(repo.id), "stash_oid": .string(stash.oid),
            "path": .string(file.path),
          ])
        guard !saved.canStageHunks, !saved.hunks.isEmpty else { throw ProbeFailure.diff }
      }
    }
    let plan: TaskPlan = try await client.call(
      "plan_task",
      params: [
        "group_id": .string("ios-2-4"), "label": .string("네이티브 Swift 검증"),
        "task_slug": .string("native-smoke"), "mode": .string("branch_only"),
      ])
    let key = "native-swift-one-request"
    let initial: WorkbenchOperation = try await client.call(
      "execute_plan", params: ["plan_id": .string(plan.id), "idempotency_key": .string(key)])
    let waiting = try await wait(client, id: initial.id)
    guard waiting.status == "waiting_for_worktree",
      waiting.repos.allSatisfy({ $0.attempts == 0 && !$0.hasWorktree })
    else { throw ProbeFailure.branchOnly }
    let repeated: WorkbenchOperation = try await client.call(
      "execute_plan", params: ["plan_id": .string(plan.id), "idempotency_key": .string(key)])
    guard repeated.id == initial.id else { throw ProbeFailure.idempotency }
    let _: WorkbenchOperation = try await client.call(
      "materialize", params: ["op_id": .string(initial.id)])
    let ready = try await wait(client, id: initial.id)
    guard ready.status == "ready", ready.repos.allSatisfy({ $0.attempts == 1 }) else {
      throw ProbeFailure.preparation
    }
    let task: TaskDetail = try await client.call(
      "get_task", params: ["task_id": .string(ready.taskId)])
    guard task.request.label == "네이티브 Swift 검증" else { throw ProbeFailure.workspace }
    var worktrees: [String: String] = [:]
    for repo in ready.repos {
      let original: RepositoryStatus = try await client.call(
        "get_repo_status", params: ["repo_id": .string(repo.id)])
      guard originals[repo.id] == original.snapshotHash else { throw ProbeFailure.originalChanged }
      worktrees[repo.id] = repo.plan.worktreePath
    }
    let repoId = "ios-app"
    let params: [String: JSONValue] = [
      "repo_id": .string(repoId), "op_id": .string(ready.id),
      "path": .string("Config/Version.xcconfig"),
    ]
    let diff: FileDiff = try await client.call("get_diff", params: params)
    guard diff.hunks.count == 1, diff.canStageHunks else { throw ProbeFailure.diff }
    var stage = params
    stage["hunk_index"] = .number(0)
    stage["snapshot_hash"] = .string(diff.snapshotHash)
    stage["diff_hash"] = .string(diff.contentIdentity)
    let staged: MutationResult = try await client.call("stage_hunk", params: stage)
    guard let stagedView = staged.view,
      stagedView.files.contains(where: { $0.path == "Config/Version.xcconfig" && $0.isStaged })
    else { throw ProbeFailure.diff }
    let committed: MutationResult = try await client.call(
      "commit",
      params: [
        "repo_id": .string(repoId), "op_id": .string(ready.id),
        "snapshot_hash": .string(stagedView.snapshotHash),
        "message": .string("Native Swift client commits reviewed version hunk"),
      ])
    guard let committedView = committed.view, committedView.files.isEmpty else { throw ProbeFailure.diff }
    let report: [String: Any] = [
      "result": "passed", "client": "Swift Unix socket client", "op_id": ready.id,
      "task_id": ready.taskId, "worktrees": worktrees,
      "committed_head": committedView.snapshot.head,
      "stash_counts": stashCounts,
      "checks": [
        "typed_contracts", "branch_only", "materialize", "idempotency",
        "original_snapshot_preservation", "hunk_stage", "commit", "typed_stash_review",
        "typed_branch_browser",
      ],
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
  private static func wait(_ client: ServiceClient, id: String) async throws -> WorkbenchOperation {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      let op: WorkbenchOperation = try await client.call(
        "get_operation", params: ["op_id": .string(id)])
      if !op.isRunning { return op }
      try await Task.sleep(for: .milliseconds(30))
    }
    throw ProbeFailure.timeout
  }
}
private enum ProbeFailure: Error {
  case usage, workspace, branchOnly, idempotency, preparation, originalChanged, diff, timeout
}
