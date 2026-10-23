# 현재 제한과 알려진 문제

이 문서는 개발 단계 구현의 경계입니다. 테스트 통과는 배포 인증이나 모든 저장소에서의 무결성·성능 보증이 아닙니다.

## 아직 지원하지 않는 기능

- Windows/Linux 네이티브 GUI.
- fetch·pull·push 등 원격 동기화, 변경 되돌리기(discard), merge·rebase·충돌 해결 UI.
- 일반적인 branch CRUD·checkout UI, history rewriting, 임의 행 스테이징. 브랜치 생성은 현재 Task 준비 과정에서만 지원합니다.
- Stash 적용·삭제. 현재 Stash는 목록·파일·Diff 읽기 전용입니다.
- GUI에서 다중 저장소·그룹·recipe·trust를 자유롭게 편집하는 기능.
- AI 도구 직접 실행, MCP 연결, 자동 CI·빌드·테스트·병합.
- 일반적인 실제 Xcode 프로젝트 편집. 첫 iOS adapter는 합성 FixtureApp/Debug의 xcconfig 두 key만 지원합니다.

## 배포·호환성

- `0.1.0-alpha.1`은 Apple Silicon(arm64)용 사전 릴리스 DMG입니다. Intel·universal2 공개 빌드는 없습니다. [다운로드와 설치 방법](../README.ko.md#macos에-설치하기)을 확인하세요.
- 선언된 최소 대상은 macOS 14이지만 실행 검증은 macOS 27.0.1에서만 했습니다. macOS 14–26에서의 호환성은 아직 검증하지 않았습니다.
- 앱과 Rust 엔진은 함께 배포하지만 Git은 포함하지 않습니다. 런타임은 `/usr/bin:/bin:/usr/sbin:/sbin` 경로를 사용하므로 Apple Command Line Tools 또는 Xcode의 Git이 필요합니다. Homebrew 전용 경로의 Git은 사용하지 않습니다.
- 공개 DMG의 서명과 Apple notarization 상태는 [릴리스 정보](releases/v0.1.0-alpha.1.md)에 기록합니다. 로컬 빌드의 기본 ad-hoc 서명과 혼동하지 마세요. notarization이 완료되지 않은 앱은 macOS의 실행 확인에 막힐 수 있습니다.
- 자동 업데이트 기능은 없습니다. 새 버전은 GitHub Releases에서 다운로드해 교체합니다.
- 라이선스는 미확정이며 현재 Cargo 메타데이터는 `UNLICENSED`입니다.

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

## 복구·조회 동작과 남은 UX 과제

2026-10-22 전체 검토에서 연결·준비 상태와 수동 새로고침을 보강했습니다.

- 새 프로젝트 연결 확인에 실패하면 이전 프로젝트의 연결·표시·초안을 함께 유지합니다. 서로 다른 프로젝트의 표시와 쓰기 대상이 섞이지 않도록 합니다.
- 작업 실행 요청 뒤 응답을 잃으면 원래 프로젝트 이름·경로와 실행 여부 확인 안내를 앱 세션에 남깁니다. 작업 목록과 실제 Git 상태를 확인해야 하며, 자동 재실행이나 재시작 이후의 안내 복원은 지원하지 않습니다.
- 작업 정보 조회 실패 시 준비·재시도·복구용 새 작업 동작을 제한하고 실패 안내를 표시합니다. 이미 실행 중인 것으로 알려진 작업의 명시적 취소는 계속 허용하며 서비스가 현재 상태를 확인합니다.
- 같은 프로젝트 재연결은 입력한 새 작업 이름·브랜치·방식을 유지하고 기존 계획만 무효화합니다. 실행 전 계획을 다시 확인해야 합니다.
- Git 속성·Diff 설정만 바뀌면 자동 polling의 파일 snapshot이 같을 수 있습니다. 수동 새로고침은 선택한 Diff도 다시 읽습니다.
- 브랜치 기록은 제목과 작성자·커밋 ID를 두 줄로 표시합니다. 매우 좁은 pane의 세로 목록 크기와 배치 방향 전환 시 스크롤·divider 유지는 후속입니다.

## 등록·복구

최근 메뉴와 workspace 등록은 별도입니다. 정상 등록은 메뉴에서 빠져도 다시 찾습니다. 손상된 최근 메뉴는 보존한 뒤 재구성합니다.

- 알려진 workspace의 설정 파일이 사라지면 journal을 새 workspace로 조용히 대체하지 않고 실패합니다. 현재 다시 열라는 안내만으로 해결되지 않을 수 있으며, 기존 설정을 복구해야 합니다.
- 안전하게 읽을 수 없는 kind record는 해당 항목 전체를 건너뜁니다. 그 항목이 복원하려던 workspace라면 기존 journal을 찾지 못하고 새 등록을 만들 수 있습니다. 손상된 등록의 자동 복구·병합 UI는 없습니다.

OS 마우스·키보드 입력과 VoiceOver, macOS 14 실행, 대형 실제 저장소 성능은 별도 검증이 필요합니다.
