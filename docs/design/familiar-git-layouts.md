# 익숙한 Git GUI 구성과 레이아웃 선택

2026-10-19. 사용자는 GitKraken·SourceTree·Tower를 많이 참고해 기존 사용자에게 익숙하게 만들고, 레이아웃 커스터마이징도 검토하라고 요청했다. 아래는 공개 공식 자료에서 확인한 구성과 이 앱에 적용할 판단이다. 경쟁 앱을 직접 실행해 사용성·성능을 비교한 결과는 아니다.

| 공식 자료에서 확인한 구성 | 이 앱에 적용할 판단 |
| --- | --- |
| GitKraken: 좌측 refs 탐색, 중앙 commit graph, 우측 변경·stage·commit 패널. 패널 크기·표시와 그래프 열을 조절한다. | 그래프를 숨겨진 sheet에만 두지 않고 기본 화면에 배치한다. 파일→stage→commit 순서와 분리된 커밋 영역을 유지한다. |
| SourceTree: Working Copy와 Log/History 진입점, 좌측 branch/remote 탐색, 브랜치 선택으로 관련 기록 확인. | 친숙한 ‘변경 파일’, ‘전체 브랜치’, ‘커밋 기록’ 이름을 유지한다. 새 Task 은유가 Git 탐색을 대체하지 않게 한다. |
| Tower Mac: sidebar에서 repository의 작업 관점을 선택, Working Copy의 좌측 파일 목록과 우측 diff, 별도 history/detail 흐름. | 초기 배치에서 파일 목록과 diff의 좌우 관계를 사용하고 그래프를 접어 코드 검토에 집중할 수 있게 한다. |

Sources: [GitKraken Desktop Interface](https://help.gitkraken.com/gitkraken-desktop/interface/), [SourceTree Log/History](https://support.atlassian.com/sourcetree/kb/viewing-log-history-of-a-repository/), [Tower Interface Overview (Mac)](https://www.git-tower.com/help/guides/first-steps/tower-overview/mac), [Tower Working Copy](https://www.git-tower.com/help/guides/working-copy/overview/mac).

SourceTree 문서는 macOS와 Windows 설명이 섞여 있고 제품 범위 안내도 있으므로 현재 모든 버전의 정확한 배치를 보장하는 자료로 취급하지 않는다. Tower의 현재 overview는 텍스트 중심으로 확인했다. 브랜드 자산이나 상용 앱 화면을 제품에 복제하지 않는다.

## 초기 구현 기록 (2026-10-19)

- **클래식**: 가로 저장소 탭 → 현재 작업 폴더 → 상단 그래프 → 좌측 파일·중앙 diff·우측 커밋. 당시 첫 실행 기본값.
- **코드 검토**: 가로 저장소 탭, 파일·diff·커밋에 집중. 그래프는 숨김.
- **저장소 트랙**: 기존 G 구성. 선택 저장소가 펼쳐지고 다른 저장소는 준비 상태를 유지한다.
- 프리셋 외에 그래프 상단/하단/숨김, 커밋 패널 자동/표시/숨김, 파일·커밋 패널 너비, 그래프 높이, 나란히/한 화면 diff를 조절한다. 드래그와 접근성 크기 조절을 제공하고 저장한다.
- 레이아웃을 바꿔도 repo/worktree 선택·file/diff·stage 상태·커밋 초안은 같은 store에 남는다. 설정은 사용자 로컬에만 저장하고 앱 재시작 후 복원한다. 기본값 복구가 있다.

## 후속 사용자 수정: 자유로운 pane 도킹

사용자는 프리셋도 결국 정해진 레이아웃이라며 특정 pane을 특정 위치로 자유롭게 이동하라고 요청했다. 위의 고정 크기/그래프 위치 옵션은 첫 증분의 기록이다. 현재는 파일·diff·그래프·커밋·Stash·위치 정보·브랜치를 각각 분리하고, 제목 드래그로 임의의 다른 pane 좌/우/위/아래 또는 중앙 탭 그룹에 배치한다. 전체 작업공간 가장자리에도 도킹할 수 있다. 중첩 split/tab tree와 비율·선택 탭·숨긴 pane을 저장한다.

프리셋은 초기 트리만 제공한다. 각 pane의 배치 메뉴로 드래그와 동일한 작업을 수행하고, 숨기기/다시 열기·이전 배치·기본값 복구를 제공한다. 창이 좁아도 사용자의 배치를 임의로 바꾸지 않고 필요한 만큼 작업 영역을 스크롤한다. 독립 플로팅 OS 창은 이번 범위 밖이다. 커밋 선택에 따른 과거 파일 diff와 고급 branch CRUD도 별도다.

## 현재 시작 배치 (2026-10-23)

[River Clear](river-clear.md)는 새 설정의 기본값을 파일·Diff 두 열의 **집중** 배치로 바꿨다. **균형** 배치는 커밋·Stash·작업 정보를 오른쪽 탭 그룹으로 더한다. 기존에 저장한 배치와 자유 도킹은 유지하며, 위 클래식·코드 검토·저장소 트랙도 계속 선택할 수 있다. 현재 규칙은 [DESIGN.md](../../DESIGN.md)를 따른다.
