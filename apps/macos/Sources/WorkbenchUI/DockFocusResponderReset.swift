import AppKit
import SwiftUI

/// Leaving a mounted editor out of view must also end its keyboard input.
/// Use this dock's own window, which may differ from a popover's key window.
struct DockFocusResponderReset: NSViewRepresentable {
  let focusedPane: WorkbenchPane?
  final class Coordinator {
    var lastPane: WorkbenchPane?
    var revision: UInt64 = 0
    init(_ pane: WorkbenchPane?) { lastPane = pane }
  }
  func makeCoordinator() -> Coordinator { Coordinator(focusedPane) }
  func makeNSView(context: Context) -> NSView { NSView() }
  func updateNSView(_ view: NSView, context: Context) {
    let coordinator = context.coordinator
    guard coordinator.lastPane != focusedPane else { return }
    coordinator.lastPane = focusedPane
    coordinator.revision &+= 1
    let revision = coordinator.revision
    DispatchQueue.main.async { [weak view, weak coordinator] in
      guard coordinator?.revision == revision, let window = view?.window else { return }
      window.makeFirstResponder(nil)
    }
  }
}
