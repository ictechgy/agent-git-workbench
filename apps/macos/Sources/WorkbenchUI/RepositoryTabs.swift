import SwiftUI
import WorkbenchProtocol

struct RepositoryTabs: View {
  @ObservedObject var store: WorkbenchStore
  @State private var hoveredRepository: String?
  private var ids: [String] {
    store.contextOperation?.repos.map(\.id) ?? store.workspace?.repositories.map(\.id) ?? []
  }
  var body: some View {
    HStack(spacing: 12) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal) {
          HStack(spacing: 4) {
            ForEach(ids, id: \.self) { id in
              repositoryTab(id).id(id)
            }
          }
        }.scrollIndicators(.hidden)
          .onChange(of: store.selection?.repoId) { _, id in
            if let id { proxy.scrollTo(id) }
          }
      }.frame(minWidth: 150, maxWidth: .infinity)
      RepositoryBranchContext(store: store).frame(maxWidth: 210)
      CurrentFolderContext(store: store).frame(maxWidth: 350)
      RemoteControl(store: store)
      if let op = store.contextOperation {
        if op.canMaterialize && !op.requiresNewPlan {
          Button("워크트리 준비") { Task { await store.operate("materialize", op: op) } }
            .disabled(!store.preparationEligibility(for: op.id).materialize)
        } else if op.isRunning {
          Button("준비 취소") { Task { await store.operate("cancel_operation", op: op) } }
            .disabled(!store.preparationEligibility(for: op.id).cancel)
        }
      }
    }.font(.system(size: 12)).controlSize(.regular)
      .padding(.horizontal, 16).frame(height: 48)
      .background(WorkbenchTheme.panel)
      .overlay(alignment: .bottom) {
        Rectangle().fill(WorkbenchTheme.line).frame(height: 1).allowsHitTesting(false)
      }
  }

  private func repositoryTab(_ id: String) -> some View {
    let selected = store.selection?.repoId == id
    let op = store.contextOperation
    let repo = op?.repos.first { $0.id == id }
    return HStack(spacing: 6) {
      Button {
        store.selectRepository(id)
      } label: {
        HStack(spacing: 7) {
          Image(systemName: "externaldrive")
            .foregroundStyle(selected ? WorkbenchTheme.accentText : WorkbenchTheme.secondaryText)
          Text(id).font(.system(size: 13, weight: selected ? .semibold : .regular))
            .lineLimit(1).truncationMode(.middle).frame(maxWidth: 230)
          if let repo, repo.state != "ready" { StateBadge(state: repo.state) }
        }.padding(.vertical, 8).padding(.horizontal, 10).contentShape(Rectangle())
      }.buttonStyle(.plain).disabled(store.busy).help("\(id) 저장소 보기")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(repo.map { StatusText.label($0.state) } ?? "")
      if let op, op.canRetry,
        repo?.state != "ready" || op.repos.allSatisfy({ $0.state == "ready" }) {
        let eligibility = store.preparationEligibility(for: op.id)
        if op.requiresNewPlan {
          Button("새 작업 만들기") { store.beginRecovery(op) }
            .disabled(!eligibility.recovery).padding(.trailing, 8)
            .help("원래 폴더의 현재 상태를 기준으로 새 계획 만들기 · 기존 변경 유지")
        } else {
          Button("다시 시도") { Task { await store.operate("retry_operation", op: op) } }
            .disabled(!eligibility.retry).padding(.trailing, 8)
            .help("작업 전체의 실패 단계부터 재개 · 완료된 저장소는 유지")
            .accessibilityLabel("\(id) 준비 다시 시도 · 작업 전체 재개, 완료된 저장소는 유지")
        }
      }
    }.background(
      selected ? WorkbenchTheme.canvas : hoveredRepository == id ? WorkbenchTheme.chrome : .clear,
      in: RoundedRectangle(cornerRadius: 6))
      .onHover { inside in hoveredRepository = inside ? id : nil }
      .overlay(alignment: .bottom) {
        if selected { Rectangle().fill(WorkbenchTheme.accent).frame(height: 2).padding(.horizontal, 8) }
      }
  }
}
