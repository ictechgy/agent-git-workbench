import AppKit
import Combine
import SwiftUI
import WorkbenchProtocol

// Original repository identity stays stable when switching its Task worktrees.
struct BranchRepositoryIdentity: Equatable {
  let socket: String
  let workspace: String?
  let repository: String?
  let root: String?
  @MainActor init(_ store: WorkbenchStore) {
    socket = store.socketPath
    workspace = store.workspace?.id
    repository = store.selection?.repoId
    root = store.workspace?.repositories.first { $0.id == store.selection?.repoId }?.path
  }
}

struct BranchRefreshIdentity: Equatable {
  let repository: BranchRepositoryIdentity
  let location: WorktreeSelection?
  let head: String?
  let branch: String?
  let refs: [String]
  let graph: [HistoryCommit]
  let worktrees: String?
  @MainActor init(_ store: WorkbenchStore) {
    repository = BranchRepositoryIdentity(store)
    location = store.selection
    head = store.repository?.snapshot.head
    branch = store.repository?.snapshot.branch
    refs = store.repository?.refs ?? []
    graph = store.repository?.graph ?? []
    worktrees = store.repository?.worktrees
  }
}

@MainActor
public final class BranchBrowserModel: ObservableObject {
  @Published public private(set) var branches: [GitBranch] = []
  @Published public private(set) var selectedReference: String?
  @Published public private(set) var commits: [HistoryCommit] = []
  @Published public private(set) var loading = false
  @Published public private(set) var loadingHistory = false
  @Published private var listError: String?
  @Published private var historyError: String?
  public var error: String? { listError ?? historyError }
  @Published public var query = ""
  private var generation = UUID()
  private var historyGeneration = UUID()
  private var repositoryID: BranchRepositoryIdentity?
  private var listRequest: Task<[GitBranch], any Error>?
  private var historyRequest: Task<[HistoryCommit], any Error>?
  private var historyReference: String?
  private var historyTip: String?
  private var historyLocation: WorktreeSelection?
  public init() {}
  public var selectedBranch: GitBranch? { branches.first { $0.fullRef == selectedReference } }
  public var filteredBranches: [GitBranch] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    return branches.filter { needle.isEmpty || $0.name.localizedCaseInsensitiveContains(needle) }
  }
  // Branches outside the bounded graph can move without changing status. Read
  // lightweight branch metadata while mounted/active, preserving unchanged history.
  func observe(
    _ store: WorkbenchStore, interval: Duration = .seconds(3),
    isActive: @MainActor () -> Bool = { NSApplication.shared.isActive }
  ) async {
    await load(store)
    while store.selection != nil && !Task.isCancelled {
      do { try await Task.sleep(for: interval) } catch { return }
      guard store.selection != nil, !Task.isCancelled else { return }
      if isActive() && !store.showingWelcome && !store.taskInformationUnavailable { await load(store) }
    }
  }
  public func load(_ store: WorkbenchStore, retryHistory: Bool = false) async {
    listRequest?.cancel()
    let requestID = UUID()
    generation = requestID
    let identity = BranchRepositoryIdentity(store)
    let location = store.selection
    let sameRepository = repositoryID == identity
    repositoryID = identity
    if !sameRepository {
      clearHistory()
      branches = []; selectedReference = nil; listError = nil
    }
    if loading != branches.isEmpty { loading = branches.isEmpty }
    defer { if generation == requestID { if loading { loading = false }; listRequest = nil } }
    let request = Task { try await store.listBranches() }
    listRequest = request
    do {
      let values = try await withTaskCancellationHandler {
        try await request.value
      } onCancel: { request.cancel() }
      guard generation == requestID, identity == BranchRepositoryIdentity(store), location == store.selection else { return }
      if branches != values { branches = values }
      if loading { loading = false }
      if listError != nil { listError = nil }
      if let branch = values.first(where: { $0.fullRef == selectedReference })
        ?? values.first(where: \.current) ?? values.first
      {
        if retryHistory || historyReference != branch.fullRef || historyTip != branch.tipOid
          || (loadingHistory && historyLocation != location)
          || (commits.isEmpty && !loadingHistory && historyError == nil)
        {
          await select(branch, store: store)
        }
      } else {
        selectedReference = nil
        clearHistory()
      }
    } catch {
      guard generation == requestID, identity == BranchRepositoryIdentity(store), location == store.selection else { return }
      if error is CancellationError { return }
      listError = "브랜치 목록을 읽지 못했습니다. 새로고침해 주세요."
    }
  }
  private func clearHistory() {
    historyRequest?.cancel(); historyRequest = nil; historyGeneration = UUID()
    historyReference = nil; historyTip = nil; historyLocation = nil
    commits = []; loadingHistory = false; historyError = nil
  }
  public func select(_ branch: GitBranch, store: WorkbenchStore) async {
    let identity = BranchRepositoryIdentity(store)
    let location = store.selection
    guard repositoryID == identity else { return }
    historyRequest?.cancel()
    let requestID = UUID()
    historyGeneration = requestID
    historyReference = branch.fullRef; historyTip = branch.tipOid; historyLocation = location
    selectedReference = branch.fullRef
    commits = []; loadingHistory = true; historyError = nil
    defer { if historyGeneration == requestID { loadingHistory = false; historyRequest = nil } }
    let request = Task { try await store.branchHistory(branch) }
    historyRequest = request
    do {
      let values = try await withTaskCancellationHandler {
        try await request.value
      } onCancel: { request.cancel() }
      guard historyGeneration == requestID, identity == BranchRepositoryIdentity(store),
        location == store.selection, selectedReference == branch.fullRef,
        selectedBranch?.tipOid == branch.tipOid else { return }
      commits = values
    } catch {
      guard historyGeneration == requestID, identity == BranchRepositoryIdentity(store), location == store.selection else { return }
      if error is CancellationError { return }
      historyError = "브랜치 기록을 읽지 못했습니다. 브랜치가 외부에서 바뀌었을 수 있으니 새로고침해 주세요."
    }
  }
}

