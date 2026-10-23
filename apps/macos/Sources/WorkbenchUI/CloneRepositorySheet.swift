import AppKit
import SwiftUI

struct CloneRepositorySheet: View {
  @ObservedObject var store: WorkbenchStore
  @Environment(\.dismiss) private var dismiss
  @State private var url = ""
  @State private var name = ""
  @State private var manuallyNamed = false
  @State private var parent: URL?
  @State private var working = false
  @State private var error: String?
  private var valid: Bool {
    !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parent != nil && !name.isEmpty
      && name != "." && name != ".." && !name.contains("/") && !name.contains("\0") && !name.contains("\n")
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("원격 저장소 복제").font(.title2.weight(.semibold))
      Text("GitHub·GitLab·Bitbucket·자체 Git 서버에서 프로젝트를 가져옵니다.")
        .font(.callout).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        Text("저장소 URL").font(.callout)
        TextField("https://host/team/repo.git 또는 git@host:team/repo.git", text: $url)
          .textFieldStyle(.roundedBorder).onChange(of: url) { _, value in
            if !manuallyNamed {
              let path = URLComponents(string: value)?.scheme != nil && value.contains("://")
                ? (URLComponents(string: value)?.path ?? "") : String(value.split(separator: ":").last ?? "")
              let last = path.split(separator: "/").last.map(String.init) ?? ""
              name = last.hasSuffix(".git") ? String(last.dropLast(4)) : last
            }
          }
      }
      HStack {
        VStack(alignment: .leading, spacing: 6) {
          Text("저장할 상위 폴더").font(.callout)
          Text(parent?.path ?? "폴더를 선택해 주세요.").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
        Button("폴더 선택…") { chooseParent() }
      }
      TextField("새 폴더 이름", text: Binding(get: { name }, set: { name = $0; manuallyNamed = true })).textFieldStyle(.roundedBorder)
      if let parent, !name.isEmpty { Text(parent.appendingPathComponent(name).path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
      Text("기존 폴더를 덮어쓰지 않습니다. SSH는 등록된 기본 키와 신뢰한 서버를, HTTPS는 macOS Git Keychain 인증을 사용합니다. URL에는 비밀번호나 토큰을 넣지 마세요.")
        .font(.caption).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(WorkbenchTheme.danger).font(.callout).textSelection(.enabled) }
      HStack {
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        if working { ProgressView().controlSize(.small) }
        Button(working ? "복제 중…" : "복제 후 열기") {
          guard let parent else { return }; working = true; error = nil
          let destination = parent.appendingPathComponent(name, isDirectory: true)
          Task {
            do { try await store.cloneRepository(url: url.trimmingCharacters(in: .whitespacesAndNewlines), destination: destination); dismiss() }
            catch { self.error = UserFacingFailure.message(error); working = false }
          }
        }.keyboardShortcut(.defaultAction).disabled(!valid)
      }
    }.padding(24).frame(width: 580).disabled(working).interactiveDismissDisabled(working)
  }
  private func chooseParent() {
    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
    panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
    panel.prompt = "이 폴더에 저장"; panel.message = "복제할 새 프로젝트 폴더의 상위 폴더를 선택하세요."
    panel.begin { response in if response == .OK { parent = panel.url } }
  }
}
