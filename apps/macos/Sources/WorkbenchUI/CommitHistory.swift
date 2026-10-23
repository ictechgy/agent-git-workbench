import SwiftUI
import WorkbenchProtocol

struct CommitHistory: View {
  @ObservedObject var store: WorkbenchStore
  @Binding var expanded: Bool
  var allowsCollapse = true
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 16) {
        Button("커밋 기록") {
          store.historyTab = "history"
          expanded = true
        }.foregroundStyle(
          store.historyTab == "history" ? WorkbenchTheme.accent : .secondary)
          .accessibilityAddTraits(store.historyTab == "history" ? [.isSelected] : [])
        Button("준비 기록") {
          store.historyTab = "events"
          expanded = true
        }.foregroundStyle(
          store.historyTab == "events" ? WorkbenchTheme.accent : .secondary)
          .accessibilityAddTraits(store.historyTab == "events" ? [.isSelected] : [])
        Spacer()
        if !expanded {
          Text("\(store.repository?.graph.count ?? 0)개 커밋").font(.system(size: 11)).foregroundStyle(
            .secondary)
        }
        if allowsCollapse {
          Button {
            expanded.toggle()
          } label: {
            Image(systemName: expanded ? "chevron.down" : "chevron.up")
          }.help(expanded ? "기록 패널 접기" : "기록 패널 펼치기")
            .accessibilityLabel(expanded ? "기록 패널 접기" : "기록 패널 펼치기")
        }
      }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 24).frame(
        height: 40)
      Divider()
      if expanded {
        if store.historyTab == "history" {
          GeometryReader { geometry in
            ScrollView([.vertical, .horizontal]) {
              VStack(spacing: 0) {
                HStack(spacing: 0) {
                  Text("그래프").padding(.leading, 20).frame(width: 92, alignment: .leading)
                  HStack(spacing: 10) {
                    Text("설명").frame(maxWidth: .infinity, alignment: .leading)
                    Text("작성자").frame(width: 85, alignment: .leading)
                    Text("커밋").frame(width: 70, alignment: .leading)
                  }.padding(.trailing, 20)
                }.font(.system(size: 10)).foregroundStyle(WorkbenchTheme.secondaryText).frame(height: 28)
                Divider()
                let commits = store.repository?.graph ?? []
                if commits.isEmpty {
                  Text(store.pendingWorktree ? "워크트리를 준비하면 커밋 기록이 표시됩니다." : "아직 커밋 기록이 없습니다.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(20)
                }
                HStack(spacing: 0) {
                  GraphCanvas(commits: commits).frame(
                    width: 92, height: CGFloat(commits.count * 36))
                  VStack(spacing: 0) {
                    ForEach(commits) { commit in
                      HStack(spacing: 10) {
                        HStack(spacing: 10) {
                          Text(commit.subject).font(.system(size: 12)).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                          if !commit.refs.isEmpty {
                            let refs = commit.refs.replacingOccurrences(of: "HEAD -> ", with: "")
                              .components(separatedBy: ", ")
                            Text((refs.first ?? "") + (refs.count > 1 ? " +\(refs.count - 1)" : ""))
                              .font(
                                .system(size: 10, design: .monospaced)
                              )
                              .foregroundStyle(WorkbenchTheme.accent).padding(.horizontal, 6)
                              .padding(
                                .vertical, 3
                              )
                              .background(
                                WorkbenchTheme.accent.opacity(0.07),
                                in: RoundedRectangle(cornerRadius: 3)
                              ).lineLimit(1).truncationMode(.middle).frame(maxWidth: 190).help(
                                commit.refs)
                          }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(commit.author).font(.system(size: 10)).foregroundStyle(.secondary)
                          .frame(
                            width: 85, alignment: .leading
                          ).lineLimit(1)
                        Text(String(commit.oid.prefix(8))).font(
                          .system(size: 10, design: .monospaced)
                        ).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                      }.padding(.trailing, 20).frame(height: 36).help(
                        commit.subject + "\n" + commit.oid)
                    }
                  }
                }
              }.frame(width: max(580, geometry.size.width))
            }
          }
          Text("최근 \(store.repository?.graph.count ?? 0)개 커밋 · 최대 80개")
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 6)
        } else {
          let events = store.events.filter { $0.operationId == store.contextOperation?.id }
          if events.isEmpty {
            ContentUnavailableView(
              "준비 로그가 없습니다", systemImage: "list.bullet.rectangle",
              description: Text("Task를 선택하면 서비스 이벤트를 볼 수 있습니다."))
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(events.reversed()) { event in
                  HStack(spacing: 12) {
                    StateDot(state: event.status)
                    Text(Date(timeIntervalSince1970: Double(event.timestamp)), style: .time)
                      .foregroundStyle(.secondary).frame(width: 75, alignment: .leading)
                    Text(StatusText.label(event.status))
                    Spacer()
                    Text("#\(event.sequence)").foregroundStyle(.tertiary)
                  }.font(.system(size: 11, design: .monospaced))
                }
              }.padding(20)
            }
          }
        }
      }
    }.background(WorkbenchTheme.canvas)
  }
}

struct GraphCanvas: View {
  let commits: [HistoryCommit]
  var rowHeight: CGFloat = 36
  var body: some View {
    Canvas { context, _ in
      var lanes: [String?] = []
      var points: [String: CGPoint] = [:]
      for (row, commit) in commits.enumerated() {
        var lane = lanes.firstIndex(of: commit.oid)
        if lane == nil {
          lane = lanes.firstIndex(of: nil) ?? lanes.count
          if lane == lanes.count { lanes.append(commit.oid) } else { lanes[lane!] = commit.oid }
        }
        let slot = lane!
        points[commit.oid] = CGPoint(x: CGFloat(28 + slot * 18), y: CGFloat(row) * rowHeight + rowHeight / 2)
        lanes[slot] = nil
        for (index, parent) in commit.parents.enumerated() where !lanes.contains(parent) {
          let next = index == 0 ? slot : lanes.firstIndex(of: nil) ?? lanes.count
          if next == lanes.count { lanes.append(parent) } else { lanes[next] = parent }
        }
      }
      for commit in commits {
        guard let point = points[commit.oid] else { continue }
        for parent in commit.parents {
          guard let end = points[parent] else { continue }
          var path = Path()
          path.move(to: point)
          path.addCurve(
            to: end, control1: .init(x: point.x, y: (point.y + end.y) / 2),
            control2: .init(x: end.x, y: (point.y + end.y) / 2))
          context.stroke(
            path, with: .color(point.x == 28 ? WorkbenchTheme.accent : WorkbenchTheme.secondaryText), lineWidth: 1.7)
        }
      }
      for point in points.values {
        let circle = Path(
          ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
        context.fill(circle, with: .color(WorkbenchTheme.accent))
      }
    }.accessibilityLabel("커밋의 실제 부모 OID를 연결한 그래프")
  }
}
