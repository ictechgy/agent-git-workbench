import AppKit
import SwiftUI
import WorkbenchUI

@main
struct AgentGitWorkbenchApp: App {
  @NSApplicationDelegateAdaptor(WorkbenchAppDelegate.self) private var appDelegate
  @StateObject private var store = WorkbenchStore()
  @StateObject private var layout = LayoutPreferences()
  @StateObject private var reading = ReadingPreferences()
  var body: some Scene {
    Window("River", id: "workbench") {
      WorkbenchRoot(store: store, layout: layout, reading: reading).frame(
        minWidth: 1100, minHeight: 720
      )
      .task {
        appDelegate.store = store
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
  }
}

@MainActor
final class WorkbenchAppDelegate: NSObject, NSApplicationDelegate {
  var store: WorkbenchStore?
  private var repliedToTermination = false
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    func finish() {
      guard !repliedToTermination else { return }
      repliedToTermination = true
      sender.reply(toApplicationShouldTerminate: true)
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
