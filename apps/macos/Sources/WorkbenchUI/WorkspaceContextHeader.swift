import SwiftUI
import WorkbenchProtocol

struct WorkspaceContextHeader: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var showInspector: Bool
  @ObservedObject var layout: LayoutPreferences
  @State private var showLayoutOptions = false
  var body: some View {
    HStack(spacing: 10) {
      RiverAppIcon(size: 22)
      Menu {
        Section(store.workspaceTitle) {
          ForEach(store.operations) { op in
            Button("\(store.title(for: op)) · \(StatusText.label(op.status))") {
              store.selectTask(op)
            }
          }
        }
        Section("기존 저장소") {
          ForEach(store.workspace?.repositories ?? []) { repo in
            Button(repo.id) { store.select(.init(repoId: repo.id), leaveTask: true) }
          }
        }
        Divider()
        Button("새 작업…") { store.recoveryTaskID = nil; store.showTaskSheet = true }
        Button("저장소 열기…") { store.chooseRepository() }
        Button("시작 화면") { store.showingWelcome = true }
      } label: {
        Text(store.taskTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(WorkbenchTheme.primaryText)
          .lineLimit(1)
      }.menuStyle(.borderlessButton).frame(maxWidth: 280, alignment: .leading).disabled(store.busy)
        .help("작업 선택")
      Spacer(minLength: 10)
      if store.validatingSelection {
        Text(store.selectionCheckFailed ? "변경 확인 실패" : "변경 확인 중…")
          .foregroundStyle(store.selectionCheckFailed ? WorkbenchTheme.warning : WorkbenchTheme.secondaryText).font(.system(size: 12))
          .fixedSize()
          .help(store.selectionCheckFailed ? "최신 상태를 확인하지 못했습니다. 새로고침이 성공하면 편집할 수 있습니다." : "최근 화면을 표시하면서 파일의 최신 상태를 확인하고 있습니다.")
      }
      HStack(spacing: 2) {
      Button {
        layout.showPane(.details)
      } label: {
        Text("작업 정보")
      }.buttonStyle(ChromeButtonStyle(active: layout.dockLayout.isVisible(.details)))
        .help("작업 정보 패널 열기 · 작업 목적 · 완료 조건 · 검증 기록 · 인수인계")
        .accessibilityValue(layout.dockLayout.isVisible(.details) ? "표시 중" : "열기")
      Button {
        layout.showPane(.graph)
      } label: {
        Text("기록")
      }.buttonStyle(ChromeButtonStyle(active: layout.dockLayout.isVisible(.graph)))
        .help("커밋 기록과 그래프 열기")
        .accessibilityLabel("커밋 기록")
        .accessibilityValue(layout.dockLayout.isVisible(.graph) ? "표시 중" : "열기")
      Button {
        layout.showPane(.branches)
      } label: {
        Text("전체 브랜치")
      }.buttonStyle(ChromeButtonStyle(active: layout.dockLayout.isVisible(.branches)))
        .help("전체 브랜치 패널 열기 · 선택한 저장소의 로컬·원격 브랜치와 기록 보기")
        .accessibilityValue(layout.dockLayout.isVisible(.branches) ? "표시 중" : "열기")
      Button {
        layout.showPane(.stash)
        store.revealStashes()
      } label: {
        Label("Stash \(store.stashes.count)", systemImage: "archivebox")
      }.buttonStyle(ChromeButtonStyle(active: layout.dockLayout.isVisible(.stash)))
        .help("Stash 패널 열기 · 선택한 저장소의 워크트리들이 공유합니다")
        .accessibilityValue(layout.dockLayout.isVisible(.stash) ? "표시 중" : "열기")
      Button {
        if layout.dockLayout.isVisible(.commit) { showInspector = false }
        else { layout.showPane(.commit) }
      } label: {
        Label("커밋 작성", systemImage: "square.and.pencil")
      }
      .buttonStyle(ChromeButtonStyle(active: layout.dockLayout.isVisible(.commit)))
      .keyboardShortcut("i", modifiers: [.command, .option])
      .accessibilityLabel(layout.dockLayout.isVisible(.commit) ? "커밋 패널 숨기기" : "커밋 작성 패널 열기")
      .accessibilityValue(layout.dockLayout.isVisible(.commit) ? "표시 중" : "열기")
      .help("커밋 작성 패널 표시 · ⌘⌥I")
      Rectangle().fill(WorkbenchTheme.line).frame(width: 1, height: 16).padding(.horizontal, 4)
      Button {
        Task { await store.refresh(forceDiff: true) }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .buttonStyle(ChromeButtonStyle())
      .keyboardShortcut("r", modifiers: .command).disabled(store.busy).help("새로고침 · ⌘R").accessibilityLabel("현재 저장소 새로고침")
      Button {
        showLayoutOptions.toggle()
      } label: {
        Image(systemName: "rectangle.3.group")
      }.buttonStyle(ChromeButtonStyle(active: showLayoutOptions))
        .keyboardShortcut("l", modifiers: [.command, .option])
        .accessibilityLabel("화면 구성")
        .help("패널 표시 · 배치 되돌리기 · 기본 배치 · ⌘⌥L")
        .popover(isPresented: $showLayoutOptions, arrowEdge: .bottom) {
          LayoutOptions(layout: layout)
        }
      }.fixedSize(horizontal: true, vertical: false)
    }.font(.system(size: 12)).controlSize(.regular)
      .padding(.horizontal, 16).frame(height: 48).background(WorkbenchTheme.chrome)
  }
}
