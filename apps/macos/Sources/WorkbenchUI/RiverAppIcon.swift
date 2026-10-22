import AppKit
import SwiftUI

struct RiverAppIcon: View {
  var size: CGFloat = 20
  @MainActor private static let icon: NSImage? = {
    guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
    return NSImage(contentsOf: url)
  }()

  var body: some View {
    Group {
      if let icon = Self.icon {
        Image(nsImage: icon).resizable().interpolation(.high)
      } else {
        Image(systemName: "arrow.triangle.branch").resizable().scaledToFit()
          .padding(size * 0.2).foregroundStyle(WorkbenchTheme.accentText)
          .background(WorkbenchTheme.elevated, in: RoundedRectangle(cornerRadius: size * 0.22))
      }
    }.frame(width: size, height: size).accessibilityHidden(true)
  }
}
