import SwiftUI

struct WelcomeView: View {
  @ObservedObject var store: WorkbenchStore

  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.colorSchemeContrast) private var contrast

  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        VStack(alignment: .leading, spacing: 42) {
          HStack(spacing: 12) {
            RiverAppIcon(size: 48)
            VStack(alignment: .leading, spacing: 3) {
              Text("River").font(.system(size: 17, weight: .semibold))
              HStack(spacing: 5) {
                HStack(spacing: 3) {
                  ForEach([WorkbenchTheme.brandAmber, WorkbenchTheme.accent, WorkbenchTheme.brandLilac].indices, id: \.self) { i in
                    Circle().fill([WorkbenchTheme.brandAmber, WorkbenchTheme.accent, WorkbenchTheme.brandLilac][i])
                      .frame(width: 4, height: 4)
                  }
                }.accessibilityHidden(true)
                Text("우리의 강줄기가 모여, 하나의 바다로.").font(.system(size: 12))
                  .foregroundStyle(WorkbenchTheme.secondaryText)
              }
            }
            Spacer()
            if store.workspace != nil {
              Button("열려 있는 작업으로 돌아가기", systemImage: "arrow.uturn.backward") {
                store.showingWelcome = false
              }.buttonStyle(.link).disabled(store.busy)
            }
          }
          HStack(alignment: .top, spacing: 54) {
            VStack(alignment: .leading, spacing: 24) {
              VStack(alignment: .leading, spacing: 14) {
                Text("프로젝트를 열고,\n작업을 이어가세요.")
                  .font(.system(size: 32, weight: .semibold)).tracking(-1).lineSpacing(5)
                  .fixedSize(horizontal: false, vertical: true)
                Text("브랜치를 나누고, 변경 사항을 살펴보고,\n다음 커밋까지 한곳에서.")
                  .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(5)
              }
              Button {
                store.chooseRepository()
              } label: {
                HStack(spacing: 12) {
                  Image(systemName: "folder.badge.plus").font(.system(size: 21))
                  Text("저장소 열기…").font(.system(size: 15, weight: .semibold))
                  Spacer()
                  Text("⌘O").font(.system(size: 12)).opacity(0.7)
                }.padding(.horizontal, 4).frame(height: 52).contentShape(Rectangle())
              }.buttonStyle(PrimaryActionStyle())
                .disabled(store.busy).help("Git 프로젝트 폴더 선택")
              Button {
                Task { await store.openExample() }
              } label: {
                HStack(spacing: 13) {
                  Image(systemName: "square.stack.3d.up").font(.system(size: 23, weight: .light))
                    .foregroundStyle(WorkbenchTheme.accentText).frame(width: 28)
                  VStack(alignment: .leading, spacing: 5) {
                    Text("예제로 먼저 둘러보기").font(.system(size: 13, weight: .medium))
                    Text("두 저장소의 작업과 코드 변경을 살펴보세요.")
                      .font(.system(size: 11)).foregroundStyle(.secondary)
                  }
                  Spacer(minLength: 0)
                  Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                }.padding(17).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                  Rectangle())
              }.buttonStyle(.plain)
                .background(WorkbenchTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                  RoundedRectangle(cornerRadius: 8).strokeBorder(WorkbenchTheme.line, lineWidth: 1).allowsHitTesting(false)
                )
                .disabled(store.busy)
              HStack(spacing: 8) {
                if let message = store.startupMessage {
                  ProgressView().controlSize(.small)
                  Text(message).foregroundStyle(.secondary)
                } else {
                  Image(systemName: "internaldrive").foregroundStyle(.tertiary)
                  Text("프로젝트와 작업 기록은 이 Mac에 보관됩니다.").foregroundStyle(.secondary)
                }
              }.font(.system(size: 11)).frame(height: 24)
            }.frame(width: 410)

            VStack(alignment: .leading, spacing: 18) {
              HStack {
                Text("최근 프로젝트").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("\(store.recentWorkspaces.count)").font(.system(size: 11, design: .monospaced))
                  .foregroundStyle(.tertiary)
              }.padding(.top, 5)
              Divider()
              if store.recentWorkspaces.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                  Image(systemName: "clock.arrow.circlepath").font(
                    .system(size: 26, weight: .light)
                  )
                  .foregroundStyle(.tertiary).padding(.bottom, 6)
                  Text("다음에는 여기서 바로 시작하세요.").font(.system(size: 13, weight: .medium))
                  Text("한 번 연 프로젝트는 이곳에 표시됩니다.\n이전 작업과 변경 사항을 그대로 이어갑니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(5)
                }.padding(.vertical, 26)
              } else {
                VStack(spacing: 4) {
                  ForEach(store.recentWorkspaces.prefix(6)) { recent in
                    Button {
                      Task { await store.openRecent(recent) }
                    } label: {
                      HStack(spacing: 12) {
                        Image(systemName: recent.isExample ? "square.stack.3d.up" : "folder")
                          .font(.system(size: 19, weight: .light)).foregroundStyle(
                            WorkbenchTheme.accentText)
                        VStack(alignment: .leading, spacing: 5) {
                          Text(recent.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                          Text(recent.isExample ? "앱에서 만든 예제" : recent.repositoryPath)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(
                          .tertiary)
                      }.padding(.vertical, 12).padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(store.busy).help(recent.repositoryPath)
                  }
                }
              }
            }.frame(maxWidth: .infinity, alignment: .leading)
          }
          Divider()
          HStack(spacing: 22) {
            Label("분리된 작업 공간", systemImage: "arrow.triangle.branch")
            Label("나란히 보는 코드 변경", systemImage: "rectangle.split.2x1")
            Label("검토한 뒤 커밋", systemImage: "checkmark.circle")
          }.font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(48).frame(maxWidth: 1040)
          .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
      }.background {
        WorkbenchTheme.chrome
        if !reduceTransparency && contrast == .standard {
          RadialGradient(colors: [WorkbenchTheme.accent.opacity(0.08), .clear],
            center: .topTrailing, startRadius: 0, endRadius: 520).allowsHitTesting(false)
        }
      }
    }
  }
}
