import SwiftUI

public enum LayoutOptionsSection: String, CaseIterable, Identifiable {
  case layouts, panels, reading
  public var id: Self { self }
  public var title: String {
    switch self {
    case .layouts: "배치"
    case .panels: "패널"
    case .reading: "읽기·색상"
    }
  }
}

public struct LayoutOptions: View {
  @ObservedObject var layout: LayoutPreferences
  @ObservedObject var reading: ReadingPreferences
  @State private var section: LayoutOptionsSection
  @State private var nameEditor: NameEditor = .save
  @State private var name = ""
  @State private var showsNameEditor = false
  @State private var confirmation: SavedLayoutConfirmation?
  @State private var validationError: String?

  public init(
    layout: LayoutPreferences, reading: ReadingPreferences? = nil,
    initialSection: LayoutOptionsSection = .layouts
  ) {
    self.layout = layout
    self.reading = reading ?? ReadingPreferences()
    _section = State(initialValue: initialSection)
  }

  public var body: some View {
    VStack(spacing: 0) {
      header
      Picker("화면 구성 항목", selection: $section) {
        ForEach(LayoutOptionsSection.allCases) { Text($0.title).tag($0) }
      }
      .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.bottom, 14)
      if let validationError {
        Label(validationError, systemImage: "exclamationmark.circle")
          .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.danger)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.bottom, 12)
      }
      if let notice = layout.recoveryNotice {
        Text(notice).font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 20).padding(.bottom, 12)
      }
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          switch section {
          case .layouts: layoutsSection
          case .panels: panelsSection
          case .reading: readingSection
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
      }
      Divider()
      footer
    }
    .frame(width: 520, height: 620)
    .background(WorkbenchTheme.chrome)
    .foregroundStyle(WorkbenchTheme.primaryText)
    .alert(nameEditor.title, isPresented: $showsNameEditor) {
      TextField("배치 이름", text: $name)
      Button(nameEditor.actionTitle) { submitName() }
        .disabled(nameIssue != nil)
      Button("취소", role: .cancel) {}
    } message: {
      Text(nameIssue ?? "1~48자로 입력하세요. 같은 이름의 배치는 저장할 수 없습니다.")
    }
    .confirmationDialog(
      confirmation?.title ?? "저장한 배치 변경", isPresented: confirmationIsPresented,
      titleVisibility: .visible
    ) {
      if let confirmation {
        Button(confirmation.actionTitle, role: .destructive) {
          do {
            switch confirmation {
            case .replace(let saved): try layout.replaceSavedLayout(saved.id)
            case .delete(let saved): layout.deleteSavedLayout(saved.id)
            }
            validationError = nil
          } catch {
            validationError = error.localizedDescription
          }
          self.confirmation = nil
        }
      }
      Button("취소", role: .cancel) { confirmation = nil }
    } message: {
      Text(confirmation?.message ?? "")
    }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("화면 구성").font(.system(size: 17, weight: .semibold))
      HStack(spacing: 7) {
        Text("현재 배치").foregroundStyle(WorkbenchTheme.secondaryText)
        Text(layout.currentLayoutTitle).fontWeight(.medium)
          .lineLimit(1).truncationMode(.tail).help(layout.currentLayoutTitle)
        Spacer(minLength: 0)
      }.font(.system(size: 12))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 16)
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("배치 되돌리기", systemImage: "arrow.uturn.backward") {
        layout.undoDock()
        validationError = nil
      }
      .disabled(!layout.canUndoDock)
      .help("직전의 패널 배치, 저장소 탐색과 Diff 표시 방식으로 돌아갑니다.")
      Spacer(minLength: 0)
      Text("현재 구성은 자동 저장됩니다.")
        .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
    }
    .controlSize(.small).padding(.horizontal, 20).padding(.vertical, 14)
  }

  private var layoutsSection: some View {
    Group {
      VStack(alignment: .leading, spacing: 12) {
        sectionHeading("시작 배치", detail: "선택한 뒤에도 패널은 자유롭게 옮길 수 있습니다.")
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10
        ) {
          ForEach(LayoutPreset.allCases) { preset in presetButton(preset) }
        }
      }
      VStack(alignment: .leading, spacing: 11) {
        HStack {
          Text("내 배치").font(.system(size: 13, weight: .semibold))
          Text("\(layout.savedLayouts.count)/20")
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
          Spacer()
          Button("현재 배치 저장…", systemImage: "plus") { beginNameEditor(.save) }
            .controlSize(.small).disabled(layout.savedLayouts.count >= 20)
            .help(layout.savedLayouts.count >= 20 ? "배치는 20개까지 저장할 수 있습니다." : "현재 구성을 이름으로 저장합니다.")
        }
        if layout.savedLayouts.isEmpty {
          Text("자주 쓰는 구성을 이름으로 저장해 다시 불러오세요.")
            .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
        } else {
          VStack(spacing: 8) {
            ForEach(layout.savedLayouts) { saved in savedLayoutRow(saved) }
          }
        }
        Text("패널 위치·탭·크기, 저장소 탐색과 Diff 표시 방식을 저장·복원합니다. 색상과 글자·간격은 별도 유지.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func presetButton(_ preset: LayoutPreset) -> some View {
    let selected = layout.preset == preset
    return Button {
      layout.apply(preset)
      validationError = nil
    } label: {
      VStack(alignment: .leading, spacing: 8) {
        LayoutThumbnail(configuration: preset.configuration).frame(height: 64)
        HStack(spacing: 4) {
          Text(preset.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
          Spacer(minLength: 0)
          if selected {
            Image(systemName: "checkmark.circle.fill")
              .foregroundStyle(WorkbenchTheme.accentText).font(.system(size: 12))
          }
        }
        Text(presetDescription(preset)).font(.system(size: 11))
          .foregroundStyle(WorkbenchTheme.secondaryText).lineLimit(1)
      }
      .padding(10).frame(maxWidth: .infinity)
      .background(
        selected ? WorkbenchTheme.selection : WorkbenchTheme.canvas,
        in: RoundedRectangle(cornerRadius: 8)
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8).stroke(
          selected ? WorkbenchTheme.accent : WorkbenchTheme.line, lineWidth: selected ? 1.5 : 1)
      )
      .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .accessibilityLabel("\(preset.title) 배치 적용. \(LayoutThumbnail.summary(preset.configuration))")
    .accessibilityValue(selected ? "현재 배치" : "")
    .help("\(presetDescription(preset)). \(LayoutThumbnail.summary(preset.configuration))")
  }

  private func savedLayoutRow(_ saved: SavedLayout) -> some View {
    let selected = isCurrent(saved.configuration) && layout.currentLayoutTitle == saved.name
    return HStack(spacing: 10) {
      Button {
        layout.applySavedLayout(saved.id)
        validationError = nil
      } label: {
        HStack(spacing: 12) {
          LayoutThumbnail(configuration: saved.configuration).frame(width: 86, height: 52)
          VStack(alignment: .leading, spacing: 5) {
            Text(saved.name).font(.system(size: 12, weight: .medium))
              .lineLimit(1).truncationMode(.tail).help(saved.name)
            Text(
              "\(saved.configuration.navigation.title) · \(saved.configuration.splitDiff ? "나란히 Diff" : "한 화면 Diff")"
            )
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText).lineLimit(1)
          }
          Spacer(minLength: 0)
          if selected {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(WorkbenchTheme.accentText)
          } else {
            Text("적용").font(.system(size: 11)).foregroundStyle(WorkbenchTheme.accentText)
          }
        }.contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(saved.name) 적용. \(LayoutThumbnail.summary(saved.configuration))")
      .accessibilityValue(selected ? "현재 배치" : "")
      Menu {
        Button("이름 변경…") { beginNameEditor(.rename(saved.id)) }
        Button("현재 구성으로 덮어쓰기…") { confirmation = .replace(saved) }
        Divider()
        Button("삭제…", role: .destructive) { confirmation = .delete(saved) }
      } label: {
        Image(systemName: "ellipsis").frame(width: 18, height: 24)
      }
      .menuStyle(.borderlessButton).fixedSize()
      .accessibilityLabel("\(saved.name) 관리")
    }
    .padding(10)
    .background(
      selected ? WorkbenchTheme.selection : WorkbenchTheme.canvas,
      in: RoundedRectangle(cornerRadius: 8)
    )
    .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkbenchTheme.line))
  }

  private var panelsSection: some View {
    Group {
      VStack(alignment: .leading, spacing: 10) {
        sectionHeading("패널 이동", detail: "패널 제목을 끌어 가장자리에서 분할하고, 중앙에서 탭으로 합치세요.")
        Text("키보드로는 패널의 ••• 메뉴 또는 ‘보기 → 패널 배치’를 사용하세요.")
          .font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
        if let focused = layout.focusedPane {
          HStack {
            Label("\(focused.title) 확대 중", systemImage: "arrow.up.left.and.arrow.down.right")
              .font(.system(size: 12))
            Spacer()
            Button("원래 배치로") { layout.restorePaneLayout() }.controlSize(.small)
          }
          .padding(12).background(WorkbenchTheme.selection, in: RoundedRectangle(cornerRadius: 8))
        } else {
          Text("패널을 잠시 확대해도 원래 구성은 유지됩니다. ‘원래 배치로’ 또는 Esc로 돌아옵니다.")
            .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        sectionHeading("표시할 패널")
        ForEach(WorkbenchPane.allCases) { pane in
          Toggle(isOn: paneBinding(pane)) {
            Label(pane.title, systemImage: pane.symbol).font(.system(size: 12))
              .frame(maxWidth: .infinity, alignment: .leading)
          }.toggleStyle(.switch).controlSize(.small).padding(.vertical, 4)
        }
      }
      VStack(alignment: .leading, spacing: 10) {
        sectionHeading("저장소 탐색")
        Picker("저장소 탐색", selection: binding(\.navigation)) {
          ForEach(RepositoryLayout.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        Text("모든 저장소에 같은 탐색 구성을 사용합니다.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
      }
    }
  }

  private var readingSection: some View {
    Group {
      VStack(alignment: .leading, spacing: 12) {
        sectionHeading("코드 글자")
        Stepper(
          value: Binding(
            get: { reading.configuration.codeSize }, set: { reading.setCodeSize($0) }),
          in: 11...20, step: 1
        ) {
          HStack {
            Text("글자 크기").font(.system(size: 12))
            Spacer()
            Text("\(Int(reading.configuration.codeSize)) pt")
              .font(.system(size: 12).monospacedDigit()).foregroundStyle(
                WorkbenchTheme.secondaryText)
          }
        }
        VStack(alignment: .leading, spacing: 0) {
          ForEach(["let changes = branch.changes", "return review(changes)"], id: \.self) { line in
            Text(line).font(.system(size: reading.configuration.codeSize, design: .monospaced))
              .frame(height: reading.configuration.codeRowHeight, alignment: .leading)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(12)
        .background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WorkbenchTheme.line))
        .accessibilityLabel("코드 미리보기, \(Int(reading.configuration.codeSize))포인트")
      }
      VStack(alignment: .leading, spacing: 10) {
        sectionHeading("코드·파일 목록 간격")
        Picker(
          "코드와 파일 목록 간격",
          selection: Binding(
            get: { reading.configuration.density }, set: { reading.setDensity($0) })
        ) {
          ForEach(ReadingDensity.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        Text("코드 행과 파일 목록의 간격만 바꿉니다.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
        Button("글자·간격 기본값으로") { reading.reset() }.controlSize(.small)
          .disabled(reading.configuration == ReadingConfiguration())
      }
      Divider()
      VStack(alignment: .leading, spacing: 8) {
        Toggle("Diff를 나란히 표시", isOn: binding(\.splitDiff)).font(.system(size: 12))
        Text("Diff 표시 방식은 배치와 함께 저장·복원됩니다.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
      }
      VStack(alignment: .leading, spacing: 10) {
        sectionHeading("색상")
        Picker("색상", selection: $layout.appearance) {
          ForEach(WorkbenchAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden()
        Text("색상과 글자·간격은 배치를 불러와도 유지됩니다.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.secondaryText)
      }
    }
  }

  private func sectionHeading(_ title: String, detail: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 13, weight: .semibold))
      if let detail {
        Text(detail).font(.system(size: 12)).foregroundStyle(WorkbenchTheme.secondaryText)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func binding<T>(_ path: WritableKeyPath<LayoutConfiguration, T>) -> Binding<T> {
    Binding(
      get: { layout.configuration[keyPath: path] },
      set: { value in layout.update { $0[keyPath: path] = value } })
  }

  private func paneBinding(_ pane: WorkbenchPane) -> Binding<Bool> {
    Binding(
      get: { layout.dockLayout.contains(pane) },
      set: { visible in
        if visible { layout.showPane(pane) } else { layout.hidePane(pane) }
      })
  }

  private func isCurrent(_ configuration: LayoutConfiguration) -> Bool {
    var candidate = configuration
    var current = layout.configuration
    let candidateDock = candidate.dock
    let currentDock = current.dock
    candidate.dock = nil
    current.dock = nil
    return candidate == current
      && candidateDock?.sameArrangement(as: currentDock ?? DockLayout(root: nil)) == true
  }

  private func presetDescription(_ preset: LayoutPreset) -> String {
    switch preset {
    case .focus: "파일과 넓은 Diff"
    case .balanced: "보조 패널은 탭으로"
    case .classic: "기록·검토·커밋"
    case .review: "검토와 커밋"
    case .tracks: "세로 저장소 탐색"
    }
  }

  private func beginNameEditor(_ editor: NameEditor) {
    nameEditor = editor
    name = editor.id.flatMap { id in layout.savedLayouts.first(where: { $0.id == id })?.name } ?? ""
    validationError = nil
    showsNameEditor = true
  }

  private var nameIssue: String? {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard (1...48).contains(trimmed.count) else { return "이름은 1~48자로 입력하세요." }
    for scalar in name.unicodeScalars {
      switch scalar.properties.generalCategory {
      case .control, .lineSeparator, .paragraphSeparator:
        return "줄바꿈이나 제어 문자 없이 이름을 입력하세요."
      default: break
      }
      if scalar.value == 0x061C || (0x200E...0x200F).contains(scalar.value)
        || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
      {
        return "제어 문자 없이 이름을 입력하세요."
      }
    }
    let nameKey = trimmed.folding(
      options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    if layout.savedLayouts.contains(where: {
      $0.id != nameEditor.id
        && $0.name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
          == nameKey
    }) {
      return "같은 이름의 배치가 있습니다. 다른 이름을 입력하세요."
    }
    return nil
  }

  private func submitName() {
    do {
      switch nameEditor {
      case .save: try layout.saveCurrentLayout(named: name)
      case .rename(let id): try layout.renameSavedLayout(id, to: name)
      }
      validationError = nil
    } catch { validationError = error.localizedDescription }
  }

  private var confirmationIsPresented: Binding<Bool> {
    Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })
  }
}

private enum NameEditor {
  case save
  case rename(UUID)
  var id: UUID? { if case .rename(let id) = self { id } else { nil } }
  var title: String { id == nil ? "현재 배치 저장" : "배치 이름 변경" }
  var actionTitle: String { id == nil ? "저장" : "변경" }
}

private enum SavedLayoutConfirmation {
  case replace(SavedLayout)
  case delete(SavedLayout)
  var title: String {
    switch self {
    case .replace(let saved): "‘\(saved.name)’을 현재 구성으로 바꿀까요?"
    case .delete(let saved): "‘\(saved.name)’을 삭제할까요?"
    }
  }
  var actionTitle: String { if case .replace = self { "덮어쓰기" } else { "삭제" } }
  var message: String {
    switch self {
    case .replace: "기존 저장본이 현재 패널 배치, 저장소 탐색과 Diff 표시 방식으로 바뀝니다."
    case .delete: "저장본만 삭제하며 현재 화면 구성은 유지됩니다."
    }
  }
}
