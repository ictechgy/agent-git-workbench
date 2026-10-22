import Foundation
import Testing
import WorkbenchProtocol
@testable import WorkbenchUI

private func reviewDiff(_ hunks: [String], key: String = "file-1", snapshot: String = "snapshot-1") throws -> FileDiff {
  let header = "diff --git a/file.swift b/file.swift\n--- a/file.swift\n+++ b/file.swift\n"
  let data = try JSONSerialization.data(withJSONObject: [
    "snapshot_hash": snapshot, "review_key": key, "path": "file.swift", "staged": false,
    "header": header, "hunks": hunks, "text": header + hunks.joined(), "can_stage_hunks": true,
  ])
  let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
  return try decoder.decode(FileDiff.self, from: data)
}

@Test func reviewCheckpointTracksChangedAndRemovedHunksWithoutApprovingNewContent() throws {
  let first = "@@ -1 +1 @@\n-old\n+one\n"
  let second = "@@ -20 +20 @@\n-old\n+two\n"
  let replacement = "@@ -20 +20 @@\n-old\n+three\n"
  let id = ReviewFileID(location: .init(repoId: "api", opId: "task"), path: "file.swift", staged: false, stashOID: nil)
  var session = ReviewSession()
  let marked = session.mark(try reviewDiff([first, second]), at: id)
  #expect(marked)
  #expect(session.state(for: id, key: "file-1") == .reviewed)
  let changed = try reviewDiff([first, replacement], key: "file-2")
  #expect(session.state(for: id, key: "file-2") == .needsReview)
  #expect(session.changedHunks(in: changed, at: id) == [1])
  #expect(session.removedHunkCount(in: changed, at: id) == 1)
  #expect(session.checkpoints[id]?.text.contains("+two") == true)
  let removed = try reviewDiff([first], key: "file-3")
  #expect(session.changedHunks(in: removed, at: id).isEmpty)
  #expect(session.removedHunkCount(in: removed, at: id) == 1)
  // A changed comparison context invalidates reading even when displayed bytes match.
  #expect(session.state(for: id, key: "new-head-same-patch") == .needsReview)
}

@Test func readingAndScrollAreScopedToFolderModeAndExactRenderedContent() throws {
  let diff = try reviewDiff(["@@ -1 +1 @@\n-a\n+b\n"])
  let task = WorktreeSelection(repoId: "api", opId: "task")
  let id = ReviewFileID(location: task, path: "file.swift", staged: false, stashOID: nil)
  let original = ReviewFileID(location: .init(repoId: "api"), path: id.path, staged: false, stashOID: nil)
  let staged = ReviewFileID(location: task, path: id.path, staged: true, stashOID: nil)
  var session = ReviewSession()
  let marked = session.mark(diff, at: id)
  #expect(marked)
  session.rememberOffset(420, content: diff.contentIdentity, at: id)
  #expect(session.offset(content: diff.contentIdentity, at: id) == 420)
  #expect(session.offset(content: "changed-content", at: id) == 0)
  #expect(session.offset(content: diff.contentIdentity, at: original) == 0)
  #expect(session.state(for: original, key: "file-1") == .unread)
  #expect(session.state(for: staged, key: "file-1") == .unread)
  session.rememberOffset(.infinity, content: diff.contentIdentity, at: id)
  #expect(session.offset(content: diff.contentIdentity, at: id) == 420)
}

@Test func reviewHistoryIsBoundedAndDoesNotSilentlyAcceptOversizedDiff() throws {
  var session = ReviewSession()
  let location = WorktreeSelection(repoId: "api")
  let first = ReviewFileID(location: location, path: "0", staged: false, stashOID: nil)
  for i in 0..<34 {
    let id = ReviewFileID(location: location, path: String(i), staged: false, stashOID: nil)
    let marked = session.mark(try reviewDiff(["@@ -1 +1 @@\n-a\n+b\n"]), at: id)
    #expect(marked)
  }
  #expect(session.checkpoints.count == 32)
  #expect(session.state(for: first, key: "file-1") == .unread)
  let oversized = session.mark(try reviewDiff([String(repeating: "x", count: 300_000)]), at: first)
  #expect(!oversized)
  #expect(session.checkpoints[first] == nil)
}

@Test func selectedHunkHandoffKeepsSnapshotAndUserInstructionAsPlainText() {
  let patch = "@@ -1 +1 @@\n-previous\n+selected\n"
  let request = HunkRequest(repository: "api", folder: "/tmp/synthetic repo", task: "Login",
    branch: "refs/heads/login", head: "abc123", path: "file.swift", staged: false,
    snapshot: "observed-snapshot", patch: patch)
  let text = request.text(instruction: "  Handle empty values  ")
  #expect(text.contains("Handle empty values"))
  #expect(text.contains("/tmp/synthetic repo"))
  #expect(text.contains("observed-snapshot"))
  #expect(text.contains(patch))
  #expect(!text.contains("unselected-hunk"))
  #expect(text.contains("stage/commit"))
}
