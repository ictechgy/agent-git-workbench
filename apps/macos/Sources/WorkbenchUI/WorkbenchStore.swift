import AppKit
import Combine
import Foundation
import WorkbenchProtocol
import WorkbenchRuntime

public struct WorktreeSelection: Hashable, Sendable {
  public let repoId: String
  public let opId: String?
  public init(repoId: String, opId: String? = nil) {
    self.repoId = repoId
    self.opId = opId
  }
}

public struct WorkspaceTaskPlan: Sendable {
  public let details: TaskPlan
  fileprivate let session: UUID
  fileprivate let socket: String
}

public struct TaskSubmissionWarning: Identifiable, Equatable {
  public let id: String
  public let workspaceTitle: String
  public let workspacePath: String
  public let message: String
}

public struct PreparationEligibility {
  public let materialize: Bool
  public let retry: Bool
  public let recovery: Bool
  public let cancel: Bool
}

@MainActor
public final class WorkbenchStore: ObservableObject {
  @Published public var socketPath: String
  @Published public private(set) var workspace: WorkspaceInfo?
  @Published public private(set) var workspaceSession = UUID()
  @Published public private(set) var planSession = UUID()
  @Published public private(set) var submissionWarnings: [TaskSubmissionWarning] = []
  @Published public private(set) var operations: [WorkbenchOperation] = []
  @Published public private(set) var tasks: [String: TaskDetail] = [:]
  @Published public private(set) var selection: WorktreeSelection?
  @Published public private(set) var repository: RepositoryStatus?
  @Published public private(set) var diff: FileDiff?
  @Published public private(set) var diffError: String?
  @Published public private(set) var selectionCheckFailed = false
  private struct DiffReadID: Equatable {
    let location: WorktreeSelection
    let path: String
    let staged: Bool
    let stash: String?
    let snapshot: String?
  }
  private var failedDiffRead: DiffReadID?
  private var lastRefreshFailure: String?
  private var lastMetadataFailure: String?
  @Published private var contextWorking = false
  private var contextWorkObserver: AnyCancellable?
  @Published public private(set) var stashes: [GitStash] = []
  @Published public private(set) var selectedStashOID: String?
  @Published public private(set) var stashDetail: StashDetail?
  @Published public private(set) var stashError: String?
  @Published public private(set) var stashFocusRequest = 0
  @Published public private(set) var events: [OperationEvent] = []
  @Published public private(set) var busy = false
  @Published public var error: String?
  @Published public private(set) var errorDetails: String?
  @Published public private(set) var recentWorkspaces: [RecentWorkspace] = []
  @Published public var showingWelcome = true
  @Published public private(set) var startupMessage: String?
  @Published public var selectedFile = ""
  @Published public var staged = false
  @Published public var splitDiff = true
  @Published public var historyTab = "history"
  public let commitDraft = CommitDraft()
  public var commitMessage: String { get { commitDraft.message } set { commitDraft.message = newValue } }
  @Published public var showTaskSheet = false
  public var recoveryTaskID: String?
  @Published public var showBranches = false
  public private(set) var lastUpdated: Date?
  @Published public private(set) var validatingSelection = false
  @Published public var onlyUnreviewedFiles = false
  private var readingSession = ReviewSession()
  public let taskContext = TaskContextStore()

  private func reviewID(path: String, staged: Bool) -> ReviewFileID? {
    selection.map { ReviewFileID(location: $0, path: path, staged: staged, stashOID: selectedStashOID) }
  }
  var currentReviewID: ReviewFileID? { reviewID(path: selectedFile, staged: staged) }
  public var displayedFiles: [FileChange] {
    guard onlyUnreviewedFiles, !isViewingStash else { return visibleFiles }
    return visibleFiles.filter { reviewState(for: $0) != .reviewed }
  }
  public func reviewState(for file: FileChange) -> FileReviewState {
    guard !isViewingStash, let id = reviewID(path: file.path, staged: staged) else { return .unread }
    if validatingSelection { return .checking }
    let state = readingSession.state(for: id, key: file.reviewKey ?? repository?.snapshotHash ?? "")
    if state == .reviewed, file.path == selectedFile, let diff,
      diff.snapshotHash == repository?.snapshotHash,
      let checkpoint = readingSession.checkpoints[id], checkpoint.contentIdentity != diff.contentIdentity
    { return .needsReview }
    return state
  }
  public var readingCheckpoint: ReadingCheckpoint? {
    guard !isViewingStash, let id = currentReviewID else { return nil }
    return readingSession.checkpoints[id]
  }
  public var currentReadingState: FileReviewState {
    guard let file = visibleFiles.first(where: { $0.path == selectedFile }) else { return .unread }
    return reviewState(for: file)
  }
  public var canUseRenderedDiff: Bool {
    guard !isViewingStash, !busy, !validatingSelection, let diff, let repository else { return false }
    return diff.path == selectedFile && diff.staged == staged && !diff.hunks.isEmpty
      && diff.encodingWarning == nil && !diff.displayLimitExceeded
      && diff.snapshotHash == repository.snapshotHash
  }
  public var canMarkRead: Bool {
    guard canUseRenderedDiff, let diff else { return false }
    return diff.text.utf8.count + diff.hunks.reduce(0, { $0 + $1.utf8.count }) <= ReviewSession.maximumCheckpointBytes
  }
  public func markCurrentFileRead() {
    guard canMarkRead, let diff, let id = currentReviewID else { return }
    objectWillChange.send()
    _ = readingSession.mark(diff, at: id)
  }
  public func clearCurrentReadingCheckpoint() {
    guard let id = currentReviewID else { return }
    objectWillChange.send()
    readingSession.unmark(id)
  }
  public var changedReadingHunks: Set<Int> {
    guard let diff, let id = currentReviewID else { return [] }
    return readingSession.changedHunks(in: diff, at: id)
  }
  public var removedReadingHunks: Int {
    guard let diff, let id = currentReviewID else { return 0 }
    return readingSession.removedHunkCount(in: diff, at: id)
  }
  func rememberReviewOffset(_ y: Double, content: String, at id: ReviewFileID) {
    readingSession.rememberOffset(y, content: content, at: id)
  }
  func reviewOffset(content: String, at id: ReviewFileID) -> Double {
    readingSession.offset(content: content, at: id)
  }
  public var currentReviewScrollOffset: Double {
    guard let diff, let id = currentReviewID else { return 0 }
    return reviewOffset(content: diff.contentIdentity, at: id)
  }
  func hunkRequest(_ index: Int, from rendered: FileDiff, at location: WorktreeSelection) -> HunkRequest? {
    guard canUseRenderedDiff, let selection, let repository,
      location == selection, rendered.path == selectedFile, rendered.staged == staged,
      rendered.contentIdentity == diff?.contentIdentity, rendered.snapshotHash == repository.snapshotHash,
      rendered.hunks.indices.contains(index)
    else { return nil }
    let patch = rendered.header + rendered.hunks[index]
    guard patch.utf8.count <= 128 * 1024 else { return nil }
    return HunkRequest(
      repository: selection.repoId, folder: repository.path, task: taskTitle,
      branch: repository.snapshot.branch, head: repository.snapshot.head, path: rendered.path,
      staged: rendered.staged, snapshot: rendered.snapshotHash, patch: patch)
  }
  public func hunkRequestText(_ index: Int, instruction: String) -> String? {
    guard let diff, let selection else { return nil }
    return hunkRequest(index, from: diff, at: selection)?.text(instruction: instruction)
  }

