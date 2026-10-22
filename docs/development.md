# 개발과 검증

macOS 네이티브 앱은 `apps/macos`, 공통 Rust 엔진은 `crates`에 있습니다. SwiftPM의 최소 도구 버전은 6.0, Rust edition은 2024입니다. 검증한 버전은 루트 [README](../README.md)에 적었습니다.

## 빌드

```sh
python3 scripts/build_macos.py
open "build/macos/River.app"
```

기본값은 debug 빌드입니다. 로컬 release 빌드는 아래와 같습니다. notarization이나 배포 업로드를 수행하지 않습니다.

```sh
python3 scripts/build_macos.py --configuration release
```

## 단위·통합 테스트

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
swift test --package-path apps/macos
python3 scripts/test_ios_adapter.py
python3 scripts/test_git_execution.py
```

Rust 테스트는 원래 폴더·index 보존, 고정 계획·recipe 신뢰, 부분 실패·취소·재개, journal/idempotency, hunk stage·commit 등을 합성 fixture로 검사합니다. Swift 테스트는 소켓·스키마, 초안·Task 문맥, 늦은 응답·조회 실패, 분할·도킹·검토 상태를 검사합니다. 검증 결과는 해당 소스 버전에만 적용합니다.

## 실제 프로세스 경계 검증

Python harness는 CLI 바이너리와 Swift probe/renderer를 사용합니다. 깨끗한 checkout에서는 먼저 모두 빌드하세요.

```sh
cargo build --workspace
swift build --package-path apps/macos
python3 scripts/build_macos.py
python3 scripts/smoke.py
python3 scripts/native_smoke.py
python3 scripts/startup_smoke.py
```

- `smoke.py`: 실제 Unix 소켓 요청으로 branch-only → materialize → 부분 실패 → 재개를 실행하고 Git 결과를 교차 확인합니다.
- `native_smoke.py`: 제품과 같은 Swift 클라이언트로 Rust 엔진을 호출해 준비·부분 스테이징·커밋·Stash·브랜치 조회를 검사합니다.
- `startup_smoke.py`: 패키징한 helper의 위치 이동, 연결 환경 변수 없는 시작, 재시작·다른 인스턴스·예제 재사용을 검사합니다.

새 임시 저장소만 사용하며 결과를 독립 Git 명령으로 확인합니다. 이 harness는 기존 사용자 앱을 조작하는 마우스·키보드 E2E나 성능 벤치마크가 아닙니다. 일부 fixture는 실행 후 `/tmp`에 남습니다.

## 실제 네이티브 화면 렌더

위 프로세스 경계 검증의 Rust·Swift 빌드를 마친 뒤 실행합니다.

```sh
python3 scripts/native_preview.py /tmp/workbench-light.png --appearance light --layout focus --scene review
python3 scripts/native_preview.py /tmp/workbench-dark.png --appearance dark --layout balanced --scene partial --stashes
python3 scripts/native_preview.py /tmp/workbench-branches.png --appearance light --width 1100 --height 800 --scene waiting --branches --dock-scene branches
```

실제 Rust 서비스와 새 합성 Git 상태에 연결한 SwiftUI/AppKit content view입니다. PNG와 같은 이름의 JSON에 사용한 fixture와 상태를 기록합니다. 데스크톱 전체 캡처나 OS 입력·접근성 검증으로 해석하지 않습니다.

`--layout focus`는 파일·Diff의 2열 집중 배치, `--layout balanced`는 커밋·Stash·작업 정보 탭을 더한 3열 균형 배치를 사용합니다. `--appearance`는 배치와 독립적으로 적용합니다. 미리보기는 격리된 설정을 사용하므로 사용자가 저장한 앱 배치를 바꾸지 않습니다. 실제 앱에서는 **화면 구성**에서 배치와 색상을 각각 선택하며, 기존 저장 배치는 새 기본값으로 덮어쓰지 않습니다.

## 소스 안내

```text
apps/macos/             SwiftUI/AppKit 앱, 런타임, IPC 클라이언트와 테스트
crates/domain/          Task·계획·operation·공개 계약
crates/git-adapter/     Git argv, 출력 파싱, snapshot·읽기/쓰기 경계
crates/recipe-runner/   고정 recipe 실행·범위 검사
crates/operation-service/ SQLite journal, 잠금, 준비·조회·mutation, Unix IPC
crates/cli/             fixture·workspace·trust·serve·rpc·schema 명령
adapters/ios-version/   합성 xcconfig 고정값 adapter
schemas/               Rust 타입에서 생성한 공개 JSON Schema
scripts/               빌드와 합성 검증 harness
```

스키마 재생성:

```sh
cargo run -p workbench-cli -- schemas schemas
```

수정할 때는 화면의 성공 표시만 보지 말고 Git HEAD·index·파일·worktree 상태를 확인하세요. 준비 변경과 staging·commit은 별도 동작으로 유지하고, 불명확한 쓰기 결과를 자동 반복하지 않습니다.
