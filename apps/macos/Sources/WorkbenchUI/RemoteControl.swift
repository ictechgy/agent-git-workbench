import SwiftUI
import WorkbenchProtocol

/// One compact entry point keeps network actions out of the normal code review surface.
struct RemoteControl: View {
  @ObservedObject var store: WorkbenchStore
  @State private var presented = false
  var body: some View {
    Button { presented.toggle() } label: { Label("원격", systemImage: "network") }
      .buttonStyle(ChromeButtonStyle(active: presented)).fixedSize()
      .disabled(store.selection == nil).help("원격 저장소 · Fetch · Pull · Push")
      .popover(isPresented: $presented, arrowEdge: .bottom) {
        RemotePopover(store: store).frame(width: 460)
      }
  }
}

struct RemotePopover: View {
  @ObservedObject var store: WorkbenchStore
  @State private var selectedRemote = ""
  @State private var targetBranch = ""
  @State private var editing = false
  @State private var adding = false
  @State private var name = ""
  @State private var fetchURL = ""
  @State private var pushURL = ""
  @State private var pending: RemoteConfirmation?
  @State private var contentHeight: CGFloat = 420
  private var remote: RemoteInfo? { store.remoteState?.remotes.first { $0.name == selectedRemote } }
  private var blocked: Bool { !store.canUseRemotes || store.remoteBusy || store.remoteLoading }
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("원격 저장소").font(.headline)
          Spacer()
          if store.remoteLoading || store.remoteBusy { ProgressView().controlSize(.small) }
          Button { Task { await store.loadRemoteState() } } label: { Image(systemName: "arrow.clockwise") }
            .buttonStyle(.plain).disabled(store.remoteLoading || store.remoteBusy).help("원격 정보 다시 읽기")
            .accessibilityLabel("원격 정보 다시 읽기")
        }
        Text(store.remoteState?.repositoryPath ?? store.repository?.path ?? "현재 폴더를 확인 중입니다.")
          .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
        if let error = store.remoteError { Text(error).font(.callout).foregroundStyle(WorkbenchTheme.danger).textSelection(.enabled) }
        if let message = store.remoteMessage { Text(message).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        if let state = store.remoteState {
          if state.remotes.isEmpty {
            Text("연결된 원격 저장소가 없습니다.").foregroundStyle(.secondary)
          } else {
            Picker("원격", selection: $selectedRemote) {
              ForEach(state.remotes) { Text($0.name).tag($0.name) }
            }.disabled(store.remoteBusy)
            if let remote {
              URLLine(title: "Fetch", value: remote.fetchUrl)
              if remote.pushUrl != remote.fetchUrl { URLLine(title: "Push", value: remote.pushUrl) }
              if !remote.supported {
                Label(remote.problem.map { UserFacingFailure.message(ServiceFailure(code: $0, message: $0)) } ?? "현재 원격 설정을 지원하지 않습니다.", systemImage: "exclamationmark.triangle")
                  .font(.callout).foregroundStyle(WorkbenchTheme.warning).textSelection(.enabled)
              }
              Divider()
              HStack {
                Label(state.branchName ?? "브랜치 없음", systemImage: "arrow.triangle.branch").lineLimit(1)
                Spacer()
                if let ahead = state.ahead, let behind = state.behind {
                  Text("↑ \(ahead)  ↓ \(behind)").monospacedDigit()
                    .help("추적 브랜치의 마지막 Fetch 기준 · 보낼 커밋 / 받을 커밋")
                }
              }.font(.callout)
              if let upstream = state.upstreamRemote, let branch = state.upstreamBranch {
                Text("추적: \(upstream)/\(branch) · 마지막 Fetch 기준").font(.caption).foregroundStyle(.secondary)
              }
              HStack {
                TextField("원격 브랜치", text: $targetBranch)
                  .textFieldStyle(.roundedBorder).accessibilityLabel("Pull 또는 Push할 원격 브랜치 이름")
                Menu("선택") {
                  ForEach(remote.branches) { branch in Button(branch.name) { targetBranch = branch.name } }
                }.disabled(remote.branches.isEmpty).fixedSize()
              }.disabled(store.remoteBusy)
              HStack(spacing: 10) {
                Button("Fetch") { prepare(.fetch) }.help("원격 브랜치 정보 받기 · 작업 파일은 유지")
                Button("Pull…") { prepare(.pull) }
                  .disabled(!state.clean || state.head == nil || state.branch == nil || targetBranch.isEmpty)
                  .help(state.clean ? "현재 브랜치를 fast-forward로만 업데이트" : "변경 사항을 커밋하거나 정리한 뒤 Pull하세요.")
                Button("Push…") { prepare(.push) }
                  .disabled(state.head == nil || state.branch == nil || targetBranch.isEmpty)
                  .help("선택한 원격 브랜치로 보내기 · 강제 Push 없음")
              }.disabled(blocked || !remote.supported)
              DisclosureGroup("받아 둔 브랜치 \(remote.branches.count)") {
                ScrollView {
                  VStack(alignment: .leading, spacing: 6) {
                    ForEach(remote.branches) { branch in
                      HStack { Text(branch.name).lineLimit(1); Spacer(); Text(String(branch.oid.prefix(8))).foregroundStyle(.secondary) }
                    }
                  }.font(.system(size: 11, design: .monospaced)).padding(.top, 6)
                }.frame(maxHeight: 120)
              }.font(.caption)
            }
          }
          Divider()
          HStack {
            Button("원격 추가…") { adding = true; editing = true; name = ""; fetchURL = ""; pushURL = "" }
            if let remote {
              Button("URL 수정…") { adding = false; editing = true; name = remote.name; fetchURL = remote.fetchUrl; pushURL = remote.pushUrl == remote.fetchUrl ? "" : remote.pushUrl }
              Spacer()
              Button("연결 제거…", role: .destructive) { configure("remove", name: remote.name) }
            }
          }.disabled(blocked)
          if editing {
            VStack(alignment: .leading, spacing: 10) {
              TextField("원격 이름 (예: origin)", text: $name).disabled(!adding)
              TextField("Fetch URL · https://… 또는 git@host:…", text: $fetchURL)
              TextField("Push URL (비우면 Fetch와 동일)", text: $pushURL)
              HStack {
                Button("취소") { editing = false }
                Spacer()
                Button(adding ? "추가 확인…" : "수정 확인…") { configure(adding ? "add" : "update", name: name) }
                  .disabled(name.isEmpty || fetchURL.isEmpty)
              }
            }.textFieldStyle(.roundedBorder).disabled(blocked)
          }
        } else if store.remoteLoading {
          Text("원격 정보를 읽고 있습니다…").foregroundStyle(.secondary)
        }
        DisclosureGroup("인증과 연결 안내") {
          Text("GitHub·GitLab·Bitbucket·자체 Git 서버의 SSH/HTTPS URL을 사용합니다. SSH는 이 Mac의 agent·기본 키·known_hosts를 사용합니다. 처음 접속하는 서버는 터미널에서 신뢰 여부를 확인해 주세요. SSH 별칭과 사용자 지정 SSH 설정은 아직 지원하지 않습니다. HTTPS는 macOS Git의 Keychain 인증을 사용합니다. URL에 비밀번호나 토큰을 넣지 마세요.")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 6)
        }.font(.caption)
      }.padding(20).background {
        GeometryReader { geometry in Color.clear.preference(key: RemoteContentHeight.self, value: geometry.size.height) }
      }
    }.frame(height: min(600, max(160, contentHeight)))
      .onPreferenceChange(RemoteContentHeight.self) { contentHeight = $0 }
      .task(id: RemoteViewContext(session: store.planSession, selection: store.selection)) {
        selectedRemote = ""; targetBranch = ""; editing = false
        await store.loadRemoteState(); chooseDefault()
      }
      .onChange(of: store.repository?.snapshotHash) { _, _ in
        // Revalidate working-tree edits while preserving the user's URL/branch draft.
        guard !store.remoteBusy else { return }
        Task { await store.loadRemoteState() }
      }
      .onChange(of: selectedRemote) { _, _ in chooseBranch() }
      .onChange(of: store.remoteState) { _, _ in chooseDefault() }
      .sheet(item: $pending) { item in
        RemoteConfirmationSheet(item: item) {
          try await store.executeRemote(item.plan, configuration: item.configuration, url: item.fetchURL, pushURL: item.pushURL)
          editing = false
        }
      }
  }
  private func chooseDefault() {
    guard let state = store.remoteState else { return }
    if !state.remotes.contains(where: { $0.name == selectedRemote }) {
      selectedRemote = state.upstreamRemote ?? state.remotes.first?.name ?? ""
      chooseBranch()
    } else if targetBranch.isEmpty { chooseBranch() }
  }
  private func chooseBranch() {
    let state = store.remoteState
    targetBranch = state?.upstreamRemote == selectedRemote ? (state?.upstreamBranch ?? state?.branchName ?? "") : (state?.branchName ?? "")
  }
  private func prepare(_ action: RemoteAction) {
    do {
      let plan = try store.remotePlan(action, remote: selectedRemote, branch: targetBranch)
      if action == .fetch { Task { try? await store.executeRemote(plan) } }
      else { pending = RemoteConfirmation(plan: plan) }
    } catch { store.reportRemote(error) }
  }
  private func configure(_ action: String, name: String) {
    do {
      pending = RemoteConfirmation(plan: try store.remotePlan(.configure, remote: name), configuration: action,
        fetchURL: action == "remove" ? nil : fetchURL, pushURL: action == "remove" ? nil : pushURL)
    } catch { store.reportRemote(error) }
  }
}

