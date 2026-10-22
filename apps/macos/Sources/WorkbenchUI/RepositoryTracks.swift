import SwiftUI
import WorkbenchProtocol

struct RepositoryTracks<Content: View>: View {
  @ObservedObject var store: WorkbenchStore
  @ViewBuilder let content: () -> Content
  private var ids: [String] {
    store.contextOperation?.repos.map(\.id) ?? store.workspace?.repositories.map(\.id) ?? []
  }
  private var selectedIndex: Int { ids.firstIndex(of: store.selection?.repoId ?? "") ?? 0 }
  var body: some View {
    VStack(spacing: 10) {
      if selectedIndex > 0 { foldedTracks(Array(ids.prefix(selectedIndex)), offset: 0) }
      VStack(spacing: 0) {
        if ids.indices.contains(selectedIndex) {
          track(ids[selectedIndex], index: selectedIndex, expanded: true)
        }
        CurrentFolderContext(store: store)
        Divider()
        content().frame(maxHeight: .infinity)
      }.background(WorkbenchTheme.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkbenchTheme.line, lineWidth: 1))
      if selectedIndex + 1 < ids.count {
        foldedTracks(Array(ids.dropFirst(selectedIndex + 1)), offset: selectedIndex + 1)
      }
    }
  }
  private func foldedTracks(_ values: [String], offset: Int) -> some View {
    ScrollView {
      VStack(spacing: 10) {
        ForEach(Array(values.enumerated()), id: \.element) { index, id in
          track(id, index: offset + index, expanded: false)
        }
      }
    }.frame(height: min(CGFloat(values.count * 64 - 10), 118))
  }
  private func track(_ id: String, index: Int, expanded: Bool) -> some View {
    let op = store.contextOperation
    let repo = op?.repos.first { $0.id == id }
    return HStack(spacing: 12) {
      Button {
        store.select(.init(repoId: id, opId: op?.id))
      } label: {
        HStack(spacing: 12) {
          Image(systemName: "externaldrive").font(.system(size: 15))
            .foregroundStyle(expanded ? WorkbenchTheme.accent : .secondary)
          Text("저장소").font(.system(size: 11)).foregroundStyle(.secondary)
          Text(id).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          if let repo { StateBadge(state: repo.state) }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(store.busy).help("\(id) 저장소 펼치기")
      if expanded {
        Spacer(minLength: 4)
        if let op {
          Picker(
            "현재 위치",
            selection: Binding(
              get: { store.selection?.opId != nil },
              set: { store.select(.init(repoId: id, opId: $0 ? op.id : nil)) }
            )
          ) {
            Text("이 작업용 폴더").tag(true)
            Text("원래 프로젝트 폴더").tag(false)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 286).disabled(store.busy)
        } else {
          Text("원래 프로젝트 폴더").font(.system(size: 12)).foregroundStyle(.secondary)
        }
      } else {
        Text(repo?.errorCode == nil ? "" : "준비를 완료하지 못했습니다.")
          .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 4)
      }
      if let op, expanded, op.canMaterialize && !op.requiresNewPlan {
        Button("워크트리 준비") { Task { await store.operate("materialize", op: op) } }.disabled(
          store.busy || store.hasRunningOperation)
      }
      if let op, op.canRetry,
        repo?.state != "ready" || op.repos.allSatisfy({ $0.state == "ready" }) {
        if op.requiresNewPlan {
          Button("새 작업 만들기") { store.beginRecovery(op) }.disabled(store.busy)
            .help("원래 폴더의 현재 상태를 기준으로 새 계획 만들기 · 기존 변경 유지")
        } else {
          Button("다시 시도") { Task { await store.operate("retry_operation", op: op) } }
            .disabled(store.busy || store.hasRunningOperation).help("완료된 저장소는 유지하고 실패 단계부터 재개")
        }
      } else if let op, expanded, op.isRunning {
        Button("준비 취소") { Task { await store.operate("cancel_operation", op: op) } }.disabled(
          store.busy)
      }
    }.controlSize(.regular).padding(.horizontal, 16).frame(height: 54)
      .background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
          .fill(expanded ? WorkbenchTheme.accent : (repo?.errorCode != nil ? Color.red : .clear))
          .frame(width: 3, height: 28)
      }
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(
          expanded ? .clear : WorkbenchTheme.line, lineWidth: 1))
  }
}

struct CurrentFolderContext: View {
  @ObservedObject var store: WorkbenchStore
  var body: some View {
    let isTask = store.selection?.opId != nil
    let pending = store.pendingWorktree
    let unavailable = store.taskInformationUnavailable
    let path =
      store.repository?.path
      ?? (isTask
        ? store.taskRepository?.plan.worktreePath
        : store.workspace?.repositories.first(where: { $0.id == store.selection?.repoId })?.path)
      ?? ""
    return HStack(spacing: 14) {
      Image(systemName: isTask ? "folder.badge.gearshape" : "folder")
        .font(.system(size: 17)).foregroundStyle(WorkbenchTheme.accent)
      VStack(alignment: .leading, spacing: 3) {
        Text(unavailable ? store.taskInformationTitle : pending ? store.pendingWorktreeTitle : isTask ? "현재 위치 · 이 작업용 폴더" : "현재 위치 · 원래 프로젝트 폴더")
          .font(.system(size: 13, weight: .semibold))
        Text(
          unavailable ? store.taskInformationHint : pending
            ? store.pendingWorktreeHint
            : isTask ? "이 작업을 위해 원래 프로젝트와 별도로 만든 폴더입니다." : "처음 열었던 프로젝트 폴더에서 변경 사항을 보고 있습니다."
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 8)
      Text(unavailable ? "위치 확인 필요" : pending ? "예정 위치 · " + path : path).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        .lineLimit(1).truncationMode(.middle).textSelection(.enabled).help(path)
        .frame(maxWidth: .infinity, alignment: .trailing)
      Button {
        store.openCurrentWorktree()
      } label: {
        Image(systemName: "arrow.up.forward.app")
      }
      .help("보고 있는 폴더를 Finder에서 열기").accessibilityLabel("현재 폴더를 Finder에서 보기").disabled(store.repository == nil)
    }.padding(.horizontal, 18).frame(height: 54).background(WorkbenchTheme.accent.opacity(0.035))
  }
}
