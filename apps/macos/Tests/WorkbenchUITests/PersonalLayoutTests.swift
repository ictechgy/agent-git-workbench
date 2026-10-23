import Foundation
import Testing
import WorkbenchUI

@Suite @MainActor
struct PersonalLayoutTests {
  private let currentKey = "workbench.layout.v1"
  private let savedKey = "workbench.saved-layouts.v1"

  private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
    let suite = "river-personal-layout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
  }

  private func customConfiguration() -> LayoutConfiguration {
    var value = LayoutConfiguration()
    value.navigation = .tracks
    value.graph = .hidden
    value.inspector = .visible
    value.splitDiff = false
    value.dock = DockLayout(
      root: .split(
        id: "review-split", axis: .horizontal, ratio: 0.37,
        first: .tabs(id: "source-tabs", panes: [.files, .branches], active: .branches),
        second: .tabs(id: "review-tabs", panes: [.diff, .stash], active: .stash)))
    return value
  }

  private func store(_ layouts: [SavedLayout], in defaults: UserDefaults, version: Int = 1) throws {
    let entries = try layouts.map {
      try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
    }
    defaults.set(
      try JSONSerialization.data(withJSONObject: ["version": version, "layouts": entries]),
      forKey: savedKey)
  }

  @Test func existingVersionOneAndAppearanceAreNotRewrittenOnLoadOrNamedSave() throws {
    try withDefaults { defaults in
      let original = try JSONEncoder().encode(customConfiguration())
      defaults.set(original, forKey: currentKey)
      defaults.set("dark", forKey: "workbench.appearance.v1")
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.configuration == customConfiguration())
      #expect(layout.savedLayouts.isEmpty)
      #expect(layout.appearance == .dark)
      #expect(layout.recoveryNotice == nil)
      try layout.saveCurrentLayout(named: "검토")
      #expect(defaults.data(forKey: currentKey) == original)
      #expect(defaults.string(forKey: "workbench.appearance.v1") == "dark")
    }
  }

  @Test func namedSnapshotsRoundTripTheCompleteConfiguration() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let custom = customConfiguration()
      layout.update { $0 = custom }
      let id = try layout.saveCurrentLayout(named: "  변경 검토  ")
      #expect(layout.savedLayouts.map(\.name) == ["변경 검토"])
      #expect(layout.currentLayoutTitle == "변경 검토")
      layout.apply(.focus)
      #expect(layout.savedLayouts.first?.configuration == custom)
      let restored = LayoutPreferences(defaults: defaults)
      restored.appearance = .dark
      restored.applySavedLayout(id)
      #expect(restored.configuration == custom)
      #expect(restored.dockLayout.panes == [.files, .branches, .diff, .stash])
      #expect(restored.dockLayout.isVisible(.branches))
      #expect(restored.dockLayout.isVisible(.stash))
      #expect(!restored.dockLayout.contains(.commit))
      #expect(restored.appearance == .dark)
      #expect(LayoutPreferences(defaults: defaults).configuration == custom)
    }
  }

  @Test func renameReplaceAndDeleteRequireExplicitActions() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let id = try layout.saveCurrentLayout(named: "기본 작업")
      let saved = try #require(layout.savedLayouts.first)
      layout.update {
        $0.navigation = .tracks
        $0.splitDiff = true
      }
      #expect(layout.savedLayouts.first == saved)
      try layout.renameSavedLayout(id, to: "  프로젝트 작업 ")
      #expect(layout.savedLayouts.first?.id == id)
      #expect(layout.savedLayouts.first?.configuration == saved.configuration)
      try layout.replaceSavedLayout(id)
      #expect(layout.savedLayouts.first?.configuration == layout.configuration)
      let restored = LayoutPreferences(defaults: defaults)
      #expect(restored.savedLayouts.first?.name == "프로젝트 작업")
      #expect(restored.savedLayouts.first?.configuration == layout.configuration)
      let beforeDelete = restored.configuration
      restored.deleteSavedLayout(id)
      #expect(restored.savedLayouts.isEmpty)
      #expect(restored.configuration == beforeDelete)
      #expect(LayoutPreferences(defaults: defaults).savedLayouts.isEmpty)
    }
  }

  @Test func namesAreTrimmedBoundedAndCaseInsensitive() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let id = try layout.saveCurrentLayout(named: "Review")
      #expect(throws: SavedLayoutError.duplicateName) {
        try layout.saveCurrentLayout(named: " review ")
      }
      try layout.renameSavedLayout(id, to: "REVIEW")
      let other = try layout.saveCurrentLayout(named: "Second")
      #expect(throws: SavedLayoutError.duplicateName) {
        try layout.renameSavedLayout(other, to: "review")
      }
      #expect(throws: SavedLayoutError.invalidName) {
        try layout.saveCurrentLayout(named: "   ")
      }
      #expect(throws: SavedLayoutError.invalidName) {
        try layout.saveCurrentLayout(named: String(repeating: "a", count: 49))
      }
      try layout.saveCurrentLayout(named: String(repeating: "가", count: 48))
      #expect(layout.savedLayouts.count == 3)
    }
  }

  @Test func namesCannotHideLineControlOrBidirectionalCharacters() {
    withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      for bad in [
        "a\nb", "\nreview", "a\tb", "a\0b", "a\u{2028}b", "a\u{2029}b",
        "a\u{061C}b", "a\u{200E}b", "a\u{202E}b", "a\u{2066}b", "a\u{2069}b",
      ] {
        #expect(throws: SavedLayoutError.invalidCharacters) {
          try layout.saveCurrentLayout(named: bad)
        }
      }
      #expect(layout.savedLayouts.isEmpty)
      #expect(defaults.data(forKey: savedKey) == nil)
    }
  }

  @Test func twentySnapshotsIsTheLimitAndDeletionMakesRoom() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      for index in 1...20 { try layout.saveCurrentLayout(named: "작업 \(index)") }
      #expect(throws: SavedLayoutError.limitReached) {
        try layout.saveCurrentLayout(named: "하나 더")
      }
      #expect(LayoutPreferences(defaults: defaults).savedLayouts.count == 20)
      layout.deleteSavedLayout(try #require(layout.savedLayouts.first).id)
      try layout.saveCurrentLayout(named: "새 작업")
      #expect(LayoutPreferences(defaults: defaults).savedLayouts.count == 20)
    }
  }

  @Test func malformedEntriesDoNotBecomeDefaultsOrDiscardValidSiblings() throws {
    try withDefaults { defaults in
      let good = SavedLayout(name: "정상", configuration: customConfiguration())
      var missingDock = customConfiguration()
      missingDock.dock = nil
      var repeatedPane = customConfiguration()
      repeatedPane.dock = DockLayout(
        root: .tabs(id: "repeated", panes: [.diff, .diff], active: .diff))
      var badRatio = customConfiguration()
      badRatio.dock = DockLayout(
        root: .split(
          id: "split", axis: .horizontal, ratio: 2,
          first: .tabs(id: "left", panes: [.files], active: .files),
          second: .tabs(id: "right", panes: [.diff], active: .diff)))
      var badSize = customConfiguration()
      badSize.fileWidth = 2000
      try store(
        [
          SavedLayout(name: "없음", configuration: missingDock),
          SavedLayout(name: "중복 패널", configuration: repeatedPane),
          SavedLayout(name: "잘못된 비율", configuration: badRatio),
          SavedLayout(name: "잘못된 크기", configuration: badSize),
          SavedLayout(name: "숨긴\u{202E}이름", configuration: customConfiguration()), good,
        ], in: defaults)
      let data = try #require(defaults.data(forKey: savedKey))
      var envelope = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
      var entries = try #require(envelope["layouts"] as? [Any])
      entries.insert(["id": "not-a-uuid", "name": "깨짐"], at: 0)
      entries.insert("not-an-object", at: 1)
      envelope["layouts"] = entries
      defaults.set(try JSONSerialization.data(withJSONObject: envelope), forKey: savedKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.savedLayouts == [good])
      #expect(layout.preset == .focus)
    }
  }

  @Test func duplicateIdentitiesAndNamesAreIgnoredOnLoad() throws {
    try withDefaults { defaults in
      let good = SavedLayout(name: "Review", configuration: customConfiguration())
      let sameID = SavedLayout(id: good.id, name: "Other", configuration: customConfiguration())
      let sameName = SavedLayout(name: "REVIEW", configuration: customConfiguration())
      let independent = SavedLayout(name: "독립", configuration: customConfiguration())
      try store([good, sameID, sameName, independent], in: defaults)
      #expect(LayoutPreferences(defaults: defaults).savedLayouts == [good, independent])
    }
  }

  @Test func unsupportedOrOversizedStoresCannotReplaceTheCurrentLayout() throws {
    try withDefaults { defaults in
      let custom = customConfiguration()
      defaults.set(try JSONEncoder().encode(custom), forKey: currentKey)
      let one = SavedLayout(name: "정상", configuration: custom)
      try store([one], in: defaults, version: 2)
      #expect(LayoutPreferences(defaults: defaults).savedLayouts.isEmpty)
      try store((1...21).map { SavedLayout(name: "작업 \($0)", configuration: custom) }, in: defaults)
      #expect(LayoutPreferences(defaults: defaults).savedLayouts.isEmpty)
      defaults.set(Data("broken-json".utf8), forKey: savedKey)
      let restored = LayoutPreferences(defaults: defaults)
      #expect(restored.savedLayouts.isEmpty)
      #expect(restored.configuration == custom)
    }
  }

  @Test func presetAndSavedSwitchingUndoTheEntireConfiguration() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let custom = customConfiguration()
      layout.update { $0 = custom }
      let id = try layout.saveCurrentLayout(named: "검토")
      layout.apply(.focus)
      let focus = layout.configuration
      #expect(focus.navigation == .tabs && !focus.splitDiff)
      layout.undoDock()
      #expect(layout.configuration == custom)
      layout.apply(.classic)
      let classic = layout.configuration
      layout.applySavedLayout(id)
      #expect(layout.configuration == custom)
      layout.undoDock()
      #expect(layout.configuration == classic)
    }
  }

  @Test func undoIsBoundedAndEquivalentApplicationsDoNotAddEntries() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      layout.apply(.focus)
      #expect(!layout.canUndoDock)
      let id = try layout.saveCurrentLayout(named: "처음")
      layout.applySavedLayout(id)
      #expect(!layout.canUndoDock)
      for index in 0..<25 { layout.apply(index.isMultiple(of: 2) ? .classic : .focus) }
      var count = 0
      while layout.canUndoDock {
        layout.undoDock()
        count += 1
      }
      #expect(count == 20)
    }
  }

  @Test func enlargementLeavesTheExactTreeAndAllPreferencesUntouched() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let original = customConfiguration()
      layout.update { $0 = original }
      let id = try layout.saveCurrentLayout(named: "검토")
      let currentBytes = defaults.data(forKey: currentKey)
      let savedBytes = defaults.data(forKey: savedKey)
      layout.focusPane(.diff)
      #expect(layout.focusedPane == .diff)
      #expect(layout.presentedDockLayout.panes == [.diff])
      #expect(layout.isPanePresented(.diff))
      #expect(!layout.isPanePresented(.stash))
      #expect(layout.configuration == original)
      #expect(layout.dockLayout.isVisible(.stash))
      #expect(defaults.data(forKey: currentKey) == currentBytes)
      #expect(defaults.data(forKey: savedKey) == savedBytes)
      let restored = LayoutPreferences(defaults: defaults)
      #expect(restored.focusedPane == nil)
      #expect(restored.configuration == original)
      #expect(restored.savedLayouts.first?.id == id)
      layout.restorePaneLayout()
      #expect(layout.configuration == original)
      #expect(layout.presentedDockLayout == original.dock)
      #expect(layout.isPanePresented(.stash))
      #expect(!layout.isPanePresented(.diff))
    }
  }

  @Test func enlargementTogglesAndCannotRevealHiddenPanes() {
    withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      layout.focusPane(.stash)
      #expect(layout.focusedPane == nil)
      layout.focusPane(.diff)
      layout.focusPane(.files)
      #expect(layout.focusedPane == .files)
      layout.focusPane(.files)
      #expect(layout.focusedPane == nil)
      #expect(!layout.canUndoDock)
    }
  }

  @Test func explicitPaneActionsAndLayoutChangesExitEnlargement() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let id = try layout.saveCurrentLayout(named: "처음")
      layout.focusPane(.diff)
      layout.showPane(.stash)
      #expect(layout.focusedPane == nil && layout.isPanePresented(.stash))
      layout.focusPane(.diff)
      layout.selectPane(.stash)
      #expect(layout.focusedPane == nil && layout.isPanePresented(.stash))
      layout.focusPane(.diff)
      layout.hidePane(.stash)
      #expect(layout.focusedPane == nil && !layout.dockLayout.contains(.stash))
      layout.focusPane(.diff)
      layout.dockPane(.stash, nextTo: .diff, edge: .bottom)
      #expect(layout.focusedPane == nil && layout.isPanePresented(.stash))
      layout.focusPane(.diff)
      layout.applySavedLayout(id)
      #expect(layout.focusedPane == nil)
      layout.focusPane(.diff)
      layout.apply(.classic)
      #expect(layout.focusedPane == nil)
      layout.focusPane(.diff)
      layout.undoDock()
      #expect(layout.focusedPane == nil)
    }
  }

  @Test func unreadableCurrentBytesAreBackedUpOnlyOnceWithoutRewritingTheOriginal() {
    withDefaults { defaults in
      let original = Data([0xFF, 0x00, 0x7B, 0xFE])
      defaults.set(original, forKey: currentKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.preset == .focus)
      #expect(layout.recoveryNotice != nil)
      #expect(defaults.data(forKey: currentKey) == original)
      #expect(defaults.data(forKey: currentKey + ".unreadable") == original)
      let laterCorruption = Data("different broken json".utf8)
      defaults.set(laterCorruption, forKey: currentKey)
      let second = LayoutPreferences(defaults: defaults)
      #expect(second.preset == .focus)
      #expect(defaults.data(forKey: currentKey) == laterCorruption)
      #expect(defaults.data(forKey: currentKey + ".unreadable") == original)
      second.apply(.classic)
      #expect(LayoutPreferences(defaults: defaults).recoveryNotice == nil)
      #expect(defaults.data(forKey: currentKey + ".unreadable") == original)
    }
  }

  @Test func invalidExplicitCurrentTreesAlwaysRecoverToFocus() throws {
    var deep = DockNode.tabs(id: "deep-leaf", panes: [.diff], active: .diff)
    for depth in 0..<14 {
      deep = .split(
        id: "deep-\(depth)", axis: .horizontal, ratio: 0.5, first: deep,
        second: .tabs(id: "extra-\(depth)", panes: [.files], active: .files))
    }
    let invalid: [DockNode] = [
      .tabs(id: "duplicate-pane", panes: [.diff, .diff], active: .diff),
      .split(
        id: "duplicate-ids", axis: .horizontal, ratio: 0.5,
        first: .tabs(id: "same", panes: [.files], active: .files),
        second: .tabs(id: "same", panes: [.diff], active: .diff)),
      .tabs(id: "wrong-active", panes: [.files], active: .diff),
      .split(
        id: "outside-ratio", axis: .horizontal, ratio: 1.4,
        first: .tabs(id: "files", panes: [.files], active: .files),
        second: .tabs(id: "diff", panes: [.diff], active: .diff)), deep,
    ]
    for tree in invalid {
      try withDefaults { defaults in
        var custom = customConfiguration()
        custom.dock = DockLayout(root: tree)
        let original = try JSONEncoder().encode(custom)
        defaults.set(original, forKey: currentKey)
        let layout = LayoutPreferences(defaults: defaults)
        #expect(layout.preset == .focus)
        #expect(layout.configuration.navigation == .tabs)
        #expect(layout.dockLayout.panes == [.files, .diff])
        #expect(layout.recoveryNotice != nil)
        #expect(defaults.data(forKey: currentKey) == original)
        #expect(defaults.data(forKey: currentKey + ".unreadable") == original)
      }
    }
  }

  @Test func unknownCurrentPaneIsPreservedBeforeFocusFallback() throws {
    try withDefaults { defaults in
      let encoded = try JSONEncoder().encode(customConfiguration())
      let unknown = Data(
        String(decoding: encoded, as: UTF8.self)
          .replacingOccurrences(of: "\"diff\"", with: "\"unknown-pane\"").utf8)
      #expect(unknown != encoded)
      defaults.set(unknown, forKey: currentKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.preset == .focus)
      #expect(layout.recoveryNotice != nil)
      #expect(defaults.data(forKey: currentKey) == unknown)
      #expect(defaults.data(forKey: currentKey + ".unreadable") == unknown)
    }
  }

  @Test func legacyMissingDockStillLoadsWithoutRecoveryOrRewrite() throws {
    try withDefaults { defaults in
      var legacy = LayoutConfiguration()
      legacy.navigation = .tracks
      legacy.graph = .bottom
      legacy.inspector = .hidden
      let original = try JSONEncoder().encode(legacy)
      defaults.set(original, forKey: currentKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.configuration.navigation == .tracks)
      #expect(layout.dockLayout.contains(.graph))
      #expect(!layout.dockLayout.contains(.commit))
      #expect(layout.recoveryNotice == nil)
      #expect(defaults.data(forKey: currentKey) == original)
      #expect(defaults.data(forKey: currentKey + ".unreadable") == nil)
    }
  }

  @Test func repairedCurrentDimensionsKeepTheirOriginalBytes() throws {
    try withDefaults { defaults in
      var custom = customConfiguration()
      custom.fileWidth = 5000
      let original = try JSONEncoder().encode(custom)
      defaults.set(original, forKey: currentKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.configuration.fileWidth == 360)
      #expect(layout.configuration.navigation == .tracks)
      #expect(layout.dockLayout == custom.dock)
      #expect(layout.recoveryNotice != nil)
      #expect(defaults.data(forKey: currentKey) == original)
      #expect(defaults.data(forKey: currentKey + ".unreadable") == original)
    }
  }

  @Test func unreadableNamedLibraryIsBackedUpOnlyOnce() throws {
    try withDefaults { defaults in
      let original = Data("broken named layouts".utf8)
      defaults.set(original, forKey: savedKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.savedLayouts.isEmpty)
      #expect(layout.recoveryNotice != nil)
      #expect(defaults.data(forKey: savedKey) == original)
      #expect(defaults.data(forKey: savedKey + ".unreadable") == original)
      try store(
        [SavedLayout(name: "다음 버전", configuration: customConfiguration())],
        in: defaults, version: 2)
      let unsupported = try #require(defaults.data(forKey: savedKey))
      let second = LayoutPreferences(defaults: defaults)
      #expect(second.savedLayouts.isEmpty)
      #expect(second.recoveryNotice != nil)
      #expect(defaults.data(forKey: savedKey) == unsupported)
      #expect(defaults.data(forKey: savedKey + ".unreadable") == original)
      try second.saveCurrentLayout(named: "새로 저장")
      #expect(LayoutPreferences(defaults: defaults).recoveryNotice == nil)
      #expect(defaults.data(forKey: savedKey + ".unreadable") == original)
    }
  }

  @Test func oversizedLibraryIsRejectedBeforeDecodingAndRetainedForRecovery() throws {
    try withDefaults { defaults in
      try store([SavedLayout(name: "정상", configuration: customConfiguration())], in: defaults)
      let valid = try #require(defaults.data(forKey: savedKey))
      var original = valid
      original.append(Data(repeating: 0x20, count: 64 * 1024 + 1 - original.count))
      defaults.set(original, forKey: savedKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.savedLayouts.isEmpty)
      #expect(layout.recoveryNotice != nil)
      #expect(defaults.data(forKey: savedKey) == original)
      #expect(defaults.data(forKey: savedKey + ".unreadable") == original)
      // Valid JSON padded to the exact bound must still decode.
      var exact = valid
      exact.append(Data(repeating: 0x20, count: 64 * 1024 - exact.count))
      defaults.set(exact, forKey: savedKey)
      let restored = LayoutPreferences(defaults: defaults)
      #expect(restored.savedLayouts.map(\.name) == ["정상"])
      #expect(restored.recoveryNotice == nil)
      #expect(defaults.data(forKey: savedKey) == exact)
    }
  }

  @Test func rejectedNamedEntriesRetainTheCompleteOriginalAndValidSiblings() throws {
    try withDefaults { defaults in
      let good = SavedLayout(name: "정상", configuration: customConfiguration())
      let duplicate = SavedLayout(id: good.id, name: "중복", configuration: customConfiguration())
      var unknown = try #require(
        JSONSerialization.jsonObject(
          with: JSONEncoder().encode(good)) as? [String: Any])
      unknown["id"] = UUID().uuidString
      unknown["configuration"] = ["unknown": "schema"]
      let goodObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(good))
      let duplicateObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(duplicate))
      let original = try JSONSerialization.data(withJSONObject: [
        "version": 1, "layouts": [unknown, goodObject, duplicateObject, "broken entry"],
      ])
      defaults.set(original, forKey: savedKey)
      let layout = LayoutPreferences(defaults: defaults)
      #expect(layout.savedLayouts == [good])
      #expect(layout.recoveryNotice != nil)
      #expect(defaults.data(forKey: savedKey) == original)
      #expect(defaults.data(forKey: savedKey + ".unreadable") == original)
    }
  }

  @Test func styleChangesRetainFocusAndExplicitLayoutActionsExitIt() {
    withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let originalDock = layout.dockLayout
      layout.focusPane(.diff)
      layout.update { $0.splitDiff.toggle() }
      #expect(layout.focusedPane == .diff)
      #expect(layout.dockLayout == originalDock)
      layout.update { _ in }
      #expect(layout.focusedPane == .diff)
      layout.selectPane(.diff)
      #expect(layout.focusedPane == nil)
      layout.focusPane(.diff)
      layout.update { $0.navigation = .tracks }
      #expect(layout.focusedPane == nil)
    }
  }

  @Test func movingASolePaneToAnOuterEdgeIgnoresFreshIDsAndDoesNotPersistOrAddUndo() {
    withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      layout.update { $0.dock = DockLayout(root: .tabs(id: "sole", panes: [.diff], active: .diff)) }
      let original = layout.configuration
      let bytes = defaults.data(forKey: currentKey)
      for edge in [DockEdge.left, .right, .top, .bottom] {
        let equivalent = layout.dockLayout.moving(.diff, nextTo: nil, edge: edge)
        #expect(equivalent != layout.dockLayout)
        #expect(equivalent.sameArrangement(as: layout.dockLayout))
        layout.dockPane(.diff, nextTo: nil, edge: edge)
        #expect(layout.configuration == original)
        #expect(!layout.canUndoDock)
        #expect(defaults.data(forKey: currentKey) == bytes)
      }
    }
  }

  @Test func oversizedSaveAndRenameLeaveTheLibraryAndStoredBytesUnchanged() throws {
    try withDefaults { defaults in
      let layout = LayoutPreferences(defaults: defaults)
      let id = try layout.saveCurrentLayout(named: "원본")
      let original = layout.savedLayouts
      let bytes = defaults.data(forKey: savedKey)
      let oversizedName = "a" + String(repeating: "\u{0301}", count: 40_000)
      #expect(oversizedName.count == 1)
      #expect(throws: SavedLayoutError.storageLimit) {
        try layout.saveCurrentLayout(named: oversizedName)
      }
      #expect(layout.savedLayouts == original)
      #expect(defaults.data(forKey: savedKey) == bytes)
      #expect(throws: SavedLayoutError.storageLimit) {
        try layout.renameSavedLayout(id, to: oversizedName)
      }
      #expect(layout.savedLayouts == original)
      #expect(defaults.data(forKey: savedKey) == bytes)
      #expect(layout.currentLayoutTitle == "원본")
      #expect(LayoutPreferences(defaults: defaults).savedLayouts == original)
    }
  }

  @Test func oversizedReplacementLeavesTheLibraryAndStoredBytesUnchanged() throws {
    try withDefaults { defaults in
      var small = LayoutPreset.focus.configuration
      small.dock = DockLayout(root: .tabs(id: "x", panes: [.diff], active: .diff))
      let id = UUID()
      try store([SavedLayout(id: id, name: "a", configuration: small)], in: defaults)
      let baseline = try #require(defaults.data(forKey: savedKey))
      let nearLimitName =
        "a" + String(repeating: "\u{0301}", count: (64 * 1024 - baseline.count - 8) / 2)
      #expect(nearLimitName.count == 1)
      try store([SavedLayout(id: id, name: nearLimitName, configuration: small)], in: defaults)
      let bytes = try #require(defaults.data(forKey: savedKey))
      #expect(bytes.count <= 64 * 1024)
      let layout = LayoutPreferences(defaults: defaults)
      let original = layout.savedLayouts
      #expect(original.count == 1)
      #expect(layout.recoveryNotice == nil)
      layout.apply(.classic)
      #expect(throws: SavedLayoutError.storageLimit) { try layout.replaceSavedLayout(id) }
      #expect(layout.savedLayouts == original)
      #expect(defaults.data(forKey: savedKey) == bytes)
      #expect(LayoutPreferences(defaults: defaults).savedLayouts == original)
    }
  }
}
