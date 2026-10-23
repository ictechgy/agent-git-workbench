import Foundation
import Darwin
import Testing
@testable import WorkbenchRuntime

@Test func reusedOwnedEngineSurvivesUnreachableReconnectAndBusyAdmission() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-reused-\(UUID().uuidString)")
  let sockets = URL(fileURLWithPath: "/tmp/agw-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: sockets) }
  let storage = folder.appendingPathComponent("data"); let repo = folder.appendingPathComponent("repo")
  let id = UUID(); let configFolder = storage.appendingPathComponent("workspaces/\(id.uuidString.lowercased())")
  try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  try Data("{}".utf8).write(to: configFolder.appendingPathComponent("workspace.json"))
  let helper = folder.appendingPathComponent("engine-stub")
  let mode = folder.appendingPathComponent("mode"); let pidFile = folder.appendingPathComponent("pid")
  try Data("ready".utf8).write(to: mode)
  let script = """
  #!/usr/bin/python3
  import socket,sys,json,os,pathlib
  mode=pathlib.Path('\(mode.path)')
  pathlib.Path('\(pidFile.path)').write_text(str(os.getpid()))
  server=socket.socket(socket.AF_UNIX);server.bind(sys.argv[-1]);server.listen(16)
  while True:
      peer,_=server.accept()
      try:
          request=json.loads(peer.makefile('rb').readline())
          if request['method']=='shutdown_if_idle':
              peer.sendall(b'{"schema_version":1,"result":{"stopping":true}}\\n');break
          state=mode.read_text()
          if state=='offline':continue
          result={'schema_version':1,'error':{'code':'service_busy','message':'busy'}} if state=='busy' else {'schema_version':1,'result':[]}
          peer.sendall((json.dumps(result)+'\\n').encode())
      finally:peer.close()
  server.close()
  """
  try Data(script.utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let runtime = WorkspaceRuntime(storageDirectory: storage, runtimeDirectory: sockets, helperURL: helper)
  let recent = RecentWorkspace(id: id, name: "Synthetic", repositoryPath: repo.path, isExample: false, lastOpened: Date())
  _ = try await runtime.openRecent(recent)
  let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
  try Data("busy".utf8).write(to: mode)
  _ = try await runtime.openRecent(recent)
  #expect(kill(pid, 0) == 0)
  try Data("offline".utf8).write(to: mode)
  do { _ = try await runtime.openRecent(recent); Issue.record("Unreachable engine unexpectedly opened") }
  catch StartupFailure.startupTimedOut {}
  #expect(kill(pid, 0) == 0)
  try Data("ready".utf8).write(to: mode)
  _ = try await runtime.openRecent(recent)
  await runtime.stopIdleServices()
  #expect(kill(pid, 0) == -1 && errno == ESRCH)
}

@Test func corruptedRecentListIsPreservedAndDoesNotBlockNewWorkspaces() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-recents-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  try Data("{broken".utf8).write(to: folder.appendingPathComponent("recent.json"))
  let runtime = WorkspaceRuntime(storageDirectory: folder)
  #expect(try await runtime.recentWorkspaces().isEmpty)
  #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).contains { $0.hasPrefix("recent-corrupt-") })
}

@Test func unsafeLegacyRuntimeNameFallsBackToPrivateUserTemporaryDirectory() throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-runtime-choice-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let legacy = folder.appendingPathComponent("legacy")
  let temporary = folder.appendingPathComponent("private-user-temp")
  try Data("occupied by an unusable entry".utf8).write(to: legacy)
  #expect(WorkspaceRuntime.defaultRuntimeDirectory(legacy: legacy, temporary: temporary) == temporary.appendingPathComponent("agw", isDirectory: true))
  try FileManager.default.removeItem(at: legacy)
  try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  #expect(WorkspaceRuntime.defaultRuntimeDirectory(legacy: legacy, temporary: temporary) == legacy)
  // The platform private-temporary path still fits Darwin's 104-byte sun_path.
  let socket = FileManager.default.temporaryDirectory.appendingPathComponent("agw/\(UUID().uuidString.lowercased()).sock")
  #expect(socket.path.utf8.count < 104)
}

