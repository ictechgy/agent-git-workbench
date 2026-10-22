# 현재 제한과 알려진 문제

이 문서는 개발 단계 구현의 경계입니다. 테스트 통과는 배포 인증이나 모든 저장소에서의 무결성·성능 보증이 아닙니다.

## 아직 지원하지 않는 기능

- Windows/Linux 네이티브 GUI, 배포 설치기·notarization.
- fetch·pull·push 등 원격 동기화, 변경 되돌리기(discard), merge·rebase·충돌 해결 UI.
- 일반적인 branch CRUD·checkout UI, history rewriting, 임의 행 스테이징. 브랜치 생성은 현재 Task 준비 과정에서만 지원합니다.
- Stash 적용·삭제. 현재 Stash는 목록·파일·Diff 읽기 전용입니다.
- GUI에서 다중 저장소·그룹·recipe·trust를 자유롭게 편집하는 기능.
- AI 도구 직접 실행, MCP 연결, 자동 CI·빌드·테스트·병합.
- 일반적인 실제 Xcode 프로젝트 편집. 첫 iOS adapter는 합성 FixtureApp/Debug의 xcconfig 두 key만 지원합니다.

## Git·준비 정책

- Git fsmonitor·hook·외부 서명 프로그램을 실행하지 않습니다. 앱 커밋에는 hook이 적용되지 않고, `commit.gpgsign=true`여도 서명하지 않습니다.
- 외부 clean/smudge/process 필터 설정이 있으면 명시적으로 중단합니다. LFS나 사용하지 않는 전역 필터도 현재 제한에 포함됩니다.
- 서브모듈·특수 파일 준비와 일부 인코딩은 지원하지 않습니다. 올바른 UTF-8로 해석할 수 없는 Diff는 경고를 표시하며 hunk staging·개인 검토 표시·수정 요청에 쓰지 않습니다.
- Source-plan drift·신뢰 변경·canonical worktree 불일치는 중단 사유입니다. 자동 재계획·reset·clean·강제 삭제로 복구하지 않습니다.
- Recipe는 OS sandbox가 아닙니다. 저장소 간 원자적 commit/rollback, process group을 벗어난 자식, 모든 비멱등 script의 안전성을 보장하지 않습니다.
- 일반 staging·commit의 영속 mutation journal과 범용 재시도 idempotency는 후속입니다. 결과가 불명확하면 Git 상태를 확인하고 자동 반복하지 않습니다.

## 표시·성능 경계

- 그래프와 선택 브랜치 기록은 최대 80개 commit을 표시합니다.
- Diff 표시는 5,000줄·512 KiB로 제한합니다. 큰 응답은 wire 크기 제한으로 실패할 수도 있습니다.
- 개인 검토 checkpoint는 최대 32개·텍스트 합계 4 MiB·개별 512 KiB입니다. 최근 폴더의 review cache는 6개입니다. 세션 초안은 이 cache와 별도로 유지합니다.
- 준비 접수 8개, IPC handler 32개, 직렬 mutation은 서로 다른 제한입니다. 이 수치가 전체 메모리나 UI 응답 시간을 보장하지는 않습니다.
- 파일·staged 선택의 빠른 연속 입력은 80ms 동안 묶습니다. 클라이언트가 취소해도 이미 시작한 서버 읽기는 계속될 수 있습니다.
- 방문한 workspace 엔진은 세션 동안 남을 수 있습니다. 많은 저장소를 오갈 때의 RSS·에너지·복귀 시간은 아직 측정하지 않았습니다.
- 큰 journal에서 최초 JSON index 생성이 엔진의 시작 대기 시간을 넘을 가능성, 큰 파일 snapshot·checkpoint 저장 비용도 계측 과제입니다.

## 남아 있는 UX 문제

2026-10-22 소스 검토와 합성 재현에서 다음 비차단 항목을 확인했습니다.

- 이전 workspace가 요청을 접수한 뒤 응답을 잃고 다른 workspace로 전환하면, 현재 화면에 실행 여부 확인 안내가 남지 않을 수 있습니다. 이전 프로젝트의 작업 목록과 실제 Git 상태를 확인해야 합니다.
- 작업 정보 조회에 실패해도 보관된 요약 때문에 워크트리 준비·재시도·새 작업 버튼이 남을 수 있습니다. 편집은 제한하며 서비스는 쓰기 전 상태·신뢰·snapshot을 다시 검증하지만 화면 안내가 일치하지 않을 수 있습니다.
- `list_operations` 자체가 실패하면 일부 pane이 조회 중 문구를 유지할 수 있습니다.
- 재연결은 기존 계획을 무효화합니다. 같은 프로젝트에서도 프로젝트 변경 문구가 표시되거나 계획 sheet의 입력이 초기화될 수 있습니다.
- 좁은 브랜치 pane의 제목 공간, 세로 목록 크기와 배치 방향 전환 시 스크롤·divider 유지가 미흡합니다.

## 등록·복구

최근 메뉴와 workspace 등록은 별도입니다. 정상 등록은 메뉴에서 빠져도 다시 찾습니다. 손상된 최근 메뉴는 보존한 뒤 재구성합니다.

- 알려진 workspace의 설정 파일이 사라지면 journal을 새 workspace로 조용히 대체하지 않고 실패합니다. 현재 다시 열라는 안내만으로 해결되지 않을 수 있으며, 기존 설정을 복구해야 합니다.
- 안전하게 읽을 수 없는 kind record는 해당 항목 전체를 건너뜁니다. 그 항목이 복원하려던 workspace라면 기존 journal을 찾지 못하고 새 등록을 만들 수 있습니다. 손상된 등록의 자동 복구·병합 UI는 없습니다.

OS 마우스·키보드 입력과 VoiceOver, macOS 14 실행, 대형 실제 저장소 성능은 별도 검증이 필요합니다.
