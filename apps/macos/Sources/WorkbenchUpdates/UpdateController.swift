import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

/// Bundle configuration is trusted only in an installed application, never a SwiftPM executable.
struct UpdateConfiguration: Equatable {
  static let applicationIdentifier = "dev.workbench.AgentGitWorkbench"
  let feedURL: URL
  let publicKey: String

  init?(bundleURL: URL, executableURL: URL?, info: [String: Any]) {
    guard bundleURL.pathExtension == "app", info["CFBundlePackageType"] as? String == "APPL",
      info["CFBundleIdentifier"] as? String == Self.applicationIdentifier,
      let executableURL,
      executableURL.deletingLastPathComponent().standardizedFileURL.path
        == bundleURL.appendingPathComponent("Contents/MacOS").standardizedFileURL.path,
      let feed = info["SUFeedURL"] as? String, let url = URL(string: feed),
      url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
      let key = info["SUPublicEDKey"] as? String,
      Data(base64Encoded: key)?.count == 32
    else { return nil }
    feedURL = url
    publicKey = key
  }
}

@MainActor
protocol UpdateBackend: AnyObject {
  var canCheck: Bool { get }
  var automaticChecks: Bool { get set }
  var lastCheck: Date? { get }
  var changed: (@MainActor () -> Void)? { get set }
  func start() throws
  func check()
}

@MainActor
private final class SparkleBackend: UpdateBackend {
  private let controller: SPUStandardUpdaterController
  private var observations: [NSKeyValueObservation] = []
  var changed: (@MainActor () -> Void)?
  var canCheck: Bool { controller.updater.canCheckForUpdates }
  var automaticChecks: Bool {
    get { controller.updater.automaticallyChecksForUpdates }
    set { controller.updater.automaticallyChecksForUpdates = newValue }
  }
  var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

  init(delegate: any SPUUpdaterDelegate) {
    controller = SPUStandardUpdaterController(
      startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: nil)
    observations = [
      controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.changed?() }
      },
      controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) {
        [weak self] _, _ in
        Task { @MainActor [weak self] in self?.changed?() }
      },
      controller.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] _, _ in
        Task { @MainActor [weak self] in self?.changed?() }
      },
    ]
  }
  func start() throws { try controller.updater.start() }
  func check() { controller.checkForUpdates(nil) }
}

/// A postponed Sparkle callback must remain reachable while the user continues working.
/// Eligibility is read again after the confirmation dialog and at application termination.
@MainActor
final class UpdateRestartGate {
  var blocker: () -> String? = { "앱이 시작되는 중입니다. 잠시 후 다시 시도해 주세요." }
  var warning: () -> String? = { nil }
  var confirm: (String?) -> Bool = { _ in false }
  private(set) var pendingInstall: (() -> Void)?
  private(set) var installationIntended = false
  private var consented = false
  private var consentedWarning: String?

  var isPending: Bool { pendingInstall != nil }
  func postpone(_ install: @escaping () -> Void) {
    pendingInstall = install
    installationIntended = true
    consented = false
  }
  func markInstallation() { installationIntended = true }
  func reset() {
    pendingInstall = nil
    installationIntended = false
    consented = false
  }
  /// nil is success; a message explains why installation remains postponed.
  @discardableResult
  func resume() -> String? {
    guard let install = pendingInstall else { return nil }
    if let reason = blocker() { return reason }
    let currentWarning = warning()
    guard confirm(currentWarning) else { return "업데이트 설치를 미뤘습니다. 작업을 계속한 뒤 다시 시도할 수 있습니다." }
    // NSAlert's nested event loop can admit new work while the dialog is open.
    if let reason = blocker() { return reason }
    guard warning() == currentWarning else {
      return "확인 중 변경 요청의 상태가 바뀌었습니다. 알림을 검토한 뒤 다시 시도해 주세요."
    }
    consented = true
    consentedWarning = currentWarning
    install()
    return nil
  }
  func permitsTermination() -> Bool {
    guard installationIntended else { return true }
    guard blocker() == nil else {
      consented = false
      return false
    }
    let currentWarning = warning()
    if !consented || consentedWarning != currentWarning {
      guard confirm(currentWarning) else { return false }
      guard blocker() == nil, warning() == currentWarning else { return false }
      consented = true
      consentedWarning = currentWarning
    }
    return true
  }
  func terminationWasCancelled() { consented = false }
}