@Test func simultaneousFirstOpenAcrossRuntimesKeepsOneWorkspaceIdentity() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-first-open-\(UUID().uuidString)")
  let sockets = URL(fileURLWithPath: "/tmp/agw-first-\(UUID().uuidString.prefix(8))", isDirectory: true)
  let storage = folder.appendingPathComponent("data")
  let repo = folder.appendingPathComponent("repo")
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: sockets) }
  let helper = folder.appendingPathComponent("engine-stub")
  let entered = folder.appendingPathComponent("workspace-entered")
  let release = folder.appendingPathComponent("release-workspace")
  let inspections = folder.appendingPathComponent("inspections")
  let creations = folder.appendingPathComponent("creations")
  let script = """
  #!/usr/bin/python3
  import sys,json,socket,os,pathlib,time
  base=pathlib.Path('\(folder.path)')
  if sys.argv[1]=='inspect':
      with (base/'inspections').open('a') as log:log.write('inspect\\n')
      print(json.dumps({'id':'repo','path':sys.argv[2]}));sys.exit(0)
  if sys.argv[1]=='workspace':
      with (base/'creations').open('a') as log:log.write(sys.argv[-1]+'\\n')
      (base/'workspace-entered').touch()
      deadline=time.monotonic()+5
      while not (base/'release-workspace').exists():
          if time.monotonic()>deadline:sys.exit(9)
          time.sleep(.01)
      pathlib.Path(sys.argv[-1]).write_text(json.dumps({'schema_version':1,'id':'repo','repositories':[{'id':'repo','path':sys.argv[2]}],'groups':[]}))
      print('{}');sys.exit(0)
  if sys.argv[1]!='serve':sys.exit(9)
  server=socket.socket(socket.AF_UNIX)
  try:server.bind(sys.argv[-1])
  except OSError:sys.exit(0)
  server.listen(16)
  while True:
      peer,_=server.accept()
      try:
          request=json.loads(peer.makefile('rb').readline())
          stopping=request['method']=='shutdown_if_idle'
          peer.sendall((json.dumps({'schema_version':1,'result':{'stopping':True} if stopping else []})+'\\n').encode())
          if stopping:break
      finally:peer.close()
  server.close();os.unlink(sys.argv[-1])
  """
  try Data(script.utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let first = WorkspaceRuntime(storageDirectory: storage, runtimeDirectory: sockets, helperURL: helper)
  let second = WorkspaceRuntime(storageDirectory: storage, runtimeDirectory: sockets, helperURL: helper)
  let firstOpen = Task { try await first.openRepository(repo) }
  for _ in 0..<200 {
    if FileManager.default.fileExists(atPath: entered.path) { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(FileManager.default.fileExists(atPath: entered.path))
  let secondOpen = Task { try await second.openRepository(repo) }
  for _ in 0..<200 {
    if (try? String(contentsOf: inspections, encoding: .utf8).split(separator: "\n").count) == 2 { break }
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(try String(contentsOf: inspections, encoding: .utf8).split(separator: "\n").count == 2)
  // Hold the first registration across the second runtime's completed inspect.
  // The fixed runtime must wait for the registration lock, not allocate a UUID.
  try await Task.sleep(for: .milliseconds(200))
  try Data().write(to: release)
  let (a, b) = try await (firstOpen.value, secondOpen.value)
  #expect(a.recent.id == b.recent.id)
  #expect(a.socketPath == b.socketPath)
  #expect(try String(contentsOf: creations, encoding: .utf8).split(separator: "\n").count == 1)
  let reopened = try await second.openRepository(repo)
  #expect(reopened.recent.id == a.recent.id)
  await first.stopIdleServices()
  await second.stopIdleServices()
}

@Test func repositoryRegistrationSurvivesMRUEvictionAndCorruptRecentMenu() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-registry-\(UUID().uuidString)")
  let sockets = URL(fileURLWithPath: "/tmp/agw-reg-\(UUID().uuidString.prefix(8))", isDirectory: true)
  let storage = folder.appendingPathComponent("data")
  let legacyID = UUID()
  let legacy = storage.appendingPathComponent("workspaces/\(legacyID.uuidString.lowercased())")
  let repo = legacy.appendingPathComponent("example/repo")
  let id = UUID(); let registered = storage.appendingPathComponent("workspaces/\(id.uuidString.lowercased())")
  try FileManager.default.createDirectory(at: registered, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: sockets) }
  let workspace: [String: Any] = ["schema_version": 1, "id": "repo", "repositories": [["id": "repo", "path": repo.path]], "groups": []]
  try JSONSerialization.data(withJSONObject: workspace).write(to: registered.appendingPathComponent("workspace.json"))
  try JSONSerialization.data(withJSONObject: workspace).write(to: legacy.appendingPathComponent("workspace.json"))
  try JSONSerialization.data(withJSONObject: workspace).write(to: legacy.appendingPathComponent("example/workspace.json"))
  // An example may mention the same source path but must never be migrated
  // into an ordinary registration or have its kind overwritten.
  let exampleID = UUID()
  let exampleFolder = storage.appendingPathComponent("workspaces/\(exampleID.uuidString.lowercased())")
  try FileManager.default.createDirectory(at: exampleFolder, withIntermediateDirectories: true)
  try JSONSerialization.data(withJSONObject: workspace).write(to: exampleFolder.appendingPathComponent("workspace.json"))
  let example = RecentWorkspace(id: exampleID, name: "Example", repositoryPath: repo.path, isExample: true, lastOpened: Date().addingTimeInterval(100))
  let exampleRecord = try JSONEncoder().encode(example)
  try exampleRecord.write(to: exampleFolder.appendingPathComponent("workspace-record.json"))
  // Reject an unsafe entry as a whole without blocking unrelated registration.
  for oversized in [false, true] {
    let odd = storage.appendingPathComponent("workspaces/\(UUID().uuidString.lowercased())")
    try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
    let record = odd.appendingPathComponent("workspace-record.json")
    if oversized {
      try Data(repeating: 0, count: 1024 * 1024 + 1).write(to: record)
    } else {
      try FileManager.default.createSymbolicLink(at: record, withDestinationURL: exampleFolder.appendingPathComponent("workspace-record.json"))
    }
    // Even a matching config cannot bypass an unsafe kind record.
    try JSONSerialization.data(withJSONObject: workspace).write(to: odd.appendingPathComponent("workspace.json"))
  }
  let journal = registered.appendingPathComponent("journal.sqlite")
  try Data("existing saved task and receipts".utf8).write(to: journal)
  let history = (0..<31).map { RecentWorkspace(id: UUID(), name: "Other \($0)", repositoryPath: folder.appendingPathComponent("other-\($0)").path, isExample: false, lastOpened: Date()) }
  try JSONEncoder().encode(history).write(to: storage.appendingPathComponent("recent.json"))
  let helper = folder.appendingPathComponent("engine-stub")
  let script = """
  #!/usr/bin/python3
  import sys,json,socket,os
  if sys.argv[1]=='inspect':
      print(json.dumps({'id':'repo','path':sys.argv[2]}));sys.exit(0)
  if sys.argv[1]!='serve':
      print('unexpected new workspace creation',file=sys.stderr);sys.exit(9)
  server=socket.socket(socket.AF_UNIX);server.bind(sys.argv[-1]);server.listen(16)
  while True:
      peer,_=server.accept()
      try:
          request=json.loads(peer.makefile('rb').readline())
          stopping=request['method']=='shutdown_if_idle'
          result={'stopping':True} if stopping else []
          peer.sendall((json.dumps({'schema_version':1,'result':result})+'\\n').encode())
          if stopping:break
      finally:peer.close()
  server.close();os.unlink(sys.argv[-1])
  """
  try Data(script.utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let runtime = WorkspaceRuntime(storageDirectory: storage, runtimeDirectory: sockets, helperURL: helper)
  let restored = try await runtime.openRepository(repo)
  #expect(restored.recent.id == id)
  #expect(try Data(contentsOf: exampleFolder.appendingPathComponent("workspace-record.json")) == exampleRecord)
  #expect(try String(contentsOf: journal, encoding: .utf8) == "existing saved task and receipts")
  #expect(FileManager.default.fileExists(atPath: registered.appendingPathComponent("workspace-record.json").path))
  await runtime.stopIdleServices()
  try Data("{broken menu".utf8).write(to: storage.appendingPathComponent("recent.json"))
  let reopened = try await runtime.openRepository(repo)
  #expect(reopened.recent.id == id)
  #expect(try String(contentsOf: journal, encoding: .utf8) == "existing saved task and receipts")
  await runtime.stopIdleServices()
  // A known registration with missing config must remain explicit failure,
  // preserving its journal instead of silently creating an empty replacement.
  let config = registered.appendingPathComponent("workspace.json")
  let savedConfig = try Data(contentsOf: config)
  try FileManager.default.removeItem(at: config)
  try Data("[]".utf8).write(to: storage.appendingPathComponent("recent.json"))
  let registrations = try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("workspaces").path)
  do { _ = try await runtime.openRepository(repo); Issue.record("Missing known config silently replaced") }
  catch StartupFailure.workspaceMissing {}
  #expect(try FileManager.default.contentsOfDirectory(atPath: storage.appendingPathComponent("workspaces").path).sorted() == registrations.sorted())
  #expect(try String(contentsOf: journal, encoding: .utf8) == "existing saved task and receipts")
  try savedConfig.write(to: config)
}

@Test func stalledOwnedEngineIsReclaimedAndNextOpenGetsANewProcess() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-owned-\(UUID().uuidString)")
  let sockets = URL(fileURLWithPath: "/tmp/agw-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: sockets) }
  let storage = folder.appendingPathComponent("data"); let repo = folder.appendingPathComponent("repo")
  let id = UUID(); let configFolder = storage.appendingPathComponent("workspaces/\(id.uuidString.lowercased())")
  try FileManager.default.createDirectory(at: configFolder, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  try Data("{}".utf8).write(to: configFolder.appendingPathComponent("workspace.json"))
  let helper = folder.appendingPathComponent("stalled-helper")
  let pids = folder.appendingPathComponent("pids")
  try Data("#!/bin/sh\ntrap '' TERM\nprintf '%s\\n' $$ >> '\(pids.path)'\nwhile :; do sleep 1; done\n".utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let runtime = WorkspaceRuntime(storageDirectory: storage, runtimeDirectory: sockets, helperURL: helper)
  let recent = RecentWorkspace(id: id, name: "Synthetic", repositoryPath: repo.path, isExample: false, lastOpened: Date())
  for _ in 0..<2 {
    do { _ = try await runtime.openRecent(recent); Issue.record("Stalled engine unexpectedly opened") }
    catch StartupFailure.startupTimedOut {} 
  }
  let owned = try String(contentsOf: pids, encoding: .utf8).split(separator: "\n").compactMap { Int32($0) }
  #expect(owned.count == 2); #expect(Set(owned).count == 2)
  for pid in owned { #expect(kill(pid, 0) == -1 && errno == ESRCH) }
}

@Test func bootstrapDrainsLargeStderrWhileWaitingForStdout() throws {
  let result = try HelperProcess.run(URL(fileURLWithPath: "/bin/sh"),
    ["-c", "i=0; while [ $i -lt 100 ]; do printf '%4096s' '' >&2; i=$((i+1)); done; printf result"], [:], timeout: 3)
  #expect(String(decoding: result, as: UTF8.self) == "result")
}
@Test func bootstrapRejectsOversizedOutputEvenWhenChildExitsSuccessfully() throws {
  do {
    _ = try HelperProcess.run(URL(fileURLWithPath: "/bin/sh"),
      ["-c", "i=0; while [ $i -lt 400 ]; do printf '%4096s' ''; i=$((i+1)); done"], [:], timeout: 3)
    Issue.record("Oversized bootstrap output was accepted")
  } catch StartupFailure.helper(let message) { #expect(message.contains("1 MiB")) }
}
@Test func bootstrapDeadlineStopsAnOwnedStalledHelper() throws {
  let start = ContinuousClock.now
  do {
    _ = try HelperProcess.run(URL(fileURLWithPath: "/bin/sleep"), ["30"], [:], timeout: 0.1)
    Issue.record("Stalled helper completed")
  } catch StartupFailure.startupTimedOut {}
  #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func inspectFailureUsesStructuredCodeRatherThanPathSubstring() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-inspect-code-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let helper = folder.appendingPathComponent("helper")
  for code in ["not_a_repository", "git_unavailable"] {
    let payload = "{\"error\":{\"code\":\"\(code)\",\"message\":\"could not inspect /tmp/not_a_repository/project\"}}"
    try Data("#!/bin/sh\nprintf '%s' '\(payload)' >&2\nexit 2\n".utf8).write(to: helper)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    let runtime = WorkspaceRuntime(storageDirectory: folder.appendingPathComponent("data"), helperURL: helper)
    do { _ = try await runtime.openRepository(folder); Issue.record("Inspect failure was accepted") }
    catch StartupFailure.notRepository { #expect(code == "not_a_repository") }
    catch StartupFailure.helper { #expect(code == "git_unavailable") }
  }
}

@Test func publishedExampleLookupFailureKeepsItsEngineUntilNormalShutdown() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-example-lookup-\(UUID().uuidString)")
  let sockets = URL(fileURLWithPath: "/tmp/agw-example-\(UUID().uuidString.prefix(8))", isDirectory: true)
  let storage = folder.appendingPathComponent("data"); let repo = folder.appendingPathComponent("example")
  let id = UUID(); let workspace = storage.appendingPathComponent("workspaces/\(id.uuidString.lowercased())")
  try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: sockets) }
  try Data("{}".utf8).write(to: workspace.appendingPathComponent("workspace.json"))
  let helper = folder.appendingPathComponent("engine-stub")
  let starts = folder.appendingPathComponent("starts"); let shutdown = folder.appendingPathComponent("shutdown")
  let script = """
  #!/usr/bin/python3
  import sys,json,socket,pathlib,os
  with pathlib.Path('\(starts.path)').open('a') as log:log.write('serve\\n')
  server=socket.socket(socket.AF_UNIX);server.bind(sys.argv[-1]);server.listen(16)
  while True:
      peer,_=server.accept()
      try:
          request=json.loads(peer.makefile('rb').readline())
          method=request['method']
          if method=='get_operation_by_key':
              response={'schema_version':1,'error':{'code':'service_busy','message':'busy'}}
          elif method=='shutdown_if_idle':
              pathlib.Path('\(shutdown.path)').touch()
              response={'schema_version':1,'result':{'stopping':True}}
          else:response={'schema_version':1,'result':[]}
          peer.sendall((json.dumps(response)+'\\n').encode())
          if method=='shutdown_if_idle':break
      finally:peer.close()
  server.close();os.unlink(sys.argv[-1])
  """
  try Data(script.utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let runtime = WorkspaceRuntime(storageDirectory: storage, runtimeDirectory: sockets, helperURL: helper)
  let recent = RecentWorkspace(id: id, name: "Example", repositoryPath: repo.path, isExample: true, lastOpened: Date())
  _ = try await runtime.openRecent(recent)
  do { _ = try await runtime.openExample(); Issue.record("Busy example lookup unexpectedly succeeded") }
  catch {}
  #expect(!FileManager.default.fileExists(atPath: shutdown.path))
  _ = try await runtime.openRecent(recent)
  #expect(try String(contentsOf: starts, encoding: .utf8) == "serve\n")
  await runtime.stopIdleServices()
  #expect(FileManager.default.fileExists(atPath: shutdown.path))
}

@Test func cloneHelperUsesExactArgumentsAndPreservesCompletedCloneOnRegistrationFailure() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-clone-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let destination = folder.appendingPathComponent("new project")
  let log = folder.appendingPathComponent("args.json")
  let helper = folder.appendingPathComponent("helper")
  let script = """
  #!/usr/bin/python3
  import sys,json,os,pathlib
  if sys.argv[1]=='clone':
      pathlib.Path('\(log.path)').write_text(json.dumps({'args':sys.argv[1:],'env':dict(os.environ)}))
      pathlib.Path(sys.argv[3]).mkdir()
      pathlib.Path(sys.argv[3],'saved').write_text('completed clone')
      print(json.dumps({'path':sys.argv[3]}));sys.exit(0)
  print('synthetic inspect failure',file=sys.stderr);sys.exit(7)
  """
  try Data(script.utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let storage = folder.appendingPathComponent("storage")
  let runtime = WorkspaceRuntime(storageDirectory: storage, helperURL: helper)
  do { _ = try await runtime.cloneRepository(url: "git@gitlab.example:team/repo.git", destination: destination); Issue.record("Expected registration failure") }
  catch StartupFailure.cloneCreated(let path) { #expect(path == destination.path) }
  let invocation = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: log)) as? [String: Any])
  #expect(invocation["args"] as? [String] == ["clone", "git@gitlab.example:team/repo.git", destination.path])
  let environment = try #require(invocation["env"] as? [String: String])
  #expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin")
  #expect(environment["SSH_AUTH_SOCK"] == ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"])
  #expect(environment["GIT_SSH_COMMAND"] == nil)
  #expect(try String(contentsOf: destination.appendingPathComponent("saved"), encoding: .utf8) == "completed clone")
  #expect(try await runtime.recentWorkspaces().isEmpty)
}

@Test func cloneHelperFailureDoesNotRegisterOrRemoveExistingDestination() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("agw-clone-fail-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: folder) }
  let destination = folder.appendingPathComponent("existing")
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  try Data("keep".utf8).write(to: destination.appendingPathComponent("existing.txt"))
  let helper = folder.appendingPathComponent("helper")
  try Data("#!/bin/sh\nprintf '%s' 'clone_destination_exists' >&2\nexit 2\n".utf8).write(to: helper)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
  let storage = folder.appendingPathComponent("storage")
  let runtime = WorkspaceRuntime(storageDirectory: storage, helperURL: helper)
  do { _ = try await runtime.cloneRepository(url: "https://gitlab.example/team/repo.git", destination: destination); Issue.record("Expected clone failure") }
  catch StartupFailure.cloneOutcomeUnknown {}
  #expect(try String(contentsOf: destination.appendingPathComponent("existing.txt"), encoding: .utf8) == "keep")
  #expect(!FileManager.default.fileExists(atPath: storage.path))
}
