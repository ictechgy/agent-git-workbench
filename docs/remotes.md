# Remote Git operations

River connects through Git's SSH and HTTPS protocols rather than provider APIs. The same operations apply to GitHub, GitLab, Bitbucket and self-hosted servers that expose those protocols. Provider OAuth, pull-request APIs and issue integration are separate features.

Remote operations require Apple command-line Git 2.41 or later. Pull captures its fetched commit from Git's structured fetch output, introduced in the [Git 2.41 release](https://github.com/git/git/blob/v2.41.0/Documentation/RelNotes/2.41.0.txt). River reports an unsupported-version error rather than falling back to mutable shared tracking references.

## User flow

Open **원격** beside the current folder to inspect a remote's fetch/push URLs, fetched branch names and upstream counts. Add, edit or remove a remote there. Remote configuration and fetched references are shared by linked worktrees.

- **Fetch** updates the selected remote's branch references without checking out files. It fetches branch heads, prunes stale heads in that remote's namespace and does not fetch tags or submodules.
- **Pull** fetches the selected branch and integrates its immutable commit from that fetch's structured result only when the current branch can fast-forward. The folder must be clean with no integration in progress. An incoming tracked file cannot overwrite an ignored local file. Divergence or a local-file collision requires a separate Git workflow.
- **Push** sends the reviewed local commit to exactly one selected remote branch. It does not force, mirror, follow tags or push submodules. A server can reject the update, including a non-fast-forward update or protected branch.
- **Clone** creates a new folder selected in the clone sheet, then opens it as a normal River workspace. Existing destinations are preserved. A completed clone remains on disk if workspace registration subsequently fails.

Pull and push require a confirmation showing the folder, local branch, URL and remote branch. The engine rechecks the reviewed state before performing the operation. Changes to the folder, HEAD, branch, remote configuration or fetched references make that state stale; refresh and confirm again.

After a confirmed push, River configures upstream tracking only if the captured local state and configuration still match. A concurrent external edit is preserved. If tracking setup is skipped or fails, the response still reports the confirmed push and asks the user to inspect tracking settings.

## Authentication and supported URLs

Supported forms are `https://host/group/project.git`, `ssh://git@host/group/project.git` and SCP syntax such as `git@host:group/project.git`. SCP paths retain their relative-path meaning. HTTPS credentials must not be embedded in the URL. Password/token entry and storage are not part of the River interface.

- **SSH:** Existing agent identities and default key files, with a host already recorded in the default known-host file. Connections are noninteractive and verify host keys. This version runs SSH without custom SSH configuration, so aliases, `ProxyCommand`, custom identity paths and interactive passphrases need a different setup. Prepare the agent/host trust outside River before connecting.
- **HTTPS:** Existing credentials available to Apple's Git keychain helper. River resets configured credential helpers before using this trusted helper. Configure authentication outside the app if credentials are missing. Public HTTPS repositories need no credentials.

Filesystem paths, `file://`, `git://`, arbitrary remote helpers, URL rewrites, multiple endpoints for one direction, partial/promisor repositories and transport-altering Git configuration are rejected. In particular, disabled TLS verification, HTTP header/cookie overrides and arbitrary executable helpers are not inherited for network operations. SSH/HTTPS remain provider-neutral within these boundaries; this is not a claim that every provider's authentication configuration has been tested.

## Execution and recovery

Remote execution uses bounded child processes, fixed Git/SSH executables, disabled hooks, disabled signing, no terminal/askpass prompts and no external content filters. Network process time is bounded to 180 seconds; remote requests allow up to 360 seconds for network, local integration and response handling. Closing a client connection is not proof that the engine stopped a write.

If a response is lost or a write times out, River reports an unknown outcome tied to the originating project. Inspect the repository and server before repeating it. River does not automatically replay writes or reset files. A failed optional refresh after a confirmed write requests a new refresh without changing the write into a failure.

River serializes its own writes through the common Git-directory lock. External Git/configuration writers do not participate in that lock. State checks detect observed drift; they are not isolation against an arbitrary process rewriting Git configuration between validation and Git execution.

Clone first creates an app-owned sibling staging folder without checkout or templates. After validating filters it checks out files, then publishes using a no-replace rename. Failure cleans only its own staging directory. There is no recursive submodule initialization.

## Wire contract

All methods reject unknown fields and use the actual selected folder. `op_id` is omitted for the original project folder, even when a task is being inspected.

| Method | Parameters beyond `repo_id`, optional `op_id` |
| --- | --- |
| `get_remote_state` | None |
| `configure_remote` | `expected_state_hash`, `action` (`add`, `update`, `remove`), `name`, optional `url`, optional `push_url` |
| `fetch_remote` | `expected_state_hash`, `remote` |
| `pull_remote` | `expected_state_hash`, `remote`, `branch` (short remote branch name) |
| `push_remote` | `expected_state_hash`, `remote`, `branch` (short remote branch name) |

`RemoteState` contains a state hash, folder, local branch/HEAD, clean status, remotes with display-safe URLs and fetched branch tips, upstream identity and optional ahead/behind counts. The hash covers local state and effective remote configuration; display data does not authorize a write on its own. A successful mutation returns `RemoteMutationResult` with an optional refreshed state, `refresh_required` and a user-facing message. Clone bootstraps outside a running workspace through `workbench clone <url> <destination>`, returning `{ "path": "..." }` before normal registration.

## Verification boundaries

Synthetic tests exercise real Git fetch/pull/push/clone using app-created bare repositories through a compile-time test-only file policy. Production URL validation never exposes this policy through RPC, CLI flags or environment variables. Production tests reject local transports and unsafe configuration before network execution. Native tests cover target identity, late responses, drafts, origin-bound unknown outcomes and clone registration failures. Public-host read-only smoke tests, when performed, are recorded separately from synthetic tests; no test implies authorization to push to a user's live server.

Git's protocol and operation semantics are documented in the official [fetch](https://git-scm.com/docs/git-fetch), [push](https://git-scm.com/docs/git-push) and [clone](https://git-scm.com/docs/git-clone) manuals.
