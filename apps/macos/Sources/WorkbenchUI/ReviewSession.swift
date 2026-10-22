import Foundation
import WorkbenchProtocol

public enum FileReviewState: Equatable, Sendable {
  case unread, reviewed, needsReview, checking
  public var label: String {
    switch self {
    case .unread: "미검토"
    case .reviewed: "검토함"
    case .needsReview: "다시 검토"
    case .checking: "변경 확인 중"
    }
  }
}

struct ReviewFileID: Hashable {
  let location: WorktreeSelection
  let path: String
  let staged: Bool
  let stashOID: String?
}

public struct ReadingCheckpoint: Sendable {
  public let date: Date
  public let text: String
  public let hunks: [String]
  public let reviewKey: String
  public let contentIdentity: String
  var byteCount: Int { text.utf8.count + hunks.reduce(0) { $0 + $1.utf8.count } }
}

/// Session-local personal reading state; never an approval or Git mutation.
struct ReviewSession {
  private(set) var checkpoints: [ReviewFileID: ReadingCheckpoint] = [:]
  private var order: [ReviewFileID] = []
  private var offsets: [ReviewFileID: (content: String, y: Double)] = [:]
  private var offsetOrder: [ReviewFileID] = []
  static let maximumCheckpointBytes = 512 * 1024
  static let maximumTotalBytes = 4 * 1024 * 1024

  mutating func mark(_ diff: FileDiff, at id: ReviewFileID, date: Date = Date()) -> Bool {
    let checkpoint = ReadingCheckpoint(
      date: date, text: diff.text, hunks: diff.hunks,
      reviewKey: diff.reviewKey ?? diff.snapshotHash, contentIdentity: diff.contentIdentity)
    guard checkpoint.byteCount <= Self.maximumCheckpointBytes else { return false }
    checkpoints[id] = checkpoint
    order.removeAll { $0 == id }
    order.append(id)
    while order.count > 32 || checkpoints.values.reduce(0, { $0 + $1.byteCount }) > Self.maximumTotalBytes {
      checkpoints.removeValue(forKey: order.removeFirst())
    }
    return true
  }

  mutating func unmark(_ id: ReviewFileID) {
    checkpoints.removeValue(forKey: id)
    order.removeAll { $0 == id }
  }

  func state(for id: ReviewFileID, key: String) -> FileReviewState {
    guard let checkpoint = checkpoints[id] else { return .unread }
    return checkpoint.reviewKey == key ? .reviewed : .needsReview
  }

  mutating func rememberOffset(_ y: Double, content: String, at id: ReviewFileID) {
    guard y.isFinite else { return }
    offsets[id] = (content, max(0, y))
    offsetOrder.removeAll { $0 == id }
    offsetOrder.append(id)
    if offsetOrder.count > 128 { offsets.removeValue(forKey: offsetOrder.removeFirst()) }
  }

  func offset(content: String, at id: ReviewFileID) -> Double {
    guard let saved = offsets[id], saved.content == content else { return 0 }
    return saved.y
  }

  func changedHunks(in diff: FileDiff, at id: ReviewFileID) -> Set<Int> {
    guard let previous = checkpoints[id] else { return Set(diff.hunks.indices) }
    var read = previous.hunks.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    return Set(diff.hunks.indices.filter { index in
      let hunk = diff.hunks[index]
      if read[hunk, default: 0] > 0 { read[hunk, default: 0] -= 1; return false }
      return true
    })
  }

  func removedHunkCount(in diff: FileDiff, at id: ReviewFileID) -> Int {
    guard let previous = checkpoints[id] else { return 0 }
    // Count occurrences, not just unique strings, for repeated hunks.
    var remaining = diff.hunks.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    return previous.hunks.reduce(0) { count, hunk in
      if remaining[hunk, default: 0] > 0 { remaining[hunk, default: 0] -= 1; return count }
      return count + 1
    }
  }
}
