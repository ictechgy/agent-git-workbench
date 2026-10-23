# Make River your workspace

River keeps a global workspace arrangement across repositories. Switching repositories does not choose a different layout. Start from a familiar arrangement, then move any panel to an edge or combine panels as tabs.

## Open the controls

Use **Screen Configuration** (`화면 구성`) in the header, or **View → Screen Configuration** in the macOS menu bar (`⌘⌥L`). The controls have three sections:

- **Layout** (`배치`): starting arrangements, accurate dock-tree miniatures and your named layouts.
- **Panels** (`패널`): panel visibility and repository tabs or tracks.
- **Reading and Color** (`읽기·색상`): code size, code/file-list spacing, Diff style and appearance.

Stash, all branches and commit remain directly available in the workspace header. The View menu also exposes every panel.

## Save and recall your own layouts

Arrange the panels, then choose **Save Current Configuration** (`현재 구성 저장…`). Names are trimmed, limited to 48 characters and unique without regard to case. Up to 20 named layouts can be kept.

A named layout saves and restores:

- Panel positions, nested splits, ratios, tab groups and active tabs.
- Hidden panels and repository navigation style.
- Side-by-side or unified Diff presentation.

**Appearance, code size and code/file-list spacing stay independent.** Applying a layout does not switch the repository, change Git state or clear a commit draft.

The current configuration is saved automatically. A named snapshot changes only when you explicitly choose **Overwrite with Current Configuration** in that row's menu. That menu also offers rename and delete. Deleting a saved layout leaves the live workspace in place.

**Undo Screen Configuration** (`화면 구성 되돌리기`, `⌘⌥Z`) restores the complete previous configuration, including navigation and Diff style. The last 20 arrangement changes can be undone during the session. Applying a starting arrangement or saved layout is undoable. Reapplying an equivalent arrangement does not consume a step. Save a named snapshot before experimenting if you want to recall it after quitting.

## Move panels and read one at a time

Drag a panel title to another panel's left, right, top or bottom edge to split. Drop in the center to combine them as tabs. The workspace's outer edge positions the panel across the whole area.

The title row's **•••** menu and **View → Panel Placement** (`패널 배치`) provide the same placements without dragging, including **Whole Area** (`전체 영역`) for the outer edges.

Choose **Enlarge Panel** (`패널 크게 보기`) to temporarily fill the work area. **Return to Layout** (`원래 배치로`) or Escape restores the complete arrangement. The original tree remains mounted; enlargement does not save a one-panel layout or add an undo step. Opening another panel or deliberately changing the arrangement exits enlargement. Quitting and reopening uses the full saved arrangement.

`⌃⌘↩` enlarges Diff, or returns to the layout if a panel is already enlarged. This is separate from the two-panel **Focus** (`집중`) starting arrangement and from `⌘↩` in the active commit pane.

## Adjust reading

Code size ranges from 11 to 20 points. **Comfortable** (`여유롭게`) and **Compact** (`촘촘하게`) adjust code rows and the file list; they do not change every application control. Diff gutters and the total hunk height follow the same code metrics.

Clear Shallows (`맑은 물`), Clear Deep (`깊은 물`) and System (`시스템 설정`) preserve River's existing palette. Reading and appearance choices persist across launches and layout changes.

## Panel shortcuts

| Shortcut | Panel/action |
| --- | --- |
| `⌘⌥1` | Files |
| `⌘⌥2` | Diff |
| `⌘⌥3` | Commit graph |
| `⌘⌥4` | All branches |
| `⌘⌥5` | Stash |
| `⌘⌥6` | Task information |
| `⌘⌥I` | Commit |
| `⌘⌥L` | Screen configuration |
| `⌘⌥Z` | Undo screen configuration |
| `⌃⌘↩` | Enlarge Diff / return to layout |

Panel shortcuts toggle inclusion in the arrangement. Menu commands for an existing inactive tab remain available through the header and its tab title. Layout commands are disabled on the welcome screen; appearance and code-size menu commands remain available.

## Existing and damaged preferences

Existing v1 layouts continue to load; a new default never replaces a valid custom tree. If saved data cannot be read, River keeps the original bytes in a one-time recovery backup and shows a quiet message in Screen Configuration. Invalid named entries are excluded while valid siblings remain available. Recovery is about local presentation preferences, not Git repository data.

Named layouts currently apply globally. Automatic per-repository switching, layout import/export, arbitrary theme editing and a layout lock are outside this version.

Panel tab titles are native buttons. For a keyboard-accessible list of tabs in the current group, use the panel menu’s **Select Tab** (`탭 선택`). Selecting an existing tab does not move it or add an undo step.

Restoring an enlarged pane keeps an editor you focused while it was enlarged. Entering enlargement still resets keyboard focus to prevent hidden editors from receiving input; select the visible editor again when needed.
