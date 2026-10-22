import SwiftUI
import WorkbenchProtocol

struct WorkspaceContextHeader: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var showInspector: Bool
  @ObservedObject var layout: LayoutPreferences
  @State private var showLayoutOptions = false
  var body: some View {
    HStack(spacing: 16) {
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
        Text(store.taskTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(.primary)
          .lineLimit(1)
      }.menuStyle(.borderlessButton).frame(maxWidth: 280, alignment: .leading).disabled(store.busy)
        .help("작업 선택")
      Label(branch, systemImage: "arrow.triangle.branch")
        .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle)
      Spacer(minLength: 10)
      if store.validatingSelection {
        Text(store.selectionCheckFailed ? "변경 확인 실패" : "변경 확인 중…").foregroundStyle(.secondary).font(.system(size: 11))
          .help(store.selectionCheckFailed ? "최신 상태를 확인하지 못했습니다. 새로고침이 성공하면 편집할 수 있습니다." : "최근 화면을 표시하면서 파일의 최신 상태를 확인하고 있습니다.")
      }
      Button {
        layout.showPane(.details)
      } label: {
        Label("작업 정보", systemImage: "checklist")
      }.help("작업 목적 · 완료 조건 · 검증 기록 · 인수인계")
      Button {
        layout.showPane(.branches)
      } label: {
        Label("전체 브랜치", systemImage: "arrow.triangle.branch")
      }.help("선택한 저장소의 로컬·원격 브랜치와 기록 보기")
      Button {
        layout.showPane(.stash)
        store.revealStashes()
      } label: {
        Label("Stash \(store.stashes.count)", systemImage: "archivebox")
      }.help("Stash 목록 보기 · 선택한 저장소의 워크트리들이 공유합니다")
      Button {
        Task { await store.refresh() }
      } label: {
        Image(systemName: "arrow.clockwise")
      }
      .keyboardShortcut("r", modifiers: .command).disabled(store.busy).help("새로고침 · ⌘R").accessibilityLabel("현재 저장소 새로고침")
      Button {
        showInspector.toggle()
      } label: {
        Image(systemName: "sidebar.right")
      }
      .keyboardShortcut("i", modifiers: [.command, .option])
      .accessibilityLabel(showInspector ? "커밋 패널 숨기기" : "커밋 패널 열기")
      .help(showInspector ? "커밋 패널 숨기기" : "커밋 패널 열기")
      Button {
        showLayoutOptions.toggle()
      } label: {
        Label("화면 구성", systemImage: "rectangle.3.group")
      }.keyboardShortcut("l", modifiers: [.command, .option])
        .help("패널 표시 · 배치 되돌리기 · 기본 배치 · ⌘⌥L")
        .popover(isPresented: $showLayoutOptions, arrowEdge: .bottom) {
          LayoutOptions(layout: layout)
        }
    }.font(.system(size: 12)).controlSize(.regular)
      .padding(.horizontal, 20).frame(height: 58).background(WorkbenchTheme.sidebar)
  }
  private var branch: String {
    let name = store.repository?.snapshot.branch ?? store.taskRepository?.plan.branchRef ?? ""
    if !name.isEmpty { return name.replacingOccurrences(of: "refs/heads/", with: "") }
    if let head = store.repository?.snapshot.head, !head.isEmpty {
      return "HEAD · \(head.prefix(8))"
    }
    return store.pendingWorktree ? "워크트리 준비 대기" : "저장소 불러오는 중…"
  }
}
