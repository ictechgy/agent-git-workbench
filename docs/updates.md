# App updates

River alpha.6 adds native updates using the pinned Sparkle 2.10.0 framework. **Alpha.5 and earlier need one manual installation of alpha.6** from [GitHub Releases](https://github.com/ictechgy/river/releases/tag/v0.1.0-alpha.6). After that, future releases can be installed from inside River.

## Using updates

- River checks for updates daily by default. Open **River → 업데이트 확인…** to check immediately.
- Open the native **Settings** window to turn automatic checking on or off and see the last check time. Changing this preference does not change Git or layout preferences.
- A new-version window offers the download and installation. River does not silently download, install or restart in the background.
- Save or copy temporary commit messages, Task information and new-task inputs before restarting. These drafts remain session-only.
- An active Git request, clone, Task preparation or Task information write postpones restart, including work in a previously visited folder/workspace. Return to a named workspace and refresh if a known Task's completion needs confirmation.
- An uncertain request outcome needs inspection of the original repository and a fresh explicit acknowledgement before restart. This does not clear the original notice or repeat a write.
- Choosing **나중에** keeps River open. Use the update command or **업데이트 설치 및 재시작…** in Settings to continue later. Eligibility is checked again before exit.

If activity changes during shutdown cleanup and the final gate cancels restart, an idle service may already have stopped; reconnect the workspace if needed. This is an availability limit, not permission to retry an uncertain Git write.

Repository files and commits are not an updater's input. The updater replaces the application bundle. River's existing idle-service cleanup preserves busy and borrowed engines. Network/signature failures leave the installed app in place; try again later or install a release DMG manually.

The current distribution is Apple Silicon only, with macOS 14 declared as the minimum. Apple notarization is still incomplete. These update checks do not certify older-macOS operation, VoiceOver or unattended installation.

## Trust and preferences

The application embeds its update feed URL and a public Ed25519 key. Both the appcast and archive require signatures; archives are checked before extraction, and the signed-feed expiry fallback is disabled. The feed lives at `https://raw.githubusercontent.com/ictechgy/river/updates/appcast.xml`. It selects immutable, versioned River DMGs from GitHub Releases, ordered by the numeric `CFBundleVersion` (alpha.6 is build 7).

The `updates` branch contains publication metadata separately from the application's source commit. Updating the feed does not rebuild or replace an existing release asset. Sparkle system profiling is disabled. Update requests contact GitHub; they do not send repository paths, source diffs or AI-request text. Automatic checking can be disabled in Settings.

Implementation and protocol references: [Sparkle setup](https://sparkle-project.org/documentation/), [signed publishing](https://sparkle-project.org/documentation/publishing/), [configuration](https://sparkle-project.org/documentation/customization/).

## Releasing an update

Keep the increasing numeric build number, application identifier and existing update public key. Rotating keys requires a separate reviewed migration; do not generate a replacement key for every release. The private signing key stays in the developer's login Keychain under account `dev.workbench.AgentGitWorkbench.sparkle`. Back up that key securely through the upstream tool when planning a signing-machine migration; do not commit it or place it in command arguments/logs.

1. Commit and review the application source, then build a Developer ID-signed package from clean source. Follow [development](development.md). The build embeds the complete pinned framework, preserves nested entitlements and includes its license. The DMG, checksum and manifest remain the three release assets.
2. Create an appcast outside the source tree using the same released package:

   ```sh
   python3 scripts/make_appcast.py \
     --release-directory build/macos/releases/v0.1.0-alpha.6-final \
     --output build/macos/updates/alpha.6/appcast.xml \
     --tools-directory apps/macos/.build/artifacts/sparkle/Sparkle/bin
   ```

   The generator rechecks actual archive bytes, mounted app, Developer ID team, source provenance and embedded updater configuration. It signs archive and feed with Sparkle's official tool, independently verifies both using the public key, then replaces the output atomically. The existing output, if any, must be a valid older signed feed. Optional `--notes-file` embeds bounded plain UTF-8 text. macOS may request permission for the signing tool to use the Keychain.
3. Publish the immutable version tag and the three verified release assets. Verify their public downloads before advertising the update. Keep appcast generation separate from source-bound packaging.
4. Check the feed publication without changing the server:

   ```sh
   python3 scripts/publish_appcast.py --feed build/macos/updates/alpha.6/appcast.xml \
     --expected-source FULL_RELEASE_SOURCE_SHA
   ```

   Add `--publish` only after the check succeeds. The publisher verifies the signed feed, published release, three anonymous downloads, GitHub asset digests, source manifest and peeled tag before changing only the `updates` branch. Existing feed updates must advance the build number; an identical feed is idempotent. Ref changes use fast-forward semantics, preserve the existing tree and do not retry an overwrite after a conflict. Release/tag validation and feed advancement are separate server operations: keep published release assets and tags immutable and avoid concurrent replacement. Branch atomicity does not make those checks one transaction.
5. Verify with only the public key—no Keychain/private key is required:

   ```sh
   xcrun swift scripts/verify_update.swift --public-key BASE64_PUBLIC_KEY \
     --feed build/macos/updates/alpha.6/appcast.xml \
     --archive build/macos/releases/v0.1.0-alpha.6-final/River-0.1.0-alpha.6-macos-arm64.dmg
   ```

   The separate `update_smoke.py`/`workbench-update-probe` developer check uses the actual Sparkle parser and update-information path. It does not install, quit or relaunch a user's application.

The generator and publisher fail closed on mismatches. A checksum alone does not establish update authenticity, and Developer ID signing does not imply Apple notarization. Test actual installation/relaunch in an isolated application copy when changing the framework, bundle layout, signing policy or termination behavior.