  private var client: ServiceClient?
  private var generation = UUID()
  private var diffGeneration = UUID()
  private var diffRequest: Task<FileDiff, any Error>?
  private var refreshing = false
  private var eventCursor = 0
  private let runtime: WorkspaceRuntime
  private var currentWorkspace: RecentWorkspace?
  private var connectedSocketPath: String?
  private var didStart = false
  @Published private var contextOperationID: String?
  // The recent list is paginated. Keep only the selected/context summaries
  // separately so an older Task retains its identity without growing that list.
  @Published private var pinnedOperations: [String: WorkbenchOperation] = [:]
  @Published private var unresolvedOperationIDs: Set<String> = []
  private var activeContextOperationID: String? { selection?.opId ?? contextOperationID }
  private var activeOperationIDs: Set<String> {
    Set([selection?.opId, activeContextOperationID].compactMap { $0 })
  }
  private struct LocationDraft {
    let selectedFile: String
    let staged: Bool
    let commitMessage: String
  }
  private struct CachedLocation {
    let repository: RepositoryStatus?
    let diff: FileDiff?
    let stashes: [GitStash]
    let selectedStashOID: String?
    let stashDetail: StashDetail?
    let lastUpdated: Date?
  }
  // Keep review data for six recent folders. Small drafts survive review-cache eviction.
  private var locationDrafts: [WorktreeSelection: LocationDraft] = [:]
  private var workspaceDrafts: [String: [WorktreeSelection: LocationDraft]] = [:]
  private var workspaceSelections: [String: WorktreeSelection] = [:]
  private var workspaceContexts: [String: String] = [:]
  private var restoredWorkspaceSelection = false
  private var locationCache: [WorktreeSelection: CachedLocation] = [:]
  private var cacheOrder: [WorktreeSelection] = []

