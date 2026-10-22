import Combine
import Foundation

public enum WorkbenchAppearance: String, CaseIterable, Sendable {
  case light, dark, system
  public var title: String {
    switch self {
    case .light: "맑은 물"
    case .dark: "깊은 물"
    case .system: "시스템 설정"
    }
  }
}

public enum RepositoryLayout: String, Codable, CaseIterable, Sendable {
  case tabs, tracks
  public var title: String { self == .tabs ? "가로 탭" : "저장소 트랙" }
}
public enum GraphPlacement: String, Codable, CaseIterable, Sendable {
  case top, bottom, hidden
  public var title: String {
    switch self {
    case .top: "상단"
    case .bottom: "하단"
    case .hidden: "숨김"
    }
  }
}
public enum InspectorVisibility: String, Codable, CaseIterable, Sendable {
  case automatic, visible, hidden
  public var title: String {
    switch self {
    case .automatic: "창 크기에 맞춤"
    case .visible: "표시"
    case .hidden: "숨김"
    }
  }
}
public enum LayoutPreset: String, CaseIterable, Identifiable, Sendable {
  case focus, balanced, classic, review, tracks
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .focus: "집중"
    case .balanced: "균형"
    case .classic: "클래식"
    case .review: "코드 검토"
    case .tracks: "저장소 트랙"
    }
  }
  public var configuration: LayoutConfiguration {
    var value = LayoutConfiguration()
    switch self {
    case .focus, .balanced:
      value.graph = .hidden
      value.inspector = self == .focus ? .hidden : .visible
      value.splitDiff = false
      value.dock = self == .focus ? .focused : .balanced
    case .classic: break
    case .review: value.graph = .hidden
    case .tracks:
      value.navigation = .tracks
      value.graph = .hidden
    }
    return value
  }
}
public struct LayoutConfiguration: Codable, Equatable, Sendable {
  public var navigation: RepositoryLayout = .tabs
  public var graph: GraphPlacement = .top
  public var inspector: InspectorVisibility = .automatic
  public var fileWidth: Double = 230
  public var inspectorWidth: Double = 310
  public var historyHeight: Double = 210
  public var historyExpanded = true
  public var splitDiff = true
  public var dock: DockLayout?
  public init() {}
  fileprivate var normalized: Self {
    var value = self
    func clamp(_ number: Double, _ bounds: ClosedRange<Double>, fallback: Double) -> Double {
      number.isFinite ? min(bounds.upperBound, max(bounds.lowerBound, number)) : fallback
    }
    value.fileWidth = clamp(fileWidth, 180...360, fallback: 230)
    value.inspectorWidth = clamp(inspectorWidth, 270...420, fallback: 310)
    value.historyHeight = clamp(historyHeight, 140...440, fallback: 210)
    value.dock = dock?.validated ?? DockLayout.legacy(value)
    return value
  }
}

@MainActor
public final class LayoutPreferences: ObservableObject {
  @Published public private(set) var configuration: LayoutConfiguration
  @Published public var appearance: WorkbenchAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: "workbench.appearance.v1") }
  }
  private let defaults: UserDefaults
  private let key = "workbench.layout.v1"
  private var dockUndo: [DockLayout] = []
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = defaults.string(forKey: "workbench.appearance.v1")
      .flatMap(WorkbenchAppearance.init(rawValue:)) ?? .light
    configuration =
      defaults.data(forKey: key)
      .flatMap { try? JSONDecoder().decode(LayoutConfiguration.self, from: $0) }?
      .normalized ?? LayoutPreset.focus.configuration.normalized
  }
  public var preset: LayoutPreset? {
    LayoutPreset.allCases.first {
      var current = configuration
      var proposed = $0.configuration.normalized
      let proposedDock = proposed.dock!
      current.dock = nil
      proposed.dock = nil
      return current == proposed && dockLayout.sameArrangement(as: proposedDock)
    }
  }
  public var dockLayout: DockLayout { configuration.dock! }
  public var canUndoDock: Bool { !dockUndo.isEmpty }
  public func apply(_ preset: LayoutPreset) {
    rememberDock()
    set(preset.configuration)
  }
  public func update(_ edit: (inout LayoutConfiguration) -> Void) {
    var value = configuration
    edit(&value)
    if value.dock == configuration.dock,
      value.graph != configuration.graph || value.inspector != configuration.inspector
        || value.historyExpanded != configuration.historyExpanded
    {
      value.dock = DockLayout.legacy(value)
    }
    set(value)
  }
  public func dockPane(_ pane: WorkbenchPane, nextTo target: WorkbenchPane?, edge: DockEdge) {
    replaceDock(dockLayout.moving(pane, nextTo: target, edge: edge))
  }
  public func hidePane(_ pane: WorkbenchPane) { replaceDock(dockLayout.hiding(pane)) }
  public func showPane(_ pane: WorkbenchPane) {
    if dockLayout.contains(pane) {
      selectPane(pane)
      return
    }
    // Reuse an existing utility group; opening a reference should not grow another column.
    if [.commit, .stash, .details].contains(pane),
      let utility = [WorkbenchPane.commit, .stash, .details].first(where: { dockLayout.contains($0) })
    {
      dockPane(pane, nextTo: utility, edge: .center)
      return
    }
    let target = dockLayout.contains(.diff) ? WorkbenchPane.diff : dockLayout.panes.first
    dockPane(
      pane, nextTo: target, edge: pane == .graph ? .bottom : (pane == .branches ? .center : .right))
  }
  public func selectPane(_ pane: WorkbenchPane) {
    update { $0.dock = dockLayout.selecting(pane) }
  }
  public func resizeDock(_ id: String, ratio: Double) {
    replaceDock(dockLayout.resizing(id, ratio: ratio))
  }
  public func undoDock() {
    guard let previous = dockUndo.popLast() else { return }
    update { $0.dock = previous }
  }
  private func replaceDock(_ value: DockLayout) {
    guard let checked = value.validated, checked != dockLayout else { return }
    rememberDock()
    update { $0.dock = checked }
  }
  private func rememberDock() {
    dockUndo.append(dockLayout)
    if dockUndo.count > 20 { dockUndo.removeFirst() }
  }
  private func set(_ value: LayoutConfiguration) {
    let normalized = value.normalized
    guard normalized != configuration else { return }
    configuration = normalized
    if let encoded = try? JSONEncoder().encode(normalized) { defaults.set(encoded, forKey: key) }
  }
  public func inspectorIsVisible(width: Double) -> Bool {
    switch configuration.inspector {
    case .automatic: width >= 1280
    case .visible: true
    case .hidden: false
    }
  }
}
