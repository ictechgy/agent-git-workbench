import AppKit
import Combine
import Foundation
import SwiftUI

public enum ReadingDensity: String, Codable, CaseIterable, Sendable {
  case comfortable, compact
  public var title: String { self == .comfortable ? "여유롭게" : "촘촘하게" }
}

public struct ReadingConfiguration: Codable, Equatable, Sendable {
  public var codeSize: Double = 13
  public var density: ReadingDensity = .comfortable
  public init() {}
  fileprivate var normalized: Self {
    var result = self
    result.codeSize = codeSize.isFinite ? min(20, max(11, codeSize.rounded())) : 13
    return result
  }
  public var codeRowHeight: CGFloat {
    ceil(codeSize * 1.45) + (density == .comfortable ? 9 : 3)
  }
  public var splitHeaderHeight: CGFloat { 28 }
  public func lineNumberWidth(digits: Int) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular)
    let digitWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
    return max(38, ceil(digitWidth * CGFloat(max(1, min(20, digits)))) + 8)
  }
  public var listVerticalPadding: CGFloat { density == .comfortable ? 10 : 6 }
  public func hunkHeight(rows: Int, split: Bool) -> CGFloat {
    CGFloat(max(0, rows)) * codeRowHeight + (split ? splitHeaderHeight : 0) + 12
  }
}

@MainActor
public final class ReadingPreferences: ObservableObject {
  @Published public private(set) var configuration: ReadingConfiguration
  private let defaults: UserDefaults
  private let key = "workbench.reading.v1"
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    configuration =
      defaults.data(forKey: key)
      .flatMap { try? JSONDecoder().decode(ReadingConfiguration.self, from: $0) }?
      .normalized ?? ReadingConfiguration()
  }
  public func setCodeSize(_ value: Double) { update { $0.codeSize = value } }
  public func setDensity(_ value: ReadingDensity) { update { $0.density = value } }
  public func reset() { update { $0 = ReadingConfiguration() } }
  private func update(_ edit: (inout ReadingConfiguration) -> Void) {
    var next = configuration
    edit(&next)
    next = next.normalized
    guard next != configuration else { return }
    configuration = next
    if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
  }
}

private struct RiverReadingKey: EnvironmentKey {
  static let defaultValue = ReadingConfiguration()
}
extension EnvironmentValues {
  var riverReading: ReadingConfiguration {
    get { self[RiverReadingKey.self] }
    set { self[RiverReadingKey.self] = newValue }
  }
}
