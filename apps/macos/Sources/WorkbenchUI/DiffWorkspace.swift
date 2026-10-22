import SwiftUI
import WorkbenchProtocol

struct DiffWorkspace: View {
  @ObservedObject var store: WorkbenchStore
  @State private var onlyChangedHunks = false
  @State private var showPreviousReading = false
  @State private var request: HunkRequest?
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(systemName: "doc.text").foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 4) {
          Text(
            store.selectedFile.isEmpty
              ? "코드 변경" : (store.selectedFile as NSString).lastPathComponent
          )
          .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
          Text(
            store.isViewingStash
              ? "\(store.selectedStash?.selector ?? "Stash") · 저장된 변경 · 읽기 전용"
              : store.taskPreparationIncomplete
                ? store.preparationHint
                : store.staged ? "스테이징한 변경 · 커밋할 내용" : "현재 폴더의 변경 · 검토 후 스테이징"
          )
          .font(.system(size: 11)).foregroundStyle(.secondary)
        }.help(store.selectedFile)
        Spacer()
        Picker("Diff 표시", selection: $store.splitDiff) {
          Text("나란히").tag(true)
          Text("한 화면").tag(false)
        }.labelsHidden().pickerStyle(.segmented).frame(width: 134).font(.system(size: 11))
      }.padding(.horizontal, 18).frame(height: 60)
      Divider()
      if store.selectionCheckFailed && store.repository != nil && store.diff != nil && !store.isViewingStash {
        HStack {
          Label("최신 상태 확인 실패 · 마지막 화면을 읽기 전용으로 표시합니다", systemImage: "exclamationmark.triangle")
          Spacer()
          Button("새로고침") { Task { await store.refresh() } }
        }.font(.system(size: 11)).padding(10).background(Color.orange.opacity(0.10))
          .accessibilityIdentifier("workbench.validation-failure")
        Divider()
      }
      if let warning = store.diff?.encodingWarning {
        Label(warning, systemImage: "exclamationmark.triangle").font(.system(size: 12))
          .foregroundStyle(.orange).padding(12).frame(maxWidth: .infinity, alignment: .leading)
        Divider()
      }
      if store.selectionCheckFailed && (store.repository == nil || store.diff == nil) && !store.isViewingStash {
        ContentUnavailableView {
          Label("현재 변경을 확인하지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: { Text("파일 상태를 확인한 뒤 편집할 수 있습니다.") } actions: {
          Button("새로고침") { Task { await store.refresh() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if store.pendingWorktree && !store.isViewingStash {
        ContentUnavailableView(
          store.pendingWorktreeTitle, systemImage: "externaldrive.badge.plus",
          description: Text(store.pendingWorktreeHint)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let failure = store.diffError {
        ContentUnavailableView {
          Label("변경 내용을 읽지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: { Text(failure) } actions: {
          Button("다시 시도") { Task { await store.retryDiff() } }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff = store.diff, diff.displayLimitExceeded {
        ContentUnavailableView("이 변경은 Git에서 확인해 주세요", systemImage: "doc.text.magnifyingglass",
          description: Text("5,000줄 또는 512 KiB를 넘는 변경은 앱에서 펼치지 않습니다. 파일을 나누어 검토하거나 Git에서 전체 변경을 확인해 주세요."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff = store.diff, !diff.hunks.isEmpty {
        let renderedLocation = store.selection
        if !store.isViewingStash { readingToolbar(diff) }
        let changed = store.changedReadingHunks
        GeometryReader { geometry in
          ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
              if onlyChangedHunks && changed.isEmpty {
                ContentUnavailableView(
                  "새로 달라진 변경 묶음이 없습니다", systemImage: "checkmark.rectangle",
                  description: Text(store.removedReadingHunks > 0
                    ? "이전 검토의 일부 변경 묶음이 사라졌습니다. ‘이전 검토’와 전체 변경을 함께 확인하세요."
                    : "전체 변경을 다시 확인하려면 ‘달라진 변경’을 끄세요."))
                  .padding(20)
              }
              ForEach(diff.parsedHunks.filter { !onlyChangedHunks || changed.contains($0.id) }) { hunk in
                HunkView(
                  hunk: hunk, split: store.splitDiff, staged: diff.staged,
                  availableWidth: geometry.size.width,
                  canStage: store.canEdit && store.canUseRenderedDiff && diff.canStageHunks,
                  readOnly: store.isViewingStash,
                  changedSinceReading: store.readingCheckpoint != nil && changed.contains(hunk.id),
                  canRequest: store.canUseRenderedDiff
                    && diff.header.utf8.count + diff.hunks[hunk.id].utf8.count <= 128 * 1024,
                  request: {
                    if let renderedLocation {
                      request = store.hunkRequest(hunk.id, from: diff, at: renderedLocation)
                    }
                  }
                ) {
                  if let selection = renderedLocation {
                    Task { await store.stageHunk(hunk.id, from: diff, at: selection) }
                  }
                }
              }
            }.frame(width: geometry.size.width, alignment: .topLeading)
              .background {
                if let id = store.currentReviewID {
                  ReviewScrollPosition(store: store, id: id, content: diff.contentIdentity,
                    enabled: !onlyChangedHunks).frame(width: 0, height: 0)
                }
              }
          }
        }
      } else if store.selectedFile.isEmpty {
        ContentUnavailableView(
          store.isViewingStash ? "Stash의 파일을 선택하세요" : "검토할 변경이 없습니다",
          systemImage: store.isViewingStash ? "archivebox" : "checkmark.circle",
          description: Text(
            store.isViewingStash
              ? (store.stashError ?? "왼쪽 파일 목록에서 저장된 변경을 확인하세요.")
              : store.staged
                ? "왼쪽 ‘변경’에서 파일을 검토한 뒤 원하는 변경을 스테이징하세요." : "파일이 변경되면 왼쪽 목록에서 선택해 검토할 수 있습니다.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let diff = store.diff {
        ContentUnavailableView(
          "표시할 텍스트 변경이 없습니다", systemImage: "doc.text.magnifyingglass",
          description: Text(
            store.isViewingStash
              ? "표시할 텍스트 변경이 없습니다. 파일 종류나 실행 권한 변경을 확인하세요."
              : "기존 텍스트 파일의 변경을 검토할 수 있습니다. 새 파일·바이너리·실행 권한 변경은 Git에서 확인해 주세요.")
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
          if !diff.text.isEmpty {
            Text(diff.text).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
              .padding(20)
          }
        }
      } else {
        ProgressView("Diff를 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(WorkbenchTheme.canvas)
      .onChange(of: store.currentReviewID) { _, _ in onlyChangedHunks = false }
      .sheet(item: $request) { HunkRequestSheet(request: $0) }
      .sheet(isPresented: $showPreviousReading) {
        if let checkpoint = store.readingCheckpoint {
          VStack(alignment: .leading, spacing: 14) {
            Text("이전 검토 당시의 변경").font(.headline)
            Text(checkpoint.date, format: .dateTime.month().day().hour().minute())
              .font(.caption).foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
              Text(checkpoint.text).font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled).padding(12)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack { Text("읽기 전용 · 이 기록으로 staging하지 않습니다.").font(.caption)
              Spacer(); Button("닫기") { showPreviousReading = false }.keyboardShortcut(.cancelAction) }
          }.padding(20).frame(width: 700, height: 520)
        }
      }
  }

  @ViewBuilder private func readingToolbar(_ diff: FileDiff) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Label(store.selectionCheckFailed ? "변경 확인 실패" : store.currentReadingState.label,
          systemImage: store.currentReadingState == .reviewed ? "checkmark.circle.fill" : "eye")
          .font(.system(size: 11)).foregroundStyle(.secondary)
          .help("현재 작업공간 세션의 개인 읽기 기록입니다. 테스트 통과나 병합 승인이 아닙니다.")
        Spacer(minLength: 0)
        if let checkpoint = store.readingCheckpoint {
          Button("이전 검토") { showPreviousReading = true }.font(.system(size: 11))
          if checkpoint.contentIdentity != diff.contentIdentity {
            Button(onlyChangedHunks ? "전체 변경" : "달라진 변경") { onlyChangedHunks.toggle() }
              .font(.system(size: 11))
              .help("이전 검토와 정확히 다른 hunk를 표시합니다. 줄 위치나 문맥 변경도 포함할 수 있습니다.")
          }
        }
        Button(store.currentReadingState == .reviewed ? "검토 표시 해제" : "파일 검토함") {
          if store.currentReadingState == .reviewed { store.clearCurrentReadingCheckpoint() }
          else { store.markCurrentFileRead() }
          onlyChangedHunks = false
        }.font(.system(size: 11)).disabled(!store.canMarkRead)
          .help("이 파일의 현재 변경을 읽었다고 표시합니다. 큰 diff(512 KiB 초과)는 기록하지 않습니다.")
      }
      if store.currentReadingState == .needsReview, let checkpoint = store.readingCheckpoint {
        Text(checkpoint.contentIdentity == diff.contentIdentity
          ? "브랜치·HEAD 또는 스테이징 기준이 바뀌었습니다. 전체 변경을 다시 확인하세요."
          : "검토 이후 달라진 hunk \(store.changedReadingHunks.count)개 · 이전 hunk \(store.removedReadingHunks)개가 사라지거나 교체됨")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }.padding(.horizontal, 16).padding(.vertical, 10)
    Divider()
  }
}

private struct HunkView: View {
  let hunk: ParsedHunk
  let split: Bool
  let staged: Bool
  let availableWidth: CGFloat
  let canStage: Bool
  let readOnly: Bool
  let changedSinceReading: Bool
  let canRequest: Bool
  let request: () -> Void
  let stage: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("변경 \(hunk.id + 1)").font(.system(size: 12, weight: .medium)).help(hunk.header)
        if changedSinceReading {
          Text("검토 후 변경").font(.system(size: 10)).foregroundStyle(.secondary)
        }
        Spacer()
        if readOnly {
          Label("Stash · 읽기 전용", systemImage: "archivebox").font(.system(size: 12)).foregroundStyle(
            .secondary)
        } else {
          Button("수정 요청", action: request).font(.system(size: 11))
            .disabled(!canRequest).help("선택한 변경을 담은 AI용 요청문 만들기 · 128 KiB 이내")
          Button(staged ? "스테이징 취소" : "이 변경 스테이징", action: stage)
            .buttonStyle(PrimaryActionStyle(compact: true)).controlSize(.regular).font(
              .system(size: 12)
            ).disabled(
              !canStage)
        }
      }.padding(.horizontal, 18).frame(height: 42).background(WorkbenchTheme.panel.opacity(0.6))
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          if split {
            HStack {
              Text(staged ? "마지막 커밋" : "이전 내용").frame(maxWidth: .infinity, alignment: .leading)
              Text(staged ? "커밋할 내용" : "변경 후").frame(maxWidth: .infinity, alignment: .leading)
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 24).frame(
              height: 28)
            ForEach(hunk.split) { row in
              HStack(spacing: 0) {
                CodeCell(cell: row.before).frame(
                  minWidth: 280, maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(WorkbenchTheme.line).frame(width: 0.5)
                CodeCell(cell: row.after).frame(
                  minWidth: 280, maxWidth: .infinity, alignment: .leading)
              }.fixedSize(horizontal: false, vertical: true)
            }
          } else {
            ForEach(hunk.unified) { row in
              HStack(spacing: 0) {
                Text(row.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
                Text(row.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
                  .padding(.trailing, 14)
                Text(
                  (row.kind == .addition ? "+ " : row.kind == .deletion ? "− " : "  ") + visibleLineEnd(row.text)
                )
                .foregroundStyle(.primary).textSelection(.enabled).frame(
                  maxWidth: .infinity, alignment: .leading)
              }.font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary).frame(
                minHeight: 28
              )
              .background(lineBackground(row.kind))
            }
          }
        }.frame(minWidth: max(560, availableWidth), maxWidth: .infinity)
      }.frame(height: CGFloat(split ? hunk.split.count * 28 + 28 : hunk.unified.count * 28) + 12)
      Divider()
    }
  }
}
private struct CodeCell: View {
  let cell: DiffCell?
  var body: some View {
    HStack(spacing: 12) {
      Text(cell?.number.map(String.init) ?? "").foregroundStyle(.tertiary).frame(
        width: 30, alignment: .trailing)
      Text(visibleLineEnd(cell?.text ?? " ")).textSelection(.enabled).fixedSize(horizontal: true, vertical: false)
      if cell?.noNewline == true {
        Text("개행 없음").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Spacer(minLength: 10)
    }.font(.system(size: 13, design: .monospaced)).frame(minHeight: 28).padding(.horizontal, 6)
      .background(lineBackground(cell?.kind ?? .context))
      .accessibilityLabel(
        cell.map {
          "\($0.kind == .addition ? "추가" : $0.kind == .deletion ? "삭제" : "") \($0.number.map(String.init) ?? "") \($0.text)"
        } ?? "빈 행")
  }
}
private func visibleLineEnd(_ text: String) -> String {
  text.hasSuffix("\r") ? String(text.dropLast()) + " ␍" : text
}
private func lineBackground(_ kind: LineKind) -> Color {
  switch kind {
  case .addition: Color.green.opacity(0.10)
  case .deletion: Color.red.opacity(0.09)
  default: .clear
  }
}
