import AppKit
import SwiftUI
import WorkbenchProtocol

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
        ForEach(store.submissionWarnings) { warning in
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkbenchTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
              Text("\(warning.workspaceTitle) · 실행 여부 확인 필요").font(.system(size: 12, weight: .semibold))
              Text(warning.message).font(.system(size: 12))
              Text(warning.workspacePath).font(.system(size: 11)).foregroundStyle(.secondary)
            }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { store.dismissSubmissionWarning(warning.id) } label: { Image(systemName: "xmark") }
              .buttonStyle(.plain).help("실행 여부 안내 닫기").accessibilityLabel("\(warning.workspaceTitle) 실행 여부 안내 닫기")
          }.padding(12).background(WorkbenchTheme.warning.opacity(0.1))
          Divider()
        }
        if let error = store.error {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(WorkbenchTheme.warning)
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
          }.padding(12).background(WorkbenchTheme.warning.opacity(0.1))
            .overlay(alignment: .leading) {
              Rectangle().fill(WorkbenchTheme.warning).frame(width: 3).allowsHitTesting(false)
            }.accessibilityElement(
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
              .background(WorkbenchTheme.chrome)
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
    .background(WorkbenchTheme.chrome)
    .foregroundStyle(WorkbenchTheme.primaryText)
    .tint(WorkbenchTheme.accent)
    .preferredColorScheme(layout.appearance == .system ? nil : layout.appearance == .dark ? .dark : .light)
    .navigationTitle(store.showingWelcome ? "River" : store.taskTitle)
    .onAppear { store.splitDiff = layout.configuration.splitDiff }
    .onChange(of: layout.configuration.splitDiff) { _, value in store.splitDiff = value }
    .onChange(of: store.splitDiff) { _, value in layout.update { $0.splitDiff = value } }
    .sheet(isPresented: $store.showCloneSheet) { CloneRepositorySheet(store: store) }
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
      .foregroundStyle(WorkbenchTheme.stateColor(state)).padding(.horizontal, 6).padding(
        .vertical, 2
      )
      .background(
        WorkbenchTheme.stateColor(state).opacity(0.12), in: RoundedRectangle(cornerRadius: 4)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 4).strokeBorder(
          WorkbenchTheme.stateColor(state).opacity(0.35), lineWidth: 0.5))
  }
}
struct StateDot: View {
  let state: String
  var body: some View {
    Circle().fill(WorkbenchTheme.stateColor(state)).frame(width: 7, height: 7).accessibilityLabel(
      StatusText.label(state))
  }
}
