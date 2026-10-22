import SwiftUI
import Combine

@MainActor
public final class CommitDraft: ObservableObject {
  @Published public var message = "" {
    didSet { if oldValue != message { revision &+= 1 } }
  }
  public private(set) var revision: UInt64 = 0
}

struct CommitComposer: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var draft: CommitDraft
  var body: some View {
    let snapshot = store.repository?.snapshotHash
    let location = store.selection
    return VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("커밋 · \(store.selection?.repoId ?? "저장소")").font(.system(size: 14, weight: .semibold))
          .lineLimit(1)
        Spacer(minLength: 2)
        Text("\(store.stagedCount)개 파일").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      TextEditor(text: $draft.message).font(.system(size: 13)).scrollContentBackground(
        .hidden
      )
      .padding(7).frame(height: 78)
      .background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 7))
      .overlay(alignment: .topLeading) {
        if store.commitMessage.isEmpty {
          Text("무엇을 바꾸셨나요?").font(.system(size: 12)).foregroundStyle(.tertiary)
            .padding(12).allowsHitTesting(false)
        }
      }
      .overlay(RoundedRectangle(cornerRadius: 7).stroke(WorkbenchTheme.line, lineWidth: 1))
      .accessibilityLabel("커밋 메시지")
      Button {
        Task { await store.commit(expectedSnapshot: snapshot, at: location) }
      } label: {
        Text("\(store.selection?.repoId ?? "저장소")에 커밋").font(.system(size: 13, weight: .medium))
          .frame(maxWidth: .infinity)
      }.buttonStyle(PrimaryActionStyle()).controlSize(.large).keyboardShortcut(
        .return, modifiers: .command
      )
      .disabled(
        !store.canEdit || store.stagedCount == 0
          || store.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      if store.isViewingStash {
        Button("현재 변경으로 돌아가기", systemImage: "arrow.uturn.backward") { store.showWorkingChanges() }
          .font(.system(size: 12)).buttonStyle(.link)
      } else {
        Text(commitHint).font(.system(size: 11)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        if let count = store.repository?.files.filter({ $0.index == "?" }).count, count > 0 {
          Text("새 파일 \(count)개는 이 커밋에 포함되지 않습니다. Git에서 내용을 확인하고 추가해 주세요.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
    }
  }
  private var commitHint: String {
    if store.repository?.conflict == true { return "충돌 또는 진행 중인 Git 작업을 해결하세요." }
    if store.taskPreparationIncomplete { return store.preparationHint }
    if store.hasRunningOperation { return "다른 저장소의 준비 작업이 끝나면 커밋할 수 있습니다." }
    if store.taskContext.working { return "검사나 작업 기록 수집이 끝나면 커밋할 수 있습니다." }
    if store.stagedCount == 0 { return "검토한 변경을 스테이징하면 커밋할 수 있습니다." }
    return "선택한 저장소의 스테이징된 변경만 커밋합니다. 현재 버전은 hook·서명 없이 커밋합니다."
  }
}
