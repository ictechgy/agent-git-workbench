import AppKit
import CryptoKit
import Foundation
import SwiftUI
import Testing
import WorkbenchProtocol

@testable import WorkbenchUI

@Test func splitDiffAccessibilityUsesTheSameControlProjectionAsTheVisibleCell() throws {
  let old = "before\rhidden\u{202e}direction"
  let new = "after\u{2028}line\u{2067}direction\u{2069}"
  let row = DiffLines.parse(["@@ -18 +31 @@\n-\(old)\n+\(new)\n"])[0].split[0]
  let before = try #require(row.before)
  let after = try #require(row.after)
  #expect(before.codeAccessibilityLabel == "삭제 18 before␍hidden⟨U+202E⟩direction")
  #expect(after.codeAccessibilityLabel == "추가 31 after⟨U+2028⟩line⟨U+2067⟩direction⟨U+2069⟩")
  #expect(Data(before.text.utf8) == Data(old.utf8))
  #expect(Data(after.text.utf8) == Data(new.utf8))
}

@Test func displayProjectionsLeaveCapturedPatchAndItsIdentityByteExact() throws {
  let header = "diff --git a/file.swift b/file.swift\n--- a/file.swift\n+++ b/file.swift\n"
  let hunk =
    "@@ -1 +1 @@ function\u{202e}name\n-old\r\n+\tnew\u{2028}line\u{2066}direction\u{2069}\n"
  let raw = header + hunk
  let data = try JSONSerialization.data(withJSONObject: [
    "snapshot_hash": "snapshot", "review_key": "review", "path": "file.swift", "staged": false,
    "header": header, "hunks": [hunk], "text": raw, "can_stage_hunks": true,
  ])
  let decoder = JSONDecoder()
  decoder.keyDecodingStrategy = .convertFromSnakeCase
  let diff = try decoder.decode(FileDiff.self, from: data)
  let id = ReviewFileID(
    location: .init(repoId: "synthetic"), path: diff.path, staged: false, stashOID: nil)
  var session = ReviewSession()
  let marked = session.mark(diff, at: id)
  #expect(marked)
  let checkpoint = try #require(session.checkpoints[id])
  let display = DiffLines.displayMultilineText(checkpoint.text)
  #expect(
    display.contains("function⟨U+202E⟩name\n-old␍\n+\tnew⟨U+2028⟩line⟨U+2066⟩direction⟨U+2069⟩\n"))
  #expect(Data(checkpoint.text.utf8) == Data(raw.utf8))
  #expect(checkpoint.hunks.map { Data($0.utf8) } == [Data(hunk.utf8)])
  #expect(Data(diff.hunks[0].utf8) == Data(hunk.utf8))
  #expect(diff.canStageHunks)
  #expect(diff.parsedHunks[0].header == "@@ -1 +1 @@ function\u{202e}name")
  #expect(diff.parsedHunks[0].split[0].after?.text == "\tnew\u{2028}line\u{2066}direction\u{2069}")
  let expectedIdentity = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }
    .joined()
  #expect(diff.contentIdentity == expectedIdentity)
  #expect(checkpoint.contentIdentity == expectedIdentity)
  #expect(session.changedHunks(in: diff, at: id).isEmpty)
}

@Test func requestPreviewExposesControlsWhileKeepingTheTransferTextUnchanged() {
  let patch = "@@ -1 +1 @@ function\u{202e}name\n-old\n+safe\u{2028}next\u{2067}direction\u{2069}\n"
  let request = HunkRequest(
    repository: "synthetic", folder: "/tmp/synthetic", task: "Review", branch: "main", head: "head",
    path: "file.swift", staged: false, snapshot: "snapshot", patch: patch)
  let instruction = "Keep\tindentation\nthen inspect \u{2066}this\u{2069}."
  let raw = request.text(instruction: instruction)
  let preview = request.previewText(instruction: instruction)
  #expect(preview.contains("function⟨U+202E⟩name"))
  #expect(preview.contains("+safe⟨U+2028⟩next⟨U+2067⟩direction⟨U+2069⟩"))
  #expect(preview.contains("Keep\tindentation\nthen inspect ⟨U+2066⟩this⟨U+2069⟩."))
  #expect(
    !preview.unicodeScalars.contains {
      [0x202e, 0x2028, 0x2066, 0x2067, 0x2069].contains($0.value)
    })
  #expect(Data(request.patch.utf8) == Data(patch.utf8))
  #expect(Data(request.text(instruction: instruction).utf8) == Data(raw.utf8))
  #expect(raw.contains(patch))
}

