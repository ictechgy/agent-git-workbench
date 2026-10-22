# Agent Git Workbench

**English (canonical)** · [한국어](README.ko.md)

**A native macOS Git app for reviewing work across repositories and worktrees.**

> Early development. The SwiftUI/AppKit app and local Rust engine work today, but there is no stable release or distribution installer yet. The product name and license are still undecided.

The app UI and detailed guides are currently in Korean. English translations of UI labels below are provided for reference.

![Native workbench showing repository preparation status, changed files, side-by-side diffs, and task details](docs/images/workbench-dark.png)

*An actual SwiftUI/AppKit view rendered with synthetic Git repositories. App-run checks and AI reports appear as separate records on the right.*

## What it does

A **workspace** defines a set of repositories and preparation rules. A **Task** can create work branches and prepare separate working directories (Git linked worktrees) across those repositories. Review and commit changes per repository while keeping the original checkout in place. If preparation fails for one repository, completed work in the others is retained.

| Feature | Available today |
| --- | --- |
| Worktree-first tasks | Create branches and prepare working directories across configured repositories, inspect each repository's status or failure, and retry explicitly. |
| Review and commit | Changed files, split or unified diffs, text-hunk staging and unstaging, and commits of staged changes. |
| Branches and stash | Search local and remote-tracking branches, inspect recent history as of the last fetch, see linked worktree locations, and browse stash files and diffs read-only. |
| Review continuity | Restore file, diff, and scroll state within the same workspace, then refresh Git state. Commit drafts last for the app session; personal review and scroll state last for the current workspace session. |
| Movable panes | Split, move, tab, or hide the files, diff, graph, commit, stash, task details, and branches panes. Layouts persist across launches. |
| Review alongside AI tools | Copy a request for a selected hunk or a handoff draft, and record task intent, completion criteria, and verification results. |

The app does not call AI models directly. Copy a request into Claude, Codex, Grok, or another tool you use. Results entered by an AI or a person are stored as **reports**, separately from checks the app actually ran.

<details>
<summary>See the branches view</summary>

![Branches pane showing branches, linked working directories, commit IDs, subjects, and authors](docs/images/workbench-branches.png)

Selecting a branch reads its history without checking it out. This synthetic example shows a task whose working directory has not been prepared yet.

</details>

## Build and run

You need macOS, Xcode with Swift 6 or later, Rust/Cargo, Git, and Python 3. Validation used full Xcode; a Command Line Tools-only setup has not been tested. The Rust code uses edition 2024. The SwiftPM deployment target is macOS 14 or later, but runtime behavior on macOS 14 has not been tested.

The tested environment is macOS 27.0.1, Swift 6.4, Rust 1.97.1, Git 2.54.0, and Python 3.9.6. These are tested versions, not a complete minimum-version compatibility matrix.

```sh
git clone https://github.com/ictechgy/agent-git-workbench.git
cd agent-git-workbench
python3 scripts/build_macos.py
open "build/macos/Agent Git Workbench.app"
```

The script builds the Rust engine and Swift app into a development-signed bundle. No Node, npm, or web server is required. The app starts its bundled engine automatically; you do not need to enter a connection address or Unix socket path.

1. Choose **Explore the example** (`예제로 먼저 둘러보기`) on the start screen. This creates two synthetic repositories and a preparation task in the app's own storage.
2. Select a repository and check **Task working directory / Original project directory** (`이 작업용 폴더 / 원래 프로젝트 폴더`) and the actual path.
3. Review a change, choose **Stage this change** (`이 변경 스테이징`), and write a message in the commit pane.
4. Open your own project with **Open repository…** (`저장소 열기…`). Opening a directory alone does not modify its files, HEAD, or index, or grant trust to preparation scripts.

Example creation only affects synthetic repositories. **Open repository…** currently registers a single-repository workspace with no preparation recipes. Multi-repository and recipe configurations are demonstrated by the built-in example and the [CLI examples (Korean)](docs/cli.md). Creating, editing, or importing these configurations through the GUI is not implemented yet.

