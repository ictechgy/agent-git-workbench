import SwiftUI

struct PrimaryActionStyle: ButtonStyle {
  var compact = false
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(.horizontal, compact ? 12 : 14).padding(.vertical, compact ? 6 : 10)
      .foregroundStyle(enabled ? Color.white : Color.secondary)
      .background(
        enabled ? WorkbenchTheme.accent : Color.secondary.opacity(0.12),
        in: RoundedRectangle(cornerRadius: 7)
      )
      .opacity(configuration.isPressed ? 0.8 : 1)
  }
}
