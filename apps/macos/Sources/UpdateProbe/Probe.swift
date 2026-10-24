import AppKit
import Foundation
import Sparkle

/// A developer-only informational check. This executable never launches River.
@MainActor
private final class FeedProbe: NSObject, SPUUpdaterDelegate {
  var result: [String: Any] = ["mode": "checkForUpdateInformation", "download_or_install": false]
  var finished = false
  var accepted = false
  private var signedFeed = false
  private var found = false
  private var noUpdateReason: Int?

  func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
    guard updateCheck.rawValue == 2 else {
      throw NSError(domain: "RiverUpdateProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: "Only an informational update check is permitted"])
    }
  }
  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    signedFeed = appcast.signingValidationStatus.rawValue == 1
    result["appcast_signature_status"] = appcast.signingValidationStatus.rawValue
    result["appcast_item_count"] = appcast.items.count
  }
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    found = true
    result["status"] = "update_available"
    record(item)
  }
  func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
    let failure = error as NSError
    noUpdateReason = (failure.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)?.intValue
    result["no_update_reason"] = noUpdateReason
    if let item = failure.userInfo[SPULatestAppcastItemFoundKey] as? SUAppcastItem { record(item) }
    result["status"] = "no_update"
  }
  func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
    let failure = error as NSError
    if failure.domain != SUSparkleErrorDomain || failure.code != SUError.noUpdateError.rawValue {
      result["error_domain"] = failure.domain
      result["error_code"] = failure.code
      result["error"] = failure.localizedDescription
    }
  }
  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
    let failure = error as NSError?
    let noUpdate = failure?.domain == SUSparkleErrorDomain && failure?.code == Int(SUError.noUpdateError.rawValue)
    let validResult = found || (noUpdate && [1, 2].contains(noUpdateReason ?? -1) && result["selected_build"] != nil)
    accepted = signedFeed && validResult && (error == nil || noUpdate) && updateCheck.rawValue == 2
    result["accepted"] = accepted
    finished = true
  }
  private func record(_ item: SUAppcastItem) {
    result["selected_build"] = item.versionString
    result["selected_version"] = item.displayVersionString
    result["selected_archive_url"] = item.fileURL?.absoluteString
  }
}

@main
struct UpdateProbe {
  @MainActor
  static func main() {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--app"), args.indices.contains(index + 1),
      let host = Bundle(path: args[index + 1]), let info = host.infoDictionary,
      let domain = info["SUDefaultsDomain"] as? String, domain.hasPrefix("dev.workbench.update-probe."),
      info["SURequireSignedFeed"] as? Bool == true,
      info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
      let feed = info["SUFeedURL"] as? String,
      feed == "https://raw.githubusercontent.com/ictechgy/river/updates/appcast.xml"
    else {
      print("{\"accepted\":false,\"error\":\"Use update_smoke.py with an isolated host fixture\"}")
      exit(2)
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = FeedProbe()
    delegate.result["feed_url"] = feed
    delegate.result["host_build"] = info["CFBundleVersion"]
    let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
    let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: delegate)
    do {
      try updater.start()
      // Sparkle documents this immediate call before the next runloop cycle.
      updater.checkForUpdateInformation()
      let deadline = Date().addingTimeInterval(90)
      while !delegate.finished && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      if !delegate.finished { delegate.result["error"] = "Informational feed check timed out" }
    } catch {
      delegate.result["error"] = error.localizedDescription
    }
    // Only a unique fixture domain is ever cleaned; River preferences are untouched.
    UserDefaults.standard.removePersistentDomain(forName: domain)
    delegate.result["accepted"] = delegate.accepted
    if let data = try? JSONSerialization.data(withJSONObject: delegate.result, options: [.sortedKeys]),
      let text = String(data: data, encoding: .utf8)
    { print(text) }
    exit(delegate.accepted ? 0 : 1)
  }
}
