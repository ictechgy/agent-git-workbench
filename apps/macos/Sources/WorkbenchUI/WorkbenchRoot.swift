import AppKit
import SwiftUI
import WorkbenchProtocol

enum WorkbenchTheme {
  static let accent = Color(red: 0.25, green: 0.34, blue: 0.91)
  static let sidebar = Color(nsColor: .windowBackgroundColor)
  static let canvas = Color(nsColor: .textBackgroundColor)
  static let panel = Color(nsColor: .controlBackgroundColor)
  static let line = Color(nsColor: .separatorColor).opacity(0.5)
  static func stateColor(_ state: String) -> Color {
    if state == "ready" { return .green }
    if ["failed", "needs_recovery"].contains(state) { return .red }
    if ["partial_failure", "waiting_for_worktree", "cancelled"].contains(state) { return .orange }
    return accent
  }
}

public struct WorkbenchRoot: View {
  @ObservedObject private var store: WorkbenchStore
  @StateObject private var layout: LayoutPreferences
  @State private var drag: DockDragSession
  @State private var showErrorDetails = false
  public init(
    store: WorkbenchStore, layout: LayoutPreferences? = nil, dockSession: DockDragSession? = nil
  ) {
    self.store = store
    _layout = StateObject(wrappedValue: layout ?? LayoutPreferences())
    _drag = State(initialValue: dockSession ?? DockDragSession())
  }

  public var body: some View {
    GeometryReader { _ in
      let inspectorVisible = layout.dockLayout.contains(.commit)
      VStack(spacing: 0) {
        if let error = store.error {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
              Text(error).font(.system(size: 12)).textSelection(.enabled)
              if let details = store.errorDetails, details != error {
                DisclosureGroup("기술 정보", isExpanded: $showErrorDetails) {
                  Text(details).font(.system(size: 10, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if store.canReconnect {
              Button("다시 연결") { Task { await store.reconnect() } }.disabled(store.busy)
            }
            Button {
              store.error = nil
            } label: {
              Image(systemName: "xmark")
            }.buttonStyle(.plain).help("오류 닫기").accessibilityLabel("오류 닫기")
          }.padding(12).background(Color.orange.opacity(0.1)).accessibilityElement(
            children: .contain)
          Divider()
        }
        if store.workspace == nil || store.showingWelcome {
          WelcomeView(store: store)
        } else {
          WorkspaceContextHeader(
            store: store,
            showInspector: Binding(
              get: { inspectorVisible },
              set: { value in
                if value { layout.showPane(.commit) } else { layout.hidePane(.commit) }
              }), layout: layout)
          if layout.configuration.navigation == .tracks {
            RepositoryTracks(store: store) {
              ReviewLayout(
                store: store, layout: layout, drag: drag)
            }.padding(.horizontal, 14).padding(.bottom, 14)
              .background(WorkbenchTheme.sidebar)
          } else {
            VStack(spacing: 0) {
              RepositoryTabs(store: store)
              ReviewLayout(
                store: store, layout: layout, drag: drag)
            }
          }
        }
      }
    }
    .background(WorkbenchTheme.canvas)
    .tint(WorkbenchTheme.accent)
    .navigationTitle(store.showingWelcome ? "Agent Git Workbench" : store.taskTitle)
    .onAppear { store.splitDiff = layout.configuration.splitDiff }
    .onChange(of: layout.configuration.splitDiff) { _, value in store.splitDiff = value }
    .onChange(of: store.splitDiff) { _, value in layout.update { $0.splitDiff = value } }
    .sheet(isPresented: $store.showTaskSheet) { NewTaskSheet(store: store).id(store.workspaceSession) }
    .sheet(isPresented: $store.showBranches) {
      BranchesView(store: store) { store.showBranches = false }
        .frame(minWidth: 900, idealWidth: 1100, minHeight: 580, idealHeight: 700)
    }
  }
}

struct StateBadge: View {
  let state: String
  var body: some View {
    Text(StatusText.label(state)).font(.system(size: 11, weight: .medium))
      .foregroundStyle(WorkbenchTheme.stateColor(state)).padding(.horizontal, 7).padding(
        .vertical, 4
      )
      .background(
        WorkbenchTheme.stateColor(state).opacity(0.08), in: RoundedRectangle(cornerRadius: 5)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 5).stroke(
          WorkbenchTheme.stateColor(state).opacity(0.25), lineWidth: 0.5))
  }
}
struct StateDot: View {
  let state: String
  var body: some View {
    Circle().fill(WorkbenchTheme.stateColor(state)).frame(width: 7, height: 7).accessibilityLabel(
      StatusText.label(state))
  }
}
