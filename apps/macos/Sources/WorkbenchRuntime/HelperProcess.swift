import Darwin
import Foundation

/// Bootstrap commands run off the UI actor. Drain both pipes concurrently,
/// retain at most 1 MiB each, and bound even helpers that never close a pipe.
enum HelperProcess {
  static func run(_ executable: URL, _ arguments: [String], _ environment: [String: String],
                  timeout: TimeInterval = 30) throws -> Data {
    let process = Process()
    let exit = ProcessExit()
    process.terminationHandler = { exit.complete($0.terminationStatus) }
    process.executableURL = executable; process.arguments = arguments; process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let output = Pipe(); let errors = Pipe()
    process.standardOutput = output; process.standardError = errors
    let out = HelperPipe(output.fileHandleForReading)
    let err = HelperPipe(errors.fileHandleForReading)
    try process.run()
    // Parent writers must close so EOF is observable after the child exits.
    try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
    let group = DispatchGroup()
    for reader in [out, err] {
      group.enter()
      DispatchQueue.global(qos: .userInitiated).async { reader.drain(); group.leave() }
    }
    let deadline = Date().addingTimeInterval(timeout)
    var status: Int32?
    var timedOut = false
    while status == nil {
      status = exit.waitBlocking(until: Date().addingTimeInterval(0.05))
      if out.exceeded || err.exceeded || Date() >= deadline {
        timedOut = Date() >= deadline
        if process.isRunning { process.terminate() }
        status = exit.waitBlocking(until: Date().addingTimeInterval(0.25))
        if status == nil, process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        status = exit.waitBlocking(until: Date().addingTimeInterval(1))
        break
      }
    }
    let drained = group.wait(timeout: .now() + .seconds(1)) == .success
    if !drained { out.stop(); err.stop(); group.wait() }
    if timedOut { throw StartupFailure.startupTimedOut }
    if out.exceeded || err.exceeded { throw StartupFailure.helper("작업 엔진의 출력이 1 MiB 제한을 넘었습니다.") }
    guard drained, !out.failed, !err.failed, let status else { throw StartupFailure.helper("작업 엔진의 출력이 완전히 도착하지 않았습니다.") }
    guard status == 0 else {
      if let payload = try? JSONSerialization.jsonObject(with: err.data) as? [String: Any],
        let failure = payload["error"] as? [String: Any], let code = failure["code"] as? String
      {
        if arguments.first == "inspect", code == "not_a_repository" { throw StartupFailure.notRepository }
        if code == "unsupported_external_filter" { throw StartupFailure.externalFilters }
        if code == "unsafe_source_repository" { throw StartupFailure.unsafeRepository }
        if arguments.first == "clone" { throw StartupFailure.remote(code) }
      }
      throw StartupFailure.helper(String(String(decoding: err.data, as: UTF8.self).prefix(2_000)))
    }
    return out.data
  }
}

private final class HelperPipe: @unchecked Sendable {
  private let handle: FileHandle
  private let lock = NSLock()
  private var bytes = Data()
  private var stopped = false
  private var overflow = false
  private var readFailed = false
  init(_ handle: FileHandle) { self.handle = handle }
  var exceeded: Bool { lock.withLock { overflow } }
  var failed: Bool { lock.withLock { readFailed } }
  var data: Data { lock.withLock { bytes } }
  func stop() { lock.withLock { stopped = true } }
  func drain() {
    defer { try? handle.close() }
    var buffer = [UInt8](repeating: 0, count: 8192)
    while !lock.withLock({ stopped }) {
      var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
      let ready = Darwin.poll(&descriptor, 1, 50)
      if ready < 0 { if errno == EINTR { continue }; lock.withLock { readFailed = true }; return }
      if ready == 0 { continue }
      let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
      if count == 0 { return }
      if count < 0 { if errno == EINTR { continue }; lock.withLock { readFailed = true }; return }
      lock.withLock {
        let keep = min(count, 1024 * 1024 - bytes.count)
        bytes.append(contentsOf: buffer.prefix(keep)); overflow = overflow || keep < count
      }
    }
  }
}
