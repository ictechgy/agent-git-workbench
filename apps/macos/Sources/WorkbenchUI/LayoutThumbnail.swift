import SwiftUI

/// A miniature of the split tree; navigation is separate because it is not a pane.
struct LayoutThumbnail: View {
  let configuration: LayoutConfiguration

  var body: some View {
    Canvas { context, size in
      let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
      context.fill(Path(roundedRect: bounds, cornerRadius: 3), with: .color(WorkbenchTheme.chrome))
      let content: CGRect
      if configuration.navigation == .tracks {
        let rail = CGRect(
          x: bounds.minX + 3, y: bounds.minY + 3, width: 10, height: bounds.height - 6)
        context.fill(Path(rail), with: .color(WorkbenchTheme.sidebar))
        for index in 0..<3 {
          let mark = CGRect(
            x: rail.minX + 2, y: rail.minY + 4 + CGFloat(index) * 9, width: 6, height: 3)
          context.fill(
            Path(mark),
            with: .color(index == 0 ? WorkbenchTheme.accent : WorkbenchTheme.secondaryText))
        }
        content = CGRect(
          x: rail.maxX + 3, y: bounds.minY + 3,
          width: max(0, bounds.maxX - rail.maxX - 6), height: max(0, bounds.height - 6))
      } else {
        for index in 0..<3 {
          let width = max(8, (bounds.width - 12) / 3)
          let tab = CGRect(
            x: bounds.minX + 3 + CGFloat(index) * (width + 2),
            y: bounds.minY + 3, width: width, height: 5)
          context.fill(
            Path(tab), with: .color(index == 0 ? WorkbenchTheme.accent : WorkbenchTheme.line))
        }
        content = CGRect(
          x: bounds.minX + 3, y: bounds.minY + 11,
          width: max(0, bounds.width - 6), height: max(0, bounds.height - 14))
      }
      let dock = configuration.dock ?? DockLayout.legacy(configuration)
      if let root = dock.root { draw(root, in: content, context: context) }
      context.stroke(
        Path(roundedRect: bounds, cornerRadius: 3), with: .color(WorkbenchTheme.line), lineWidth: 1)
    }
    .accessibilityHidden(true)
    .allowsHitTesting(false)
  }

  static func summary(_ configuration: LayoutConfiguration) -> String {
    let dock = configuration.dock ?? DockLayout.legacy(configuration)
    let panels = dock.panes.map(\.title).joined(separator: ", ")
    return
      "\(configuration.navigation.title), \(configuration.splitDiff ? "나란히 Diff" : "한 화면 Diff"), \(panels.isEmpty ? "표시된 패널 없음" : panels)"
  }

  private func draw(_ node: DockNode, in bounds: CGRect, context: GraphicsContext) {
    guard bounds.width > 0, bounds.height > 0 else { return }
    switch node {
    case .split(_, let axis, let ratio, let first, let second):
      let fraction = CGFloat(ratio.isFinite ? min(1, max(0, ratio)) : 0.5)
      let gap: CGFloat = 2
      if axis == .horizontal {
        let available = max(0, bounds.width - gap)
        let length = available * fraction
        draw(
          first, in: CGRect(x: bounds.minX, y: bounds.minY, width: length, height: bounds.height),
          context: context)
        draw(
          second,
          in: CGRect(
            x: bounds.minX + length + gap, y: bounds.minY,
            width: available - length, height: bounds.height), context: context)
      } else {
        let available = max(0, bounds.height - gap)
        let length = available * fraction
        draw(
          first, in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: length),
          context: context)
        draw(
          second,
          in: CGRect(
            x: bounds.minX, y: bounds.minY + length + gap,
            width: bounds.width, height: available - length), context: context)
      }
    case .tabs(_, let panes, let active):
      context.fill(
        Path(bounds),
        with: .color(active == .diff ? WorkbenchTheme.selection : WorkbenchTheme.canvas))
      context.stroke(
        Path(bounds.insetBy(dx: 0.5, dy: 0.5)), with: .color(WorkbenchTheme.line), lineWidth: 1)
      let tabHeight = min(8, bounds.height * 0.25)
      let tabWidth = bounds.width / CGFloat(max(1, panes.count))
      for (index, pane) in panes.enumerated() {
        let tab = CGRect(
          x: bounds.minX + CGFloat(index) * tabWidth, y: bounds.minY,
          width: max(0, tabWidth - 1), height: tabHeight)
        context.fill(
          Path(tab), with: .color(pane == active ? WorkbenchTheme.accent : WorkbenchTheme.line))
      }
      if bounds.width >= 35 && bounds.height >= 23 {
        var clipped = context
        clipped.clip(to: Path(bounds.insetBy(dx: 2, dy: 1)))
        clipped.draw(
          Text(active.title).font(.system(size: 9, weight: .medium))
            .foregroundStyle(WorkbenchTheme.secondaryText),
          at: CGPoint(x: bounds.midX, y: bounds.midY + tabHeight / 2), anchor: .center)
      }
    }
  }
}