  public init(
    socketPath: String = ProcessInfo.processInfo.environment["WORKBENCH_SOCKET"] ?? "",
    runtime: WorkspaceRuntime = WorkspaceRuntime()
  ) {
    self.socketPath = socketPath
    self.runtime = runtime
    contextWorkObserver = taskContext.$working.removeDuplicates().dropFirst().sink { [weak self] in self?.contextWorking = $0 }
  }
  public var canReconnect: Bool { currentWorkspace != nil || !socketPath.isEmpty }
  public var workspaceTitle: String { currentWorkspace?.name ?? workspace?.id ?? "작업공간" }
  public func startup() async {
    guard !didStart else { return }
    didStart = true
    do { recentWorkspaces = try await runtime.recentWorkspaces() } catch { report(error) }
    // Explicit development injection is optional; Finder launches need no environment setup.
    if !socketPath.isEmpty { await connect() }
  }
  public func chooseRepository() {
    guard !busy else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "저장소 열기"
    panel.message = "Git으로 관리하는 프로젝트 폴더를 선택하세요."
    panel.begin { [weak self] response in
      guard response == .OK, let url = panel.url else { return }
      Task { @MainActor in await self?.openRepository(url) }
    }
  }
  public func openRepository(_ url: URL) async {
    await openWorkspace(message: "저장소 여는 중…") { try await self.runtime.openRepository(url) }
  }
  public func openExample() async {
    await openWorkspace(message: "예제 준비 중…") { try await self.runtime.openExample() }
  }
  public func openRecent(_ recent: RecentWorkspace) async {
    await openWorkspace(message: "\(recent.name) 여는 중…") {
      try await self.runtime.openRecent(recent)
    }
  }
  public func reconnect() async {
    if let currentWorkspace { await openRecent(currentWorkspace) } else { await connect() }
  }
  public func stopIdleServices() async { await runtime.stopIdleServices() }
  func openWorkspace(message: String, work: () async throws -> WorkspaceSession) async {
    guard !busy else { return }
    busy = true
    startupMessage = message
    error = nil
    errorDetails = nil
    defer {
      busy = false
      startupMessage = nil
    }
    do {
      let session = try await work()
      let returningToSameWorkspace = connectedSocketPath == session.socketPath
      try await connectToService(socket: session.socketPath, recent: session.recent)
      recentWorkspaces = try await runtime.recentWorkspaces()
      if session.recent.isExample && !returningToSameWorkspace && !restoredWorkspaceSelection { await selectFirstPreparedTaskAfterOpening() }
    } catch { report(error) }
  }
  private func selectFirstPreparedTaskAfterOpening() async {
    if let op = operations.first(where: { $0.repos.contains { $0.hasWorktree } }),
      let repo = op.repos.first(where: { $0.hasWorktree })
    {
      generation = UUID()
      cancelDiffRead()
      selection = .init(repoId: repo.id, opId: op.id)
      contextOperationID = op.id
      clearStashReview()
      repository = nil
      diff = nil
      selectedFile = ""
      await refresh()
    }
  }
  public func report(_ failure: any Error) {
    errorDetails = failure.localizedDescription
    error = UserFacingFailure.message(failure)
    if case .helper(let details) = failure as? StartupFailure { errorDetails = details }
  }
  private func operationSummary(for id: String?) -> WorkbenchOperation? {
    guard let id else { return nil }
    return pinnedOperations[id] ?? operations.first { $0.id == id }
  }
  public var operation: WorkbenchOperation? { operationSummary(for: selection?.opId) }
  public var contextOperation: WorkbenchOperation? {
    operationSummary(for: activeContextOperationID)
  }
  public var taskDetail: TaskDetail? { operation.flatMap { tasks[$0.taskId] } }
  public var taskRepository: TaskRepository? {
    operation?.repos.first { $0.id == selection?.repoId }
  }
  public var taskTitle: String {
    if contextTaskInformationUnavailable { return taskInformationTitle }
    return contextOperation.map { title(for: $0) }
      ?? (activeContextOperationID != nil ? "작업 정보 확인 필요" : selection?.repoId)
      ?? "River"
  }
  public var hasRunningOperation: Bool {
    operations.contains { $0.isRunning } || pinnedOperations.values.contains { $0.isRunning }
  }
  public var visibleFiles: [FileChange] {
    if isViewingStash { return stashDetail?.files ?? [] }
    return repository?.files.filter { staged ? $0.isStaged : $0.isWorking } ?? []
  }
  public var isViewingStash: Bool { selectedStashOID != nil }
  public var selectedStash: GitStash? { stashes.first { $0.oid == selectedStashOID } }
  public var stagedCount: Int { repository?.files.filter(\.isStaged).count ?? 0 }
  public var taskInformationUnavailable: Bool {
    guard let id = selection?.opId else { return false }
    return unresolvedOperationIDs.contains(id) || taskRepository == nil
  }
  public var taskInformationLookupFailed: Bool {
    activeContextOperationID.map { unresolvedOperationIDs.contains($0) } ?? false
  }
  public var contextTaskInformationUnavailable: Bool {
    guard let id = activeContextOperationID else { return false }
    return unresolvedOperationIDs.contains(id) || contextOperation == nil
  }
  public var taskInformationTitle: String {
    taskInformationLookupFailed ? "작업 정보 확인 필요" : "작업 정보 확인 중…"
  }
  public var taskInformationHint: String {
    taskInformationLookupFailed
      ? "작업 정보를 읽지 못했습니다. 새로고침한 뒤 폴더를 확인해 주세요."
      : "저장된 작업과 폴더 정보를 확인하고 있습니다. 확인이 끝나면 변경을 편집할 수 있습니다."
  }
  public var pendingWorktree: Bool { !taskInformationUnavailable && taskRepository?.hasWorktree == false }
  public var pendingWorktreeTitle: String {
    if operation?.isRunning == true { return "작업 폴더 준비 중" }
    if ["failed", "needs_recovery", "cancelled"].contains(taskRepository?.state ?? "") { return "작업 폴더 준비 중단" }
    return "워크트리 준비 대기"
  }
  public var pendingWorktreeHint: String {
    if operation?.isRunning == true { return "저장소 준비가 끝나면 변경 내용을 확인할 수 있습니다." }
    if operation?.requiresNewPlan == true {
      return "계획을 만든 뒤 원래 폴더가 바뀌었습니다. 원래 변경은 유지됩니다. 현재 상태를 기준으로 새 작업을 만들어 주세요."
    }
    if ["failed", "needs_recovery", "cancelled"].contains(taskRepository?.state ?? "") {
      return "위 저장소의 준비 상태와 오류를 확인한 뒤 재시도하세요. 원래 프로젝트 폴더의 변경은 계속 확인할 수 있습니다."
    }
    return "위의 ‘워크트리 준비’를 눌러 작업용 폴더를 만드세요."
  }
  public var preparationHint: String {
    if taskInformationUnavailable { return taskInformationHint }
    if operation?.requiresNewPlan == true {
      return "원래 폴더가 바뀌어 이 계획을 계속할 수 없습니다. ‘새 작업 만들기’로 현재 상태에서 준비하세요. 기존 폴더와 브랜치는 유지됩니다."
    }
    if pendingWorktree { return pendingWorktreeHint }
    if taskRepository?.state == "cancelled" { return "준비가 취소되었습니다. 위 저장소에서 재시도한 뒤 변경을 편집할 수 있습니다." }
    return "이 작업 폴더의 준비가 끝나면 변경을 편집할 수 있습니다. 위 저장소의 상태와 오류를 확인해 주세요."
  }
  public func beginRecovery(_ operation: WorkbenchOperation) {
    guard preparationEligibility(for: operation.id).recovery,
      let current = operationSummary(for: operation.id) else { return }
    recoveryTaskID = current.taskId
    showTaskSheet = true
  }
  public func nextTaskSlug(_ base: String) -> String {
    let root = String(base.prefix(55))
    var number = 2
    while operations.flatMap(\.repos).contains(where: { $0.plan.branchRef.hasSuffix("/\(root)-\(number)") }) { number += 1 }
    return "\(root)-\(number)"
  }
  public var taskPreparationIncomplete: Bool {
    guard let id = selection?.opId else { return false }
    return unresolvedOperationIDs.contains(id) || taskRepository?.state != "ready"
  }
  public var canEdit: Bool {
    !isViewingStash && repository != nil && repository?.conflict != true && !busy
      && !hasRunningOperation && !validatingSelection && !taskPreparationIncomplete && !contextWorking
      && socketPath == connectedSocketPath
  }
  public func preparationEligibility(for id: String) -> PreparationEligibility {
    let op = operationSummary(for: id)
    let connected = client != nil && socketPath == connectedSocketPath && !busy
    let resolved = connected && !unresolvedOperationIDs.contains(id) && op != nil
    let canPrepare = resolved && !hasRunningOperation
    return PreparationEligibility(
      materialize: canPrepare && op?.canMaterialize == true && op?.requiresNewPlan != true,
      retry: canPrepare && op?.canRetry == true && op?.requiresNewPlan != true,
      recovery: canPrepare && op?.canRetry == true && op?.requiresNewPlan == true,
      // Cancellation is a safety action against an already-known operation ID.
      // The service verifies its current state; stale metadata must not trap a running job.
      cancel: connected && op?.isRunning == true)
  }
  public func title(for op: WorkbenchOperation) -> String {
    tasks[op.taskId]?.request.label ?? op.repos.first?.plan.branchRef.components(separatedBy: "/")
      .last ?? String(op.id.prefix(8))
  }

