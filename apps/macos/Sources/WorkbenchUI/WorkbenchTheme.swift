import AppKit
import SwiftUI

private extension NSColor {
  convenience init(rgb: UInt32) {
    self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
  }
}

private extension Color {
  /// Static semantic token. Resolves light / dark / Increase Contrast without assets.
  static func river(_ light: UInt32, _ dark: UInt32, hcLight: UInt32? = nil, hcDark: UInt32? = nil) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
      case .darkAqua?: return NSColor(rgb: dark)
      case .accessibilityHighContrastDarkAqua?: return NSColor(rgb: hcDark ?? dark)
      case .accessibilityHighContrastAqua?: return NSColor(rgb: hcLight ?? light)
      default: return NSColor(rgb: light)
      }
    })
  }
}

enum WorkbenchTheme {
  // Clear Shallows / Clear Deep: quiet water-colored chrome and opaque code surfaces.
  static let chrome = Color.river(0xF3F7F9, 0x0E1A22, hcLight: 0xEAF2F5, hcDark: 0x08151D)
  static let sidebar = Color.river(0xEAF2F5, 0x122129)
  static let canvas = Color.river(0xFFFFFF, 0x15232C)
  static let panel = sidebar
  static let elevated = canvas
  static let line = Color.river(0xD9E4EA, 0x24363F, hcLight: 0x788C98, hcDark: 0x708B99)
  static let highlight = Color.river(0xFFFFFF, 0x24363F)
  static let accent = Color.river(0x0779A0, 0x4CC9E0, hcLight: 0x055D7A, hcDark: 0x7FE3F0)
  // Small accent labels need stronger contrast than the fill on tinted navigation.
  static let accentText = Color.river(0x066B8C, 0x4CC9E0, hcLight: 0x044B64, hcDark: 0xA6EEF7)
  static let onAccent = Color.river(0xFFFFFF, 0x032530)
  static let selection = Color.river(0xE1F3F8, 0x173B48, hcLight: 0xC4E3EA, hcDark: 0x22505C)
  static let primaryText = Color.river(0x102231, 0xE3EEF2)
  static let secondaryText = Color.river(0x5A6B78, 0x94A9B4, hcLight: 0x37424D, hcDark: 0xC3CCD5)
  // Brand hints · signature & Welcome only, never state
  static let brandAmber = Color.river(0xC98A2E, 0xE0B25A)
  static let brandLilac = Color.river(0x8A78D6, 0xA898EE)
  // Semantics · never decorative
  static let success = Color.river(0x166B3B, 0x4CC27A, hcLight: 0x13663A, hcDark: 0x7EE0A3)
  static let warning = Color.river(0x865000, 0xE5A040, hcLight: 0x7F4A00, hcDark: 0xF5C27A)
  static let danger = Color.river(0xA92F23, 0xF0716B, hcLight: 0x962A1F, hcDark: 0xFF9E99)
  static let addBackground = Color.river(0xE6F6EA, 0x163828, hcLight: 0xCDEBD6, hcDark: 0x23472E)
  static let addGutter = Color.river(0xCBEAD4, 0x24452F)
  static let deleteBackground = Color.river(0xFDEBEC, 0x3E1F27, hcLight: 0xF6D2D2, hcDark: 0x52292D)
  static let deleteGutter = Color.river(0xF4CFCF, 0x4E2B2F)

  static func stateColor(_ state: String) -> Color {
    if state == "ready" { return success }
    if ["failed", "needs_recovery"].contains(state) { return danger }
    if ["partial_failure", "waiting_for_worktree", "cancelled"].contains(state) { return warning }
    return accentText
  }
}