Running a new task for a project registered with **Open repository…** creates a `feature/<task_slug>` branch ref in the original repository. `materialize` also creates a separate working directory under the app data location; `branch_only` creates only the ref and leaves the directory pending. Registration defaults to the current branch at the time of first registration, falling back to the first local branch for a detached HEAD, or `main` if none exists. Check the base branch and OID in the plan before executing it.

## Keep working

- **Check the location:** Switch between a task's working directory and the original project directory. Pending or failed preparation is not shown as successful.
- **Resume a review:** Switching directories within a workspace restores the recent file, diff, and scroll position. Saved intent, completion criteria, and verification records remain in the journal. Commit drafts last for the current app session. Personal review and scroll state clear when you switch workspaces or quit.
- **Arrange the panes:** Drag a pane title to another pane's left, right, top, or bottom edge to split, or to its center to combine them as tabs. The layout is restored on the next launch. Reopen hidden panes through **Layout** (`화면 구성`) in the toolbar.
- **Separate checks from reports:** **Whitespace and conflict-marker check** (`공백 · 충돌 마커 검사`) runs `git diff --check` on tracked and staged changes and checks Git conflict and in-progress operation state. It does not build or test the project, or inspect untracked file contents or submodule contents.

Shortcuts: `⌘O` open repository · `⌘N` new task · `⌘R` refresh · `⌘↩` commit · `⌘⌥L` layout.

Settings, recent projects, and the task journal live in `~/Library/Application Support/AgentGitWorkbench`. The recent menu holds up to 30 entries; existing workspace registrations are looked up separately. Restoration depends on those registrations being readable.

## Current limitations

- **Not implemented:** Remote sync (fetch, pull, push, etc.), general branch checkout/rename/deletion (branches can be created only through task preparation), discard, merge/rebase/conflict-resolution UI, history rewriting, arbitrary-line staging, stash apply/delete, automatic AI calls, CI/build/merge execution, and Windows/Linux GUIs.
- **Git execution policy:** The app does not run Git fsmonitor, hooks, or external signing programs. App-created commits do not run hooks and are unsigned, including when `commit.gpgsign=true`. Configured external clean/smudge/process commands cause status/diff reads, preparation, and writes to be rejected. Global LFS filter commands trigger this restriction even when the repository does not use LFS. In the repository, inspect configured commands with `git config --show-origin --get-regexp '^filter\..*\.(clean|smudge|process)$'`.
- **Preparation and writes:** Working directories are prepared without changing the original checkout. A changed source snapshot or trust basis stops execution; there is no silent replanning or recovery through reset/clean. Recipes are not an OS security sandbox.
- **Display and resources:** Graph and branch history show at most 80 recent commits. Diff display is capped at 5,000 lines and 512 KiB. Speed, memory, and energy use on large repositories have not been measured.
- **Development-stage UX:** Notices for some lookup failures and lost responses, and the consistency of preparation-button state, still have known issues. A read already started in the engine may continue after the client cancels it.
- **Distribution:** The `.app` uses an ad-hoc development signature. Notarization, an installer, OS-level input testing, and VoiceOver validation are not complete.

See [limitations and known issues (Korean)](docs/limitations.md) for details.

## Development and validation

```sh
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
swift test --package-path apps/macos
```

On 2026-10-22, **62 Rust tests and 51 Swift tests** passed in the tested environment above, both in the developer checkout and in a separate copy containing only the files selected for publication. CLI, native-protocol, and app-startup smoke scenarios using synthetic repositories also passed. There is no CI yet. These results do not establish behavior on real user repositories or performance on large repositories.

Detailed guides are currently in Korean:

- [Development setup and validation commands](docs/development.md)
- [Architecture and execution boundaries](docs/architecture.md)
- [CLI, workspace, and recipe examples](docs/cli.md)
- [Limitations and known issues](docs/limitations.md)

The license has not been chosen. Cargo metadata currently declares `UNLICENSED`.
