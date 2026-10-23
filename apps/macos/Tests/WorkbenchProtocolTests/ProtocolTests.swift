import Foundation
import Testing

@testable import WorkbenchProtocol

@Test func largeDiffKeepsItsExactHashButSkipsUnboundedRowParsing() throws {
  let hunk = "@@ -0,0 +1,20000 @@\n" + String(repeating: "+line\n", count: 20_000)
  let object: [String: Any] = ["snapshot_hash": "snapshot", "path": "large.txt", "staged": false,
    "header": "header\n", "hunks": [hunk], "text": "header\n" + hunk, "can_stage_hunks": true]
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  let diff = try decoder.decode(FileDiff.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(diff.displayLimitExceeded); #expect(diff.parsedHunks.isEmpty)
  #expect(diff.text == "header\n" + hunk); #expect(diff.contentIdentity.count == 64)
}

@Test func splitDiffKeepsRealLineNumbersAndPairsUnequalEdits() {
  let text =
    "@@ -18,4 +31,5 @@ function\n context\n-old one\n-old two\n+new one\n+new two\n+new three\n tail\n"
  let hunk = DiffLines.parse([text])[0]
  #expect(hunk.split.count == 5)
  #expect(hunk.split[0].before?.number == 18)
  #expect(hunk.split[0].after?.number == 31)
  #expect(hunk.split[1].before?.text == "old one")
  #expect(hunk.split[1].after?.text == "new one")
  #expect(hunk.split[3].before == nil)
  #expect(hunk.split[3].after?.number == 34)
  #expect(hunk.split[4].before?.number == 21)
  #expect(hunk.split[4].after?.number == 35)
}

@Test func diffDisplayMakesEmbeddedLineControlsVisibleWithoutChangingSource() {
  let original = "old\rhidden\u{b}vertical\u{c}page\u{85}next\u{2028}line\u{2029}paragraph\u{202e}reversed\t끝"
  let hunk = DiffLines.parse(["@@ -1 +1 @@\n-\(original)\n+new\n"])[0]
  #expect(hunk.split[0].before?.text == original)
  #expect(hunk.split[0].after?.text == "new")
  let display = DiffLines.displayText(original)
  #expect(display == "old␍hidden␋vertical␌page⟨U+0085⟩next⟨U+2028⟩line⟨U+2029⟩paragraph⟨U+202E⟩reversed\t끝")
  #expect(!display.unicodeScalars.contains { [0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029].contains($0.value) })
}

@Test func diffMarkersRemainSeparateFromLeadingCombiningSourceScalars() {
  let hunk = DiffLines.parse(["@@ -1,2 +1,2 @@\n \u{301}context\n-\u{301}before\n+\u{301}after\n"])[0]
  #expect(hunk.unified.map(\.kind) == [.context, .deletion, .addition])
  #expect(hunk.unified.map(\.text) == ["\u{301}context", "\u{301}before", "\u{301}after"])
  #expect(hunk.split[1].before?.number == 2)
  #expect(hunk.split[1].after?.number == 2)
}

@Test func noNewlineMetadataDoesNotConsumeSourceLines() {
  let text =
    "@@ -1 +1 @@\n-before\n\\ No newline at end of file\n+after\n\\ No newline at end of file\n"
  let hunk = DiffLines.parse([text])[0]
  #expect(hunk.split.count == 1)
  #expect(hunk.split[0].before?.number == 1)
  #expect(hunk.split[0].after?.number == 1)
  #expect(hunk.unified.filter { $0.kind == .metadata }.count == 2)
  #expect(hunk.split[0].before?.noNewline == true)
  #expect(hunk.split[0].after?.noNewline == true)
}

@Test func serviceErrorsRemainMachineReadable() throws {
  let payload = Data(
    #"{"schema_version":1,"error":{"code":"stale_snapshot","message":"external edit"}}"#.utf8)
  do {
    let _: [WorkspaceInfo] = try ServiceClient.decode(payload, as: [WorkspaceInfo].self)
    Issue.record("Service error was accepted as a result")
  } catch let error as ServiceFailure {
    #expect(error.code == "stale_snapshot")
  }
}

@Test func unsupportedWireVersionIsRejected() {
  let payload = Data(#"{"schema_version":2,"result":[]}"#.utf8)
  #expect(throws: TransportFailure.self) {
    try ServiceClient.decode(payload, as: [WorkspaceInfo].self)
  }
}

@Test func snakeCaseContractDecodesBranchOnlyRepoWithoutWorktree() throws {
  let data = Data(
    #"{"schema_version":1,"result":{"schema_version":1,"id":"op","task_id":"task","plan_id":"plan","status":"waiting_for_worktree","materialize":false,"repos":[{"plan":{"repo_id":"ios-app","base_ref":"refs/heads/release/2.4","base_oid":"abc","branch_ref":"refs/heads/feature/login","worktree_path":"/tmp/new worktree","recipe_hash":"pin","policy":{"recipe":"ios.set-version@1","inputs":{"marketing_version":"2.4.0","local_build":"241"}}},"state":"waiting_for_worktree","error_code":null,"attempts":0,"baseline":null,"postcondition":null}]}}"#
      .utf8)
  let op = try ServiceClient.decode(data, as: WorkbenchOperation.self)
  #expect(op.taskId == "task")
  #expect(!op.repos[0].hasWorktree)
  #expect(op.repos[0].plan.policy.inputs?.localBuild == "241")
}

@Test func oversizedUnixSocketPathFailsWithoutNetwork() async {
  let client = ServiceClient(socketPath: "/tmp/" + String(repeating: "a", count: 200))
  await #expect(throws: TransportFailure.self) {
    let _: [WorkspaceInfo] = try await client.call("list_workspaces")
  }
}

@Test func cancelledOperationsExposeRecoveryWithoutRepositoryErrors() throws {
  for materialize in [true, false] {
    let payload = try JSONSerialization.data(withJSONObject: [
      "schema_version": 1,
      "result": ["schema_version": 1, "id": "cancelled", "task_id": "task", "plan_id": "plan",
                 "status": "cancelled", "materialize": materialize, "repos": []] as [String: Any],
    ])
    let operation = try ServiceClient.decode(payload, as: WorkbenchOperation.self)
    #expect(operation.canRetry)
    #expect(operation.canMaterialize == !materialize)
  }
}
