import AppKit
import SwiftUI
import WorkbenchProtocol
import WorkbenchRuntime
import WorkbenchUI

/// Renders our own live-data native view offscreen. Does not automate other apps or capture the desktop.
@main
struct NativePreview {
  @MainActor static func main() async throws {
    guard [3, 4, 6].contains(CommandLine.arguments.count) else {
      print(
        "usage: workbench-native-preview SOCKET|--welcome|--example OUTPUT.png [light|dark [WIDTH HEIGHT]]"
      )
      return
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let dark = CommandLine.arguments.count >= 4 && CommandLine.arguments[3] == "dark"
    let highContrast = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_HIGH_CONTRAST"] == "1"
    let width = CommandLine.arguments.count == 6 ? Double(CommandLine.arguments[4]) ?? 1440 : 1440
    let height = CommandLine.arguments.count == 6 ? Double(CommandLine.arguments[5]) ?? 960 : 960
    guard (1100...3000).contains(width), (720...2000).contains(height) else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    app.appearance = NSAppearance(named: highContrast
      ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
      : (dark ? .darkAqua : .aqua))
    let mode = CommandLine.arguments[1]
    let previewStorage = FileManager.default.temporaryDirectory.appendingPathComponent(
      "agw-preview-\(UUID().uuidString)")
    let runtime = WorkspaceRuntime(storageDirectory: previewStorage)
    let store = WorkbenchStore(socketPath: mode.hasPrefix("--") ? "" : mode, runtime: runtime)
    let preferenceSuite = "agw-preview-layout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: preferenceSuite)!
    defer { defaults.removePersistentDomain(forName: preferenceSuite) }
    let layout = LayoutPreferences(defaults: defaults)
    // The harness controls AppKit appearance, including Increase Contrast.
    layout.appearance = .system
    let dockSession = DockDragSession()
    if let name = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_LAYOUT"],
      let preset = LayoutPreset(rawValue: name)
    {
      layout.apply(preset)
    }
    if let name = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_GRAPH"],
      let placement = GraphPlacement(rawValue: name)
    {
      layout.update { $0.graph = placement }
    }
    if let visible = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_INSPECTOR"] {
      layout.update { $0.inspector = visible == "1" ? .visible : .hidden }
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_HISTORY"] == "0" {
      layout.update { $0.historyExpanded = false }
    }
    if mode == "--example" {
      await store.openExample()
    } else if mode != "--welcome" {
      await store.connect()
      await store.selectInitialTask(
        preferredRepository: ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_REPO"])
      // Socket-mode probes can exercise write guards even for a plain Stash render.
      try requireSyntheticFixture(store)
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_READINESS"] == "1" {
        try await verifyPreparationReadiness(store)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_STAGED"] == "1" {
        guard store.stagedCount > 0 else { throw CocoaError(.validationMissingMandatoryProperty) }
        store.chooseStaged(true)
        store.commitMessage = "로그인 상태 처리 개선"
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_SWITCH"] == "1" {
        try await verifyFolderSwitching(store)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_REVIEW"] == "1" {
        store.chooseFile("Sources/Session.swift", staged: false)
        for _ in 0..<200 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_CONTEXT"] == "1" {
        try await verifyTaskContext(store)
        layout.hidePane(.graph)
        layout.hidePane(.commit)
        layout.showPane(.details)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_ORIGINAL"] == "1",
        let selection = store.selection
      {
        store.select(.init(repoId: selection.repoId))
        try await waitForSelection(store)
      }
      if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_STASH"] == "1" {
        guard let stash = store.stashes.first else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        let originalHash = store.repository?.snapshotHash
        store.chooseStash(stash)
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard store.isViewingStash, store.stashDetail != nil, store.diff != nil, !store.canEdit,
          store.error == nil
        else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        // Exercise the actual store's read-only guards and return navigation, not OS clicks.
        store.commitMessage = "로그인 세션 처리 개선"
        await store.stageHunk(0)
        guard let stagingRefusal = store.error,
          stagingRefusal == "변경이 바뀌었거나 확인 중입니다. 현재 변경을 다시 확인한 뒤 스테이징하세요."
        else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        await store.commit()
        var values: [String: JSONValue] = ["repo_id": .string(store.selection!.repoId)]
        if let opID = store.selection?.opId { values["op_id"] = .string(opID) }
        let checked: RepositoryStatus = try await ServiceClient(socketPath: mode).call(
          "get_repo_status", params: values)
        guard checked.snapshotHash == originalHash, store.error == stagingRefusal else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        store.showWorkingChanges()
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard !store.isViewingStash, store.diff?.snapshotHash == originalHash else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        store.chooseStash(stash)
        for _ in 0..<100 where store.diff == nil { try await Task.sleep(for: .milliseconds(20)) }
        guard store.isViewingStash, store.stashDetail != nil,
          store.diff?.snapshotHash == stash.oid, !store.canEdit, store.error == stagingRefusal
        else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        // The probe deliberately triggered this visible read-only refusal.
        // Clear it only after the independent status check and navigation assertions.
        store.error = nil
        print(
          "Verified stash read-only guards, current snapshot preservation and return navigation")
      }
    }
    guard
      mode == "--welcome"
        || (store.workspace != nil && (store.repository != nil || store.pendingWorktree)
          && store.error == nil)
    else {
      throw NSError(
        domain: "NativePreview", code: 1,
        userInfo: [NSLocalizedDescriptionKey: store.error ?? "No prepared worktree to render"])
    }
    let branchModel = BranchBrowserModel()
    let branchMode = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_BRANCHES"] == "1"
    if branchMode {
      let selection = store.selection
      let before = store.repository?.snapshotHash
      await branchModel.load(store)
      guard branchModel.error == nil, branchModel.branches.contains(where: \.current),
        let remote = branchModel.branches.first(where: \.isRemote)
      else { throw CocoaError(.validationMissingMandatoryProperty) }
      branchModel.query = "origin/"
      guard !branchModel.filteredBranches.isEmpty,
        branchModel.filteredBranches.allSatisfy(\.isRemote)
      else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
      branchModel.query = ""
      await branchModel.select(remote, store: store)
      guard branchModel.error == nil, branchModel.commits.first?.oid == remote.tipOid,
        store.selection == selection, store.repository?.snapshotHash == before
      else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
      print(
        "Verified actual local/remote branch list, search and pinned per-branch history without folder selection changes"
      )
    }
    let content: AnyView
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_LAYOUT_SETTINGS"] == "1" {
      content = AnyView(
        LayoutOptions(layout: layout).background(Color(nsColor: .windowBackgroundColor)))
    } else if branchMode {
      content = AnyView(BranchesView(store: store, model: branchModel))
    } else {
      content = AnyView(
        WorkbenchRoot(
          store: store,
          layout: layout, dockSession: dockSession
        ))
    }
    let view = NSHostingView(
      rootView:
        content
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.controlActiveState, .active)
        .frame(width: width, height: height))
    view.frame = NSRect(x: 0, y: 0, width: width, height: height)
    let window = NSWindow(
      contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    // Let SwiftUI resolve native control layout in this process's run loop.
    try await Task.sleep(for: .milliseconds(500))
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_REVIEW"] == "1" {
      try await verifyReviewContinuity(store, view: view, layout: layout)
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_DOCKING"] == "1" {
      try await verifyDocking(
        store, layout: layout, drag: dockSession, defaults: defaults, socket: mode)
    }
    let dockScene = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_DOCK_SCENE"] ?? "default"
    if dockScene != "default" {
      layout.hidePane(.details)
      if dockScene == "free" {
        layout.showPane(.commit)
        try await Task.sleep(for: .milliseconds(100))
        try await dock(.stash, beside: .diff, edge: .left, layout: layout, drag: dockSession)
        try await dock(.graph, beside: .commit, edge: .bottom, layout: layout, drag: dockSession)
        try await dock(.files, beside: .diff, edge: .bottom, layout: layout, drag: dockSession)
      } else if dockScene == "tabs" {
        try await dock(.files, beside: .diff, edge: .center, layout: layout, drag: dockSession)
        try await dock(.graph, beside: .diff, edge: .center, layout: layout, drag: dockSession)
        layout.selectPane(.diff)
      } else if dockScene == "drag-preview" {
        guard let frame = dockSession.frames[.diff] else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
        dockSession.drag(.stash, to: CGPoint(x: frame.minX + 20, y: frame.midY))
      } else if dockScene == "branches" {
        layout.showPane(.branches)
      } else if dockScene == "empty" {
        for pane in WorkbenchPane.allCases { layout.hidePane(pane) }
      }
      try await Task.sleep(for: .milliseconds(dockScene == "branches" ? 500 : 160))
    }
    if ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_VERIFY_LAYOUT"] == "1" {
      let savedLayout = layout.configuration
      let selection = store.selection
      let snapshot = store.repository?.snapshotHash
      let selectedFile = store.selectedFile
      let staged = store.staged
      let draft = store.commitMessage
      for preset in LayoutPreset.allCases {
        layout.apply(preset)
        try await Task.sleep(for: .milliseconds(60))
        view.layoutSubtreeIfNeeded()
        guard store.selection == selection, store.repository?.snapshotHash == snapshot,
          store.selectedFile == selectedFile, store.staged == staged, store.commitMessage == draft,
          LayoutPreferences(defaults: defaults).configuration == layout.configuration
        else { throw CocoaError(.validationMissingMandatoryProperty) }
      }
      layout.update { $0 = savedLayout }
      try await Task.sleep(for: .milliseconds(60))
      if let selection, !mode.hasPrefix("--") {
        var params: [String: JSONValue] = ["repo_id": .string(selection.repoId)]
        if let opID = selection.opId { params["op_id"] = .string(opID) }
        let checked: RepositoryStatus = try await ServiceClient(socketPath: mode).call(
          "get_repo_status", params: params)
        guard checked.snapshotHash == snapshot else {
          throw CocoaError(.validationMissingMandatoryProperty)
        }
      }
      print(
        "Verified layout presets and saved settings with the same mounted native root; live selection, file, staging and draft preserved"
      )
    }
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw CocoaError(.fileWriteUnknown)
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    print("Rendered native SwiftUI/AppKit view: \(CommandLine.arguments[2])")
    window.contentView = nil
    await store.stopIdleServices()
    if mode.hasPrefix("--") { try? FileManager.default.removeItem(at: previewStorage) }
  }

  @MainActor private static func requireSyntheticFixture(_ store: WorkbenchStore) throws {
    guard let value = ProcessInfo.processInfo.environment["WORKBENCH_PREVIEW_FIXTURE_ROOT"] else {
      throw NSError(domain: "PreviewScope", code: 1, userInfo: [NSLocalizedDescriptionKey: "Mutation probes require scripts/native_preview.py's private synthetic fixture"])
    }
    let root = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL
    let parent = root.deletingLastPathComponent()
    let temporary = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().standardizedFileURL
    func inside(_ path: String) -> Bool {
      let components = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.pathComponents
      return components.starts(with: root.pathComponents) && components.count > root.pathComponents.count
    }
    guard root.lastPathComponent == "fixture", parent.lastPathComponent.hasPrefix("workbench-preview-"),
      parent.deletingLastPathComponent().pathComponents == temporary.pathComponents,
      let marker = try? String(contentsOf: root.appendingPathComponent(".native-preview-fixture"), encoding: .utf8),
      URL(fileURLWithPath: marker).resolvingSymlinksInPath().standardizedFileURL.pathComponents == root.pathComponents,
      let repositories = store.workspace?.repositories, !repositories.isEmpty,
      repositories.allSatisfy({ inside($0.path) }), store.repository.map({ inside($0.path) }) ?? true
    else { throw NSError(domain: "PreviewScope", code: 2, userInfo: [NSLocalizedDescriptionKey: "Refused verification outside the synthetic preview fixture"]) }
  }

  @MainActor private static func waitForSelection(_ store: WorkbenchStore) async throws {
    for _ in 0..<1000 {
      if !store.validatingSelection { return }
      if let error = store.error {
        throw NSError(
          domain: "NativePreview", code: 2, userInfo: [NSLocalizedDescriptionKey: error])
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    throw CocoaError(.validationMissingMandatoryProperty)
  }

  @MainActor private static func diffScroll(in view: NSView) -> NSScrollView? {
    if view.identifier?.rawValue == "workbench.diff-scroll-position" { return view.enclosingScrollView }
    for child in view.subviews {
      if let found = diffScroll(in: child) { return found }
    }
    return nil
  }

  @MainActor private static func verifyTaskContext(_ store: WorkbenchStore) async throws {
    guard let selection = store.selection, let opID = selection.opId, let initial = store.repository else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let client = ServiceClient(socketPath: store.socketPath)
    let model = store.taskContext
    var values: [String: JSONValue] = [
      "repo_id": .string(selection.repoId), "context_op_id": .string(opID), "expected_revision": .number(0),
      "purpose": .string("앱을 다시 열어도 로그인 상태가 이어지도록 세션 복원을 개선합니다."),
      "criteria": .array([.string("재시작 후 세션이 복원된다"), .string("만료된 세션은 로그인 화면으로 돌아간다")]),
      "references": .array([.string("docs/session-recovery.md")]), "notes": .string("오프라인·만료 세션 테스트를 추가하고 API 저장소의 준비 실패를 확인해야 합니다.")]
    let _: TaskContextBundle = try await client.call("save_task_context", params: values)
    await model.refresh()
    guard model.bundle?.context.revision == 1 else { throw CocoaError(.validationMissingMandatoryProperty) }
    await model.runCheck(snapshot: initial.snapshotHash, at: selection)
    guard model.bundle?.verifications.first?.kind == "git_check",
      model.bundle?.verifications.first?.verdict == "passed" else { throw CocoaError(.validationMissingMandatoryProperty) }
    let beforeCount = model.bundle?.verifications.count
    let staleRecord = await model.record(kind: "human_report", verdict: "passed", command: "", note: "must not save", at: "obsolete-screen")
    guard !staleRecord, model.bundle?.verifications.count == beforeCount else { throw CocoaError(.validationMissingMandatoryProperty) }
    let recorded = await model.record(kind: "ai_report", verdict: "passed", command: "swift test (AI report)", note: "AI가 세션 테스트 통과를 보고했습니다. 앱은 실행을 관찰하지 않았습니다.", at: model.identity)
    guard recorded, let report = model.bundle?.verifications.first, report.kind == "ai_report", report.afterSnapshotHash == nil else { throw CocoaError(.validationMissingMandatoryProperty) }
    let file = URL(fileURLWithPath: initial.path).appendingPathComponent("Sources/Session.swift")
    let original = try String(contentsOf: file, encoding: .utf8)
    try (original + "// whitespace fixture   \n").write(to: file, atomically: false, encoding: .utf8)
    await store.refresh()
    guard let changed = store.repository, changed.snapshotHash != initial.snapshotHash,
      changed.snapshot.head == initial.snapshot.head, changed.snapshot.indexHash == initial.snapshot.indexHash,
      report.freshness(repoId: selection.repoId, opId: selection.opId, snapshot: changed.snapshotHash, requirements: model.bundle?.context.requirementsHash).contains("이전 코드")
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    await model.runCheck(snapshot: changed.snapshotHash, at: selection)
    guard model.bundle?.verifications.first?.verdict == "failed" else { throw CocoaError(.validationMissingMandatoryProperty) }
    values["expected_revision"] = .number(1)
    values["criteria"] = .array([.string("재시작 후 세션이 복원된다"), .string("만료된 세션은 로그인 화면으로 돌아간다"), .string("오프라인에서도 저장된 세션을 복원한다")])
    let _: TaskContextBundle = try await client.call("save_task_context", params: values)
    await model.refresh()
    guard let receipt = model.bundle?.verifications.first,
      receipt.freshness(repoId: selection.repoId, opId: selection.opId, snapshot: changed.snapshotHash, requirements: model.bundle?.context.requirementsHash).contains("완료 조건 변경"),
      let handoff = await model.handoff(), handoff.contains("### \"api\""), handoff.contains("### \"ios-app\""),
      handoff.contains("AI가 보고한 결과"), handoff.contains("오프라인에서도"), handoff.contains("통합 검증/승인을 뜻하지 않습니다")
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    try handoff.write(to: URL(fileURLWithPath: CommandLine.arguments[2]).deletingPathExtension().appendingPathExtension("handoff.txt"), atomically: true, encoding: .utf8)
    await store.connect()
    guard store.taskContext.bundle?.context.revision == 2,
      store.taskContext.bundle?.verifications.count == 3,
      store.repository?.snapshot.head == initial.snapshot.head,
      store.repository?.snapshot.indexHash == initial.snapshot.indexHash
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    print("Verified task context persistence/reconnect, observed vs AI report, stale screen guard, code/criteria freshness, failed whitespace check, multi-repo handoff and unchanged HEAD/index")
  }

  @MainActor private static func verifyReviewContinuity(
    _ store: WorkbenchStore, view: NSView, layout: LayoutPreferences
  ) async throws {
    guard let selection = store.selection, let repo = store.repository, let diff = store.diff,
      store.canMarkRead, diff.path == "Sources/Session.swift", diff.hunks.count == 2,
      let scroll = diffScroll(in: view),
      (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 300
    else { throw NSError(domain: "ReviewProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing long mounted diff"] ) }
    scroll.contentView.scroll(to: NSPoint(x: 0, y: 280))
    scroll.reflectScrolledClipView(scroll.contentView)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
    guard abs(store.currentReviewScrollOffset - 280) < 2 else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.markCurrentFileRead()
    guard store.currentReadingState == .reviewed,
      let request = store.hunkRequestText(0, instruction: "Handle an empty session"),
      request.contains(repo.path), request.contains(diff.snapshotHash), request.contains(diff.hunks[0]),
      !request.contains(diff.hunks[1])
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.onlyUnreviewedFiles = true
    guard !store.displayedFiles.contains(where: { $0.path == diff.path }) else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.onlyUnreviewedFiles = false
    store.commitMessage = "검토 중인 로그인 변경"
    store.select(.init(repoId: selection.repoId))
    try await waitForSelection(store)
    store.select(selection)
    guard !store.canMarkRead else { throw CocoaError(.validationMissingMandatoryProperty) }
    try await waitForSelection(store)
    try await Task.sleep(for: .milliseconds(200))
    view.layoutSubtreeIfNeeded()
    guard store.currentReadingState == .reviewed,
      store.commitMessage == "검토 중인 로그인 변경",
      abs((diffScroll(in: view)?.contentView.bounds.minY ?? -1) - 280) < 2,
      store.repository?.snapshotHash == repo.snapshotHash
    else { throw NSError(domain: "ReviewProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Reading/scroll restoration failed"]) }
    let saved = layout.configuration
    layout.dockPane(.diff, nextTo: .files, edge: .bottom)
    try await Task.sleep(for: .milliseconds(200))
    layout.update { $0 = saved }
    try await Task.sleep(for: .milliseconds(200))
    guard abs((diffScroll(in: view)?.contentView.bounds.minY ?? -1) - 280) < 2 else {
      throw NSError(domain: "ReviewProbe", code: 3, userInfo: [NSLocalizedDescriptionKey: "Docking lost scroll position"])
    }
    // External edits only touch this probe's newly-created synthetic worktree.
    let peer = URL(fileURLWithPath: repo.path).appendingPathComponent("README.md")
    let savedPeer = try Data(contentsOf: peer)
    try (savedPeer + Data("\n// Unrelated external edit\n".utf8)).write(to: peer)
    await store.refresh()
    guard store.currentReadingState == .reviewed else { throw CocoaError(.validationMissingMandatoryProperty) }
    try savedPeer.write(to: peer)
    let file = URL(fileURLWithPath: repo.path).appendingPathComponent(diff.path)
    let source = try Data(contentsOf: file)
    try (source + Data("// External change after reading\n".utf8)).write(to: file)
    await store.refresh()
    try await Task.sleep(for: .milliseconds(200))
    guard store.currentReadingState == .needsReview, store.changedReadingHunks == [1],
      store.readingCheckpoint?.text == diff.text, store.currentReviewScrollOffset == 0,
      abs(diffScroll(in: view)?.contentView.bounds.minY ?? -1) < 2,
      store.repository?.snapshot.head == repo.snapshot.head,
      store.repository?.snapshot.indexHash == repo.snapshot.indexHash
    else { throw NSError(domain: "ReviewProbe", code: 4, userInfo: [NSLocalizedDescriptionKey: "External edit did not invalidate reading/scroll"]) }
    // Fault-inject only the synthetic original's config. A refused status must
    // keep the existing mounted diff readable without authorizing a write.
    if let original = store.workspace?.repositories.first(where: { $0.id == selection.repoId }),
      let sibling = store.workspace?.repositories.first(where: { $0.id != selection.repoId }),
      let mounted = diffScroll(in: view) {
      let config = URL(fileURLWithPath: original.path).appendingPathComponent(".git/config")
      let saved = try Data(contentsOf: config)
      defer { try? saved.write(to: config, options: .atomic) }
      mounted.contentView.scroll(to: NSPoint(x: 0, y: 180))
      mounted.reflectScrolledClipView(mounted.contentView)
      NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: mounted)
      let y = mounted.contentView.bounds.minY
      let rendered = store.diff?.contentIdentity
      try Data((String(decoding: saved, as: UTF8.self) + "\n[core]\nworktree = \(sibling.path)\n").utf8).write(to: config, options: .atomic)
      await store.refresh(); try await Task.sleep(for: .milliseconds(200))
      view.layoutSubtreeIfNeeded()
      guard store.selectionCheckFailed, !store.canEdit, store.diff?.contentIdentity == rendered,
        diffScroll(in: view) === mounted, abs(mounted.contentView.bounds.minY - y) < 2
      else { throw NSError(domain: "ReviewProbe", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed validation unmounted the cached read-only diff"]) }
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let failureImage = URL(fileURLWithPath: CommandLine.arguments[2]).deletingPathExtension().appendingPathExtension("validation-failed.png")
      guard let failurePNG = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
      try failurePNG.write(to: failureImage)
      try saved.write(to: config, options: .atomic)
      await store.refresh(); try await Task.sleep(for: .milliseconds(100))
      guard store.canEdit, !store.selectionCheckFailed else { throw CocoaError(.validationMissingMandatoryProperty) }
    } else { throw CocoaError(.validationMissingMandatoryProperty) }
    print("Verified mounted diff scroll restoration across folders/docking, reading checkpoints, unrelated edits, own-file invalidation, unchanged Git HEAD/index, snapshot-bound selected-hunk handoff and cached read-only diff continuity through validation failure/recovery")
  }

  @MainActor private static func verifyPreparationReadiness(_ store: WorkbenchStore) async throws {
    guard let initial = store.selection, let operation = store.operation,
      let unfinished = operation.repos.first(where: { $0.state != "ready" && $0.hasWorktree }),
      let ready = operation.repos.first(where: { $0.state == "ready" }), !operation.isRunning
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.select(.init(repoId: unfinished.id, opId: operation.id))
    try await waitForSelection(store)
    guard store.repository != nil, store.taskPreparationIncomplete, !store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let snapshot = store.repository?.snapshotHash
    store.select(.init(repoId: unfinished.id))
    try await waitForSelection(store)
    guard !store.taskPreparationIncomplete, store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.select(.init(repoId: ready.id, opId: operation.id))
    try await waitForSelection(store)
    guard !store.taskPreparationIncomplete, store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.select(.init(repoId: unfinished.id, opId: operation.id))
    try await waitForSelection(store)
    guard store.repository?.snapshotHash == snapshot, !store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.select(initial)
    try await waitForSelection(store)
    print("Verified unfinished task is read-only while original folder and Ready sibling stay editable; snapshot preserved")
  }

  @MainActor private static func dock(
    _ pane: WorkbenchPane, beside target: WorkbenchPane,
    edge: DockEdge, layout: LayoutPreferences, drag: DockDragSession
  ) async throws {
    try await Task.sleep(for: .milliseconds(80))
    guard let rect = drag.frames[target] else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let point: CGPoint
    switch edge {
    case .left: point = .init(x: rect.minX + 20, y: rect.midY)
    case .right: point = .init(x: rect.maxX - 20, y: rect.midY)
    case .top: point = .init(x: rect.midX, y: rect.minY + 20)
    case .bottom: point = .init(x: rect.midX, y: rect.maxY - 20)
    case .center: point = .init(x: rect.midX, y: rect.midY)
    }
    drag.drag(pane, to: point)
    // Every tab in one group shares a drop region; its representative pane may differ.
    guard drag.target?.edge == edge,
      let hitPane = drag.target?.pane, drag.frames[hitPane] == rect
    else {
      throw NSError(
        domain: "NativeDock", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Incorrect pane drop target"])
    }
    drag.finish(in: layout)
    try await Task.sleep(for: .milliseconds(100))
  }

  @MainActor private static func verifyDocking(
    _ store: WorkbenchStore, layout: LayoutPreferences,
    drag: DockDragSession, defaults: UserDefaults, socket: String
  ) async throws {
    let original = layout.configuration
    let selection = store.selection
    let snapshot = store.repository?.snapshotHash
    let file = store.selectedFile
    let diff = store.diff?.text
    let staged = store.staged
    let message = store.commitMessage
    // Focus starts with two panes; materialize a target for the same drag scenario.
    layout.showPane(.commit)
    try await Task.sleep(for: .milliseconds(100))
    layout.hidePane(.details)
    try await dock(.stash, beside: .diff, edge: .left, layout: layout, drag: drag)
    guard let stash = drag.frames[.stash], let review = drag.frames[.diff],
      stash.maxX <= review.minX
    else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await dock(.graph, beside: .commit, edge: .bottom, layout: layout, drag: drag)
    guard let graph = drag.frames[.graph], let commit = drag.frames[.commit],
      graph.minY >= commit.maxY
    else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await dock(.files, beside: .diff, edge: .bottom, layout: layout, drag: drag)
    let split = layout.dockLayout
    try await dock(.stash, beside: .graph, edge: .center, layout: layout, drag: drag)
    guard drag.frames[.stash] == drag.frames[.graph] else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    layout.undoDock()
    guard layout.dockLayout == split else { throw CocoaError(.validationMissingMandatoryProperty) }
    let restored = LayoutPreferences(defaults: defaults)
    guard restored.dockLayout == layout.dockLayout,
      store.selection == selection, store.repository?.snapshotHash == snapshot,
      store.selectedFile == file, store.diff?.text == diff, store.staged == staged,
      store.commitMessage == message
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    if let selection {
      var params: [String: JSONValue] = ["repo_id": .string(selection.repoId)]
      if let opID = selection.opId { params["op_id"] = .string(opID) }
      let status: RepositoryStatus = try await ServiceClient(socketPath: socket).call(
        "get_repo_status", params: params)
      guard status.snapshotHash == snapshot else {
        throw CocoaError(.validationMissingMandatoryProperty)
      }
    }
    layout.update { $0 = original }
    try await Task.sleep(for: .milliseconds(100))
    print(
      "Verified arbitrary pane splits/tabs from mounted geometry through the actual drag controller, undo, saved tree and live Git review preservation"
    )
  }

  @MainActor private static func verifyFolderSwitching(_ store: WorkbenchStore) async throws {
    guard let task = store.selection, let opID = task.opId, let repo = store.repository,
      let diff = store.diff,
      let otherRepo = store.operation?.repos.first(where: { $0.id != task.repoId && $0.hasWorktree }
      )
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    let path = store.selectedFile
    let staged = store.staged
    store.commitMessage = "작업 폴더의 작성 중인 커밋"
    store.select(.init(repoId: task.repoId))
    try await waitForSelection(store)
    guard store.repository?.path != repo.path else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    store.commitMessage = "원래 폴더의 별도 커밋 초안"
    let started = ContinuousClock.now
    store.select(task)
    let restored = started.duration(to: .now)
    // These assertions run synchronously, before the next service read can finish.
    guard store.repository?.path == repo.path, store.repository?.snapshotHash == repo.snapshotHash,
      store.diff?.text == diff.text, store.selectedFile == path, store.staged == staged,
      store.commitMessage == "작업 폴더의 작성 중인 커밋", store.validatingSelection, !store.canEdit
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    try await waitForSelection(store)
    store.select(.init(repoId: otherRepo.id, opId: opID))
    try await waitForSelection(store)
    store.commitMessage = "다른 저장소의 커밋 초안"
    store.select(task)
    guard store.repository?.path == repo.path, store.commitMessage == "작업 폴더의 작성 중인 커밋"
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    // Rapid selection changes must not publish a superseded response.
    store.select(.init(repoId: task.repoId))
    guard store.commitMessage == "원래 폴더의 별도 커밋 초안" else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    let file = URL(fileURLWithPath: repo.path).appendingPathComponent("Sources/Session.swift")
    let saved = try Data(contentsOf: file)
    defer { try? saved.write(to: file) }
    var edited = saved
    edited.append(Data("// External edit while another folder is active\n".utf8))
    try edited.write(to: file)
    store.select(task)
    guard store.repository?.snapshotHash == repo.snapshotHash, !store.canEdit else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await waitForSelection(store)
    guard store.selection == task, store.repository?.snapshotHash != repo.snapshotHash,
      store.commitMessage == "작업 폴더의 작성 중인 커밋", store.canEdit
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    try saved.write(to: file)
    await store.refresh()
    let reconnectedHash = store.repository?.snapshotHash
    await store.reconnect()
    guard store.selection == task, store.repository?.snapshotHash == reconnectedHash,
      store.selectedFile == path, store.staged == staged,
      store.commitMessage == "작업 폴더의 작성 중인 커밋"
    else { throw CocoaError(.validationMissingMandatoryProperty) }
    store.select(.init(repoId: task.repoId))
    guard store.commitMessage == "원래 폴더의 별도 커밋 초안" else {
      throw CocoaError(.validationMissingMandatoryProperty)
    }
    try await waitForSelection(store)
    store.select(task)
    try await waitForSelection(store)
    print(
      "Verified immediate review/draft restoration across repositories, folders and reconnect; external drift revalidated before editing. Synchronous restore: \(restored)"
    )
  }
}
