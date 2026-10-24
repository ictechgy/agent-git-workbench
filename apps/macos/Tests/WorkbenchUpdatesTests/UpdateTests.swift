import Foundation
import Sparkle
import Testing

@testable import WorkbenchUpdates

private func configurationInfo() -> [String: Any] {
  [
    "CFBundlePackageType": "APPL", "CFBundleIdentifier": "dev.workbench.AgentGitWorkbench",
    "SUFeedURL": "https://raw.githubusercontent.com/ictechgy/river/updates/appcast.xml",
    "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
  ]
}

@Test func updaterRequiresPackagedApplicationAndSigningConfiguration() {
  let app = URL(fileURLWithPath: "/Applications/River.app")
  let executable = app.appendingPathComponent("Contents/MacOS/AgentGitWorkbench")
  #expect(
    UpdateConfiguration(bundleURL: app, executableURL: executable, info: configurationInfo()) != nil
  )
  #expect(
    UpdateConfiguration(
      bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"), executableURL: executable,
      info: configurationInfo()) == nil)
  #expect(
    UpdateConfiguration(
      bundleURL: app, executableURL: URL(fileURLWithPath: "/tmp/AgentGitWorkbench"),
      info: configurationInfo()) == nil)
  for (key, value) in [
    ("CFBundleIdentifier", "other.application"), ("SUFeedURL", "http://example.com/feed.xml"),
    ("SUFeedURL", "https://user:secret@example.com/feed.xml"), ("SUPublicEDKey", "invalid"),
    ("SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString()),
  ] {
    var info = configurationInfo()
    info[key] = value
    #expect(UpdateConfiguration(bundleURL: app, executableURL: executable, info: info) == nil)
  }
}

@MainActor
private final class FakeBackend: UpdateBackend {
  var canCheck = true
  var automaticChecks = false { didSet { preferenceWrites += 1 } }
  var lastCheck: Date?
  var changed: (@MainActor () -> Void)?
  var starts = 0
  var checks = 0
  var preferenceWrites = 0
  var shouldFail = false
  func start() throws {
    starts += 1
    if shouldFail { throw CocoaError(.fileReadCorruptFile) }
  }
  func check() { checks += 1 }
}

@Test @MainActor func updaterStartsOnceAndNeverOverwritesUserPreference() {
  let backend = FakeBackend()
  let gate = UpdateRestartGate()
  let updates = UpdateController(backend: backend, restart: gate)
  updates.checkForUpdates()
  #expect(backend.checks == 0)
  updates.start()
  updates.start()
  #expect(backend.starts == 1)
  #expect(updates.isAvailable && updates.canCheckForUpdates)
  #expect(!updates.automaticallyChecksForUpdates)
  #expect(backend.preferenceWrites == 0)
  updates.setAutomaticallyChecksForUpdates(true)
  #expect(backend.automaticChecks && backend.preferenceWrites == 1)
  updates.checkForUpdates()
  #expect(backend.checks == 1)
}

@Test @MainActor func updaterTracksBackendAvailabilityAndLastCheck() {
  let backend = FakeBackend()
  let updates = UpdateController(backend: backend, restart: UpdateRestartGate())
  updates.start()
  backend.canCheck = false
  backend.lastCheck = Date(timeIntervalSince1970: 100)
  backend.changed?()
  #expect(!updates.canCheckForUpdates)
  #expect(updates.lastCheckDate == backend.lastCheck)
  updates.checkForUpdates()
  #expect(backend.checks == 0)
  backend.canCheck = true
  backend.changed?()
  updates.checkForUpdates()
  #expect(backend.checks == 1)
}

@Test @MainActor func failedOrDevelopmentStartupCannotCheckOrChangePreferences() {
  let backend = FakeBackend()
  backend.shouldFail = true
  let updates = UpdateController(backend: backend, restart: UpdateRestartGate())
  updates.start()
  updates.checkForUpdates()
  updates.setAutomaticallyChecksForUpdates(true)
  #expect(!updates.isAvailable && !updates.canCheckForUpdates)
  #expect(backend.checks == 0 && backend.preferenceWrites == 0)
  let development = UpdateController()
  development.start()
  development.checkForUpdates()
  #expect(!development.isAvailable && !development.canCheckForUpdates)
}

@Test @MainActor func postponedInstallRemainsReachableWhenSparkleCannotStartAnotherCheck() {
  let backend = FakeBackend()
  backend.canCheck = false
  let gate = UpdateRestartGate()
  gate.blocker = { nil }
  gate.confirm = { _ in false }
  let updates = UpdateController(backend: backend, restart: gate)
  updates.start()
  var installs = 0
  updates.postponeInstallation { installs += 1 }
  #expect(updates.canCheckForUpdates && updates.installationPending)
  updates.checkForUpdates()
  #expect(installs == 0 && backend.checks == 0)
  #expect(updates.installationPending && updates.canCheckForUpdates)
  gate.confirm = { _ in true }
  updates.checkForUpdates()
  #expect(installs == 1 && backend.checks == 0)
}

@Test @MainActor func busyInstallNeverRequestsDraftConsentOrInvokesCallback() {
  let gate = UpdateRestartGate()
  var busy = true
  var confirmations = 0
  var installs = 0
  gate.blocker = { busy ? "A remote mutation is still running" : nil }
  gate.confirm = { _ in
    confirmations += 1
    return true
  }
  gate.postpone { installs += 1 }
  #expect(gate.resume() != nil)
  #expect(gate.isPending && confirmations == 0 && installs == 0)
  busy = false
  #expect(gate.resume() == nil)
  #expect(confirmations == 1 && installs == 1)
}