  public func connect() async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    let requestedSocket = socketPath
    do {
      try await connectToService(socket: requestedSocket)
    } catch {
      if socketPath == requestedSocket, let connectedSocketPath { socketPath = connectedSocketPath }
      report(error)
    }
  }
  // Keep every published workspace identity and client from the old connection
  // until the candidate handshake succeeds. Failed candidates preserve its drafts.
  private func connectToService(socket: String, recent: RecentWorkspace? = nil) async throws {
    let requestedSocket = socketPath
    let candidate = ServiceClient(socketPath: socket)
    let spaces: [WorkspaceInfo] = try await candidate.call("list_workspaces")
    guard let workspace = spaces.first else { throw UIError.emptyWorkspace }
    guard socketPath == requestedSocket else { throw UIError.workspaceChanged }
    let restoring = connectedSocketPath == socket && self.workspace?.id == workspace.id
    rememberLocation()
    if let oldSocket = connectedSocketPath, let oldWorkspace = self.workspace {
      let oldKey = oldSocket + ":" + oldWorkspace.id
      workspaceDrafts[oldKey] = locationDrafts
      workspaceSelections[oldKey] = selection
      workspaceContexts[oldKey] = contextOperationID
    }
    let workspaceKey = socket + ":" + workspace.id
    let restoredSelection = restoring ? selection : workspaceSelections[workspaceKey]
    let restoredContext = restoring ? contextOperationID : workspaceContexts[workspaceKey]
    restoredWorkspaceSelection = restoredSelection != nil
    self.client = candidate
    self.workspace = workspace
    currentWorkspace = recent ?? (restoring ? currentWorkspace : nil)
    socketPath = socket
    connectedSocketPath = socket
    planSession = UUID()
    generation = UUID()
    cancelDiffRead()
    clearDiffFailure()
    selectionCheckFailed = false
    lastRefreshFailure = nil
    lastMetadataFailure = nil
    if !restoring {
      workspaceSession = UUID()
      taskContext.reset()
      locationCache.removeAll()
      locationDrafts = workspaceDrafts[workspaceKey] ?? [:]
      cacheOrder.removeAll()
      readingSession = ReviewSession()
      onlyUnreviewedFiles = false
    }
    operations = []
    pinnedOperations = [:]
    unresolvedOperationIDs = []
    contextOperationID = restoredContext
    stashes = []
    stashError = nil
    clearStashReview()
    tasks = [:]
    events = []
    eventCursor = 0
    selection = restoredSelection ?? workspace.repositories.first.map { .init(repoId: $0.id) }
    repository = nil
    diff = nil
    let restoredDraft = selection.flatMap { locationDrafts[$0] }
    selectedFile = restoredDraft?.selectedFile ?? ""
    staged = restoredDraft?.staged ?? false
    commitMessage = restoredDraft?.commitMessage ?? ""
    lastUpdated = nil
    validatingSelection = true
    showingWelcome = false
    // A prior workspace read may still be finishing. It cannot publish after generation changed.
    while refreshing { try await Task.sleep(for: .milliseconds(20)) }
    await refresh()
  }

  public func select(_ value: WorktreeSelection, leaveTask: Bool = false) {
    let contextID = value.opId ?? (leaveTask || contextOperation?.repos.contains(where: { $0.id == value.repoId }) == false ? nil : activeContextOperationID)
    guard !busy, value != selection || contextID != contextOperationID else { return }
    if value == selection {
      contextOperationID = contextID
      configureTaskContext()
      Task { await taskContext.refresh() }
      return
    }
    clearDiffFailure()
    selectionCheckFailed = false
    lastRefreshFailure = nil
    rememberLocation()
    let version = UUID()
    generation = version
    cancelDiffRead()
    contextOperationID = contextID
    selection = value
    configureTaskContext()
    let cached = locationCache[value]
    let draft = locationDrafts[value]
    stashes = cached?.stashes ?? []
    stashError = nil
    selectedStashOID = cached?.selectedStashOID
    stashDetail = cached?.stashDetail
    repository = cached?.repository
    diff = cached?.diff
    selectedFile = draft?.selectedFile ?? ""
    staged = draft?.staged ?? false
    commitMessage = draft?.commitMessage ?? ""
    lastUpdated = cached?.lastUpdated
    validatingSelection = true
    error = nil
    errorDetails = nil
    Task {
      // A superseded read may still be in flight. Refresh this selection as soon as it ends.
      while refreshing {
        guard generation == version else { return }
        try? await Task.sleep(for: .milliseconds(20))
      }
      guard generation == version, validatingSelection else { return }
      await refresh()
    }
  }
  private func rememberLocation() {
    guard let selection else { return }
    locationDrafts[selection] = LocationDraft(
      selectedFile: selectedFile, staged: staged, commitMessage: commitMessage)
    // Large diffs are fetched again; retaining every diff would undermine the memory budget.
    let cachedDiff = diff.flatMap {
      $0.text.utf8.count + $0.header.utf8.count + $0.hunks.reduce(0) { $0 + $1.utf8.count }
        <= 512 * 1024 ? $0 : nil
    }
    locationCache[selection] = CachedLocation(
      repository: repository, diff: cachedDiff, stashes: stashes,
      selectedStashOID: selectedStashOID, stashDetail: stashDetail, lastUpdated: lastUpdated)
    cacheOrder.removeAll { $0 == selection }
    cacheOrder.append(selection)
    while cacheOrder.count > 6 { locationCache.removeValue(forKey: cacheOrder.removeFirst()) }
  }
  public func selectTask(_ op: WorkbenchOperation) {
    guard let repo = op.repos.first(where: { $0.state == "ready" }) ?? op.repos.first else {
      return
    }
    select(.init(repoId: repo.id, opId: op.id))
  }
  public func selectInitialTask(preferredRepository: String? = nil) async {
    if let op = operations.first(where: { $0.repos.contains { $0.hasWorktree } })
      ?? operations.first
    {
      if let preferredRepository, op.repos.contains(where: { $0.id == preferredRepository }) {
        select(.init(repoId: preferredRepository, opId: op.id))
      } else {
        selectTask(op)
      }
      // Wait for any in-flight old selection read to finish, then refresh this one.
      while refreshing { try? await Task.sleep(for: .milliseconds(20)) }
      await refresh()
    }
  }

  public func refresh(forceDiff: Bool = false) async {
    if forceDiff && refreshing {
      let version = generation
      while refreshing {
        do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
        guard version == generation else { return }
      }
    }
    guard let client, !refreshing else { return }
    refreshing = true
    defer { refreshing = false }
    let version = generation
    let location = selection
    var metadataFailures: [String] = []
    do {
      let ops: [WorkbenchOperation]
      do {
        ops = try await client.call("list_operations")
      } catch {
        guard version == generation else { return }
        unresolvedOperationIDs.formUnion(activeOperationIDs)
        unresolvedOperationIDs.formUnion(operations.map(\.id))
        unresolvedOperationIDs.formUnion(pinnedOperations.keys)
        configureTaskContext()
        throw error
      }
      guard version == generation else { return }
      if operations != ops { operations = ops }
      let requiredIDs = activeOperationIDs
      var pinned: [String: WorkbenchOperation] = [:]
      var unresolved: Set<String> = []
      for id in requiredIDs.sorted() {
        if let listed = ops.first(where: { $0.id == id }) {
          pinned[id] = listed
        } else {
          do {
            let value: WorkbenchOperation = try await client.call("get_operation", params: ["op_id": .string(id)])
            guard version == generation, requiredIDs == activeOperationIDs else { return }
            guard value.id == id else { throw UIError.operationIdentityMismatch }
            pinned[id] = value
          } catch {
            guard version == generation, requiredIDs == activeOperationIDs else { return }
            // Keep known identity/drafts for display, but never authorize Task
            // context or worktree edits using a summary that failed to refresh.
            pinned[id] = pinnedOperations[id]
            unresolved.insert(id)
            metadataFailures.append("선택한 작업 정보를 확인하지 못했습니다.")
          }
        }
      }
      if pinnedOperations != pinned { pinnedOperations = pinned }
      if unresolvedOperationIDs != unresolved { unresolvedOperationIDs = unresolved }
      let neededDetails = pinned.values.sorted { $0.id < $1.id } + ops.filter { !requiredIDs.contains($0.id) }
      for op in neededDetails.filter({ tasks[$0.taskId] == nil }).prefix(8) {
        do {
          let detail: TaskDetail = try await client.call("get_task", params: ["task_id": .string(op.taskId)])
          guard version == generation else { return }
          tasks[detail.id] = detail
        } catch {
          guard version == generation else { return }
          metadataFailures.append("작업 정보를 읽지 못했습니다.")
        }
      }
      configureTaskContext()
      await taskContext.refresh()
      guard version == generation else { return }
      do {
        let newEvents: [OperationEvent] = try await client.call("events", params: ["cursor": .number(Double(eventCursor)), "latest": .bool(eventCursor == 0)])
        guard version == generation else { return }
        if !newEvents.isEmpty { events.append(contentsOf: newEvents) }
        if let last = newEvents.last { eventCursor = last.sequence }
        if events.count > 1000 { events.removeFirst(events.count - 1000) }
      } catch {
        guard version == generation else { return }
        metadataFailures.append("준비 기록을 읽지 못했습니다.")
      }
      if let location {
        do {
          let entries: [GitStash] = try await client.call(
            "list_stashes", params: ["repo_id": .string(location.repoId)])
          guard version == generation else { return }
          if stashes != entries { stashes = entries }
          if stashError != nil { stashError = nil }
          if let selectedStashOID, !entries.contains(where: { $0.oid == selectedStashOID }) {
            clearStashReview()
            cancelDiffRead()
            diff = nil
            selectedFile = ""
            stashError = "선택한 stash가 외부에서 삭제되었습니다. 현재 변경으로 돌아왔습니다."
          }
        } catch {
          guard version == generation else { return }
          stashError = "Stash 목록을 읽지 못했습니다. 새로고침해 주세요."
        }
        if let opId = location.opId,
          operationSummary(for: opId)?.repos.first(where: { $0.id == location.repoId })?
            .hasWorktree != true
        {
          if repository != nil { repository = nil }
          if !isViewingStash && diff != nil { diff = nil }
        } else {
          let status: RepositoryStatus = try await client.call(
            "get_repo_status", params: params(for: location))
          guard version == generation else { return }
          let changed = repository?.snapshotHash != status.snapshotHash
          if repository != status { repository = status }
          if !isViewingStash {
            if !visibleFiles.contains(where: { $0.path == selectedFile }) {
              let fallback = visibleFiles.first?.path ?? ""
              if selectedFile != fallback { selectedFile = fallback }
            }
            if forceDiff { clearDiffFailure() }
            if !selectedFile.isEmpty && (forceDiff || changed || diff?.path != selectedFile || diff?.staged != staged) { await loadDiff() }
          }
        }
        if isViewingStash {
          if stashDetail == nil {
            await loadStashDetail()
          } else {
            if !visibleFiles.contains(where: { $0.path == selectedFile }) {
              let fallback = visibleFiles.first?.path ?? ""
              if selectedFile != fallback { selectedFile = fallback }
            }
            if forceDiff { clearDiffFailure() }
            if forceDiff || diff?.path != selectedFile { await loadDiff() }
          }
        }
      }
      guard version == generation else { return }
      if taskInformationUnavailable {
        if !validatingSelection { validatingSelection = true }
        if !selectionCheckFailed { selectionCheckFailed = true }
      } else {
        lastUpdated = Date()
        if validatingSelection { validatingSelection = false }
        if selectionCheckFailed { selectionCheckFailed = false }
      }
      let metadataMessage = metadataFailures.isEmpty ? nil : Array(Set(metadataFailures)).sorted().joined(separator: " ")
        + (taskInformationUnavailable ? " 새로고침으로 작업과 폴더 정보를 확인해 주세요." : " 파일의 현재 상태는 별도로 확인했습니다. 새로고침으로 기록을 다시 불러오세요.")
      if let metadataMessage, metadataMessage != lastMetadataFailure { error = metadataMessage; errorDetails = nil }
      if metadataMessage == nil, error == lastMetadataFailure, lastMetadataFailure != nil { error = nil; errorDetails = nil }
      lastMetadataFailure = metadataMessage
      if error == lastRefreshFailure && lastRefreshFailure != nil { error = nil; errorDetails = nil }
      lastRefreshFailure = nil
    } catch {
      guard version == generation else { return }
      // Keep mutation guards until a fresh coherent read succeeds. An error
      // is no longer presented as endless loading or re-opened every poll.
      if !validatingSelection { validatingSelection = true }
      if !selectionCheckFailed { selectionCheckFailed = true }
      let message = UserFacingFailure.message(error)
      if lastRefreshFailure != message {
        report(error)
        lastRefreshFailure = message
      }
    }
  }
  private func configureTaskContext() {
    guard let client, let selection, let workspace, let connectedSocketPath else { return }
    taskContext.configure(client: client, workspace: connectedSocketPath + ":" + workspace.id,
      location: selection, contextOperationID: activeContextOperationID, operation: contextOperation,
      operationResolved: activeContextOperationID.map { !unresolvedOperationIDs.contains($0) } ?? true,
      title: taskTitle)
  }
  public func chooseFile(_ path: String, staged: Bool? = nil) {
    clearDiffFailure()
    cancelDiffRead()
    if let staged { self.staged = staged }
    selectedFile = path
    diff = nil
    Task { await loadDiff(debounce: true) }
  }
  public func chooseStaged(_ value: Bool) {
    clearDiffFailure()
    cancelDiffRead()
    clearStashReview()
    staged = value
    if !visibleFiles.contains(where: { $0.path == selectedFile }) {
      selectedFile = visibleFiles.first?.path ?? ""
    }
    diff = nil
    Task { await loadDiff(debounce: true) }
  }
  private func loadDiff(debounce: Bool = false) async {
    cancelDiffRead()
    let version = UUID()
    diffGeneration = version
    guard let client, let selection, !selectedFile.isEmpty, repository != nil || isViewingStash
    else {
      diff = nil
      return
    }
    let locationVersion = generation
    let readID = DiffReadID(location: selection, path: selectedFile, staged: staged,
      stash: selectedStashOID, snapshot: repository?.snapshotHash)
    guard failedDiffRead != readID else { return }
    diffError = nil
    var values = params(for: selection)
    values["path"] = .string(selectedFile)
    values["staged"] = .bool(staged)
    let stashOID = selectedStashOID
    if let stashOID { values["stash_oid"] = .string(stashOID) }
    let request = Task<FileDiff, any Error> {
      // Coalesce navigation bursts before admitting expensive server reads.
      // Socket cancellation cannot undo a read already running in the engine.
      if debounce { try await Task.sleep(for: .milliseconds(80)) }
      try Task.checkCancellation()
      return try await client.call(stashOID == nil ? "get_diff" : "get_stash_diff", params: values)
    }
    diffRequest = request
    defer { if version == diffGeneration { diffRequest = nil } }
    do {
      let value = try await withTaskCancellationHandler {
        try await request.value
      } onCancel: { request.cancel() }
      guard
        version == diffGeneration && locationVersion == generation && stashOID == selectedStashOID
      else { return }
      diff = value
      failedDiffRead = nil
    } catch {
      if error is CancellationError { return }
      if version == diffGeneration && locationVersion == generation {
        diff = nil
        failedDiffRead = readID
        diffError = UserFacingFailure.message(error)
      }
    }
  }
  private func cancelDiffRead() {
    diffGeneration = UUID()
    diffRequest?.cancel()
    diffRequest = nil
  }
  private func clearDiffFailure() { diffError = nil; failedDiffRead = nil }
  public func retryDiff() async { clearDiffFailure(); await loadDiff() }
  private func clearStashReview() {
    selectedStashOID = nil
    stashDetail = nil
  }
  public func revealStashes() { stashFocusRequest += 1 }
  public func chooseStash(_ stash: GitStash) {
    guard !busy else { return }
    clearDiffFailure()
    cancelDiffRead()
    selectedStashOID = stash.oid
    stashDetail = nil
    selectedFile = ""
    diff = nil
    Task { await loadStashDetail() }
  }
  private func loadStashDetail() async {
    guard let client, let selection, let requestedOID = selectedStashOID else { return }
    let version = generation
    do {
      let detail: StashDetail = try await client.call(
        "get_stash",
        params: [
          "repo_id": .string(selection.repoId), "stash_oid": .string(requestedOID),
        ])
      guard generation == version && selectedStashOID == requestedOID else { return }
      stashDetail = detail
      stashError = nil
      if !visibleFiles.contains(where: { $0.path == selectedFile }) {
        selectedFile = visibleFiles.first?.path ?? ""
      }
      await loadDiff()
    } catch {
      guard generation == version && selectedStashOID == requestedOID else { return }
      stashError = "Stash 내용을 읽지 못했습니다. 목록을 새로고침해 주세요."
    }
  }
  public func showWorkingChanges() {
    clearDiffFailure()
    clearStashReview()
    cancelDiffRead()
    staged = false
    selectedFile = visibleFiles.first?.path ?? ""
    diff = nil
    Task { await loadDiff() }
  }
  public func stageHunk(_ index: Int) async {
    guard let selection, let diff else { return }
    await stageHunk(index, from: diff, at: selection)
  }
  public func stageHunk(_ index: Int, from diff: FileDiff, at selection: WorktreeSelection) async {
    guard let client, selection == self.selection, canEdit, canUseRenderedDiff,
      diff.contentIdentity == self.diff?.contentIdentity, diff.snapshotHash == repository?.snapshotHash,
      diff.path == selectedFile, diff.staged == staged else {
      error = "변경이 바뀌었거나 확인 중입니다. 현재 변경을 다시 확인한 뒤 스테이징하세요."
      return
    }
    var values = params(for: selection)
    values["path"] = .string(diff.path)
    values["staged"] = .bool(diff.staged)
    values["hunk_index"] = .number(Double(index))
    values["snapshot_hash"] = .string(diff.snapshotHash)
    values["diff_hash"] = .string(diff.contentIdentity)
    await mutation {
      let _: MutationResult = try await client.call("stage_hunk", params: values)
    }
  }
  public func commit(expectedSnapshot: String? = nil, at location: WorktreeSelection? = nil) async {
    guard let client, let selection, let repository, canEdit, stagedCount > 0,
      location == nil || location == selection,
      !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return }
    var values = params(for: selection)
    values["snapshot_hash"] = .string(expectedSnapshot ?? repository.snapshotHash)
    let submittedMessage = commitMessage
    let submittedRevision = commitDraft.revision
    values["message"] = .string(submittedMessage)
    await mutation {
      let _: MutationResult = try await client.call("commit", params: values)
      if self.commitDraft.revision == submittedRevision { self.commitMessage = "" }
    }
  }
  public func operate(_ method: String, op: WorkbenchOperation) async {
    guard let client else { return }
    let eligibility = preparationEligibility(for: op.id)
    if ["retry_operation", "materialize"].contains(method), eligibility.recovery {
      if let current = operationSummary(for: op.id) { beginRecovery(current) }
      return
    }
    guard (method == "materialize" && eligibility.materialize)
      || (method == "retry_operation" && eligibility.retry)
      || (method == "cancel_operation" && eligibility.cancel) else { return }
    await mutation {
      let _: WorkbenchOperation = try await client.call(method, params: ["op_id": .string(op.id)])
    }
  }
  public func planTask(group: String, label: String, slug: String, mode: String) async throws
    -> WorkspaceTaskPlan
  {
    guard let client, let socket = connectedSocketPath else { throw UIError.notConnected }
    let session = planSession
    guard socketPath == socket else { throw UIError.workspaceChanged }
    let details: TaskPlan = try await client.call(
      "plan_task",
      params: [
        "group_id": .string(group), "label": .string(label), "task_slug": .string(slug),
        "mode": .string(mode),
      ])
    guard socketPath == socket, connectedSocketPath == socket else { throw UIError.workspaceChanged }
    guard planSession == session, self.client === client else { throw UIError.planInvalidated }
    return WorkspaceTaskPlan(details: details, session: session, socket: socket)
  }
  public func listBranches() async throws -> [GitBranch] {
    guard let client, let selection else { throw UIError.notConnected }
    return try await client.call("list_branches", params: params(for: selection))
  }
  public func branchHistory(_ branch: GitBranch) async throws -> [HistoryCommit] {
    guard let client, let selection else { throw UIError.notConnected }
    return try await client.call(
      "get_branch_history",
      params: [
        "repo_id": .string(selection.repoId), "branch_ref": .string(branch.fullRef),
        "tip_oid": .string(branch.tipOid),
      ])
  }
  public func executePlan(_ plan: WorkspaceTaskPlan, key: String) async throws {
    guard let client else { throw UIError.notConnected }
    guard plan.socket == socketPath, socketPath == connectedSocketPath else { throw UIError.workspaceChanged }
    guard plan.session == planSession else { throw UIError.planInvalidated }
    let originTitle = workspaceTitle
    let originPath = currentWorkspace?.repositoryPath ?? workspace?.repositories.first?.path ?? plan.socket
    let warningID = plan.socket + ":" + key
    let op: WorkbenchOperation
    do {
      op = try await client.call(
        "execute_plan", params: ["plan_id": .string(plan.details.id), "idempotency_key": .string(key)])
    } catch {
      guard !(error is ServiceFailure) else { throw error }
      let warning = TaskSubmissionWarning(id: warningID, workspaceTitle: originTitle,
        workspacePath: originPath, message: UIError.submissionOutcomeUnknown.localizedDescription)
      if !submissionWarnings.contains(where: { $0.id == warningID }) { submissionWarnings.append(warning) }
      throw UIError.submissionOutcomeUnknown
    }
    guard plan.session == planSession, self.client === client, plan.socket == socketPath
    else {
      report(UIError.workspaceChangedAfterSubmission)
      throw UIError.workspaceChangedAfterSubmission
    }
    if !operations.contains(where: { $0.id == op.id }) { operations.insert(op, at: 0) }
    selectTask(op)
    await refresh()
  }
  public func dismissSubmissionWarning(_ id: String) {
    submissionWarnings.removeAll { $0.id == id }
  }
  private func mutation(_ work: () async throws -> Void) async {
    busy = true
    error = nil
    defer { busy = false }
    do {
      try await work()
      while refreshing { try? await Task.sleep(for: .milliseconds(20)) }
      await refresh()
    } catch {
      report(error)
      while refreshing { try? await Task.sleep(for: .milliseconds(20)) }
      await refresh()
    }
  }
  private func params(for value: WorktreeSelection) -> [String: JSONValue] {
    var params: [String: JSONValue] = ["repo_id": .string(value.repoId)]
    if let id = value.opId { params["op_id"] = .string(id) }
    return params
  }
  public func openCurrentWorktree() {
    if let path = repository?.path {
      NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
    }
  }
  public func copyCurrentPath() {
    guard let path = repository?.path else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
  }
}

