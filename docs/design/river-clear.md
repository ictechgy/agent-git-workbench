# River Clear

**Status: implemented native design, 2026-10-23.** The product owner approved a less crowded, fresher River interface after reviewing the Claude/Codex comparison. Focus and Clear Shallows are the defaults for new preferences. Existing saved layouts remain intact. This document extends the [active design contract](../../DESIGN.md).

## Direction and authorship

Claude reviewed current native screenshots and scoped source, diagnosed repeated context/title rows, and proposed simpler arrangements and water-colored palettes. Codex built the comparison, recommended the two-column starting arrangement for the reported density problem, and corrected small accent-text contrast. The product owner approved that direction; Codex implemented it in SwiftUI/AppKit.

The approved G icon, “유리 속의 바다,” remains the app identity. Its glass material is concentrated in the icon. The reading surface stays opaque, with pale water-colored light navigation and an ocean-navy dark companion.

## Context and hierarchy

Normal repository-tab navigation uses **two 48pt rows**, replacing the earlier four bands:

1. Task/workspace selection; named task information, history, all branches, Stash, and commit actions; refresh and layout.
2. Repository navigation; actual branch or detached HEAD; folder kind and identifying basename; preparation actions when applicable.

Exceptional notices may use additional space. Repository-track navigation remains an optional alternative.

The folder control opens selectable full-path text, path copy, Finder, and explicit task/original-folder choices. A pending folder says it is planned and not yet prepared; unresolved task metadata is a separate state. Long values may truncate in the row, with full values exposed through help, accessibility, and disclosure.

Each pane has one draggable title row with placement and hide controls. Body content retains useful counts, filters, selected filenames, and read-only state while removing duplicate titles and routine explanatory copy. Hunk staging uses a quiet outlined action. The commit action retains the strongest filled treatment.

## Starting arrangements and persistence

| Arrangement | Initial content | Intended use |
|---|---|---|
| **Focus — 집중** | Files and broad unified Diff | Start with the code review itself; open reference/composer panels when needed |
| **Balanced — 균형** | Files, unified Diff, and a commit/Stash/task-information tab group | Keep a supporting panel beside the code |
| **Classic — 클래식** | Graph above files/Diff and commit/Stash/details | Familiar overview with multiple regions |
| **Code Review — 코드 검토** | Files/Diff and commit/Stash/details, without the top graph | Review with supporting panels available |
| **Repository Tracks — 저장소 트랙** | Expanded repository navigation plus review panels | Inspect preparation across repositories |

Presets are starting trees. Files, Diff, graph, branches, commit, Stash, and task information can still move to any edge, split recursively, combine into tabs, or hide. Preserve saved ratios, active tabs, hidden panes, and diff style. Existing layouts are not migrated to Focus; users choose it explicitly in **화면 구성**. Layout changes do not clear drafts or mutate Git.

Opening a visible pane selects its tab. A missing commit, Stash, or task-information pane joins an existing utility group; it opens beside Diff when no such group exists. History initially opens below Diff, and branches initially join Diff as a tab. Subsequent placement remains unrestricted. Header highlights follow the active visible pane, including custom tab groups.

The separately saved appearance choice is **맑은 물** (Clear Shallows, default), **깊은 물** (Clear Deep), or **시스템 설정** (System). Choosing a preset does not change appearance; choosing appearance does not change the dock tree.

## Color tokens

The implementation source is [WorkbenchTheme.swift](../../apps/macos/Sources/WorkbenchUI/WorkbenchTheme.swift). Panel reuses navigation and elevated surfaces reuse canvas, reducing near-identical background levels.

| Role | Clear Shallows | Clear Deep |
|---|---|---|
| Chrome | `#F3F7F9` | `#0E1A22` |
| Navigation/panel | `#EAF2F5` | `#122129` |
| Canvas/elevated | `#FFFFFF` | `#15232C` |
| Divider | `#D9E4EA` | `#24363F` |
| Primary text | `#102231` | `#E3EEF2` |
| Secondary text | `#5A6B78` | `#94A9B4` |
| Accent fill | `#0779A0` | `#4CC9E0` |
| Text on accent | `#FFFFFF` | `#032530` |
| Accent text | `#066B8C` | `#4CC9E0` |
| Selection | `#E1F3F8` | `#173B48` |
| Added fill | `#E6F6EA` | `#163828` |
| Deleted fill | `#FDEBEC` | `#3E1F27` |

Opaque sRGB token calculations give primary/canvas contrast of **16.21:1 light / 13.59:1 dark**, secondary/canvas **5.51:1 / 6.57:1**, and filled-action text **4.94:1 / 8.19:1**. Claude's light accent fill used as small text on navigation would give **4.36:1**, below 4.5:1. Codex's separate `#066B8C` accent-text token raises this to **5.31:1** on navigation and **5.27:1** on selection. Selected file text uses the primary text token.

These ratios verify token pairs, not complete native accessibility. Dedicated Increase Contrast values strengthen text/dividers. Keep signs and labels with semantic red/green, visible focus, and normal 12–13pt controls. Do not add translucent code backgrounds, decorative panel gradients, or amber/lilac status colors.

## Information that must remain explicit

- Actual repository, branch, folder kind, and folder name; full path through a named control.
- Preparation failure, planned folders, unresolved tasks, validation failure/read-only state, and unknown write outcomes, with the appropriate recovery action.
- Active filters, re-review reason, Stash read-only mode, and an explicit way back to current changes.
- Commit target/staged count, hook and signing behavior, and excluded untracked files. A cleaner composer must not hide what its commit actually does.
- Personal review marks, app-run checks, and human/AI reports as distinct records. Hunk requests and handoffs remain explicit copy-out actions.

No source/target scope, authorization, pinned plan, snapshot validation, or mutation policy is relaxed by this presentation change.

## Native validation

On 2026-10-23, 65 Rust tests and 62 Swift tests passed, along with CLI, native-protocol, and app-startup smoke checks. Native view renders covered light Focus, dark Balanced with a staged commit, read-only Stash, a 1100-point branch browser, and partial preparation failure. Live probes covered folder switching, review continuity, layout persistence, docking, preparation guards, and task context. The [README](../../README.md#development-and-validation) records the environment; the [development guide](../development.md#실제-네이티브-화면-렌더) documents reproducible native renders. Synthetic view renders do not constitute OS mouse/keyboard or VoiceOver validation.

Acceptance coverage should include light/dark at 1440×960 and 1100×720, both starting layouts, existing saved layouts, custom docking, independent appearance persistence, long identities, staged zero/nonzero, drafts, multiple stashes, re-review, pending/failed tasks, and unsupported/oversized diff states. Check accessibility preferences and keyboard/focus behavior separately.
