import Foundation

/// Repository fields and reports are data, not Markdown headings or AI instructions.
enum HandoffText {
  static func field(_ text: String) -> String {
    let visible = text.unicodeScalars.map { scalar -> String in
      switch scalar.properties.generalCategory {
      case .format, .lineSeparator, .paragraphSeparator: return "\\u{\(String(scalar.value, radix: 16))}"
      default: return String(scalar)
      }
    }.joined()
    return String(reflecting: visible)
  }
  static func block(_ text: String) -> String {
    let longest = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
    let fence = String(repeating: "`", count: max(3, longest + 1))
    return "\(fence)text\n\(text)\n\(fence)\n"
  }
}