@MainActor
public final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
  @Published public private(set) var canCheckForUpdates = false
  @Published public private(set) var automaticallyChecksForUpdates = false
  @Published public private(set) var lastCheckDate: Date?
  @Published public private(set) var isAvailable = false
  @Published public private(set) var installationPending = false
  @Published public private(set) var status =
    "이 실행본에는 업데이트 설정이 없습니다. GitHub에서 배포한 River 앱을 설치해 주세요."
  private let configuration: UpdateConfiguration?
  private var backend: (any UpdateBackend)?
  private var started = false
  private var presentingRestart = false
  private let restart: UpdateRestartGate

  public override init() {
    let bundle = Bundle.main
    configuration = UpdateConfiguration(
      bundleURL: bundle.bundleURL, executableURL: bundle.executableURL,
      info: bundle.infoDictionary ?? [:])
    restart = UpdateRestartGate()
    super.init()
    restart.confirm = Self.confirmRestart
  }
  // No Sparkle instance or network requests are made by the test backend.
  init(backend: any UpdateBackend, restart: UpdateRestartGate) {
    configuration = nil
    self.backend = backend
    self.restart = restart
    super.init()
  }

  public func configureRestartSafety(
    blocker: @escaping @MainActor () -> String?, warning: @escaping @MainActor () -> String?
  ) {
    restart.blocker = blocker
    restart.warning = warning
  }
  public func start() {
    guard !started else { return }
    started = true
    guard configuration != nil || backend != nil else { return }
    if backend == nil { backend = SparkleBackend(delegate: self) }
    backend?.changed = { [weak self] in self?.refresh() }
    do {
      try backend?.start()
      isAvailable = true
      status = "새 버전을 자동으로 확인하고, 설치 전에는 승인을 받습니다."
    } catch {
      status = "업데이트를 시작하지 못했습니다. 앱을 다시 열거나 최신 배포 앱을 설치해 주세요."
      backend = nil
    }
    refresh()
  }
  private func refresh() {
    canCheckForUpdates = isAvailable && (restart.isPending || backend?.canCheck == true)
    automaticallyChecksForUpdates = backend?.automaticChecks ?? false
    lastCheckDate = backend?.lastCheck
    installationPending = restart.isPending
  }
  public func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
    guard isAvailable else { return }
    // Only an explicit user change writes Sparkle's persisted preference.
    backend?.automaticChecks = enabled
    refresh()
  }
  public func checkForUpdates() {
    guard canCheckForUpdates else { return }
    if restart.isPending { requestRestart() } else { backend?.check() }
  }
  private func requestRestart() {
    guard !presentingRestart else { return }
    presentingRestart = true
    defer {
      presentingRestart = false
      refresh()
    }
    if let message = restart.resume() {
      status = message
      if restart.blocker() != nil { Self.showPostponed(message) }
    } else {
      status = "업데이트를 설치하기 위해 River를 재시작하고 있습니다."
    }
  }
  /// Also covers Sparkle's resumed / quit-install paths that bypass the postpone delegate.
  public func permitsApplicationTermination() -> Bool {
    let allowed = restart.permitsTermination()
    if !allowed {
      restart.terminationWasCancelled()
      status = restart.blocker() ?? "업데이트 설치를 미뤘습니다. 작업을 계속할 수 있습니다."
      if let blocker = restart.blocker() { Self.showPostponed(blocker) }
      refresh()
    }
    return allowed
  }
  private static func confirmRestart(_ warning: String?) -> Bool {
    let alert = NSAlert()
    alert.messageText = "업데이트를 설치하고 River를 재시작할까요?"
    alert.informativeText =
      "저장하지 않은 커밋 메시지, 작업 정보, 새 작업 입력 등 앱의 임시 입력은 사라질 수 있습니다. 필요한 내용을 저장하거나 복사한 뒤 재시작하세요. Git 파일과 커밋은 유지됩니다."
    if let warning {
      alert.informativeText += "\n\n" + warning + "\n\n위 요청의 실제 상태를 확인했고 재시작해도 안전할 때만 계속하세요."
    }
    alert.addButton(withTitle: warning == nil ? "설치 및 재시작" : "실제 상태 확인 후 재시작")
    alert.addButton(withTitle: "나중에")
    alert.alertStyle = .warning
    return alert.runModal() == .alertFirstButtonReturn
  }
  private static func showPostponed(_ reason: String) {
    let alert = NSAlert()
    alert.messageText = "업데이트 재시작을 미뤘습니다"
    alert.informativeText = reason + "\n작업을 마친 뒤 River 메뉴의 ‘업데이트 확인…’ 또는 설정에서 설치를 다시 시도하세요."
    alert.addButton(withTitle: "계속 작업")
    alert.runModal()
  }

  public func updater(
    _ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
    untilInvokingBlock installHandler: @escaping () -> Void
  ) -> Bool {
    postponeInstallation(installHandler)
    // Return before showing UI: Sparkle must retain its postponed driver first.
    Task { @MainActor [weak self] in self?.requestRestart() }
    return true
  }
  func postponeInstallation(_ install: @escaping () -> Void) {
    restart.postpone(install)
    status = "업데이트를 설치할 준비가 되었습니다. 재시작 전에 작업을 저장해 주세요."
    refresh()
  }
  public func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
    restart.markInstallation()
  }
  public func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    finishUpdateCycle(error: error)
  }
  public func updater(
    _ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
    error: (any Error)?
  ) {
    finishUpdateCycle(error: error)
  }
  func finishUpdateCycle(error: (any Error)?) {
    if let error {
      restart.reset()
      let failure = error as NSError
      if failure.domain == SUSparkleErrorDomain && failure.code == SUError.noUpdateError.rawValue {
        status = "현재 환경에서 설치할 새 버전이 없습니다."
      } else if failure.domain == SUSparkleErrorDomain
        && failure.code == SUError.installationCanceledError.rawValue
      {
        status = "업데이트 설치를 취소했습니다. 나중에 다시 확인할 수 있습니다."
      } else {
        status = "업데이트를 확인하거나 설치하지 못했습니다. 잠시 후 다시 시도해 주세요."
      }
    } else if !restart.isPending && !restart.installationIntended {
      restart.reset()
      status = "확인을 마쳤습니다. 새 버전이 있으면 업데이트 창에서 설치할 수 있습니다."
    }
    refresh()
  }
}

public struct UpdateSettingsView: View {
  @ObservedObject private var updates: UpdateController
  public init(updates: UpdateController) { self.updates = updates }
  public var body: some View {
    Form {
      Toggle(
        "자동으로 업데이트 확인",
        isOn: Binding(
          get: { updates.automaticallyChecksForUpdates },
          set: { updates.setAutomaticallyChecksForUpdates($0) }
        )
      ).disabled(!updates.isAvailable)
      LabeledContent("마지막 확인") {
        if let date = updates.lastCheckDate {
          Text(date, format: .dateTime.year().month().day().hour().minute())
        } else {
          Text("아직 확인하지 않음").foregroundStyle(.secondary)
        }
      }
      Text(updates.status).font(.callout).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
      Button(updates.installationPending ? "업데이트 설치 및 재시작…" : "업데이트 확인…") {
        updates.checkForUpdates()
      }.disabled(!updates.canCheckForUpdates)
    }
    .formStyle(.grouped)
    .padding()
    .frame(width: 460)
  }
}
