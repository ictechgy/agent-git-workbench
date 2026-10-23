import SwiftUI

public struct WorkbenchViewCommands: Commands {
  @ObservedObject private var store: WorkbenchStore
  @ObservedObject private var layout: LayoutPreferences
  @ObservedObject private var reading: ReadingPreferences
  public init(store: WorkbenchStore, layout: LayoutPreferences, reading: ReadingPreferences) {
    self.store = store
    self.layout = layout
    self.reading = reading
  }
  private var available: Bool { store.workspace != nil && !store.showingWelcome }
  public var body: some Commands {
    CommandGroup(after: .toolbar) {
      Divider()
      Menu("패널") {
        ForEach(WorkbenchPane.allCases) { pane in
          Toggle(
            pane.title,
            isOn: Binding(
              get: { layout.dockLayout.contains(pane) },
              set: { visible in
                if visible {
                  layout.showPane(pane)
                  if pane == .stash { store.revealStashes() }
                } else {
                  layout.hidePane(pane)
                }
              })
          ).keyboardShortcut(KeyEquivalent(shortcut(pane)), modifiers: [.command, .option])
        }
      }.disabled(!available)
      Menu("패널 배치") {
        ForEach(layout.dockLayout.panes) { pane in
          Menu(pane.title) {
            Menu("전체 영역") {
              ForEach(DockEdge.allCases.filter { $0 != .center }) { edge in
                Button(edge.title) { layout.dockPane(pane, nextTo: nil, edge: edge) }
              }
            }
            ForEach(layout.dockLayout.panes.filter { $0 != pane }) { target in
              Menu(target.title) {
                ForEach(DockEdge.allCases) { edge in
                  Button(edge.title) { layout.dockPane(pane, nextTo: target, edge: edge) }
                }
              }
            }
          }
        }
      }.disabled(!available || layout.dockLayout.panes.isEmpty)
      Button(layout.focusedPane == nil ? "Diff 크게 보기" : "원래 배치로") {
        if layout.focusedPane == nil { layout.focusPane(.diff) } else { layout.restorePaneLayout() }
      }.keyboardShortcut(.return, modifiers: [.command, .control])
        .disabled(!available || (layout.focusedPane == nil && !layout.dockLayout.contains(.diff)))
      Menu("다른 패널 크게 보기") {
        ForEach(layout.dockLayout.panes) { pane in
          Button(pane.title) { layout.focusPane(pane) }
        }
      }.disabled(!available || layout.dockLayout.panes.isEmpty)
      Divider()
      Menu("배치") {
        Section("시작 배치") {
          ForEach(LayoutPreset.allCases) { preset in Button(preset.title) { layout.apply(preset) } }
        }
        if !layout.savedLayouts.isEmpty {
          Section("내 배치") {
            ForEach(layout.savedLayouts) { saved in
              Button(saved.name) { layout.applySavedLayout(saved.id) }.help(saved.name)
            }
          }
        }
        Divider()
        Button("배치 저장·관리…") { layout.showsOptions = true }
      }.disabled(!available)
      Button("화면 구성 되돌리기") { layout.undoDock() }
        .keyboardShortcut("z", modifiers: [.command, .option])
        .disabled(!available || !layout.canUndoDock)
      Button("화면 구성…") { layout.showsOptions = true }
        .keyboardShortcut("l", modifiers: [.command, .option]).disabled(!available)
      Menu("Diff 표시") {
        Picker(
          "Diff 표시",
          selection: Binding(
            get: { layout.configuration.splitDiff },
            set: { value in layout.update { $0.splitDiff = value } })
        ) {
          Text("나란히").tag(true)
          Text("한 화면").tag(false)
        }
      }.disabled(!available)
      Menu("코드 글자 크기") {
        Button("크게") { reading.setCodeSize(reading.configuration.codeSize + 1) }
          .disabled(reading.configuration.codeSize >= 20)
        Button("작게") { reading.setCodeSize(reading.configuration.codeSize - 1) }
          .disabled(reading.configuration.codeSize <= 11)
        Button("기본 글자·간격") { reading.reset() }
      }
      Menu("색상") {
        Picker("색상", selection: $layout.appearance) {
          ForEach(WorkbenchAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
      }
    }
  }
  private func shortcut(_ pane: WorkbenchPane) -> Character {
    switch pane {
    case .files: "1"
    case .diff: "2"
    case .graph: "3"
    case .branches: "4"
    case .stash: "5"
    case .details: "6"
    case .commit: "i"
    }
  }
}
