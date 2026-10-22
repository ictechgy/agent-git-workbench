import SwiftUI
import WorkbenchProtocol

struct WorkspaceSidebar: View {
  @ObservedObject var store: WorkbenchStore
  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(store.isViewingStash ? "Stash의 파일" : "변경 파일")
          Spacer()
          Text(store.onlyUnreviewedFiles && !store.isViewingStash
            ? "\(store.displayedFiles.count)/\(store.visibleFiles.count)" : "\(store.visibleFiles.count)")
            .foregroundStyle(.secondary).monospacedDigit()
        }.font(.system(size: 13, weight: .semibold))
        if store.isViewingStash {
          Button("현재 변경으로 돌아가기", systemImage: "arrow.uturn.backward") { store.showWorkingChanges() }
            .font(.system(size: 12)).buttonStyle(.link)
        } else {
          Picker(
            "변경 파일 영역", selection: Binding(get: { store.staged }, set: { store.chooseStaged($0) })
          ) {
            Text("변경 \(store.repository?.files.filter(\.isWorking).count ?? 0)").tag(false)
            Text("스테이징 \(store.stagedCount)").tag(true)
          }.pickerStyle(.segmented).labelsHidden().font(.system(size: 12))
          Toggle("미검토·다시 검토만", isOn: $store.onlyUnreviewedFiles)
            .toggleStyle(.checkbox).font(.system(size: 11))
            .help("이 작업공간 세션에서 표시한 읽기 기록입니다. 테스트나 병합 승인을 뜻하지 않습니다.")
        }
      }.padding(16)
      if store.displayedFiles.isEmpty {
        Text(store.onlyUnreviewedFiles && !store.visibleFiles.isEmpty && !store.isViewingStash
          ? "현재 변경을 모두 검토했습니다. 필터를 끄면 전체 파일이 표시됩니다." : emptyMessage)
          .font(.system(size: 12)).foregroundStyle(.secondary)
          .padding(.horizontal, 16).frame(maxWidth: .infinity, alignment: .leading)
        Spacer()
      } else {
        ScrollView {
          LazyVStack(spacing: 3) {
            ForEach(store.displayedFiles) { file in fileRow(file) }
          }.padding(.horizontal, 8).padding(.bottom, 12)
        }
      }
      Divider()
      HStack(spacing: 7) {
        Image(systemName: store.isViewingStash ? "archivebox" : "folder").foregroundStyle(
          .secondary)
        Text(
          store.isViewingStash
            ? "저장된 변경 · 읽기 전용" : (store.selection?.opId == nil ? "원래 프로젝트 폴더" : "이 작업용 폴더")
        )
        .font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
      }.padding(14)
    }.background(WorkbenchTheme.canvas)
  }
  private var emptyMessage: String {
    if store.isViewingStash {
      return store.stashError
        ?? (store.stashDetail == nil ? "Stash 파일을 불러오는 중…" : "저장된 파일 변경이 없습니다.")
    }
    if store.pendingWorktree { return store.pendingWorktreeHint }
    if store.selectionCheckFailed { return "파일 목록을 확인하지 못했습니다. 새로고침으로 다시 확인해 주세요." }
    if store.repository == nil { return "파일 목록을 불러오는 중…" }
    return store.staged ? "스테이징한 파일이 없습니다." : "작업 폴더에 변경이 없습니다."
  }
  private func fileRow(_ file: FileChange) -> some View {
    let selected = file.path == store.selectedFile
    let path = file.path as NSString
    let parent = path.deletingLastPathComponent
    let marker =
      file.index == "?" ? "?" : (store.staged && !store.isViewingStash ? file.index : file.worktree)
    let color: Color = marker == "D" ? .red : (marker == "A" || marker == "?" ? .green : .orange)
    return Button {
      store.chooseFile(file.path)
    } label: {
      HStack(alignment: .top, spacing: 9) {
        Text(marker).font(.system(size: 12, weight: .semibold, design: .monospaced))
          .foregroundStyle(color).frame(width: 15)
        VStack(alignment: .leading, spacing: 4) {
          Text(path.lastPathComponent).font(
            .system(size: 13, weight: selected ? .medium : .regular)
          )
          .lineLimit(1).truncationMode(.middle)
          if !parent.isEmpty && parent != "." {
            Text(parent).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
              .truncationMode(.middle)
          }
        }.frame(maxWidth: .infinity, alignment: .leading)
        if !store.isViewingStash {
          let review = store.reviewState(for: file)
          if review != .unread {
            Image(systemName: review == .reviewed ? "checkmark.circle.fill" : review == .checking ? "clock" : "arrow.clockwise.circle")
              .font(.system(size: 11)).foregroundStyle(review == .reviewed ? Color.green : Color.secondary)
              .help(review.label).accessibilityLabel(review.label)
          }
        }
      }.padding(10).contentShape(Rectangle())
    }.buttonStyle(.plain)
      .background(
        selected ? WorkbenchTheme.accent.opacity(0.12) : .clear,
        in: RoundedRectangle(cornerRadius: 7)
      )
      .help(file.path).accessibilityLabel(
        "\(file.path), \(store.isViewingStash ? "stash의 변경" : store.staged ? "스테이징됨" : "변경됨"), \(store.isViewingStash ? "읽기 전용" : store.reviewState(for: file).label)")
  }
}
