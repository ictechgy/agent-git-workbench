import AppKit
import SwiftUI
import WorkbenchProtocol

struct TaskContextView: View {
  @ObservedObject var store: WorkbenchStore
  @ObservedObject var model: TaskContextStore
  @State private var editing = false
  @State private var reporting = false
  @State private var editorIdentity = ""
  @State private var reportIdentity = ""
  @State private var handoffText: String?
  private var canRecord: Bool {
    model.loaded && !model.working && !model.isDirty && !store.busy
      && !store.validatingSelection && store.repository != nil && !store.hasRunningOperation
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Label("작업 목적", systemImage: "scope").font(.system(size: 13, weight: .semibold))
          .foregroundStyle(WorkbenchTheme.accentText).accessibilityAddTraits(.isHeader)
        Spacer()
        Button(model.isDirty ? "이어서 작성" : "작성 · 수정") { editorIdentity = model.identity; editing = true }
          .disabled(!model.loaded || model.working)
      }
      Text(store.contextOperation == nil ? "이 저장소에 저장됩니다." : "이 작업의 저장소들이 함께 사용하는 기록입니다.")
        .font(.system(size: 11)).foregroundStyle(.secondary)
      if let c = model.bundle?.context {
        Text(c.purpose.isEmpty ? "어떤 문제를 해결할 작업인가요?" : c.purpose)
          .font(.system(size: 13)).foregroundStyle(c.purpose.isEmpty ? .secondary : .primary)
          .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        VStack(alignment: .leading, spacing: 8) {
          Text("완료 조건").font(.system(size: 12, weight: .semibold))
          if c.criteria.isEmpty {
            Text("완료를 판단할 조건을 적어 두세요.").foregroundStyle(.secondary)
          } else {
            ForEach(Array(c.criteria.enumerated()), id: \.offset) { _, criterion in
              HStack(alignment: .top, spacing: 7) {
                Image(systemName: "circle").font(.system(size: 9)).padding(.top, 3).foregroundStyle(.secondary)
                Text(criterion).fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }.font(.system(size: 12))
        if !c.notes.isEmpty {
          DisclosureGroup("남은 일 · 주의할 점") {
            Text(c.notes).font(.system(size: 12)).textSelection(.enabled).padding(.top, 6)
          }.font(.system(size: 12))
        }
        if !c.references.isEmpty {
          DisclosureGroup("참고 \(c.references.count)개") {
            ForEach(Array(c.references.enumerated()), id: \.offset) { _, reference in
              Text(reference).font(.system(size: 11)).textSelection(.enabled).padding(.top, 4)
            }
          }.font(.system(size: 12))
        }
      } else if !model.loaded && model.message == nil {
        ProgressView("작업 정보 읽는 중…").controlSize(.small)
      }
      if model.isDirty {
        Text("저장하지 않은 작성 내용이 있습니다. 검증·인수인계 전에 저장해 주세요.")
          .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.warning)
      }
      Divider()
      VStack(alignment: .leading, spacing: 10) {
        HStack {
          Label("검증 기록", systemImage: "checkmark.shield").font(.system(size: 13, weight: .semibold))
            .foregroundStyle(WorkbenchTheme.accentText).accessibilityAddTraits(.isHeader)
          Spacer()
          if model.working { ProgressView().controlSize(.small) }
        }
        Button("공백 · 충돌 마커 검사", systemImage: "play.circle") {
          guard let snapshot = store.repository?.snapshotHash, let location = store.selection else { return }
          Task { await model.runCheck(snapshot: snapshot, at: location); await store.refresh() }
        }.disabled(!canRecord)
        Text("추적 중인 파일과 스테이징을 검사합니다. 빌드·테스트·새 파일·서브모듈 내용은 검사하지 않습니다.")
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Button("직접 / AI 결과 기록…") { reportIdentity = model.identity; reporting = true }.disabled(!canRecord)
        if let bundle = model.bundle {
          if bundle.verifications.isEmpty {
            Text("아직 검증 기록이 없습니다.").font(.system(size: 12)).foregroundStyle(.secondary)
          }
          ForEach(Array(bundle.verifications.prefix(5))) { receipt in
            receiptRow(receipt, requirements: bundle.context.requirementsHash)
          }
          if bundle.verifications.count > 5 {
            DisclosureGroup("이전 기록 \(bundle.verifications.count - 5)개") {
              ForEach(Array(bundle.verifications.dropFirst(5))) { receipt in
                receiptRow(receipt, requirements: bundle.context.requirementsHash).padding(.top, 10)
              }
            }.font(.system(size: 12))
          }
        }
      }
      Divider()
      Button {
        Task { handoffText = await model.handoff() }
      } label: {
        Label("인수인계 초안 만들기", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
      }.disabled(!model.loaded || model.working || model.isDirty || store.busy)
      Text("저장소별 현재 상태와 기록을 모아, 복사 전에 내용을 확인하고 수정합니다.")
        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      if let message = model.message {
        Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .sheet(isPresented: $editing) { ContextEditor(model: model, identity: editorIdentity) }
    .sheet(isPresented: $reporting) { VerificationReportEditor(model: model, identity: reportIdentity) }
    .sheet(isPresented: Binding(get: { handoffText != nil }, set: { if !$0 { handoffText = nil } })) {
      HandoffEditor(text: Binding(get: { handoffText ?? "" }, set: { handoffText = $0 }))
    }
    .onChange(of: model.identity) { _, _ in editing = false; reporting = false }
  }
  private func receiptRow(_ r: VerificationReceipt, requirements: String) -> some View {
    DisclosureGroup {
      VStack(alignment: .leading, spacing: 6) {
        Text("\(r.repoId) · \(r.path)")
        Text("HEAD \(r.head.prefix(12)) · 상태 \(r.snapshotHash.prefix(12))")
        Text(r.command).textSelection(.enabled)
        Text(r.note).textSelection(.enabled)
        if !r.output.isEmpty { Text(String(r.output.prefix(8_000))).font(.system(size: 10, design: .monospaced)).textSelection(.enabled) }
        if r.truncated || r.output.count > 8_000 { Text("출력이 길어 일부만 표시합니다.") }
      }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
    } label: {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(r.repoId) · \(r.opId == nil ? "원래 폴더" : "작업용 폴더")")
          .font(.system(size: 12, weight: .semibold)).lineLimit(2)
        HStack {
          Label(r.sourceLabel, systemImage: r.kind == "git_check" ? "terminal" : "quote.bubble")
            .font(.system(size: 12, weight: .medium))
          Spacer(minLength: 0)
          Label(r.verdictLabel, systemImage: r.verdict == "failed" ? "xmark.circle" : r.verdict == "passed" ? "checkmark.circle" : "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(r.verdict == "failed" ? WorkbenchTheme.danger : r.kind == "git_check" && r.verdict == "passed" ? WorkbenchTheme.success : WorkbenchTheme.secondaryText)
        }
        Text(r.freshness(repoId: store.selection?.repoId, opId: store.selection?.opId,
          snapshot: store.validatingSelection ? nil : store.repository?.snapshotHash, requirements: requirements))
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        (Text(Date(timeIntervalSince1970: r.finishedAt), style: .relative) + Text(" 전"))
          .font(.system(size: 11)).foregroundStyle(.secondary)
      }
    }.padding(.vertical, 10)
      .overlay(alignment: .bottom) {
        Rectangle().fill(WorkbenchTheme.line).frame(height: 1).allowsHitTesting(false)
      }
  }
}

private struct ContextEditor: View {
  @ObservedObject var model: TaskContextStore
  let identity: String
  @Environment(\.dismiss) private var dismiss
  private func binding(_ key: WritableKeyPath<ContextDraft, String>) -> Binding<String> {
    Binding(get: { model.draft?[keyPath: key] ?? "" }, set: { if identity == model.identity { model.draft?[keyPath: key] = $0 } })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("작업 목적 · 완료 조건").font(.headline)
      Text("목적").font(.subheadline)
      TextField("해결할 문제와 원하는 결과", text: binding(\.purpose), axis: .vertical).lineLimit(2...4)
      editor("완료 조건 · 한 줄에 하나씩", key: \.criteria, height: 100)
      editor("남은 일 · 주의할 점", key: \.notes, height: 85)
      editor("참고 경로 / 링크 · 한 줄에 하나씩 (내용은 자동으로 읽지 않습니다)", key: \.references, height: 55)
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
      HStack {
        if model.draft?.revision != model.bundle?.context.revision {
          Button("현재 저장본 불러오기") { if identity == model.identity { model.reloadDraft() } }
          Text("다른 저장본이 있습니다. 입력을 먼저 복사해 두세요.").font(.caption).foregroundStyle(WorkbenchTheme.warning)
        }
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("저장") { Task { guard identity == model.identity else { return }; await model.save(); if !model.isDirty { dismiss() } } }
          .keyboardShortcut(.defaultAction).disabled(!model.isDirty || !model.loaded)
      }
    }.padding(24).frame(width: 620).disabled(model.working || identity != model.identity)
  }
  private func editor(_ label: String, key: WritableKeyPath<ContextDraft, String>, height: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.subheadline)
      TextEditor(text: binding(key)).font(.system(size: 13)).frame(height: height)
        .border(WorkbenchTheme.line).accessibilityLabel(label)
    }
  }
}

