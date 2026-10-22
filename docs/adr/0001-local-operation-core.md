# ADR 0001 — Local operation core and first adapter

후속 보강: 현재 index fingerprint는 raw index 파일 대신 staged mode/OID/stage/path와 intent-to-add 구분을 사용한다. 실행 정책·복구 범위는 [현재 구조](../architecture.md)와 [제한 목록](../limitations.md)을 따른다. 아래는 초기 기술 결정의 기록이며 현재 desktop 구현·시작 계약은 ADR 0002·0003이 우선한다.

Status: accepted for the initial spike, 2026-10-19. Packaging and public-alpha decisions remain open.

Desktop-framework update: [ADR 0002](0002-native-macos-and-design-c.md) supersedes the Tauri/React choice following the user's selection of C and a native macOS requirement. The historical frontend is not included in this publication; the Rust core decisions below remain active.

The initial spike used Rust/cargo, Git and an Xcode developer directory, with Node/npm for the former web frontend. Current native builds do not require Node/npm. No existing user repository is used as a fixture.

Use Git CLI for real Git state, Rust for policy/execution, bundled SQLite for the durable journal, and a user-private Unix socket for all clients. The spike's first desktop surface was Tauri 2 and React/TypeScript; that frontend is outside this publication. Current native builds do not require Node/npm. The current Rust dependency resolution is recorded in Cargo.lock. No runtime LLM dependency or external TCP service is introduced.

The domain crate contains versioned serializable contracts and generates JSON Schema via schemars. Branch groups resolve metadata policies; each repository's base ref becomes a pinned commit OID. Resolution records a source per field. The initial template supports one fixed-input Python xcconfig adapter per repository. Generic steps, arbitrary input schemas, inherited xcconfig, plist and pbxproj editing are deferred.

Plans expire after 15 minutes and retain source HEAD/branch, raw index hash, tracked/untracked file content and mode hashes. Executions own branch refs with an operation-specific reflog message. `git worktree add` receives the short local branch name: passing `refs/heads/...` produced a detached checkout in the first integration test. Checkout identity is verified before any recipe executes.

SQLite commits intent before Git/process effects. A unique idempotency key binds one plan payload to one operation, and a plan cannot be executed twice with different keys. Successful per-repo results are retained on a failed repository's retry. Restart marks unfinished operations as needing recovery. Explicit retry checks existing refs/worktrees, the recorded file observation and the fixed-input postcondition before replay. A simulated lost completion record is tested with already-applied file edits and failure gates proving the script was skipped.

One service owns a journal (file lock), and mutations are sequential with an additional common-Git-directory advisory lock shared by worktrees. This deliberately uses a coarser lock than the proposed per-worktree index lock. Read-only calls use Git optional-lock suppression and before/after snapshots so progress remains observable during a long recipe. External Git/editor processes do not honor these application locks; snapshots detect their changes and Git maintains its own ref/index locks. This does not promise transactional isolation from external processes.

Trust is a hash of repo-associated recipe contract, revision, absolute Python executable bytes, script bytes, write scope, timeout and target/configuration. A local `trust CONFIG RECIPE_ID` command saves the pin. No RPC exposes recipe registration or trust mutation. After materializing, the runner checks the pin again in the new cwd. Inputs are bounded version/build strings; stdout/stderr are drained and discarded, not journaled. The first adapter has no secret input fields. This is a policy-and-detection runner, not an OS sandbox. Arbitrary malicious scripts or descendants escaping the process group require stronger isolation and are outside this spike's guarantees.

The runner uses a dedicated Unix process group, TERM then KILL on timeout/cancel, and verifies file scope plus HEAD/index preservation after exit. It supports explicit fixed values, never increment operations. Failed/cancelled worktrees and file evidence are retained. No automatic reset, clean, branch deletion, worktree removal, push or deployment is implemented.

The frontend calls only a Rust Unix-socket client. The optional Vite development bridge binds loopback, requires a custom header, checks the browser Origin and only forwards to its configured socket. Production has no HTTP bridge. Read MCP remains a later adapter rather than a second execution implementation.

Alternatives: libgit2/gix if measured graph performance requires it; Electron if WebView distribution limits become material; per-repo/per-worktree scheduling after correctness tests; generic adapters only after inspect/plan/apply/verify and secret-redaction contracts are extended. Minimum Git/OS versions are not yet certified; the tested platform is this macOS host with Git 2.54.0.

Public API references used during implementation: [Tauri commands](https://v2.tauri.app/develop/calling-rust/), [rusqlite](https://docs.rs/rusqlite/0.38.0/rusqlite/), [Git apply](https://git-scm.com/docs/git-apply), [Rust UnixListener](https://doc.rust-lang.org/std/os/unix/net/struct.UnixListener.html). These describe APIs; the fixture scenarios provide the execution evidence.
