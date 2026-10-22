import Foundation
import Testing
import WorkbenchUI

@MainActor
private func isolatedPreferences(_ body: (UserDefaults) -> Void) {
  let suite = "workbench-layout-test-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  body(defaults)
}

@Test @MainActor
func customizedLayoutSurvivesANewPreferencesInstance() {
  isolatedPreferences { defaults in
    let first = LayoutPreferences(defaults: defaults)
    #expect(first.preset == .classic)
    first.apply(.tracks)
    first.update {
      $0.graph = .bottom
      $0.inspector = .visible
      $0.fileWidth = 280
      $0.inspectorWidth = 350
      $0.historyHeight = 260
      $0.historyExpanded = false
      $0.splitDiff = false
    }
    let restored = LayoutPreferences(defaults: defaults)
    #expect(restored.configuration == first.configuration)
    #expect(restored.preset == nil)
    #expect(restored.inspectorIsVisible(width: 1100))
    restored.apply(.classic)
    #expect(LayoutPreferences(defaults: defaults).preset == .classic)
  }
}

@Test @MainActor
func invalidSavedLayoutAndExtremeSizesRemainUsable() {
  isolatedPreferences { defaults in
    defaults.set(Data("{\"graph\":\"retired-layout\"}".utf8), forKey: "workbench.layout.v1")
    let layout = LayoutPreferences(defaults: defaults)
    #expect(layout.preset == .classic)
    layout.update {
      $0.fileWidth = -.infinity
      $0.inspectorWidth = 10000
      $0.historyHeight = -100
    }
    let restored = LayoutPreferences(defaults: defaults)
    #expect(restored.configuration.fileWidth.isFinite)
    #expect(restored.configuration.inspectorWidth == 420)
    #expect(restored.configuration.historyHeight == 140)
    #expect(!restored.inspectorIsVisible(width: 1100))
    #expect(restored.inspectorIsVisible(width: 1440))
  }
}
