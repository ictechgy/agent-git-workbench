import SwiftUI

public struct LayoutOptions: View {
  @ObservedObject var layout: LayoutPreferences
  public init(layout: LayoutPreferences) { self.layout = layout }
  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text("화면 구성").font(.system(size: 16, weight: .semibold))
          Spacer()
          if layout.preset == nil { Text("사용자 설정").font(.caption).foregroundStyle(.secondary) }
        }
        Text("패널 제목을 끌어 원하는 위치에 놓으세요. 가장자리는 영역 분할, 중앙은 탭 합치기입니다.")
          .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
            horizontal: false, vertical: true)
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
          ForEach(LayoutPreset.allCases) { preset in
            Button {
              layout.apply(preset)
            } label: {
              VStack(spacing: 9) {
                Image(systemName: symbol(preset)).font(.system(size: 22))
                Text(preset.title).font(.system(size: 12, weight: .medium))
              }.frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(
                  layout.preset == preset
                    ? WorkbenchTheme.accent.opacity(0.12) : WorkbenchTheme.canvas,
                  in: RoundedRectangle(cornerRadius: 7)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: 7).stroke(
                    layout.preset == preset ? WorkbenchTheme.accent : WorkbenchTheme.line))
            }.buttonStyle(.plain)
          }
        }
        Picker("색상", selection: $layout.appearance) {
          ForEach(WorkbenchAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Picker("저장소 탐색", selection: binding(\.navigation)) {
          ForEach(RepositoryLayout.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        Toggle("Diff를 나란히 표시", isOn: binding(\.splitDiff))
        Divider()
        Text("표시할 패널").font(.system(size: 13, weight: .semibold))
        ForEach(WorkbenchPane.allCases) { pane in
          Toggle(
            pane.title,
            isOn: Binding(
              get: { layout.dockLayout.contains(pane) },
              set: { visible in
                if visible { layout.showPane(pane) } else { layout.hidePane(pane) }
              }))
        }
        Button("이전 배치로 되돌리기", systemImage: "arrow.uturn.backward") { layout.undoDock() }
          .disabled(!layout.canUndoDock)
        HStack {
          Text("변경한 구성은 자동으로 저장됩니다.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
          Spacer()
          Button("집중 배치로 복구") { layout.apply(.focus) }
        }
      }.padding(22)
    }.frame(width: 420, height: 650)
  }
  private func binding<T>(_ path: WritableKeyPath<LayoutConfiguration, T>) -> Binding<T> {
    Binding(
      get: { layout.configuration[keyPath: path] },
      set: { value in
        layout.update { $0[keyPath: path] = value }
      })
  }
  private func symbol(_ preset: LayoutPreset) -> String {
    switch preset {
    case .focus: "rectangle.split.2x1"
    case .balanced: "rectangle.split.3x1"
    case .classic: "rectangle.split.2x2"
    case .review: "rectangle.split.3x1"
    case .tracks: "rectangle.3.group"
    }
  }
}
