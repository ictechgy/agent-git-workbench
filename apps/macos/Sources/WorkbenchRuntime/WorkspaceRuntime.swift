import Darwin
import Foundation
import WorkbenchProtocol

public struct RecentWorkspace: Codable, Sendable, Identifiable, Equatable {
  public let id: UUID
  public let name: String
  public let repositoryPath: String
  public let isExample: Bool
  public var lastOpened: Date
}

public struct WorkspaceSession: Sendable {
  public let recent: RecentWorkspace
  public let socketPath: String
}

public enum StartupFailure: Error, LocalizedError, Sendable {
  case engineMissing, repositoryMissing, notRepository, privateDirectory, startupTimedOut
  case helper(String)
  case cloneCreated(String), cloneOutcomeUnknown(String), remote(String)
  case workspaceMissing
  case workspaceBusy, examplePreparationFailed, externalFilters, unsafeRepository
  public var errorDescription: String? {
    switch self {
    case .engineMissing: "앱에 필요한 작업 엔진이 없습니다. 앱을 다시 설치해 주세요."
    case .repositoryMissing: "저장소 폴더를 찾을 수 없습니다. ‘저장소 열기’에서 다시 선택해 주세요."
    case .notRepository: "이 폴더에는 Git 저장소가 없습니다. Git으로 관리하는 프로젝트 폴더를 선택해 주세요."
    case .privateDirectory: "앱의 작업 폴더를 준비하지 못했습니다. 폴더 접근 권한을 확인해 주세요."
    case .startupTimedOut: "작업 준비가 지연되고 있습니다. 잠시 후 다시 열어 주세요."
    case .helper: "작업 엔진을 준비하지 못했습니다. 다시 시도해 주세요."
    case .cloneOutcomeUnknown(let path): "복제의 완료 여부를 확인하지 못했습니다. 다시 복제하기 전에 다음 폴더와 상위 폴더의 상태를 확인해 주세요: \(path)"
    case .remote(let code):
      switch code {
      case "unsupported_git_version": "원격 기능에는 Apple Git 2.41 이상이 필요합니다. Xcode 또는 Command Line Tools를 업데이트해 주세요."
      case "unsupported_alternate_command": "외부 Git 명령 설정이 있어 원격 연결을 중단했습니다. Git 설정의 core.alternateRefsCommand를 확인해 주세요."
      case "clone_destination_exists": "같은 이름의 폴더가 이미 있습니다. 다른 이름을 입력해 주세요."
      case "invalid_clone_destination": "복제할 상위 폴더와 새 폴더 이름을 확인해 주세요."
      case "invalid_remote_url", "unsupported_remote_transport": "SSH 또는 HTTPS 저장소 URL을 입력해 주세요. URL에 비밀번호나 토큰을 넣지 마세요."
      case "remote_connection_failed": "원격 서버에 연결하지 못했습니다. URL과 접근 권한을 확인해 주세요. SSH는 기본 키·agent·신뢰한 서버를, HTTPS는 macOS Git Keychain 인증을 사용합니다."
      case "clone_staging_failed": "복제용 임시 폴더를 만들지 못했습니다. 상위 폴더의 쓰기 권한을 확인해 주세요."
      default: "현재 Git 연결 설정을 지원하지 않습니다. URL 재작성, 사용자 지정 전송 명령, 외부 필터와 인증 도우미 설정을 확인해 주세요."
      }
    case .cloneCreated(let path): "복제는 완료했습니다. 프로젝트를 여는 데 실패했습니다. ‘저장소 열기’에서 다음 폴더를 선택해 주세요: \(path)"
    case .workspaceMissing: "이 작업의 기록을 찾을 수 없습니다. 저장소를 다시 열어 주세요."
    case .workspaceBusy: "다른 창에서 작업 엔진을 정리 중입니다. 잠시 후 다시 열어 주세요."
    case .examplePreparationFailed: "예제 준비를 완료하지 못했습니다. 예제를 다시 열어 주세요."
    case .externalFilters: "Git 외부 필터가 등록되어 작업을 준비할 수 없습니다. 현재는 실제 사용 여부와 관계없이 전역 필터 설정도 지원하지 않습니다."
    case .unsafeRepository: "선택한 폴더의 Git 설정이 다른 저장소를 가리킵니다. 폴더의 Git 위치 설정을 확인한 뒤 다시 열어 주세요."
    }
  }
}

