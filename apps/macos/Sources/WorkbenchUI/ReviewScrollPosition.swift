import AppKit
import SwiftUI

/// Keeps scrolling out of the observable Git store: wheel movement must not
/// republish/reparse the entire workspace. Uses our own diff's enclosing scroll.
struct ReviewScrollPosition: NSViewRepresentable {
  let store: WorkbenchStore
  let id: ReviewFileID
  let content: String
  let enabled: Bool

  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.identifier = NSUserInterfaceItemIdentifier("workbench.diff-scroll-position")
    return view
  }
  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.configure(store: store, id: id, content: content, enabled: enabled)
    DispatchQueue.main.async { [weak view, weak coordinator] in
      guard let view else { return }
      coordinator?.attach(to: view.enclosingScrollView)
    }
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

  @MainActor final class Coordinator: NSObject {
    private weak var store: WorkbenchStore?
    private weak var scroll: NSScrollView?
    private var id: ReviewFileID?
    private var content = ""
    private var enabled = true
    private var restoreNeeded = true
    private var restoring = false
    private var liveScrolling = false

    func configure(store: WorkbenchStore, id: ReviewFileID, content: String, enabled: Bool) {
      if self.id != id || self.content != content || self.enabled != enabled {
        restoreNeeded = true
      }
      self.store = store
      self.id = id
      self.content = content
      self.enabled = enabled
    }
    func attach(to candidate: NSScrollView?) {
      guard let candidate else { return }
      if scroll !== candidate {
        detach()
        scroll = candidate
        restoreNeeded = true
        candidate.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
          self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification,
          object: candidate.contentView)
        NotificationCenter.default.addObserver(
          self, selector: #selector(liveScroll), name: NSScrollView.didLiveScrollNotification,
          object: candidate)
        NotificationCenter.default.addObserver(
          self, selector: #selector(endScroll), name: NSScrollView.didEndLiveScrollNotification,
          object: candidate)
      }
      guard restoreNeeded, let id, let store else { return }
      restoreNeeded = false
      restoring = true
      candidate.layoutSubtreeIfNeeded()
      let y = enabled ? store.reviewOffset(content: content, at: id) : 0
      let maximum = max(0, (candidate.documentView?.frame.height ?? 0) - candidate.contentView.bounds.height)
      candidate.contentView.scroll(to: NSPoint(x: candidate.contentView.bounds.minX, y: min(y, maximum)))
      candidate.reflectScrolledClipView(candidate.contentView)
      restoring = false
    }
    func detach() {
      NotificationCenter.default.removeObserver(self)
      scroll = nil
      liveScrolling = false
    }
    @objc private func liveScroll() { liveScrolling = true; record() }
    @objc private func endScroll() { record(); liveScrolling = false }
    @objc private func boundsChanged() {
      // Layout changes/unmounting can clamp an old view to zero; they are not
      // new reading positions. Keyboard and scrollbar scrolling still count.
      let event = NSApplication.shared.currentEvent?.type
      if liveScrolling || event == .scrollWheel || event == .keyDown || event == .leftMouseDragged {
        record()
      }
    }
    private func record() {
      guard enabled, !restoring, let id, let scroll, scroll.window != nil else { return }
      store?.rememberReviewOffset(scroll.contentView.bounds.minY, content: content, at: id)
    }
  }
}
