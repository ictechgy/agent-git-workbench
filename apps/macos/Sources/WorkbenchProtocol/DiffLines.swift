import Foundation

public enum LineKind: Sendable, Equatable { case context, addition, deletion, metadata }
public struct DiffCell: Sendable {
  public let number: Int?
  public let text: String
  public let kind: LineKind
  public var noNewline = false
}
public struct SplitDiffRow: Sendable, Identifiable {
  public let id: Int
  public let before: DiffCell?
  public let after: DiffCell?
}
public struct UnifiedDiffRow: Sendable, Identifiable {
  public let id: Int
  public let oldNumber: Int?
  public let newNumber: Int?
  public let text: String
  public let kind: LineKind
}
public struct ParsedHunk: Sendable, Identifiable {
  public let id: Int
  public let header: String
  public let unified: [UnifiedDiffRow]
  public let split: [SplitDiffRow]
}

public enum DiffLines {
  /// Keep one Git line on one visual row without changing the reviewed bytes.
  public static func displayText(_ text: String) -> String {
    displayText(text, preservingLineFeeds: false)
  }

  /// Show captured patches and request previews without hiding control scalars.
  /// Ordinary LF line breaks and tabs retain their layout; stored bytes stay raw.
  public static func displayMultilineText(_ text: String) -> String {
    displayText(text, preservingLineFeeds: true)
  }

  private static func displayText(_ text: String, preservingLineFeeds: Bool) -> String {
    var output = ""
    for scalar in text.unicodeScalars {
      switch scalar.value {
      case 10 where preservingLineFeeds: output.unicodeScalars.append(scalar)
      case 0...8, 10...31: output.unicodeScalars.append(Unicode.Scalar(0x2400 + scalar.value)!)
      case 0x7f: output += "␡"
      case 0x85, 0x061c, 0x200e, 0x200f, 0x2028, 0x2029, 0x202a...0x202e, 0x2066...0x2069:
        output += String(format: "⟨U+%04X⟩", scalar.value)
      default: output.unicodeScalars.append(scalar)
      }
    }
    return output
  }

  public static func parse(_ hunks: [String]) -> [ParsedHunk] {
    hunks.enumerated().map { index, text in
      var lines = text.components(separatedBy: "\n")
      if lines.last == "" { lines.removeLast() }
      let header = lines.first ?? ""
      let pattern = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/
      let match = try? pattern.firstMatch(in: header)
      var old = Int(match?.1 ?? "") ?? 0
      var new = Int(match?.2 ?? "") ?? 0
      var unified: [UnifiedDiffRow] = []
      for (lineIndex, line) in lines.dropFirst().enumerated() {
        // Git's prefix is one ASCII scalar, which may share a Swift grapheme
        // with the first combining scalar of the file's actual contents.
        switch line.unicodeScalars.first {
        case "-":
          unified.append(
            .init(
              id: lineIndex, oldNumber: old, newNumber: nil, text: String(line.unicodeScalars.dropFirst()),
              kind: .deletion))
          old += 1
        case "+":
          unified.append(
            .init(
              id: lineIndex, oldNumber: nil, newNumber: new, text: String(line.unicodeScalars.dropFirst()),
              kind: .addition))
          new += 1
        case " ":
          unified.append(
            .init(
              id: lineIndex, oldNumber: old, newNumber: new, text: String(line.unicodeScalars.dropFirst()),
              kind: .context))
          old += 1
          new += 1
        default:
          unified.append(
            .init(id: lineIndex, oldNumber: nil, newNumber: nil, text: line, kind: .metadata))
        }
      }
      var split: [SplitDiffRow] = []
      var removals: [DiffCell] = []
      var additions: [DiffCell] = []
      func flush() {
        for i in 0..<max(removals.count, additions.count) {
          split.append(
            .init(
              id: split.count, before: i < removals.count ? removals[i] : nil,
              after: i < additions.count ? additions[i] : nil))
        }
        removals.removeAll()
        additions.removeAll()
      }
      for (index, row) in unified.enumerated() {
        switch row.kind {
        case .deletion:
          removals.append(.init(number: row.oldNumber, text: row.text, kind: .deletion))
        case .addition:
          additions.append(.init(number: row.newNumber, text: row.text, kind: .addition))
        case .context:
          flush()
          split.append(
            .init(
              id: split.count, before: .init(number: row.oldNumber, text: row.text, kind: .context),
              after: .init(number: row.newNumber, text: row.text, kind: .context)))
        case .metadata:
          if row.text == "\\ No newline at end of file", index > 0 {
            switch unified[index - 1].kind {
            case .deletion:
              if !removals.isEmpty { removals[removals.count - 1].noNewline = true }
            case .addition:
              if !additions.isEmpty { additions[additions.count - 1].noNewline = true }
            case .context:
              if let last = split.popLast() {
                var before = last.before; before?.noNewline = true
                var after = last.after; after?.noNewline = true
                split.append(.init(id: last.id, before: before, after: after))
              }
            case .metadata: break
            }
          }
        }
      }
      flush()
      return ParsedHunk(id: index, header: header, unified: unified, split: split)
    }
  }
}
