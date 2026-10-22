import Foundation
import Testing
import WorkbenchUI

@Test
func everyPaneCanSplitOrTabWithEveryOtherPaneWithoutLoss() {
  let original = DockLayout(root: .group(WorkbenchPane.allCases, active: .diff))
  for pane in WorkbenchPane.allCases {
    for target in WorkbenchPane.allCases where target != pane {
      for edge in DockEdge.allCases {
        let result = original.moving(pane, nextTo: target, edge: edge)
        #expect(result.validated != nil)
        #expect(result.panes.count == WorkbenchPane.allCases.count)
        #expect(Set(result.panes) == Set(WorkbenchPane.allCases))
        if edge == .center {
          guard case .tabs(_, _, let active) = result.root else {
            Issue.record("Expected tab group")
            continue
          }
          #expect(active == pane)
        } else {
          guard case .split(_, let axis, _, let first, let second) = result.root else {
            Issue.record("Expected a new split")
            continue
          }
          #expect(axis == (edge == .left || edge == .right ? .horizontal : .vertical))
          #expect((edge == .left || edge == .top ? first : second).panes == [pane])
        }
      }
    }
  }
  // Repeatedly remove and reinsert through a nested tree, not just a single group.
  var nested = original
  for step in 0..<250 {
    let pane = WorkbenchPane.allCases[step % 7]
    let target = WorkbenchPane.allCases[(step + 3) % 7]
    nested = nested.moving(pane, nextTo: target, edge: DockEdge.allCases[step % 5])
    #expect(nested.validated != nil)
    #expect(nested.panes.count == 7 && Set(nested.panes).count == 7)
  }
}

@Test @MainActor
func arbitraryDockingPersistsRatiosTabsVisibilityAndUndo() throws {
  let suite = "workbench-docking-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let layout = LayoutPreferences(defaults: defaults)
  layout.apply(.classic)
  layout.dockPane(.stash, nextTo: .files, edge: .left)
  layout.dockPane(.graph, nextTo: .commit, edge: .bottom)
  layout.dockPane(.files, nextTo: .diff, edge: .center)
  layout.selectPane(.diff)
  #expect(layout.dockLayout.contains(.files))
  #expect(!layout.dockLayout.isVisible(.files))
  #expect(layout.dockLayout.isVisible(.diff))
  #expect(layout.dockLayout.isVisible(.stash))
  let beforeResize = layout.dockLayout
  layout.resizeDock(try #require(beforeResize.root).id, ratio: 0.62)
  let restored = LayoutPreferences(defaults: defaults)
  #expect(restored.dockLayout == layout.dockLayout)
  #expect(restored.preset == nil)
  layout.undoDock()
  #expect(layout.dockLayout == beforeResize)
  for pane in WorkbenchPane.allCases { layout.hidePane(pane) }
  #expect(layout.dockLayout.root == nil)
  layout.showPane(.diff)
  #expect(layout.dockLayout.panes == [.diff])
  #expect(LayoutPreferences(defaults: defaults).dockLayout == layout.dockLayout)
}

@Test @MainActor
func malformedDockTreeFallsBackAndLegacySettingsMigrate() throws {
  let suite = "workbench-docking-migration-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  var legacy = LayoutConfiguration()
  legacy.graph = .bottom
  legacy.inspector = .hidden
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
  object.removeValue(forKey: "dock")
  defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: "workbench.layout.v1")
  let migrated = LayoutPreferences(defaults: defaults)
  #expect(migrated.dockLayout.contains(.graph))
  #expect(!migrated.dockLayout.contains(.commit))
  legacy.dock = DockLayout(root: .divided(.horizontal, 0.5, .group([.diff]), .group([.diff])))
  defaults.set(try JSONEncoder().encode(legacy), forKey: "workbench.layout.v1")
  let repaired = LayoutPreferences(defaults: defaults)
  #expect(repaired.dockLayout.validated != nil)
  #expect(repaired.dockLayout.panes.filter { $0 == .diff }.count == 1)
}

@Test @MainActor
func dragTargetsUsePaneGeometryAndCancelOutsideWorkspace() {
  let suite = "workbench-docking-drag-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let layout = LayoutPreferences(defaults: defaults)
  layout.apply(.classic)
  let drag = DockDragSession()
  drag.bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
  drag.frames = [.diff: CGRect(x: 200, y: 200, width: 600, height: 400)]
  let points: [(CGPoint, DockEdge)] = [
    (.init(x: 210, y: 400), .left), (.init(x: 790, y: 400), .right),
    (.init(x: 500, y: 210), .top), (.init(x: 500, y: 590), .bottom),
    (.init(x: 500, y: 400), .center),
  ]
  for (point, edge) in points {
    drag.drag(.stash, to: point)
    #expect(drag.target == DockDropTarget(pane: .diff, edge: edge))
  }
  let before = layout.dockLayout
  drag.drag(.stash, to: .init(x: -10, y: 400))
  drag.finish(in: layout)
  #expect(layout.dockLayout == before && drag.pane == nil)
  drag.drag(.stash, to: .init(x: 500, y: 210))
  drag.finish(in: layout)
  #expect(layout.dockLayout != before && drag.pane == nil)
  #expect(layout.dockLayout.panes.count == before.panes.count)
  drag.drag(.graph, to: .init(x: 5, y: 400))
  #expect(drag.target == DockDropTarget(pane: nil, edge: .left))
  drag.finish(in: layout)
  #expect(layout.dockLayout.validated != nil)
}