@Test @MainActor func requestCopyUsesRawBytesOnAnIsolatedPasteboard() throws {
  let patch = "@@ -1 +1 @@ name\u{202e}suffix\n-before\r\n+\tafter\u{2028}tail\n"
  let request = HunkRequest(
    repository: "synthetic", folder: "/tmp/synthetic", task: "Review", branch: "main", head: "head",
    path: "file.swift", staged: false, snapshot: "snapshot", patch: patch)
  let instruction = "Keep raw\tindentation\nwith \u{2067}direction\u{2069}."
  let before = Data(request.text(instruction: instruction).utf8)
  let preview = request.previewText(instruction: instruction)
  let pasteboard = NSPasteboard.withUniqueName()
  defer { pasteboard.releaseGlobally() }
  #expect(request.copy(instruction: instruction, to: pasteboard))
  let copied = try #require(pasteboard.string(forType: .string))
  #expect(Data(copied.utf8) == before)
  #expect(copied.contains(patch))
  #expect(copied.contains(instruction))
  #expect(!copied.contains("⟨U+202E⟩"))
  #expect(preview.contains("⟨U+202E⟩"))
}

@Test @MainActor func nativeHunkRequestPreviewRendersItsProductionSheet() async throws {
  _ = NSApplication.shared
  let request = HunkRequest(
    repository: "synthetic", folder: "/tmp/synthetic", task: "Review", branch: "main", head: "head",
    path: "file.swift", staged: false, snapshot: "snapshot",
    patch: "@@ -1 +1 @@ function\u{202e}name\n-old\n+safe\u{2028}next\u{2067}direction\u{2069}\n")
  let window = NSWindow(
    contentRect: NSRect(x: -10_000, y: -10_000, width: 640, height: 540),
    styleMask: [.borderless], backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  defer { window.close() }
  window.appearance = NSAppearance(named: .aqua)
  let host = NSHostingView(
    rootView: HunkRequestSheet(request: request)
      .background(WorkbenchTheme.canvas).environment(\.colorScheme, .light))
  window.contentView = host
  window.orderFront(nil)
  for _ in 0..<10 {
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(15))
  }
  #expect(host.bounds.size == NSSize(width: 640, height: 540))
  if let artifact = ProcessInfo.processInfo.environment["RIVER_DISPLAY_PROOF_PNG"] {
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: artifact))
    func scrollViews(in view: NSView) -> [NSScrollView] {
      (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
    }
    let previewScroll = scrollViews(in: host).filter { $0.bounds.height > 100 }.first
    if let previewScroll, let document = previewScroll.documentView {
      previewScroll.contentView.scroll(
        to: NSPoint(
          x: 0, y: max(0, document.bounds.height - previewScroll.contentView.bounds.height)))
      previewScroll.reflectScrolledClipView(previewScroll.contentView)
      host.layoutSubtreeIfNeeded()
      try await Task.sleep(for: .milliseconds(30))
      let bottomBitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bottomBitmap)
      let bottomPNG = try #require(bottomBitmap.representation(using: .png, properties: [:]))
      try bottomPNG.write(
        to: URL(fileURLWithPath: artifact).deletingPathExtension().appendingPathExtension(
          "bottom.png"))
    }
    let metadata = try JSONSerialization.data(
      withJSONObject: [
        "scope":
          "Owned offscreen NSWindow hosting the production HunkRequestSheet; cached view only, no OS input, accessibility-tree, or VoiceOver claim.",
        "raw_request_contains_direction_control": request.text(instruction: "").contains(
          "\u{202e}"),
        "preview_scroll_found": previewScroll != nil,
        "appearance": "light",
        "png_bytes": png.count,
      ], options: [.prettyPrinted, .sortedKeys])
    try metadata.write(
      to: URL(fileURLWithPath: artifact).deletingPathExtension().appendingPathExtension("json"))
  }
}