@Test @MainActor func installRechecksActivityAfterModalConfirmationAndAtTermination() {
  let gate = UpdateRestartGate()
  var busy = false
  var installs = 0
  gate.blocker = { busy ? "New work started" : nil }
  gate.confirm = { _ in
    busy = true
    return true
  }
  gate.postpone { installs += 1 }
  #expect(gate.resume() == "New work started")
  #expect(installs == 0 && gate.isPending)
  busy = false
  gate.confirm = { _ in true }
  #expect(gate.resume() == nil && installs == 1)
  busy = true
  #expect(!gate.permitsTermination())
  gate.terminationWasCancelled()
  busy = false
  #expect(gate.resume() == nil && installs == 2)
  #expect(gate.permitsTermination())
}

@Test @MainActor func resumedInstallWithoutPostponeStillRequiresConsentAndFreshEligibility() {
  let gate = UpdateRestartGate()
  var busy = false
  var consent = false
  var confirmations = 0
  gate.blocker = { busy ? "Unresolved write" : nil }
  gate.confirm = { _ in
    confirmations += 1
    return consent
  }
  #expect(gate.permitsTermination())  // Ordinary quitting keeps its existing behavior.
  gate.markInstallation()
  busy = true
  #expect(!gate.permitsTermination() && confirmations == 0)
  busy = false
  #expect(!gate.permitsTermination() && confirmations == 1)
  consent = true
  #expect(gate.permitsTermination() && confirmations == 2)
  busy = true
  #expect(!gate.permitsTermination())
}

@Test @MainActor func cancelledOrAbortedInstallDoesNotPreventLaterWorkOrChecks() {
  let gate = UpdateRestartGate()
  gate.blocker = { nil }
  gate.confirm = { _ in false }
  var installs = 0
  gate.postpone { installs += 1 }
  #expect(gate.resume() != nil && installs == 0)
  #expect(gate.isPending)
  gate.reset()
  #expect(!gate.isPending && !gate.installationIntended)
  #expect(gate.permitsTermination())
}

@Test @MainActor func updateCycleCompletionPreservesDeferredInstallAndRecoversAfterAbort() {
  let backend = FakeBackend()
  backend.canCheck = false
  let gate = UpdateRestartGate()
  gate.blocker = { nil }
  gate.confirm = { _ in false }
  let updates = UpdateController(backend: backend, restart: gate)
  updates.start()
  updates.postponeInstallation {}
  updates.finishUpdateCycle(error: nil)
  #expect(updates.installationPending && updates.canCheckForUpdates)
  backend.canCheck = true
  updates.finishUpdateCycle(
    error: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
  #expect(!updates.installationPending && updates.canCheckForUpdates)
  #expect(updates.status.contains("새 버전이 없습니다"))
  #expect(gate.permitsTermination())
  updates.postponeInstallation {}
  updates.finishUpdateCycle(error: CocoaError(.fileReadCorruptFile))
  #expect(!updates.installationPending && updates.canCheckForUpdates)
  // A completed cycle may leave installation scheduled, including a resumed path
  // that bypassed the postpone delegate. The termination backstop must survive it.
  gate.markInstallation()
  gate.blocker = { "A new write started" }
  updates.finishUpdateCycle(error: nil)
  #expect(gate.installationIntended)
  #expect(!gate.permitsTermination())
}

@Test @MainActor func uncertainOutcomeNeedsExplicitCurrentConsentWithoutClearingWarnings() {
  let gate = UpdateRestartGate()
  gate.blocker = { nil }
  var warning = "Uncertain push in the original workspace"
  var acknowledged: [String?] = []
  var installs = 0
  gate.warning = { RestartConsentSnapshot(message: warning, identity: []) }
  gate.confirm = {
    acknowledged.append($0)
    return true
  }
  gate.postpone { installs += 1 }
  #expect(gate.resume() == nil && installs == 1)
  #expect(acknowledged == [warning])
  #expect(warning == "Uncertain push in the original workspace")
  warning = "Another uncertain write arrived"
  #expect(gate.permitsTermination())
  #expect(acknowledged == ["Uncertain push in the original workspace", warning])
  gate.terminationWasCancelled()
  gate.confirm = { _ in
    warning = "Warning changed while confirming"
    return true
  }
  #expect(gate.resume() != nil)
  #expect(installs == 1)
}

@Test(arguments: ["same-origin", "fifth-hidden-origin"]) @MainActor
func unchangedDisplayForNewUncertainWriteRequiresFreshTerminationConsent(scenario: String) {
  let gate = UpdateRestartGate()
  gate.blocker = { nil }
  var identity = ["context-write:1", scenario]
  let unchangedDisplay = "The original four warning origins are still shown"
  // The complete opaque identity crosses the same bridge as the bounded copy.
  gate.warning = { RestartConsentSnapshot(message: unchangedDisplay, identity: identity) }
  var confirmations = 0
  gate.confirm = { _ in
    confirmations += 1
    return true
  }
  gate.postpone {}
  #expect(gate.resume() == nil && confirmations == 1)
  identity[0] = "context-write:2"
  #expect(identity[0] == "context-write:2")
  #expect(gate.permitsTermination())
  #expect(confirmations == 2)
  gate.terminationWasCancelled()
  gate.confirm = { _ in
    identity[0] = "context-write:3"
    return true
  }
  #expect(gate.resume() != nil)  // An identity change inside the modal also invalidates consent.
}