private struct URLLine: View {
  let title: String
  let value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
    }
  }
}
private struct RemoteConfirmation: Identifiable {
  let plan: RemoteActionPlan
  var configuration: String? = nil
  var fetchURL: String? = nil
  var pushURL: String? = nil
  var id: UUID { plan.id }
}
private struct RemoteConfirmationSheet: View {
  let item: RemoteConfirmation
  let execute: () async throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var working = false
  @State private var error: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.title2.weight(.semibold))
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        row("저장소", item.plan.repositoryID)
        row("폴더", item.plan.repositoryPath)
        row("현재 브랜치", item.plan.localBranch ?? "없음")
        row("원격", item.plan.remote)
        row("URL", item.fetchURL ?? item.plan.url)
        if let push = item.pushURL, !push.isEmpty { row("Push URL", push) }
        if !item.plan.branch.isEmpty { row("대상", "refs/heads/" + item.plan.branch) }
      }.font(.callout).textSelection(.enabled)
      Text(item.plan.action == .pull ? "현재 브랜치를 fast-forward로만 업데이트합니다. 분기된 이력은 자동 병합하지 않습니다." : item.plan.action == .push ? "현재 커밋을 위 원격 브랜치로 보냅니다. 서버의 다른 이력을 덮어쓰는 강제 Push는 하지 않습니다." : item.configuration == "remove" ? "원격 연결과 받아 둔 추적 브랜치 정보를 제거합니다. 서버의 저장소는 유지됩니다." : "이 저장소의 원격 연결 설정을 변경합니다.")
        .font(.callout).foregroundStyle(.secondary)
      if let error { Text(error).foregroundStyle(WorkbenchTheme.danger).font(.callout).textSelection(.enabled) }
      HStack { Button("취소") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working); Spacer()
        if working { ProgressView().controlSize(.small) }
        Button(working ? "처리 중…" : "확인 후 실행") {
          working = true
          Task {
            do { try await execute(); dismiss() }
            catch { self.error = UserFacingFailure.message(error); working = false }
          }
        }.keyboardShortcut(.defaultAction).disabled(working)
      }
    }.padding(24).frame(width: 540).interactiveDismissDisabled(working)
  }
  private var title: String {
    item.plan.action == .configure ? (item.configuration == "remove" ? "원격 연결 제거" : "원격 설정 확인") : "\(item.plan.action.label) 확인"
  }
  private func row(_ title: String, _ value: String) -> some View {
    GridRow { Text(title).foregroundStyle(.secondary); Text(value).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true) }
  }
}

/// Harness-only composition of the real popover content. It sends no writes.
public struct RemotePreviewOverlay: View {
  @ObservedObject private var store: WorkbenchStore
  public init(store: WorkbenchStore) { self.store = store }
  public var body: some View {
    RemotePopover(store: store).frame(width: 460)
      .background(WorkbenchTheme.canvas, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).stroke(WorkbenchTheme.line))
      .shadow(color: .black.opacity(0.15), radius: 16, y: 6)
  }
}

private struct RemoteContentHeight: PreferenceKey {
  static let defaultValue: CGFloat = 420
  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct RemoteViewContext: Hashable {
  let session: UUID
  let selection: WorktreeSelection?
}
