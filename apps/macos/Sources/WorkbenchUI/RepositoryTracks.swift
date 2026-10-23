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
            .foregroundStyle(expanded ? WorkbenchTheme.accentText : WorkbenchTheme.secondaryText)
          Text(id).font(.system(size: 13, weight: .semibold)).lineLimit(1)
          if let repo, repo.state != "ready" { StateBadge(state: repo.state) }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(store.busy).help("\(id) 저장소 펼치기")
        .accessibilityValue(repo.map { StatusText.label($0.state) } ?? "")
      if expanded {
        Spacer(minLength: 4)
        RepositoryBranchContext(store: store).frame(maxWidth: 210)
        CurrentFolderContext(store: store).frame(maxWidth: 350)
      RemoteControl(store: store)
      } else {
        Text(repo?.errorCode == nil ? "" : "준비를 완료하지 못했습니다.")
          .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 4)
      }
      if let op, expanded, op.canMaterialize && !op.requiresNewPlan {
        Button("워크트리 준비") { Task { await store.operate("materialize", op: op) } }.disabled(
          !store.preparationEligibility(for: op.id).materialize)
      }
      if let op, op.canRetry,
        repo?.state != "ready" || op.repos.allSatisfy({ $0.state == "ready" }) {
        if op.requiresNewPlan {
          Button("새 작업 만들기") { store.beginRecovery(op) }.disabled(!store.preparationEligibility(for: op.id).recovery)
            .help("원래 폴더의 현재 상태를 기준으로 새 계획 만들기 · 기존 변경 유지")
        } else {
          Button("다시 시도") { Task { await store.operate("retry_operation", op: op) } }
            .disabled(!store.preparationEligibility(for: op.id).retry)
            .help("작업 전체의 실패 단계부터 재개 · 완료된 저장소는 유지")
            .accessibilityLabel("\(id) 준비 다시 시도 · 작업 전체 재개, 완료된 저장소는 유지")
        }
      } else if let op, expanded, op.isRunning {
        Button("준비 취소") { Task { await store.operate("cancel_operation", op: op) } }.disabled(
          !store.preparationEligibility(for: op.id).cancel)
      }
    }.controlSize(.regular).padding(.horizontal, 16).frame(height: 54)
      .background(expanded ? WorkbenchTheme.canvas : WorkbenchTheme.sidebar, in: RoundedRectangle(cornerRadius: 10))
      .overlay(alignment: .leading) {
        RoundedRectangle(cornerRadius: 2)
          .fill(expanded ? WorkbenchTheme.accent : (repo?.errorCode != nil ? WorkbenchTheme.danger : .clear))
          .frame(width: 3, height: 28)
      }
      .overlay(
        RoundedRectangle(cornerRadius: 10).stroke(
          WorkbenchTheme.line, lineWidth: 1))
  }
}
