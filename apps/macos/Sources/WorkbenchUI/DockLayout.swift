import Foundation

public enum WorkbenchPane: String, CaseIterable, Codable, Identifiable, Sendable {
  case files, diff, graph, commit, stash, details, branches
  public var id: String { rawValue }
  public var title: String {
    switch self {
    case .files: "파일"
    case .diff: "Diff"
    case .graph: "커밋 그래프"
    case .commit: "커밋"
    case .stash: "Stash"
    case .details: "작업 정보"
    case .branches: "전체 브랜치"
    }
  }
  public var symbol: String {
    switch self {
    case .files: "doc.on.doc"
    case .diff: "text.alignleft"
    case .graph: "point.3.connected.trianglepath.dotted"
    case .commit: "checkmark.circle"
    case .stash: "archivebox"
    case .details: "info.circle"
    case .branches: "arrow.triangle.branch"
    }
  }
}
public enum DockAxis: String, Codable, Sendable { case horizontal, vertical }
public enum DockEdge: String, CaseIterable, Codable, Sendable {
  case left, right, top, bottom, center
  public var title: String {
    switch self {
    case .left: "왼쪽"
    case .right: "오른쪽"
    case .top: "위"
    case .bottom: "아래"
    case .center: "탭으로 합치기"
    }
  }
}

public indirect enum DockNode: Codable, Equatable, Sendable, Identifiable {
  case tabs(id: String, panes: [WorkbenchPane], active: WorkbenchPane)
  case split(id: String, axis: DockAxis, ratio: Double, first: DockNode, second: DockNode)
  public var id: String {
    switch self {
    case .tabs(let id, _, _), .split(let id, _, _, _, _): id
    }
  }
  public static func group(_ panes: [WorkbenchPane], active: WorkbenchPane? = nil) -> Self {
    .tabs(id: UUID().uuidString, panes: panes, active: active ?? panes.first ?? .diff)
  }
  public static func divided(_ axis: DockAxis, _ ratio: Double, _ first: Self, _ second: Self)
    -> Self
  {
    .split(id: UUID().uuidString, axis: axis, ratio: ratio, first: first, second: second)
  }
  public var panes: [WorkbenchPane] {
    switch self {
    case .tabs(_, let panes, _): panes
    case .split(_, _, _, let first, let second): first.panes + second.panes
    }
  }
  public func contains(_ pane: WorkbenchPane) -> Bool { panes.contains(pane) }
  public func isVisible(_ pane: WorkbenchPane) -> Bool {
    switch self {
    case .tabs(_, _, let active): active == pane
    case .split(_, _, _, let first, let second): first.isVisible(pane) || second.isVisible(pane)
    }
  }
  fileprivate func removing(_ pane: WorkbenchPane) -> Self? {
    switch self {
    case .tabs(let id, let panes, let active):
      let remaining = panes.filter { $0 != pane }
      guard let first = remaining.first else { return nil }
      return .tabs(id: id, panes: remaining, active: remaining.contains(active) ? active : first)
    case .split(let id, let axis, let ratio, let first, let second):
      let a = first.removing(pane)
      let b = second.removing(pane)
      if let a, let b { return .split(id: id, axis: axis, ratio: ratio, first: a, second: b) }
      return a ?? b
    }
  }
  fileprivate func inserting(_ pane: WorkbenchPane, nextTo target: WorkbenchPane, edge: DockEdge)
    -> Self
  {
    switch self {
    case .tabs(let id, let panes, _) where panes.contains(target):
      if edge == .center { return .tabs(id: id, panes: panes + [pane], active: pane) }
      return wrapping(pane, edge: edge)
    case .tabs: return self
    case .split(let id, let axis, let ratio, let first, let second):
      return .split(
        id: id, axis: axis, ratio: ratio,
        first: first.inserting(pane, nextTo: target, edge: edge),
        second: second.inserting(pane, nextTo: target, edge: edge))
    }
  }
  fileprivate func wrapping(_ pane: WorkbenchPane, edge: DockEdge) -> Self {
    let incoming = Self.group([pane])
    switch edge {
    case .left: return .divided(.horizontal, 0.3, incoming, self)
    case .right: return .divided(.horizontal, 0.7, self, incoming)
    case .top: return .divided(.vertical, 0.3, incoming, self)
    case .bottom: return .divided(.vertical, 0.7, self, incoming)
    case .center: return .divided(.horizontal, 0.7, self, incoming)
    }
  }
  fileprivate func selecting(_ pane: WorkbenchPane) -> Self {
    switch self {
    case .tabs(let id, let panes, let active):
      return .tabs(id: id, panes: panes, active: panes.contains(pane) ? pane : active)
    case .split(let id, let axis, let ratio, let first, let second):
      return .split(
        id: id, axis: axis, ratio: ratio, first: first.selecting(pane),
        second: second.selecting(pane))
    }
  }
  fileprivate func resizing(_ split: String, ratio: Double) -> Self {
    switch self {
    case .tabs: return self
    case .split(let id, let axis, let old, let first, let second):
      return .split(
        id: id, axis: axis, ratio: id == split ? ratio : old,
        first: first.resizing(split, ratio: ratio), second: second.resizing(split, ratio: ratio))
    }
  }
  fileprivate func validated() -> Self? {
    var seenPanes = Set<WorkbenchPane>()
    var seenIDs = Set<String>()
    func visit(_ node: Self, depth: Int) -> Self? {
      guard depth <= 12, !node.id.isEmpty, node.id.count <= 80, seenIDs.insert(node.id).inserted
      else { return nil }
      switch node {
      case .tabs(let id, let panes, let active):
        guard !panes.isEmpty, panes.contains(active), panes.count <= WorkbenchPane.allCases.count
        else { return nil }
        for pane in panes { guard seenPanes.insert(pane).inserted else { return nil } }
        return .tabs(id: id, panes: panes, active: active)
      case .split(let id, let axis, let ratio, let first, let second):
        guard let a = visit(first, depth: depth + 1), let b = visit(second, depth: depth + 1) else {
          return nil
        }
        return .split(
          id: id, axis: axis, ratio: ratio.isFinite ? min(0.9, max(0.1, ratio)) : 0.5, first: a,
          second: b)
      }
    }
    return visit(self, depth: 0)
  }
}

