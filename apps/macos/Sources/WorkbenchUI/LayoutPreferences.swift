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

public struct SavedLayout: Codable, Identifiable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var configuration: LayoutConfiguration
  public init(id: UUID = UUID(), name: String, configuration: LayoutConfiguration) {
    self.id = id
    self.name = name
    self.configuration = configuration
  }
}

public enum SavedLayoutError: Error, LocalizedError, Equatable, Sendable {
  case invalidName, invalidCharacters, duplicateName, limitReached, storageLimit, notFound
  public var errorDescription: String? {
    switch self {
    case .invalidName: "이름은 1~48자로 입력하세요."
    case .invalidCharacters: "이름에 줄바꿈이나 제어 문자를 사용할 수 없습니다."
    case .duplicateName: "같은 이름의 화면 구성이 있습니다."
    case .limitReached: "화면 구성은 20개까지 저장할 수 있습니다."
    case .storageLimit: "화면 구성의 저장 용량을 넘었습니다. 이름을 줄이거나 저장한 구성을 정리하세요."
    case .notFound: "저장한 화면 구성을 찾을 수 없습니다."
    }
  }
}

private struct StoredLayouts: Codable {
  var version = 1
  var layouts: [SavedLayout]
  var rejectedEntries = false
  init(layouts: [SavedLayout]) { self.layouts = layouts }
  private enum CodingKeys: String, CodingKey { case version, layouts }
  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    version = try values.decode(Int.self, forKey: .version)
    guard version == 1 else {
      throw DecodingError.dataCorruptedError(
        forKey: .version, in: values, debugDescription: "Unsupported saved-layout version")
    }
    var entries = try values.nestedUnkeyedContainer(forKey: .layouts)
    guard let count = entries.count, count <= 20 else {
      throw DecodingError.dataCorruptedError(
        forKey: .layouts, in: values, debugDescription: "Too many saved layouts")
    }
    layouts = []
    while !entries.isAtEnd {
      // A malformed entry must not discard its valid siblings or become a factory layout.
      let entry = try entries.superDecoder()
      if let layout = try? SavedLayout(from: entry) {
        layouts.append(layout)
      } else {
        rejectedEntries = true
      }
    }
  }
}