private struct VerificationReportEditor: View {
  @ObservedObject var model: TaskContextStore
  let identity: String
  @Environment(\.dismiss) private var dismiss
  @State private var kind = "human_report"
  @State private var verdict = "unknown"
  @State private var command = ""
  @State private var note = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("검증 결과 기록").font(.headline)
      Picker("출처", selection: $kind) {
        Text("직접 적은 결과").tag("human_report")
        Text("AI가 보고한 결과").tag("ai_report")
      }.pickerStyle(.segmented)
      Text("앱이 실행을 관찰한 검증과 구분해 저장합니다. 아래 명령은 실행되지 않습니다.")
        .font(.caption).foregroundStyle(.secondary)
      TextField("검증 항목 / 실행했다고 보고한 명령 (선택)", text: $command)
      Picker("보고된 결과", selection: $verdict) {
        Text("확인 필요").tag("unknown"); Text("통과").tag("passed"); Text("실패").tag("failed")
      }
      Text("결과와 근거").font(.subheadline)
      TextEditor(text: $note).font(.system(size: 13)).frame(height: 150).border(WorkbenchTheme.line)
        .accessibilityLabel("결과와 근거")
      if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
      HStack {
        Spacer()
        Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("보고로 저장") {
          Task { if await model.record(kind: kind, verdict: verdict, command: command, note: note, at: identity) { dismiss() } }
        }.keyboardShortcut(.defaultAction).disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }.padding(24).frame(width: 580).disabled(model.working)
  }
}

private struct HandoffEditor: View {
  @Binding var text: String
  @Environment(\.dismiss) private var dismiss
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("인수인계 초안").font(.headline)
      Text("경로·변경 파일명·기록이 포함되어 있습니다. 전달할 내용을 확인하고 수정하세요.")
        .font(.caption).foregroundStyle(.secondary)
      TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(minHeight: 440)
        .border(WorkbenchTheme.line).accessibilityLabel("인수인계 초안")
      HStack {
        if copied { Text("복사했습니다.").font(.caption).foregroundStyle(.secondary) }
        Spacer()
        Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("초안 복사") { NSPasteboard.general.clearContents(); copied = NSPasteboard.general.setString(text, forType: .string) }
          .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 760, height: 650)
  }
}