public struct DockLayout: Codable, Equatable, Sendable {
  public var root: DockNode?
  public init(root: DockNode?) { self.root = root }
  public var panes: [WorkbenchPane] { root?.panes ?? [] }
  public func contains(_ pane: WorkbenchPane) -> Bool { root?.contains(pane) == true }
  public func isVisible(_ pane: WorkbenchPane) -> Bool { root?.isVisible(pane) == true }
  public var validated: Self? {
    guard let root else { return self }
    return root.validated().map { Self(root: $0) }
  }
  public func moving(_ pane: WorkbenchPane, nextTo target: WorkbenchPane?, edge: DockEdge) -> Self {
    guard pane != target, target == nil || contains(target!) else { return self }
    let remaining = root?.removing(pane)
    guard let remaining else { return Self(root: .group([pane])) }
    let result =
      target.map { remaining.inserting(pane, nextTo: $0, edge: edge) }
      ?? remaining.wrapping(pane, edge: edge)
    return Self(root: result).validated ?? self
  }
  public func hiding(_ pane: WorkbenchPane) -> Self { Self(root: root?.removing(pane)) }
  public func selecting(_ pane: WorkbenchPane) -> Self { Self(root: root?.selecting(pane)) }
  public func resizing(_ split: String, ratio: Double) -> Self {
    Self(root: root?.resizing(split, ratio: ratio)).validated ?? self
  }
  public static var focused: Self {
    Self(root: .divided(.horizontal, 0.18, .group([.files]), .group([.diff])))
  }
  public static var balanced: Self {
    Self(root: .divided(.horizontal, 0.78,
      .divided(.horizontal, 0.23, .group([.files]), .group([.diff])),
      .group([.commit, .stash, .details], active: .commit)))
  }
  public static func legacy(_ value: LayoutConfiguration) -> Self {
    let review = DockNode.divided(.horizontal, 0.24, .group([.files]), .group([.diff]))
    let inspector = DockNode.divided(
      .vertical, 0.64, .group([.commit]), .group([.stash, .details]))
    var root = value.inspector == .hidden ? review : .divided(.horizontal, 0.76, review, inspector)
    if value.graph == .top && value.historyExpanded {
      root = .divided(.vertical, 0.29, .group([.graph]), root)
    }
    if value.graph == .bottom && value.historyExpanded {
      root = .divided(.vertical, 0.71, root, .group([.graph]))
    }
    return Self(root: root)
  }
  public func sameArrangement(as other: Self) -> Bool {
    func equal(_ a: DockNode?, _ b: DockNode?) -> Bool {
      switch (a, b) {
      case (nil, nil): return true
      case (.tabs(_, let ap, let aa)?, .tabs(_, let bp, let ba)?): return ap == bp && aa == ba
      case (.split(_, let ax, let ar, let af, let ab)?, .split(_, let bx, let br, let bf, let bb)?):
        return ax == bx && ar == br && equal(af, bf) && equal(ab, bb)
      default: return false
      }
    }
    return equal(root, other.root)
  }
}

public struct DockDropTarget: Equatable, Sendable {
  public let pane: WorkbenchPane?
  public let edge: DockEdge
  public init(pane: WorkbenchPane?, edge: DockEdge) {
    self.pane = pane
    self.edge = edge
  }
  public static func edge(at point: CGPoint, in rect: CGRect) -> DockEdge {
    let x = (point.x - rect.minX) / max(1, rect.width)
    let y = (point.y - rect.minY) / max(1, rect.height)
    if x > 0.3 && x < 0.7 && y > 0.3 && y < 0.7 { return .center }
    let choices: [(Double, DockEdge)] = [(x, .left), (1 - x, .right), (y, .top), (1 - y, .bottom)]
    return choices.min { $0.0 < $1.0 }!.1
  }
}