@MainActor
public final class LayoutPreferences: ObservableObject {
  public let recoveryNotice: String?
  @Published public private(set) var configuration: LayoutConfiguration
  @Published public private(set) var savedLayouts: [SavedLayout]
  @Published public private(set) var focusedPane: WorkbenchPane?
  @Published public var showsOptions = false
  @Published public var appearance: WorkbenchAppearance {
    didSet { defaults.set(appearance.rawValue, forKey: "workbench.appearance.v1") }
  }
  private let defaults: UserDefaults
  private let key = "workbench.layout.v1"
  private let savedKey = "workbench.saved-layouts.v1"
  private var dockUndo: [LayoutConfiguration] = []
  @Published private var selectedSavedLayoutID: UUID?
  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance =
      defaults.string(forKey: "workbench.appearance.v1")
      .flatMap(WorkbenchAppearance.init(rawValue:)) ?? .light
    let current = Self.loadCurrent(defaults: defaults, key: key)
    configuration = current.configuration
    let library = Self.loadSaved(defaults: defaults, key: savedKey)
    savedLayouts = library.layouts
    recoveryNotice =
      current.recovered || library.recovered
      ? "읽지 못한 화면 설정의 원본을 보관했습니다. 사용 가능한 설정으로 화면을 열었습니다."
      : nil
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
  public var presentedDockLayout: DockLayout {
    guard let focusedPane else { return dockLayout }
    return DockLayout(
      root: .tabs(id: "focused-\(focusedPane.rawValue)", panes: [focusedPane], active: focusedPane))
  }
  public var currentLayoutTitle: String {
    if let selected = savedLayouts.first(where: {
      $0.id == selectedSavedLayoutID && Self.sameConfiguration($0.configuration, configuration)
    }) {
      return selected.name
    }
    return savedLayouts.first(where: { Self.sameConfiguration($0.configuration, configuration) })?
      .name ?? preset?.title ?? "사용자 설정"
  }
  public var canUndoDock: Bool { !dockUndo.isEmpty }
  public func apply(_ preset: LayoutPreset) {
    restorePaneLayout()
    let next = preset.configuration.normalized
    guard !Self.sameConfiguration(next, configuration) else { return }
    rememberDock()
    set(next)
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
    var styleOnly = configuration
    styleOnly.splitDiff = value.splitDiff
    if value != styleOnly { restorePaneLayout() }
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
      let utility = [WorkbenchPane.commit, .stash, .details].first(where: {
        dockLayout.contains($0)
      })
    {
      dockPane(pane, nextTo: utility, edge: .center)
      return
    }
    let target = dockLayout.contains(.diff) ? WorkbenchPane.diff : dockLayout.panes.first
    dockPane(
      pane, nextTo: target, edge: pane == .graph ? .bottom : (pane == .branches ? .center : .right))
  }
  public func selectPane(_ pane: WorkbenchPane) {
    restorePaneLayout()
    update { $0.dock = dockLayout.selecting(pane) }
  }
  public func resizeDock(_ id: String, ratio: Double) {
    replaceDock(dockLayout.resizing(id, ratio: ratio))
  }
  public func undoDock() {
    restorePaneLayout()
    guard let previous = dockUndo.popLast() else { return }
    set(previous)
  }
  @discardableResult
  public func saveCurrentLayout(named name: String) throws -> UUID {
    let name = try availableName(name)
    guard savedLayouts.count < 20 else { throw SavedLayoutError.limitReached }
    let saved = SavedLayout(name: name, configuration: configuration.normalized)
    try persistSavedLayouts(savedLayouts + [saved])
    selectedSavedLayoutID = saved.id
    return saved.id
  }
  public func applySavedLayout(_ id: UUID) {
    restorePaneLayout()
    guard let saved = savedLayouts.first(where: { $0.id == id }) else { return }
    if !Self.sameConfiguration(saved.configuration, configuration) {
      rememberDock()
      set(saved.configuration)
    }
    selectedSavedLayoutID = id
  }
  public func renameSavedLayout(_ id: UUID, to name: String) throws {
    guard let index = savedLayouts.firstIndex(where: { $0.id == id }) else {
      throw SavedLayoutError.notFound
    }
    let name = try availableName(name, excluding: id)
    guard savedLayouts[index].name != name else { return }
    var candidate = savedLayouts
    candidate[index].name = name
    try persistSavedLayouts(candidate)
  }
  public func replaceSavedLayout(_ id: UUID) throws {
    guard let index = savedLayouts.firstIndex(where: { $0.id == id }) else {
      throw SavedLayoutError.notFound
    }
    var candidate = savedLayouts
    candidate[index].configuration = configuration.normalized
    try persistSavedLayouts(candidate)
    selectedSavedLayoutID = id
  }
  public func deleteSavedLayout(_ id: UUID) {
    guard savedLayouts.contains(where: { $0.id == id }) else { return }
    let candidate = savedLayouts.filter { $0.id != id }
    guard (try? persistSavedLayouts(candidate)) != nil else { return }
    if selectedSavedLayoutID == id { selectedSavedLayoutID = nil }
  }
  public func focusPane(_ pane: WorkbenchPane) {
    guard dockLayout.contains(pane) else { return }
    focusedPane = focusedPane == pane ? nil : pane
  }
  public func restorePaneLayout() { focusedPane = nil }
  public func isPanePresented(_ pane: WorkbenchPane) -> Bool {
    focusedPane.map { $0 == pane } ?? dockLayout.isVisible(pane)
  }
  private func replaceDock(_ value: DockLayout) {
    restorePaneLayout()
    guard let checked = value.validated, !checked.sameArrangement(as: dockLayout) else { return }
    rememberDock()
    update { $0.dock = checked }
  }
  private func rememberDock() {
    dockUndo.append(configuration)
    if dockUndo.count > 20 { dockUndo.removeFirst() }
  }
  private func set(_ value: LayoutConfiguration) {
    let normalized = value.normalized
    guard normalized != configuration else { return }
    configuration = normalized
    if let encoded = try? JSONEncoder().encode(normalized) { defaults.set(encoded, forKey: key) }
  }
  private func persistSavedLayouts(_ candidate: [SavedLayout]) throws {
    let encoded = try JSONEncoder().encode(StoredLayouts(layouts: candidate))
    guard encoded.count <= 64 * 1024 else { throw SavedLayoutError.storageLimit }
    defaults.set(encoded, forKey: savedKey)
    savedLayouts = candidate
  }
  private static func loadCurrent(defaults: UserDefaults, key: String)
    -> (configuration: LayoutConfiguration, recovered: Bool)
  {
    let fallback = LayoutPreset.focus.configuration.normalized
    guard let data = defaults.data(forKey: key) else { return (fallback, false) }
    guard let decoded = try? JSONDecoder().decode(LayoutConfiguration.self, from: data) else {
      preserveUnreadable(data, defaults: defaults, key: key)
      return (fallback, true)
    }
    // A missing dock belongs to the supported legacy schema. An explicit invalid
    // tree must not silently become a different legacy arrangement.
    if let dock = decoded.dock, dock.validated != dock {
      preserveUnreadable(data, defaults: defaults, key: key)
      return (fallback, true)
    }
    let normalized = decoded.normalized
    var comparable = normalized
    comparable.dock = decoded.dock
    let repaired = comparable != decoded
    if repaired { preserveUnreadable(data, defaults: defaults, key: key) }
    return (normalized, repaired)
  }
  private static func loadSaved(defaults: UserDefaults, key: String)
    -> (layouts: [SavedLayout], recovered: Bool)
  {
    guard let data = defaults.data(forKey: key) else { return ([], false) }
    guard data.count <= 64 * 1024,
      let decoded = try? JSONDecoder().decode(StoredLayouts.self, from: data)
    else {
      preserveUnreadable(data, defaults: defaults, key: key)
      return ([], true)
    }
    var ids = Set<UUID>()
    var names = Set<String>()
    var recovered = decoded.rejectedEntries
    let layouts = decoded.layouts.compactMap { layout -> SavedLayout? in
      guard let name = try? validatedName(layout.name), name == layout.name,
        let dock = layout.configuration.dock, dock.validated == dock,
        layout.configuration.normalized == layout.configuration,
        !ids.contains(layout.id), !names.contains(nameKey(name))
      else {
        recovered = true
        return nil
      }
      ids.insert(layout.id)
      names.insert(nameKey(name))
      return layout
    }
    if recovered { preserveUnreadable(data, defaults: defaults, key: key) }
    return (layouts, recovered)
  }
  private static func preserveUnreadable(_ data: Data, defaults: UserDefaults, key: String) {
    let backupKey = key + ".unreadable"
    if defaults.object(forKey: backupKey) == nil { defaults.set(data, forKey: backupKey) }
  }
  private func availableName(_ name: String, excluding id: UUID? = nil) throws -> String {
    let name = try Self.validatedName(name)
    guard
      !savedLayouts.contains(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(name) })
    else { throw SavedLayoutError.duplicateName }
    return name
  }
  private static func validatedName(_ name: String) throws -> String {
    for scalar in name.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .lineSeparator, .paragraphSeparator: throw SavedLayoutError.invalidCharacters
      default: break
      }
      if scalar.value == 0x061C || (0x200E...0x200F).contains(scalar.value)
        || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
      {
        throw SavedLayoutError.invalidCharacters
      }
    }
    let name = name.trimmingCharacters(in: .whitespaces)
    guard (1...48).contains(name.count) else { throw SavedLayoutError.invalidName }
    return name
  }
  private static func nameKey(_ name: String) -> String {
    name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
  }
  private static func sameConfiguration(_ first: LayoutConfiguration, _ second: LayoutConfiguration)
    -> Bool
  {
    var first = first
    var second = second
    let firstDock = first.dock
    let secondDock = second.dock
    first.dock = nil
    second.dock = nil
    return first == second
      && firstDock?.sameArrangement(as: secondDock ?? DockLayout(root: nil)) == true
  }
  public func inspectorIsVisible(width: Double) -> Bool {
    switch configuration.inspector {
    case .automatic: width >= 1280
    case .visible: true
    case .hidden: false
    }
  }
}
