import Darwin
import Foundation
import Testing
@testable import WorkbenchProtocol

private struct DeliveryFailureCase: Sendable {
  let failure: TransportFailure
  let mayHaveBeenSent: Bool
}

@Test(arguments: [
  DeliveryFailureCase(failure: .invalidSocketPath, mayHaveBeenSent: false),
  DeliveryFailureCase(failure: .oversizedRequest, mayHaveBeenSent: false),
  DeliveryFailureCase(failure: .system("socket", EMFILE), mayHaveBeenSent: false),
  DeliveryFailureCase(failure: .system("timeout 설정", EINVAL), mayHaveBeenSent: false),
  DeliveryFailureCase(failure: .system("연결", ECONNREFUSED), mayHaveBeenSent: false),
  DeliveryFailureCase(failure: .system("전송", EPIPE), mayHaveBeenSent: true),
  DeliveryFailureCase(failure: .system("수신", EAGAIN), mayHaveBeenSent: true),
  DeliveryFailureCase(failure: .system("unrecognized phase", EIO), mayHaveBeenSent: true),
  DeliveryFailureCase(failure: .invalidReply, mayHaveBeenSent: true),
  DeliveryFailureCase(failure: .oversizedReply, mayHaveBeenSent: true),
  DeliveryFailureCase(failure: .unsupportedSchema(2), mayHaveBeenSent: true),
])
private func transportDeliveryClassificationOnlyExcludesProvenUnsentFailures(value: DeliveryFailureCase) {
  #expect(value.failure.requestMayHaveBeenSent == value.mayHaveBeenSent)
}

// Only a new private Unix socket is used; no application service or user repo.
private final class ReplyServer: @unchecked Sendable {
  let path = "/tmp/agw-test-\(UUID().uuidString.prefix(12)).sock"
  private let listener: Int32
  private let lock = NSLock()
  private var receivedRequests = 0
  var receivedCount: Int { lock.withLock { receivedRequests } }
  var received: Bool { receivedCount > 0 }
  init(reply: Data?, connections: Int = 1) throws {
    listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw POSIXError(.EIO) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: Array(path.utf8) + [0])
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard bound == 0, Darwin.listen(listener, 4) == 0 else {
      Darwin.close(listener)
      throw POSIXError(.EIO)
    }
    for _ in 0..<connections {
      DispatchQueue.global().async { [self] in
        let client = Darwin.accept(listener, nil, nil)
        guard client >= 0 else { return }
        defer { Darwin.close(client) }
        var noSignal: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
          let count = Darwin.recv(client, &buffer, buffer.count, 0)
          if count <= 0 { return }
          if buffer[..<count].contains(0x0A) { break }
        }
        lock.withLock { receivedRequests += 1 }
        if let reply {
          reply.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
              let count = Darwin.send(client, bytes.baseAddress!.advanced(by: offset), min(4096, bytes.count - offset), 0)
              if count <= 0 { break }
              offset += count
            }
          }
        } else {
          // EOF proves cancellation woke the blocked client without its 30s timeout.
          _ = Darwin.recv(client, &buffer, buffer.count, 0)
        }
      }
    }
  }
  deinit { Darwin.close(listener); Darwin.unlink(path) }
}

@Test func multiMegabyteFragmentedReplyIsDecodedWithTrailingBytesIgnored() async throws {
  let expected = String(repeating: "x", count: 4 * 1024 * 1024)
  var payload = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "result": expected])
  payload.append(contentsOf: Array("\nignored after frame".utf8))
  let server = try ReplyServer(reply: payload)
  let value: String = try await ServiceClient(socketPath: server.path).call("synthetic_large_reply")
  #expect(value == expected)
}

@Test func cancellationInterruptsAWaitingSocket() async throws {
  let server = try ReplyServer(reply: nil)
  let task = Task { () -> String in
    try await ServiceClient(socketPath: server.path).call("synthetic_delayed_reply")
  }
  let deadline = ContinuousClock.now + .seconds(2)
  while !server.received, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(server.received)
  let start = ContinuousClock.now
  task.cancel()
  do { _ = try await task.value; Issue.record("Cancelled socket returned a value") }
  catch is CancellationError {}
  #expect(ContinuousClock.now - start < .seconds(1))
}

private actor CallCompletion {
  var started = false
  var finished = false
  func start() { started = true }
  func finish() { finished = true }
}

@Test func cancellationDoesNotWaitForASaturatedIOQueue() async throws {
  let server = try ReplyServer(reply: nil, connections: 4)
  let client = ServiceClient(socketPath: server.path)
  let running = (0..<4).map { _ in
    Task { () -> String in try await client.call("hold_slot") }
  }
  let deadline = ContinuousClock.now + .seconds(3)
  while server.receivedCount < 4, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(server.receivedCount == 4)
  let otherServer = try ReplyServer(reply: Data("{\"schema_version\":1,\"result\":\"independent\"}\n".utf8))
  let independentCompletion = CallCompletion()
  let independent = Task {
    let value: String = try await ServiceClient(socketPath: otherServer.path, timeoutSeconds: 1).call("independent_socket")
    #expect(value == "independent")
    await independentCompletion.finish()
  }
  let independentDeadline = ContinuousClock.now + .seconds(1)
  while !(await independentCompletion.finished), ContinuousClock.now < independentDeadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  let independentFinishedBeforeReleasingSlots = await independentCompletion.finished
  if !independentFinishedBeforeReleasingSlots { independent.cancel() }
  let completion = CallCompletion()
  let queued = Task {
    await completion.start()
    do {
      let _: String = try await client.call("queued_call")
      Issue.record("Cancelled queued call succeeded")
    } catch is CancellationError {} catch { Issue.record("Unexpected cancellation error: \(error)") }
    await completion.finish()
  }
  while !(await completion.started) { await Task.yield() }
  try await Task.sleep(for: .milliseconds(30))
  queued.cancel()
  let cancelDeadline = ContinuousClock.now + .milliseconds(300)
  while !(await completion.finished), ContinuousClock.now < cancelDeadline {
    try await Task.sleep(for: .milliseconds(5))
  }
  let completedBeforeReleasingSlots = await completion.finished
  // Release held slots even on a regression; the test fails rather than hanging.
  for task in running { task.cancel() }
  for task in running { _ = try? await task.value }
  await queued.value
  _ = try? await independent.value
  #expect(independentFinishedBeforeReleasingSlots)
  #expect(completedBeforeReleasingSlots)
}