@MainActor
public struct BranchesView: View {
  @ObservedObject private var store: WorkbenchStore
  @StateObject private var model: BranchBrowserModel
  private let close: () -> Void
  @FocusState private var searchFocused: Bool
  public init(
    store: WorkbenchStore, model: BranchBrowserModel = BranchBrowserModel(),
    close: @escaping () -> Void = {}
  ) {
    self.store = store
    _model = StateObject(wrappedValue: model)
    self.close = close
  }
  public var body: some View {
    VStack(spacing: 0) {
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 16) { heading; Spacer(minLength: 8); headerActions }
        VStack(alignment: .leading, spacing: 10) {
          heading
          HStack { Spacer(minLength: 0); headerActions }
        }
      }.padding(16).background(WorkbenchTheme.panel)
      if let error = model.error {
        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12))
          .foregroundStyle(WorkbenchTheme.warning)
          .padding(.horizontal, 20).padding(.bottom, 14).frame(
            maxWidth: .infinity, alignment: .leading)
      }
      Divider()
      GeometryReader { geometry in
        if geometry.size.width < 560 {
          VSplitView {
            branchList.frame(minHeight: 90, idealHeight: 130, maxHeight: 180)
            branchHistory.frame(minHeight: 120)
          }
        } else {
          HSplitView {
            branchList.frame(minWidth: 190, idealWidth: 220, maxWidth: 260)
            branchHistory.frame(minWidth: 300, maxHeight: .infinity)
          }
        }
      }
    }.background(WorkbenchTheme.canvas).tint(WorkbenchTheme.accent)
      .task(id: refreshKey) { await model.observe(store) }
  }
  private var heading: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("\(store.selection?.repoId ?? "저장소") · 전체 브랜치")
        .font(.system(size: 16, weight: .semibold)).lineLimit(1)
        .help("\(store.selection?.repoId ?? "저장소") · 전체 브랜치")
      Text("브랜치를 선택해 커밋 기록과 연결된 폴더를 살펴보세요.")
        .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
    }
  }
  private var headerActions: some View {
    HStack(spacing: 8) {
      Button("새로고침", systemImage: "arrow.clockwise") { Task { await model.load(store, retryHistory: true) } }
        .disabled(model.loading)
      Button("닫기", action: close)
    }.fixedSize(horizontal: true, vertical: false)
  }
  private var branchList: some View {
    VStack(spacing: 0) {
      HStack {
        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        TextField("브랜치 검색", text: $model.query).textFieldStyle(.plain).focused($searchFocused)
        if !model.query.isEmpty {
          Button {
            model.query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }.buttonStyle(.plain)
            .accessibilityLabel("검색 지우기")
        }
      }.padding(12).background(WorkbenchTheme.elevated, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
          .strokeBorder(searchFocused ? WorkbenchTheme.accent : WorkbenchTheme.line,
                        lineWidth: searchFocused ? 2 : 1).allowsHitTesting(false))
        .padding(14)
      if model.loading {
        ProgressView("브랜치 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List(
          selection: Binding(
            get: { model.selectedReference },
            set: { reference in
              if let branch = model.branches.first(where: { $0.fullRef == reference }) {
                Task { await model.select(branch, store: store) }
              }
            })
        ) {
          let local = model.filteredBranches.filter { !$0.isRemote }
          let remote = model.filteredBranches.filter(\.isRemote)
          Section("로컬 브랜치 · \(local.count)") {
            ForEach(local) { branch in branchRow(branch).tag(branch.fullRef) }
          }
          Section("원격 브랜치 · \(remote.count)") {
            ForEach(remote) { branch in branchRow(branch).tag(branch.fullRef) }
          }
        }.listStyle(.sidebar).scrollContentBackground(.hidden)
          .overlay {
            if model.filteredBranches.isEmpty {
              Text(model.branches.isEmpty ? "아직 브랜치가 없습니다." : "검색과 일치하는 브랜치가 없습니다.")
                .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
            }
          }
      }
    }
    .background(WorkbenchTheme.sidebar)
  }
  private var refreshKey: BranchRefreshIdentity { BranchRefreshIdentity(store) }
  private func branchRow(_ branch: GitBranch) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: branch.isRemote ? "network" : "arrow.triangle.branch").foregroundStyle(
        .secondary
      ).padding(.top, 2)
      VStack(alignment: .leading, spacing: 5) {
        Text(branch.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(
          .middle)
        if branch.current {
          Label("보고 있는 폴더의 브랜치", systemImage: "checkmark.circle.fill").foregroundStyle(
            WorkbenchTheme.accentText)
        } else if !branch.worktreePath.isEmpty {
          let original = store.workspace?.repositories.first { $0.id == store.selection?.repoId }?.path
          Label(branch.worktreePath == original ? "원래 프로젝트 폴더에서 사용 중" : "다른 작업 폴더에서 사용 중", systemImage: "folder").foregroundStyle(.secondary)
        }
      }.font(.system(size: 11))
      Spacer(minLength: 0)
    }.padding(.vertical, 6).help(branch.fullRef)
  }
  private var branchHistory: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let branch = model.selectedBranch {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text(branch.name).font(.system(size: 17, weight: .semibold)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Text(branch.isRemote ? "원격" : "로컬").font(.system(size: 12)).foregroundStyle(.secondary)
          }
          Text("마지막 커밋 · \(branch.tipOid.prefix(10)) · \(branch.subject)")
            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(
              .enabled)
          if !branch.upstream.isEmpty {
            Label("연결된 브랜치 · \(branch.upstream)", systemImage: "arrow.left.arrow.right").font(
              .system(size: 12)
            ).foregroundStyle(.secondary)
          }
          if !branch.worktreePath.isEmpty {
            Label(branch.worktreePath, systemImage: "folder").font(
              .system(size: 11, design: .monospaced)
            )
            .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
          }
        }.padding(20)
        Divider()
        if model.loadingHistory {
          ProgressView("커밋 기록 불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
              GraphCanvas(commits: model.commits, rowHeight: 52).frame(
                width: 92, height: CGFloat(model.commits.count * 52))
              VStack(alignment: .leading, spacing: 0) {
                ForEach(model.commits) { commit in
                  VStack(alignment: .leading, spacing: 4) {
                    Text(commit.subject).font(.system(size: 13))
                      .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
                      .textSelection(.enabled)
                    HStack(spacing: 10) {
                      Text(String(commit.oid.prefix(8)))
                        .font(.system(size: 11, design: .monospaced)).fixedSize()
                      Text(commit.author).font(.system(size: 11)).lineLimit(1)
                    }.foregroundStyle(WorkbenchTheme.secondaryText)
                  }.frame(height: 52).padding(.trailing, 16).help(
                    commit.subject + "\n" + commit.oid + "\n" + commit.author)
                    .accessibilityElement(children: .combine)
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 12)
          }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        Divider()
        Text("선택한 브랜치의 최근 \(model.commits.count)개 커밋 · 최대 80개")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText).padding(14)
          .frame(maxWidth: .infinity, alignment: .leading).background(WorkbenchTheme.panel)
      } else {
        ContentUnavailableView("살펴볼 브랜치를 선택하세요", systemImage: "arrow.triangle.branch")
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.background(WorkbenchTheme.canvas)
  }
}
