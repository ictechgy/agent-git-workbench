import AppKit
import SwiftUI

struct HistoryResizeHandle: View {
  @Binding var height: CGFloat?
  let defaultHeight: CGFloat
  let maximumHeight: CGFloat
  var growthDirection: CGFloat = -1
  @State private var dragStart: CGFloat?
  @State private var hovering = false
  var body: some View {
    Rectangle().fill(WorkbenchTheme.sidebar)
      .overlay(Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 34, height: 3))
      .frame(height: 8).contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .onChanged { value in
            if dragStart == nil { dragStart = min(height ?? defaultHeight, maximumHeight) }
            height = min(
              maximumHeight,
              max(140, (dragStart ?? defaultHeight) + value.translation.height * growthDirection))
          }
          .onEnded { _ in dragStart = nil }
      )
      .onTapGesture(count: 2) { height = nil }
      .onHover { inside in
        guard inside != hovering else { return }
        hovering = inside
        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
      }
      .onDisappear {
        if hovering {
          NSCursor.pop()
          hovering = false
        }
      }
      .accessibilityElement().accessibilityLabel("커밋 기록 높이 조절")
      .accessibilityValue("\(Int(min(height ?? defaultHeight, maximumHeight))) 포인트")
      .accessibilityAdjustableAction { direction in
        let current = min(height ?? defaultHeight, maximumHeight)
        switch direction {
        case .increment: height = min(maximumHeight, current + 40)
        case .decrement: height = max(140, current - 40)
        @unknown default: break
        }
      }
      .help("드래그로 기록 높이 조절 · 두 번 클릭해 기본 높이로")
  }
}
