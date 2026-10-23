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
    coordinator.scheduleAttach(to: view)
  }
  static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

  @MainActor final class Coordinator: NSObject {
    private weak var store: WorkbenchStore?
    private weak var scroll: NSScrollView?
    private weak var document: NSView?
    private var attachmentVersion = UUID()
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
    func scheduleAttach(to view: NSView) {
      let version = UUID()
      attachmentVersion = version
      DispatchQueue.main.async { [weak view, weak self] in
        guard let self, let view, self.attachmentVersion == version else { return }
        self.attach(to: view.enclosingScrollView)
      }
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
          self, selector: #selector(beginScroll), name: NSScrollView.willStartLiveScrollNotification,
          object: candidate)
        NotificationCenter.default.addObserver(
          self, selector: #selector(liveScroll), name: NSScrollView.didLiveScrollNotification,
          object: candidate)
        NotificationCenter.default.addObserver(
          self, selector: #selector(endScroll), name: NSScrollView.didEndLiveScrollNotification,
          object: candidate)
      }
      if document !== candidate.documentView {
        if let document {
          NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: document)
        }
        document = candidate.documentView
        document?.postsFrameChangedNotifications = true
        if let document {
          NotificationCenter.default.addObserver(self, selector: #selector(documentChanged),
            name: NSView.frameDidChangeNotification, object: document)
        }
      }
      restore()
    }
    private func restore() {
      guard restoreNeeded, !restoring, let candidate = scroll, let id, let store else { return }
      restoring = true
      defer { restoring = false }
      candidate.layoutSubtreeIfNeeded()
      let y = enabled ? store.reviewOffset(content: content, at: id) : 0
      let height = candidate.documentView?.frame.height ?? 0
      let viewport = candidate.contentView.bounds.height
      let maximum = max(0, height - viewport)
      // SwiftUI can attach the background before its document has grown to
      // the diff's height. Retry on layout instead of consuming the checkpoint.
      guard viewport > 0, height > 0, y == 0 || maximum > 0 else { return }
      candidate.contentView.scroll(to: NSPoint(x: candidate.contentView.bounds.minX, y: min(y, maximum)))
      candidate.reflectScrolledClipView(candidate.contentView)
      // An intermediate nonzero height can also be shorter than the saved
      // position. Keep following layout until it can represent that position.
      restoreNeeded = y > maximum
    }
    func detach() {
      attachmentVersion = UUID()
      NotificationCenter.default.removeObserver(self)
      scroll = nil
      document = nil
      liveScrolling = false
    }
    @objc private func documentChanged() { restore() }
    @objc private func beginScroll() { liveScrolling = true }
    @objc private func liveScroll() { liveScrolling = true; record() }
    @objc private func endScroll() { record(); liveScrolling = false }
    @objc private func boundsChanged() {
      // Layout changes/unmounting can clamp an old view to zero; they are not
      // new reading positions. Keyboard and scrollbar scrolling still count.
      let event = NSApplication.shared.currentEvent?.type
      if liveScrolling || event == .scrollWheel || event == .keyDown || event == .leftMouseDragged {
        record()
        return
      }
      restore()
    }
    private func record() {
      guard enabled, !restoring, let id, let scroll, scroll.window != nil else { return }
      restoreNeeded = false
      store?.rememberReviewOffset(scroll.contentView.bounds.minY, content: content, at: id)
    }
  }
}
