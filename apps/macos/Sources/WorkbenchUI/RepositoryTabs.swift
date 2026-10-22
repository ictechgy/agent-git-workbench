import SwiftUI

struct RepositoryTabs: View {
  @ObservedObject var store: WorkbenchStore
  private var ids: [String] {
    store.contextOperation?.repos.map(\.id) ?? store.workspace?.repositories.map(\.id) ?? []
  }
  var body: some View {
    VStack(spacing: 0) {
      ScrollView(.horizontal) {
        HStack(spacing: 4) {
          ForEach(ids, id: \.self) { id in
            let selected = store.selection?.repoId == id
            let op = store.contextOperation
            let repo = op?.repos.first { $0.id == id }
            HStack(spacing: 9) {
              Button {
                store.select(.init(repoId: id, opId: op?.id))
              } label: {
                HStack(spacing: 9) {
                  Image(systemName: "externaldrive").foregroundStyle(.secondary)
                  Text(id).font(.system(size: 13, weight: selected ? .semibold : .regular))
                  if let repo { StateBadge(state: repo.state) }
                }.padding(.vertical, 8).padding(.leading, 12).padding(.trailing, 9)
                  .contentShape(Rectangle())
              }.buttonStyle(.plain).disabled(store.busy).help("\(id) 저장소 보기")
              if let op, op.canRetry,
                repo?.state != "ready" || op.repos.allSatisfy({ $0.state == "ready" }) {
                if op.requiresNewPlan {
                  Button("새 작업 만들기") { store.beginRecovery(op) }.disabled(store.busy).padding(.trailing, 10)
                } else {
                  Button("재시도") { Task { await store.operate("retry_operation", op: op) } }
                    .disabled(store.busy || store.hasRunningOperation).padding(.trailing, 10)
                }
              }
            }.background(selected ? WorkbenchTheme.canvas : .clear)
              .overlay(alignment: .bottom) {
                if selected { Rectangle().fill(WorkbenchTheme.accent).frame(height: 2) }
              }
          }
        }.padding(.horizontal, 14)
      }.frame(height: 46)
      HStack(spacing: 14) {
        Text(store.selection?.repoId ?? "저장소").font(.system(size: 13, weight: .semibold))
        if let op = store.contextOperation, let repoID = store.selection?.repoId {
          Picker(
            "현재 위치",
            selection: Binding(
              get: { store.selection?.opId != nil },
              set: { store.select(.init(repoId: repoID, opId: $0 ? op.id : nil)) }
            )
          ) {
            Text("이 작업용 폴더").tag(true)
            Text("원래 프로젝트 폴더").tag(false)
          }.pickerStyle(.segmented).labelsHidden().frame(width: 286).disabled(store.busy)
          Spacer()
          if op.canMaterialize && !op.requiresNewPlan {
            Button("워크트리 준비") { Task { await store.operate("materialize", op: op) } }
              .disabled(store.busy || store.hasRunningOperation)
          } else if op.isRunning {
            Button("준비 취소") { Task { await store.operate("cancel_operation", op: op) } }
              .disabled(store.busy)
          }
        } else {
          Spacer()
        }
      }.padding(.horizontal, 18).frame(height: 44)
      CurrentFolderContext(store: store)
      Divider()
    }.background(WorkbenchTheme.sidebar)
  }
}
