import SwiftUI

struct PrimaryActionStyle: ButtonStyle {
  var compact = false
  func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration, compact: compact) }
  private struct StyleBody: View {
    let configuration: ButtonStyleConfiguration
    let compact: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
      let shape = RoundedRectangle(cornerRadius: 6)
      configuration.label
        .padding(.horizontal, compact ? 10 : 14)
        .frame(minHeight: compact ? 26 : 32)
        .foregroundStyle(enabled ? WorkbenchTheme.onAccent : WorkbenchTheme.secondaryText)
        .background(enabled ? WorkbenchTheme.accent : WorkbenchTheme.panel, in: shape)
        .overlay(alignment: .top) {
          if enabled && contrast == .standard {
            Rectangle().fill(Color.white.opacity(0.18)).frame(height: 1).padding(.horizontal, 3)
          }
        }
        .overlay(shape.strokeBorder(enabled ? (contrast == .increased ? WorkbenchTheme.primaryText : .clear) : WorkbenchTheme.line, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.85 : 1)
        .contentShape(shape)
    }
  }
}

/// Quiet chrome button for the workspace header: no box until hover.
struct ChromeButtonStyle: ButtonStyle {
  var active = false
  func makeBody(configuration: Configuration) -> some View { StyleBody(configuration: configuration, active: active) }
  private struct StyleBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    var body: some View {
      configuration.label.font(.system(size: 12))
        .foregroundStyle(enabled ? (active ? WorkbenchTheme.accentText : WorkbenchTheme.primaryText) : WorkbenchTheme.secondaryText)
        .padding(.horizontal, 8).frame(height: 26)
        .background(configuration.isPressed || active ? WorkbenchTheme.selection : hovering ? WorkbenchTheme.panel : .clear,
          in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
  }
}

/// Opaque reading surface with a single glass-edge highlight. No blur.
struct RiverPaneSurface: ViewModifier {
  @Environment(\.colorSchemeContrast) private var contrast
  func body(content: Content) -> some View {
    content.background(WorkbenchTheme.canvas)
      .overlay(alignment: .top) {
        if contrast == .standard { Rectangle().fill(WorkbenchTheme.highlight).frame(height: 1).allowsHitTesting(false) }
      }
      .overlay(Rectangle().strokeBorder(WorkbenchTheme.line, lineWidth: 1).allowsHitTesting(false))
  }
}
extension View { func riverPaneSurface() -> some View { modifier(RiverPaneSurface()) } }
