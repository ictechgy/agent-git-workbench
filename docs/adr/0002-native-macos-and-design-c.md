# ADR 0002 — Native macOS client and selected design C

Status: accepted by explicit user instruction, 2026-10-19. Supersedes ADR 0001's desktop framework choice. The Rust operation contracts remain active.

Update, 2026-10-22: the native framework decision remains active. The initial fixed C composition below has evolved into freely dockable panes; the app now bundles and starts its engine (ADR 0003). See [current architecture](../architecture.md) and [README](../../README.md) for present behavior.

"C" names the initial sidebar/Diff/inspector design proposal. The exploration files are not part of this publication.

The user selected Claude proposal C and required native UI instead of Tauri. The implementation uses SwiftUI and AppKit, built with Swift Package Manager and a macOS 14 deployment target. It has no WebView, JavaScript, React, Tauri or Node runtime dependency. The former web spike is not included in this publication.

The initial C composition was: task/repository sidebar, central split/unified diff, resizable history below, and a right Task/repository/worktree inspector with a persistent commit composer. Native controls, sheets, toolbar, keyboard commands, SF Symbols and semantic system colors follow macOS conventions. The app supports the system light/dark appearance rather than changing OS settings. Unsupported Fetch/agent actions from the concept are not presented as working controls.

`WorkbenchProtocol` provides Codable models, stable error codes, versioned reply validation, bounded newline-delimited JSON framing, and a direct AF_UNIX socket client. Blocking I/O runs off the main actor with 30-second send/receive timeouts and SIGPIPE protection. The UI does not invoke Git or a shell. The single Rust service retains mutation locking, trust, snapshots, journals and idempotency for CLI/native/future MCP clients.

`WorkbenchUI` owns state and layout. Selection/diff generation tokens discard stale asynchronous responses. Mutations use the target and snapshot returned by the service. Task creation retains one idempotency key for repeat execution of a previewed plan. File edits, staging and commit stay separate. The commit composer remains visible while the inspector's context scrolls.

At the time of this ADR, the desktop app connected to a service started outside the bundle (`scripts/demo.py`). ADR 0003 superseded that startup: `scripts/build_macos.py` now bundles the engine and the app manages its connection. The current bundle still uses a development ad-hoc signature, with no notarization or distribution installer. No network port is opened.

Historical verification at this decision: Swift build and six protocol/diff tests; a Swift-client-to-Rust-service scenario covering branch-only, materialize, idempotency, source preservation, hunk staging and commit, independently checked by Git; native content rendered from a live synthetic partial-failure Task; existing Rust regression scenarios. Current counts are in the root README. The render uses this app's own NSHostingView without capturing the desktop or automating another app. It is not a substitute for OS-level keyboard, window, VoiceOver or packaging QA. Only the macOS 27.0.1 development host was used; the macOS 14 deployment target is not a certification of that older runtime.

API references: [Apple HSplitView](https://developer.apple.com/documentation/swiftui/hsplitview), [VSplitView](https://developer.apple.com/documentation/swiftui/vsplitview), [Swift Package Manager](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/).
