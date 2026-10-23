import AppKit
import SwiftUI

/// Leaving a mounted editor out of view must also end its keyboard input.
/// Use this dock's own window, which may differ from a popover's key window.
struct DockFocusResponderReset: NSViewRepresentable {
  let focusedPane: WorkbenchPane?
  var onExit: () -> Void

  final class InputView: NSView {
    var onExit: () -> Void = {}
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
      if event.keyCode == 53,
        event.modifierFlags.intersection([.command, .option, .control]).isEmpty
      {
        onExit()
      } else {
        super.keyDown(with: event)
      }
    }
    override func cancelOperation(_ sender: Any?) { onExit() }
  }

  final class Coordinator {
    var lastPane: WorkbenchPane?
    var revision: UInt64 = 0
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> InputView { InputView() }
  func updateNSView(_ view: InputView, context: Context) {
    view.onExit = onExit
    let coordinator = context.coordinator
    guard coordinator.lastPane != focusedPane else { return }
    coordinator.lastPane = focusedPane
    coordinator.revision &+= 1
    let revision = coordinator.revision
    let isEnlarged = focusedPane != nil
    DispatchQueue.main.async { [weak view, weak coordinator] in
      guard coordinator?.revision == revision, let window = view?.window else { return }
      // Keep Escape in this dock's responder chain after ending hidden input.
      if isEnlarged {
        window.makeFirstResponder(view)
      } else if window.firstResponder === view {
        // A user may have focused an editor in the enlarged pane. It remains
        // visible after restoration and must keep receiving keyboard input.
        window.makeFirstResponder(nil)
      }
    }
  }
}