/// Owns bootstrap and child processes away from the UI actor. Repository mutations remain in Rust.
public actor WorkspaceRuntime {
  private let storage: URL
  private let runtime: URL
  private let explicitHelper: URL?
  private struct ChildProcess {
    let process: Process
    let exit: ProcessExit
  }
  private var children: [UUID: ChildProcess] = [:]
  private var leases: [UUID: WorkspaceLease] = [:]
  private var opening: [String: Task<WorkspaceSession, Error>] = [:]
  private var stoppingServices = false

  public init(storageDirectory: URL? = nil, runtimeDirectory: URL? = nil, helperURL: URL? = nil) {
    storage =
      storageDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("AgentGitWorkbench", isDirectory: true)
    // Darwin sun_path is 104 bytes. Never derive it from a potentially long user/project path.
    runtime = runtimeDirectory ?? URL(fileURLWithPath: "/tmp/agw-\(getuid())", isDirectory: true)
    explicitHelper = helperURL
  }

  public func recentWorkspaces() throws -> [RecentWorkspace] {
    let file = storage.appendingPathComponent("recent.json")
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    let data = try Data(contentsOf: file)
    do { return try JSONDecoder().decode([RecentWorkspace].self, from: data).sorted { $0.lastOpened > $1.lastOpened } }
    catch is DecodingError {
      try? FileManager.default.moveItem(at: file, to: storage.appendingPathComponent("recent-corrupt-\(UUID().uuidString).json"))
      return []
    }
  }

  public func openRepository(_ selected: URL) async throws -> WorkspaceSession {
    guard FileManager.default.fileExists(atPath: selected.path) else {
      throw StartupFailure.repositoryMissing
    }
    let info: RepositoryInfo
    do {
      let data = try await runHelper(["inspect", selected.path])
      info = try JSONDecoder().decode(RepositoryInfo.self, from: data)
    } catch StartupFailure.helper(let details) where details.contains("not_a_repository") {
      throw StartupFailure.notRepository
    }
    return try await coalesce("repository:\(info.path)") {
      try await self.openInspectedRepository(info)
    }
  }
  public func cloneRepository(url: String, destination: URL) async throws -> WorkspaceSession {
    struct CloneResult: Decodable { let path: String }
    let result: CloneResult
    do {
      let data = try await runHelper(["clone", url, destination.path], timeout: 360)
      result = try JSONDecoder().decode(CloneResult.self, from: data)
    } catch StartupFailure.remote(let code) where code != "remote_outcome_unknown" {
      throw StartupFailure.remote(code)
    } catch StartupFailure.engineMissing { throw StartupFailure.engineMissing }
    catch StartupFailure.externalFilters { throw StartupFailure.externalFilters }
    catch StartupFailure.unsafeRepository { throw StartupFailure.unsafeRepository }
    catch { throw StartupFailure.cloneOutcomeUnknown(destination.path) }
    do { return try await openRepository(URL(fileURLWithPath: result.path, isDirectory: true)) }
    catch { throw StartupFailure.cloneCreated(result.path) }
  }
  private func openInspectedRepository(_ info: RepositoryInfo) async throws -> WorkspaceSession {
    if let existing = try recentWorkspaces().first(where: {
      !$0.isExample && $0.repositoryPath == info.path
    }),
      FileManager.default.fileExists(atPath: config(existing.id).path)
    {
      return try await openRecent(existing)
    }
    // MRU is a bounded menu, not the durable repository-to-journal registry.
    if let existing = try registeredWorkspace(for: info) {
      return try await openRecent(existing)
    }
    let recent = RecentWorkspace(
      id: UUID(), name: info.id, repositoryPath: info.path,
      isExample: false, lastOpened: Date())
    try prepareDirectories(recent.id)
    _ = try await runHelper(["workspace", info.path, config(recent.id).path])
    return try await activate(recent)
  }

  private func registeredWorkspace(for info: RepositoryInfo) throws -> RecentWorkspace? {
    let collection = storage.appendingPathComponent("workspaces", isDirectory: true)
    guard FileManager.default.fileExists(atPath: collection.path) else { return nil }
    var rootInfo = stat()
    guard lstat(collection.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR,
      rootInfo.st_uid == getuid() else { throw StartupFailure.privateDirectory }
    let entries = try FileManager.default.contentsOfDirectory(at: collection, includingPropertiesForKeys: nil)
    var matches: [RecentWorkspace] = []
    for entry in entries {
      guard let id = UUID(uuidString: entry.lastPathComponent) else { continue }
      var entryInfo = stat()
      guard lstat(entry.path, &entryInfo) == 0, (entryInfo.st_mode & S_IFMT) == S_IFDIR,
        entryInfo.st_uid == getuid() else { continue }
      do {
        let record = entry.appendingPathComponent("workspace-record.json")
        if let bytes = try privateRecord(record),
          let recent = try? JSONDecoder().decode(RecentWorkspace.self, from: bytes),
          recent.id == id
        {
          // A valid record is authoritative about workspace kind. Do not
          // reinterpret an excluded example through legacy config discovery.
          if !recent.isExample && recent.repositoryPath == info.path { matches.append(recent) }
          continue
        }
        // Migrate registrations made before per-workspace records existed.
        let file = entry.appendingPathComponent("workspace.json")
        guard let bytes = try privateRecord(file) else { continue }
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let workspace = try? decoder.decode(WorkspaceInfo.self, from: bytes),
          workspace.schemaVersion == 1, workspace.repositories.first?.path == info.path else { continue }
        // Older built-in examples retain their generated config under example/.
        // They are not ordinary registrations even before kind records existed.
        let example = entry.appendingPathComponent("example", isDirectory: true).resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: example.appendingPathComponent("workspace.json").path),
          workspace.repositories.allSatisfy({ $0.path.hasPrefix(example.path + "/") }) { continue }
        let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        matches.append(RecentWorkspace(id: id, name: info.id, repositoryPath: info.path,
          isExample: false, lastOpened: modified))
      } catch {
        // An unreadable/unsafe unrelated entry must not block the collection.
        // Skip the entire entry, including its legacy fallback.
        continue
      }
    }
    return matches.sorted { $0.lastOpened > $1.lastOpened }.first
  }

  private func privateRecord(_ url: URL) throws -> Data? {
    let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      if errno == ENOENT { return nil }
      throw StartupFailure.privateDirectory
    }
    let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? file.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(),
      info.st_size >= 0, info.st_size <= 1024 * 1024
    else { throw StartupFailure.privateDirectory }
    let data = try file.read(upToCount: 1024 * 1024 + 1) ?? Data()
    guard data.count <= 1024 * 1024 else { throw StartupFailure.privateDirectory }
    return data
  }

  public func openRecent(_ recent: RecentWorkspace) async throws -> WorkspaceSession {
    guard FileManager.default.fileExists(atPath: recent.repositoryPath) else {
      throw StartupFailure.repositoryMissing
    }
    guard FileManager.default.fileExists(atPath: config(recent.id).path) else {
      throw StartupFailure.workspaceMissing
    }
    return try await activate(recent)
  }

  public func openExample() async throws -> WorkspaceSession {
    try await coalesce("example") { try await self.createOrOpenExample() }
  }
  private func createOrOpenExample() async throws -> WorkspaceSession {
    if let existing = try recentWorkspaces().first(where: \.isExample),
      FileManager.default.fileExists(atPath: existing.repositoryPath),
      FileManager.default.fileExists(atPath: config(existing.id).path)
    {
      return try await prepareExample(openRecent(existing))
    }
    let id = UUID()
    try prepareDirectories(id)
    let example = directory(id).appendingPathComponent("example", isDirectory: true)
    _ = try await runHelper(["fixture", example.path])
    let generatedConfig = example.appendingPathComponent("workspace.json")
    // Trust only the two scripts just generated by our own helper, never selected repository code.
    for recipe in ["api.set-version@1", "ios-app.set-version@1"] {
      _ = try await runHelper(["trust", generatedConfig.path, recipe])
    }
    try FileManager.default.copyItem(at: generatedConfig, to: config(id))
    let recent = RecentWorkspace(
      id: id, name: "예제 워크스페이스", repositoryPath: example.path,
      isExample: true, lastOpened: Date())
    let session = try await start(recent)
    // Publish the workspace identity before preparation so retries reuse its
    // operation/journal even if preparation is slow or fails.
    try remember(recent)
    return try await prepareExample(session)
  }
  private func prepareExample(_ session: WorkspaceSession) async throws -> WorkspaceSession {
    let id = session.recent.id
    do {
      let client = ServiceClient(socketPath: session.socketPath)
      let key = "welcome-example-\(id.uuidString)"
      let lookup: OperationLookup = try await client.call("get_operation_by_key", params: ["idempotency_key": .string(key)])
      let operation: WorkbenchOperation
      if let previous = lookup.operation { operation = previous }
      else {
      let plan: TaskPlan = try await client.call(
        "plan_task",
        params: [
          "group_id": .string("ios-2-4"), "label": .string("로그인 화면 개선"),
          "task_slug": .string("login-screen"), "mode": .string("materialize"),
        ])
      operation = try await client.call(
        "execute_plan",
        params: [
          "plan_id": .string(plan.id), "idempotency_key": .string(key),
        ])
      }
      let deadline = Date().addingTimeInterval(120)
      while Date() < deadline {
        let current: WorkbenchOperation = try await client.call("get_operation", params: ["op_id": .string(operation.id)])
        if !current.isRunning {
          // Terminal failures are inspectable in the normal Task UI, with its
          // retry/recovery controls, instead of generating another example.
          try remember(session.recent)
          return session
        }
        try await Task.sleep(for: .milliseconds(100))
      }
      throw StartupFailure.startupTimedOut
    } catch {
      // Failed, unpublished examples must not accumulate idle engines on every retry.
      // Preserve a preparation still in progress and its journal for recovery.
      await stopIdleService(id)
      throw error
    }
  }
  private struct OperationLookup: Decodable, Sendable { let operation: WorkbenchOperation? }

  private func activate(_ recent: RecentWorkspace) async throws -> WorkspaceSession {
    let session = try await start(recent)
    try remember(session.recent)
    return session
  }

  private func start(_ recent: RecentWorkspace) async throws -> WorkspaceSession {
    try await coalesce("service:\(recent.id)") { try await self.startProcess(recent) }
  }
  private func startProcess(_ recent: RecentWorkspace) async throws -> WorkspaceSession {
    guard !stoppingServices else { throw StartupFailure.workspaceBusy }
    try prepareDirectories(recent.id)
    if leases[recent.id] == nil {
      leases[recent.id] = try WorkspaceLease(url: leaseFile(recent.id), exclusive: false)
    }
    let socket = runtime.appendingPathComponent("\(recent.id.uuidString.lowercased()).sock").path
    let session = WorkspaceSession(recent: recent, socketPath: socket)
    let probe = ServiceClient(socketPath: socket, timeoutSeconds: 1)
    if await serviceResponds(probe) { return session }
    let process: Process
    let launched: Bool
    if let existing = children[recent.id], existing.process.isRunning {
      process = existing.process
      launched = false
    } else {
      launched = true
      process = Process()
      process.executableURL = try helper()
      process.arguments = [
        "serve", config(recent.id).path,
        directory(recent.id).appendingPathComponent("journal.sqlite").path, socket,
      ]
      process.environment = helperEnvironment
      let exit = ProcessExit()
      process.terminationHandler = { exit.complete($0.terminationStatus) }
      process.standardOutput = FileHandle.nullDevice
      let logURL = directory(recent.id).appendingPathComponent("engine.log")
      FileManager.default.createFile(
        atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
      let log = try FileHandle(forWritingTo: logURL)
      defer { try? log.close() }
      process.standardError = log
      try process.run()
      children[recent.id] = ChildProcess(process: process, exit: exit)
    }
    let readinessDeadline = Date().addingTimeInterval(10)
    for _ in 0..<100 {
      if Date() >= readinessDeadline { break }
      if await serviceResponds(probe) { return session }
      // Another app instance may have won the journal lock; allow its socket to become ready.
      if !process.isRunning {
        try await Task.sleep(for: .milliseconds(150))
        if await serviceResponds(probe) { return session }
        let log =
          (try? String(
            contentsOf: directory(recent.id).appendingPathComponent("engine.log"), encoding: .utf8))
          ?? ""
        throw StartupFailure.helper(
          "Engine exited: \(process.terminationStatus). \(log.prefix(8000))")
      }
      try await Task.sleep(for: .milliseconds(50))
    }
    // Reused engines can own CLI work even with no other app lease. A failed
    // reconnect is never permission to terminate a previously running child.
    guard launched else { throw StartupFailure.startupTimedOut }
    // This new child never became ready during this launch.
    // Only reclaim a failed owned launch after proving no other app holds a
    // lease. An unreachable borrowed/busy engine is never treated as idle.
    leases.removeValue(forKey: recent.id)?.release()
    if let exclusive = try? WorkspaceLease(url: leaseFile(recent.id), exclusive: true) {
      defer { exclusive.release() }
      if let child = children[recent.id] {
        if process.isRunning { process.terminate() }
        if await child.exit.wait(until: Date().addingTimeInterval(0.5)) == nil, process.isRunning {
          Darwin.kill(process.processIdentifier, SIGKILL)
        }
        _ = await child.exit.wait(until: Date().addingTimeInterval(1))
        if !process.isRunning { children.removeValue(forKey: recent.id) }
      }
    }
    throw StartupFailure.startupTimedOut
  }
  private func serviceResponds(_ probe: ServiceClient) async -> Bool {
    do { let _: [WorkspaceInfo] = try await probe.call("list_workspaces"); return true }
    catch let failure as ServiceFailure where failure.code == "service_busy" { return true }
    catch { return false }
  }

  /// Do not interrupt an in-flight preparation when the user closes the UI.
  public func stopIdleServices() async {
    guard !stoppingServices else { return }
    stoppingServices = true
    defer { stoppingServices = false }
    for task in Array(opening.values) { _ = try? await task.value }
    let ids = Array(leases.keys)
    await withTaskGroup(of: Void.self) { group in
      for id in ids { group.addTask { await self.stopIdleService(id) } }
    }
    children = children.filter { $0.value.process.isRunning }
  }
  private func stopIdleService(_ id: UUID) async {
    guard let lease = leases.removeValue(forKey: id) else { return }
    lease.release()
    // Another instance keeps its shared lease. Never stop its engine.
    guard let exclusive = try? WorkspaceLease(url: leaseFile(id), exclusive: true) else { return }
    defer { exclusive.release() }
    let path = runtime.appendingPathComponent("\(id.uuidString.lowercased()).sock").path
    let probe = ServiceClient(socketPath: path, timeoutSeconds: 1)
    guard let decision: ShutdownDecision = try? await probe.call("shutdown_if_idle"), decision.stopping
    else {
      // Keep observing a busy owned child so a later normal quit can retry safely.
      exclusive.release()
      leases[id] = try? WorkspaceLease(url: leaseFile(id), exclusive: false)
      return
    }
    if let child = children[id] {
      // The service already acknowledged idle shutdown. Let bounded reads
      // finish independently; never hold app termination on an exit callback.
      if await child.exit.wait(until: Date().addingTimeInterval(2)) != nil { children.removeValue(forKey: id) }
    }
  }
  private struct ShutdownDecision: Decodable, Sendable { let stopping: Bool }
  private func leaseFile(_ id: UUID) -> URL {
    runtime.appendingPathComponent("\(id.uuidString.lowercased()).clients.lock")
  }
  private func coalesce(
    _ key: String, work: @escaping @Sendable () async throws -> WorkspaceSession
  ) async throws -> WorkspaceSession {
    if let task = opening[key] { return try await task.value }
    let task = Task { try await work() }
    opening[key] = task
    defer { opening.removeValue(forKey: key) }
    return try await task.value
  }

  private func directory(_ id: UUID) -> URL {
    storage.appendingPathComponent("workspaces", isDirectory: true).appendingPathComponent(
      id.uuidString.lowercased(), isDirectory: true)
  }
  private func config(_ id: UUID) -> URL { directory(id).appendingPathComponent("workspace.json") }
  private func prepareDirectories(_ id: UUID) throws {
    for path in [storage, storage.appendingPathComponent("workspaces"), directory(id), runtime] {
      try FileManager.default.createDirectory(
        at: path, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      var info = stat()
      guard lstat(path.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
        info.st_uid == getuid(), chmod(path.path, 0o700) == 0
      else { throw StartupFailure.privateDirectory }
    }
  }
  private func remember(_ recent: RecentWorkspace) throws {
    var recent = recent
    recent.lastOpened = Date()
    try JSONEncoder().encode(recent).write(
      to: directory(recent.id).appendingPathComponent("workspace-record.json"), options: .atomic)
    var history = try recentWorkspaces().filter {
      $0.id != recent.id && !(recent.isExample && $0.isExample)
    }
    history.insert(recent, at: 0)
    try JSONEncoder().encode(Array(history.prefix(30))).write(
      to: storage.appendingPathComponent("recent.json"), options: .atomic)
  }
  private func helper() throws -> URL {
    let bundled = Bundle.main.executableURL?.deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("Helpers/workbench")
    let development = ProcessInfo.processInfo.environment["WORKBENCH_SERVICE"].map {
      URL(fileURLWithPath: $0)
    }
    guard
      let candidate = explicitHelper ?? bundled.flatMap({
        FileManager.default.isExecutableFile(atPath: $0.path) ? $0 : nil
      }) ?? development,
      FileManager.default.isExecutableFile(atPath: candidate.path)
    else { throw StartupFailure.engineMissing }
    return candidate
  }
  private var helperEnvironment: [String: String] {
    var environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "LANG": "en_US.UTF-8",
    ]
    // Authentication socket is passed deliberately; arbitrary inherited Git variables are not.
    if let socket = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"], socket.hasPrefix("/"), !socket.contains("\0") {
      environment["SSH_AUTH_SOCK"] = socket
    }
    return environment
  }
  private func runHelper(_ arguments: [String], timeout: TimeInterval = 30) async throws -> Data {
    let executable = try helper()
    let environment = helperEnvironment
    return try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        do { continuation.resume(returning: try Self.runProcess(executable, arguments, environment, timeout: timeout)) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
  private nonisolated static func runProcess(
    _ executable: URL, _ arguments: [String], _ environment: [String: String], timeout: TimeInterval = 30
  ) throws -> Data {
    try HelperProcess.run(executable, arguments, environment, timeout: timeout)
  }
}

// Registered before run(): completion remains observable even if the child has
// already exited before a waiter arrives. No Foundation run-loop wait is used.
final class ProcessExit: @unchecked Sendable {
  private let condition = NSCondition()
  private var status: Int32?
  private var waiters: [CheckedContinuation<Int32, Never>] = []
  func complete(_ value: Int32) {
    condition.lock()
    guard status == nil else { condition.unlock(); return }
    status = value
    let pending = waiters
    waiters.removeAll()
    condition.broadcast()
    condition.unlock()
    for waiter in pending { waiter.resume(returning: value) }
  }
  func wait() async -> Int32 {
    await withCheckedContinuation { continuation in
      condition.lock()
      if let status {
        condition.unlock()
        continuation.resume(returning: status)
      } else {
        waiters.append(continuation)
        condition.unlock()
      }
    }
  }
  func waitBlocking(until deadline: Date) -> Int32? {
    condition.lock()
    defer { condition.unlock() }
    while status == nil { if !condition.wait(until: deadline) { return status } }
    return status
  }
  func wait(until deadline: Date) async -> Int32? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async { continuation.resume(returning: self.waitBlocking(until: deadline)) }
    }
  }
}

private final class WorkspaceLease: @unchecked Sendable {
  private var descriptor: Int32
  init(url: URL, exclusive: Bool) throws {
    descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard descriptor >= 0 else { throw StartupFailure.privateDirectory }
    if flock(descriptor, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
      Darwin.close(descriptor)
      descriptor = -1
      throw StartupFailure.workspaceBusy
    }
  }
  func release() {
    if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 }
  }
  deinit { release() }
}
