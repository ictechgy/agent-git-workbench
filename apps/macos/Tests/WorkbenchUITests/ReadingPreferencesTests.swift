import AppKit
import Foundation
import Testing
import WorkbenchUI

@Test @MainActor
func readingControlsPersistIndependentlyOfLayoutAndAppearance() {
  let suite = "river-reading-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let layout = LayoutPreferences(defaults: defaults)
  let reading = ReadingPreferences(defaults: defaults)
  layout.appearance = .dark
  let original = layout.configuration
  reading.setCodeSize(18)
  reading.setDensity(.compact)
  #expect(layout.configuration == original)
  let restored = ReadingPreferences(defaults: defaults)
  #expect(restored.configuration == reading.configuration)
  layout.apply(.tracks)
  #expect(restored.configuration.codeSize == 18)
  #expect(restored.configuration.density == .compact)
  #expect(layout.appearance == .dark)
  reading.reset()
  #expect(reading.configuration == ReadingConfiguration())
}

@Test @MainActor
func readingGeometryIncludesEveryRowAtEverySupportedSizeAndDensity() {
  let suite = "river-reading-geometry-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let reading = ReadingPreferences(defaults: defaults)
  for density in ReadingDensity.allCases {
    reading.setDensity(density)
    for size in 11...20 {
      reading.setCodeSize(Double(size))
      let value = reading.configuration
      #expect(value.codeRowHeight > value.codeSize * 1.45)
      let font = NSFont.monospacedSystemFont(ofSize: value.codeSize, weight: .regular)
      for number in ["1", "9999", "12345678", String(Int.max)] {
        let width = (number as NSString).size(withAttributes: [.font: font]).width
        #expect(value.lineNumberWidth(digits: number.count) > width)
      }
      #expect(value.hunkHeight(rows: 200, split: false) >= value.codeRowHeight * 200)
      #expect(
        value.hunkHeight(rows: 200, split: true) == value.hunkHeight(rows: 200, split: false)
          + value.splitHeaderHeight)
    }
  }
  reading.setCodeSize(.infinity)
  #expect(reading.configuration.codeSize == 13)
  reading.setCodeSize(100)
  #expect(reading.configuration.codeSize == 20)
  reading.setCodeSize(-100)
  #expect(reading.configuration.codeSize == 11)
}