enum UIError: LocalizedError {
  case emptyWorkspace, notConnected, operationIdentityMismatch, workspaceChanged, workspaceChangedAfterSubmission, submissionOutcomeUnknown, planInvalidated
  var errorDescription: String? {
    switch self {
    case .emptyWorkspace: "등록된 워크스페이스가 없습니다."
    case .notConnected: "로컬 서비스에 먼저 연결하세요."
    case .operationIdentityMismatch: "선택한 작업과 다른 정보가 반환되었습니다. 새로고침해 주세요."
    case .workspaceChanged: "프로젝트가 바뀌었습니다. 현재 프로젝트에서 계획을 다시 확인해 주세요."
    case .workspaceChangedAfterSubmission: "프로젝트가 바뀌었습니다. 이전 요청의 실행 여부는 이전 프로젝트의 작업 목록에서 확인해 주세요."
    case .submissionOutcomeUnknown: "작업 준비 요청의 접수 여부를 확인하지 못했습니다. 같은 요청을 반복하기 전에 이 프로젝트의 작업 목록과 실제 Git 상태를 확인해 주세요."
    case .planInvalidated: "다시 연결하여 이전 계획을 사용할 수 없습니다. 입력은 유지했습니다. 현재 상태로 계획을 다시 확인해 주세요."
    }
  }
}
