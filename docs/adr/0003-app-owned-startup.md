# ADR 0003: 앱이 시작과 엔진 연결을 소유한다

후속 보강: lease는 native runtime별로 공유하며 마지막 사용자가 server shutdown_if_idle을 요청한다. Process termination handler를 실행 전에 등록하고 완료 상태를 보존해 종료를 기다린다. 현재 화면·엔진 수명은 [구조](../architecture.md)와 [README](../../README.md)를 따른다. 아래는 시작 계약을 도입한 당시의 결정이다.

Status: accepted, 2026-10-19.

## 문제

기존 `.app`은 Swift 실행 파일만 포함하고 Rust service는 demo 스크립트가 실행했다. Finder에서 앱을 열면 `WORKBENCH_SOCKET`이 없어서 빈 입력에 “유효한 짧은 절대 Unix 소켓 경로를 입력하세요”가 표시됐다. 내부 IPC 경로를 사용자에게 요구하는 시작 화면도 제품 흐름에 맞지 않았다.

## 결정

- SwiftUI/AppKit와 사용자 선택 C안은 유지한다. 시작 화면은 저장소 폴더 선택, 내장 예제, 최근 프로젝트로 구성한다.
- 번들의 `Contents/Helpers/workbench`에 Rust 엔진을 포함하고 helper와 앱을 각각 로컬 서명한다. `WorkspaceRuntime` actor가 셸 없이 argv로 엔진을 시작하고 readiness를 확인한다. 앱 이동 후에도 번들 상대 경로로 찾는다.
- 저장소 등록·판별은 Rust CLI `inspect`/`workspace`를 사용한다. 앱 전용 설정만 만들고 선택한 checkout·HEAD·index를 수정하거나 그 저장소의 recipe를 신뢰하지 않는다. 첫 commit 전 저장소도 열 수 있다.
- 설정·journal·최근 기록은 Application Support에 둔다. IPC는 긴 저장소/사용자 경로와 독립적인 `/tmp/agw-UID/UUID.sock`을 사용한다. 전용 디렉터리 소유자·타입·0700 권한을 확인하고 service가 0600 소켓을 만든다.
- 예제 버튼은 앱 전용 새 합성 repo를 만들고 그 생성물에 한해 fixture recipe를 신뢰한다. 한 번 생성한 예제와 작업은 재사용한다. 사용자 repo로 확대해서 trust하지 않는다.
- 재연결은 같은 설정·journal·socket ID를 사용한다. 이미 준비된 service가 있으면 연결한다. UI 종료 때 자신이 시작한 유휴 service만 종료하며 실행 중인 operation은 중단하지 않는다.
- 기술 오류는 이해 가능한 한국어와 복구 동작으로 표시하고 상세 진단은 접힌 영역에 둔다. 정상 시작 화면에는 연결 설정을 노출하지 않는다.

## 검증 경계

새 임시 repo에서 실제 Swift runtime→번들 Rust→Git 경로를 검사한다. native content 렌더는 실제 OS 폴더 선택·키보드·접근성 테스트와 구분한다. 개발용 `WORKBENCH_SOCKET`/`WORKBENCH_SERVICE` 주입은 유지하지만 일반 실행의 필수 조건으로 삼지 않는다. notarization/설치기는 별도다.
