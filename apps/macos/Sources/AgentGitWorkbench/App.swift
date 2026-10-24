import AppKit
import SwiftUI
import WorkbenchUI
import WorkbenchUpdates

@main
struct AgentGitWorkbenchApp: App {
  @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var appDelegate
  @StateObject private var store = WorkbenchStore()
  @StateObject private var updates = UpdateController()
  @StateObject private var layout = LayoutPreferences()
  @StateObject private var reading = ReadingPreferences()
  var body: some Scene {
    Window("River", id: "workbench") {
      WorkbenchRoot(store: store, layout: layout, reading: reading).frame(
        minWidth: 1100, minHeight: 720
      )
      .task {
        appDelegate.store = store
        appDelegate.updates = updates
        updates.configureRestartSafety(
          blocker: { [weak store = store] in
            guard let store else { return "앱이 시작되는 중입니다. 잠시 후 다시 시도해 주세요." }
            return store.updateRestartBlocker
          },
          warning: { [weak store = store] in
            RestartConsentSnapshot(
              message: store?.updateRestartWarning,
              identity: store?.updateRestartConsentIdentity ?? [])
          }
        )
        updates.start()
        await store.startup()
        while !Task.isCancelled {
          do { try await Task.sleep(for: .seconds(3)) } catch { break }
          if NSApplication.shared.isActive && !store.showingWelcome {
            await store.refresh()
          }
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
      ) { _ in
        if !store.showingWelcome { Task { await store.refresh() } }
      }
    }
    .defaultSize(width: 1440, height: 960)
    .commands {
      WorkbenchViewCommands(store: store, layout: layout, reading: reading)
      CommandGroup(after: .appInfo) {
        Button("업데이트 확인…") { updates.checkForUpdates() }
          .disabled(!updates.canCheckForUpdates)
      }
      CommandGroup(replacing: .newItem) {
        Button("새 작업…") {
          store.recoveryTaskID = nil
          store.showTaskSheet = true
        }.keyboardShortcut("n").disabled(
          store.workspace == nil || store.busy || store.remoteBusy)
        Button("원격 저장소 복제…") { store.showCloneSheet = true }.disabled(store.busy)
        Button("저장소 열기…") { store.chooseRepository() }.keyboardShortcut("o").disabled(store.busy)
        Menu("최근 저장소") {
          ForEach(store.recentWorkspaces) { recent in
            Button(recent.name) { Task { await store.openRecent(recent) } }.help(
              recent.repositoryPath)
          }
        }.disabled(store.busy || store.recentWorkspaces.isEmpty)
        Button("시작 화면") { store.showingWelcome = true }.disabled(store.busy)
      }
    }
    Settings { UpdateSettingsView(updates: updates) }
  }
}

@MainActor
final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
  var store: WorkbenchStore?
  var updates: UpdateController?
  private var terminationRequestID: UUID?
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard updates?.permitsApplicationTermination() != false else { return .terminateCancel }
    let requestID = UUID()
    terminationRequestID = requestID
    func finish() {
      guard terminationRequestID == requestID else { return }
      terminationRequestID = nil
      // Cleanup awaits and the timeout both yield; new work must still veto an update exit.
      sender.reply(toApplicationShouldTerminate: updates?.permitsApplicationTermination() != false)
    }
    Task {
      await store?.stopIdleServices()
      finish()
    }
    Task {
      try? await Task.sleep(for: .seconds(3))
      finish()
    }
    return .terminateLater
  }
}
