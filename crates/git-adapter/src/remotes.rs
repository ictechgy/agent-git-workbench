//! Provider-neutral, noninteractive remote operations. Network commands never use
//! imported refspecs, shell credential helpers, SSH commands, or raw diagnostics.
use anyhow::{Context, Result, bail, ensure};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
    time::Duration,
};
use workbench_domain::{RemoteBranch, RemoteInfo, RemoteState, digest};

#[derive(Clone, Copy)]
enum Policy {
    Network,
    #[cfg(test)]
    Fixture,
}

fn config(path: &Path) -> Result<Vec<(String, String)>> {
    let out = run_local(path, &["config", "--null", "--list"], false)?;
    let mut values = Vec::new();
    for item in out.stdout.split(|b| *b == 0).filter(|b| !b.is_empty()) {
        let text = std::str::from_utf8(item).context("unsupported_remote_config")?;
        let (key, value) = text.split_once('\n').unwrap_or((text, ""));
        // Sections and variable names are case-insensitive; subsection names
        // (remote and branch names) are case-sensitive.
        let key = if let Some((section, rest)) = key.split_once('.') {
            if let Some((subsection, field)) = rest.rsplit_once('.') {
                format!(
                    "{}.{subsection}.{}",
                    section.to_ascii_lowercase(),
                    field.to_ascii_lowercase()
                )
            } else {
                key.to_ascii_lowercase()
            }
        } else {
            key.to_ascii_lowercase()
        };
        values.push((key, value.to_string()));
    }
    Ok(values)
}
fn run_local(path: &Path, args: &[&str], write: bool) -> Result<Output> {
    let out = super::process::run(
        super::git_command(path, args),
        None,
        Duration::from_secs(if write { 120 } else { 15 }),
        8 * 1024 * 1024,
    )
    .map_err(|_| {
        anyhow::anyhow!(if write {
            "remote_outcome_unknown"
        } else {
            "remote_read_failed"
        })
    })?;
    ensure!(
        out.status.success(),
        "{}",
        if write {
            "remote_outcome_unknown"
        } else {
            "remote_configuration_failed"
        }
    );
    Ok(out)
}
fn scalar<'a>(cfg: &'a [(String, String)], key: &str) -> Option<&'a str> {
    cfg.iter()
        .rev()
        .find(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
}
fn values<'a>(cfg: &'a [(String, String)], key: &str) -> Vec<&'a str> {
    cfg.iter()
        .filter(|(k, _)| k == key)
        .map(|(_, v)| v.as_str())
        .collect()
}
fn transport_config(cfg: &[(String, String)]) -> Result<()> {
    for (key, value) in cfg {
        ensure!(
            !(key.starts_with("url.")
                && (key.ends_with(".insteadof") || key.ends_with(".pushinsteadof"))),
            "unsupported_url_rewrite"
        );
        ensure!(
            !(key == "extensions.partialclone"
                || (key.starts_with("remote.")
                    && (key.ends_with(".promisor") || key.ends_with(".partialclonefilter")))),
            "unsupported_partial_clone"
        );
        ensure!(
            !(key.starts_with("remote.")
                && (key.ends_with(".vcs")
                    || key.ends_with(".uploadpack")
                    || key.ends_with(".receivepack"))),
            "unsupported_remote_command"
        );
        // HTTP settings can redirect credentials or weaken transport. The first
        // version deliberately accepts only settings we replace with fixed values.
        if key.starts_with("http.") {
            ensure!(
                matches!(
                    key.as_str(),
                    "http.postbuffer" | "http.version" | "http.lowspeedlimit" | "http.lowspeedtime"
                ),
                "unsupported_http_configuration"
            );
        }
        ensure!(
            !(key == "core.repositoryformatversion" && value.parse::<u64>().unwrap_or(0) > 1),
            "unsupported_repository_format"
        );
    }
    Ok(())
}
fn remote_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name.len() <= 64
            && name.as_bytes()[0].is_ascii_alphanumeric()
            && name
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.'))
            && !name.ends_with('.')
            && !name.contains(".."),
        "invalid_remote_name"
    );
    Ok(())
}
fn host(authority: &str, ssh: bool) -> Result<()> {
    let server = if let Some((user, rest)) = authority.rsplit_once('@') {
        ensure!(
            ssh && !user.is_empty()
                && user
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'-' | b'.')),
            "invalid_remote_url"
        );
        rest
    } else {
        authority
    };
    ensure!(
        !server.is_empty() && !server.starts_with('-'),
        "invalid_remote_url"
    );
    let (hostname, port) = if server.starts_with('[') {
        let end = server.find(']').context("invalid_remote_url")?;
        ensure!(
            end > 1
                && server[1..end]
                    .bytes()
                    .all(|b| b.is_ascii_hexdigit() || b == b':'),
            "invalid_remote_url"
        );
        let suffix = &server[end + 1..];
        ensure!(
            suffix.is_empty() || suffix.starts_with(':'),
            "invalid_remote_url"
        );
        (&server[..=end], suffix.strip_prefix(':'))
    } else {
        let (h, p) = server
            .split_once(':')
            .map_or((server, None), |(h, p)| (h, Some(p)));
        ensure!(
            h.bytes()
                .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.')),
            "invalid_remote_url"
        );
        (h, p)
    };
    ensure!(
        !hostname.is_empty() && hostname != "." && !hostname.ends_with(".."),
        "invalid_remote_url"
    );
    if let Some(port) = port {
        ensure!(
            !port.is_empty()
                && port.bytes().all(|b| b.is_ascii_digit())
                && port.parse::<u16>().unwrap_or(0) > 0,
            "invalid_remote_url"
        );
    }
    Ok(())
}
fn validate_url(url: &str, policy: Policy) -> Result<()> {
    ensure!(
        !url.is_empty()
            && url.len() <= 4096
            && !url.starts_with('-')
            && url
                .bytes()
                .all(|b| b.is_ascii_graphic() && !matches!(b, b'\\' | b'?' | b'#' | b'%')),
        "invalid_remote_url"
    );
    #[cfg(test)]
    if matches!(policy, Policy::Fixture) && url.starts_with("file:///") {
        return Ok(());
    }
    let _ = policy;
    if let Some(rest) = url.strip_prefix("https://") {
        let (authority, path) = rest.split_once('/').context("invalid_remote_url")?;
        host(authority, false)?;
        ensure!(!path.is_empty(), "invalid_remote_url");
    } else if let Some(rest) = url.strip_prefix("ssh://") {
        let (authority, path) = rest.split_once('/').context("invalid_remote_url")?;
        host(authority, true)?;
        ensure!(!path.is_empty(), "invalid_remote_url");
    } else {
        ensure!(
            !url.contains("://") && !url.starts_with('/') && !url.starts_with('.'),
            "unsupported_remote_transport"
        );
        let (authority, path) = url
            .split_once(':')
            .context("unsupported_remote_transport")?;
        host(authority, true)?;
        ensure!(
            !path.is_empty() && !path.starts_with('-'),
            "invalid_remote_url"
        );
    }
    Ok(())
}
/// Public validation does not probe a network endpoint or save credentials.
pub fn validate_remote_url(url: &str) -> Result<()> {
    validate_url(url, Policy::Network)
}
fn display_url(url: &str, policy: Policy) -> String {
    if validate_url(url, policy).is_ok() {
        url.to_string()
    } else {
        "[unsupported or credential-bearing URL]".to_string()
    }
}
fn endpoints(cfg: &[(String, String)], name: &str, policy: Policy) -> Result<(String, String)> {
    remote_name(name)?;
    transport_config(cfg)?;
    let fetch = values(cfg, &format!("remote.{name}.url"));
    let push = values(cfg, &format!("remote.{name}.pushurl"));
    ensure!(
        fetch.len() == 1 && push.len() <= 1,
        "unsupported_remote_endpoints"
    );
    validate_url(fetch[0], policy)?;
    let push = push.first().copied().unwrap_or(fetch[0]);
    validate_url(push, policy)?;
    Ok((fetch[0].into(), push.into()))
}
fn credential_helper() -> Option<&'static str> {
    ["/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-credential-osxkeychain", "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-credential-osxkeychain"]
        .into_iter().find(|path| Path::new(path).is_file())
}
fn network_command(path: &Path, args: &[&str], policy: Policy) -> Command {
    let mut command = super::git_command(path, &[]);
    command.env_clear();
    for key in ["HOME", "XDG_CONFIG_HOME", "SSH_AUTH_SOCK", "LANG"] {
        if let Some(value) = std::env::var_os(key) {
            command.env(key, value);
        }
    }
    command.env("GIT_OPTIONAL_LOCKS", "0")
        .env("GIT_LITERAL_PATHSPECS", "1")
        .env("GIT_TERMINAL_PROMPT", "0")
        .env("GIT_NO_LAZY_FETCH", "1")
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("GIT_ALLOW_PROTOCOL", match policy { Policy::Network => "https:ssh", #[cfg(test)] Policy::Fixture => "file:https:ssh" })
        .env("GIT_PROTOCOL_FROM_USER", "0")
        .env("GIT_ASKPASS", "/usr/bin/false")
        .env("SSH_ASKPASS", "/usr/bin/false")
        .env("SSH_ASKPASS_REQUIRE", "never")
        .env("GIT_SSH_COMMAND", "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2")
        .args(["-c", "credential.helper=", "-c", "credential.interactive=false", "-c", "core.askPass=/usr/bin/false", "-c", "http.sslVerify=true", "-c", "http.followRedirects=false", "-c", "http.postBuffer=1048576", "-c", "http.lowSpeedLimit=1", "-c", "http.lowSpeedTime=30", "-c", "push.pushOption=", "-c", "push.followTags=false", "-c", "push.gpgSign=false"]);
    if let Some(helper) = credential_helper() {
        command.args(["-c", &format!("credential.helper={helper}")]);
    }
    command.args(args);
    command
}
fn network(path: &Path, args: &[&str], policy: Policy, push: bool) -> Result<Vec<u8>> {
    let out = super::process::run(
        network_command(path, args, policy),
        None,
        Duration::from_secs(180),
        8 * 1024 * 1024,
    )
    .map_err(|_| anyhow::anyhow!("remote_outcome_unknown"))?;
    if !out.status.success() {
        // Only structured porcelain rejection lines prove that a push was
        // rejected. Raw server diagnostics may contain credentials and are never
        // included in errors, logs, or RPC responses.
        if push {
            let text = String::from_utf8_lossy(&out.stdout);
            if text.lines().any(|line| {
                line.starts_with("!\t")
                    && (line.contains("[rejected]") || line.contains("[remote rejected]"))
            }) {
                bail!("remote_push_rejected");
            }
            bail!("remote_outcome_unknown");
        }
        bail!("remote_connection_failed");
    }
    Ok(out.stdout)
}
fn remote_refs(path: &Path) -> Result<Vec<(String, String)>> {
    let output = run_local(
        path,
        &[
            "for-each-ref",
            "--format=%(refname)%00%(objectname)%00%(symref)",
            "refs/remotes/",
        ],
        false,
    )?;
    let text = std::str::from_utf8(&output.stdout).context("unsupported_remote_refs")?;
    text.lines()
        .map(|line| {
            let items: Vec<_> = line.split('\0').collect();
            ensure!(items.len() == 3, "unsupported_remote_refs");
            Ok((
                items[0].to_string(),
                if items[2].is_empty() {
                    items[1].into()
                } else {
                    String::new()
                },
            ))
        })
        .collect()
}
pub fn state(path: &Path) -> Result<RemoteState> {
    state_policy(path, Policy::Network)
}
fn state_policy(path: &Path, policy: Policy) -> Result<RemoteState> {
    let cfg = config(path)?;
    let snapshot = super::snapshot(path)?;
    let refs = remote_refs(path)?;
    let mut names = BTreeMap::<String, ()>::new();
    for (key, _) in &cfg {
        if let Some(rest) = key.strip_prefix("remote.")
            && let Some((name, field)) = rest.rsplit_once('.')
            && matches!(field, "url" | "pushurl")
        {
            names.insert(name.to_string(), ());
        }
    }
    let mut remotes = Vec::new();
    for name in names.keys() {
        let prefix = format!("refs/remotes/{name}/");
        let validation = endpoints(&cfg, name, policy);
        let branches = refs
            .iter()
            .filter_map(|(r, oid)| {
                r.strip_prefix(&prefix)
                    .filter(|_| !oid.is_empty())
                    .map(|short| RemoteBranch {
                        name: short.into(),
                        oid: oid.clone(),
                    })
            })
            .collect();
        remotes.push(RemoteInfo {
            name: name.clone(),
            fetch_url: display_url(
                scalar(&cfg, &format!("remote.{name}.url")).unwrap_or(""),
                policy,
            ),
            push_url: display_url(
                scalar(&cfg, &format!("remote.{name}.pushurl"))
                    .or_else(|| scalar(&cfg, &format!("remote.{name}.url")))
                    .unwrap_or(""),
                policy,
            ),
            supported: validation.is_ok(),
            problem: validation.err().map(|e| e.to_string()),
            branches,
        });
    }
    let branch_short = snapshot.branch.strip_prefix("refs/heads/");
    let upstream_remote = branch_short
        .and_then(|branch| scalar(&cfg, &format!("branch.{branch}.remote")))
        .filter(|s| *s != ".")
        .map(str::to_string);
    let upstream_branch = branch_short
        .and_then(|branch| scalar(&cfg, &format!("branch.{branch}.merge")))
        .and_then(|s| s.strip_prefix("refs/heads/"))
        .map(str::to_string);
    let mut ahead = None;
    let mut behind = None;
    if !snapshot.head.is_empty()
        && let (Some(remote), Some(branch)) = (&upstream_remote, &upstream_branch)
    {
        let reference = format!("refs/remotes/{remote}/{branch}");
        if let Some((_, oid)) = refs
            .iter()
            .find(|(r, oid)| r == &reference && !oid.is_empty())
        {
            let range = format!("{}...{oid}", snapshot.head);
            let out = run_local(
                path,
                &["rev-list", "--left-right", "--count", &range, "--"],
                false,
            )?;
            let numbers: Vec<_> = std::str::from_utf8(&out.stdout)?
                .split_whitespace()
                .collect();
            if numbers.len() == 2 {
                ahead = numbers[0].parse().ok();
                behind = numbers[1].parse().ok();
            }
        }
    }
    let clean = run_local(
        path,
        &[
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=normal",
            "--ignore-submodules=none",
        ],
        false,
    )?
    .stdout
    .is_empty()
        && super::no_conflicts(path).is_ok();
    let repository_path = fs::canonicalize(path)?
        .to_str()
        .context("unsupported_repo_path_encoding")?
        .to_string();
    Ok(RemoteState {
        state_hash: digest(&(&repository_path, &cfg, &snapshot, &refs))?,
        repository_path,
        branch: (!snapshot.branch.is_empty()).then_some(snapshot.branch),
        head: (!snapshot.head.is_empty()).then_some(snapshot.head),
        clean,
        remotes,
        upstream_remote,
        upstream_branch,
        ahead,
        behind,
    })
}
fn expected(path: &Path, hash: &str, policy: Policy) -> Result<RemoteState> {
    let current = state_policy(path, policy)?;
    ensure!(current.state_hash == hash, "stale_remote_state");
    Ok(current)
}
fn reviewed_endpoints(
    current: &RemoteState,
    cfg: &[(String, String)],
    name: &str,
    policy: Policy,
) -> Result<(String, String)> {
    let (fetch, push) = endpoints(cfg, name, policy)?;
    let reviewed = current
        .remotes
        .iter()
        .find(|r| r.name == name)
        .context("remote_not_found")?;
    ensure!(
        reviewed.supported && reviewed.fetch_url == fetch && reviewed.push_url == push,
        "stale_remote_state"
    );
    Ok((fetch, push))
}
pub fn configure(
    path: &Path,
    hash: &str,
    action: &str,
    name: &str,
    url: Option<&str>,
    push_url: Option<&str>,
) -> Result<()> {
    remote_name(name)?;
    ensure!(
        matches!(action, "add" | "update" | "remove"),
        "invalid_remote_action"
    );
    if action != "remove" {
        validate_remote_url(url.context("invalid_remote_url")?)?;
    }
    if let Some(push) = push_url {
        validate_remote_url(push)?;
    }
    ensure!(
        action != "remove" || (url.is_none() && push_url.is_none()),
        "invalid_remote_action"
    );
    let current = expected(path, hash, Policy::Network)?;
    let exists = current.remotes.iter().any(|r| r.name == name);
    ensure!(
        if action == "add" { !exists } else { exists },
        "remote_name_conflict"
    );
    // Restrict edits to local config; imported/global remotes must not be
    // silently shadowed. Git's own remove also updates upstream/ref metadata.
    let local = run_local(
        path,
        &[
            "config",
            "--local",
            "--null",
            "--get-all",
            &format!("remote.{name}.url"),
        ],
        false,
    );
    if action != "add" {
        ensure!(local.is_ok(), "remote_not_local");
    }
    match action {
        "remove" => {
            run_local(path, &["remote", "remove", name], true)?;
        }
        "add" => {
            run_local(path, &["remote", "add", name, url.unwrap()], true)?;
            if let Some(push) = push_url {
                run_local(path, &["remote", "set-url", "--push", name, push], true)?;
            }
        }
        _ => {
            run_local(
                path,
                &[
                    "config",
                    "--local",
                    "--replace-all",
                    &format!("remote.{name}.url"),
                    url.unwrap(),
                ],
                true,
            )?;
            if let Some(push) = push_url {
                run_local(
                    path,
                    &[
                        "config",
                        "--local",
                        "--replace-all",
                        &format!("remote.{name}.pushurl"),
                        push,
                    ],
                    true,
                )?;
            } else {
                let out = super::process::run(
                    super::git_command(
                        path,
                        &[
                            "config",
                            "--local",
                            "--unset-all",
                            &format!("remote.{name}.pushurl"),
                        ],
                    ),
                    None,
                    Duration::from_secs(15),
                    1024,
                )
                .map_err(|_| anyhow::anyhow!("remote_outcome_unknown"))?;
                ensure!(
                    out.status.success() || out.status.code() == Some(5),
                    "remote_configuration_failed"
                );
            }
        }
    }
    Ok(())
}
pub fn fetch(path: &Path, hash: &str, name: &str) -> Result<()> {
    fetch_policy(path, hash, name, Policy::Network)
}
fn fetch_policy(path: &Path, hash: &str, name: &str, policy: Policy) -> Result<()> {
    let initial = expected(path, hash, policy)?;
    let cfg = config(path)?;
    let (url, _) = reviewed_endpoints(&initial, &cfg, name, policy)?;
    expected(path, hash, policy)?;
    fetch_url(path, &url, name, policy)
}
fn fetch_url(path: &Path, url: &str, name: &str, policy: Policy) -> Result<()> {
    let mapping = format!("+refs/heads/*:refs/remotes/{name}/*");
    network(
        path,
        &[
            "fetch",
            "--atomic",
            "--prune",
            "--no-tags",
            "--no-recurse-submodules",
            "--no-auto-maintenance",
            "--refmap=",
            "--",
            url,
            &mapping,
        ],
        policy,
        false,
    )?;
    Ok(())
}
pub fn pull(path: &Path, hash: &str, name: &str, branch: &str) -> Result<()> {
    pull_policy(path, hash, name, branch, Policy::Network)
}
fn pull_policy(path: &Path, hash: &str, name: &str, branch: &str, policy: Policy) -> Result<()> {
    validate_branch(path, branch)?;
    let initial = expected(path, hash, policy)?;
    ensure!(
        initial.branch.is_some() && initial.head.is_some(),
        "remote_branch_required"
    );
    ensure!(initial.clean, "remote_worktree_dirty");
    super::no_conflicts(path)?;
    super::no_external_filters(path)?;
    let local_snapshot = super::snapshot(path)?;
    let cfg = config(path)?;
    let (url, _) = reviewed_endpoints(&initial, &cfg, name, policy)?;
    expected(path, hash, policy)?;
    fetch_url(path, &url, name, policy)?;
    integrate_fetched(path, initial, &local_snapshot, &cfg, name, branch)
}
fn integrate_fetched(
    path: &Path,
    initial: RemoteState,
    local_snapshot: &workbench_domain::Snapshot,
    cfg: &[(String, String)],
    name: &str,
    branch: &str,
) -> Result<()> {
    ensure!(
        &super::snapshot(path)? == local_snapshot && config(path)? == cfg,
        "stale_remote_state"
    );
    super::no_conflicts(path)?;
    super::no_external_filters(path)?;
    let target = super::oid(path, &format!("refs/remotes/{name}/{branch}"))?;
    let ancestor = super::process::run(
        super::git_command(
            path,
            &[
                "merge-base",
                "--is-ancestor",
                initial.head.as_ref().unwrap(),
                &target,
            ],
        ),
        None,
        Duration::from_secs(15),
        1024,
    )?;
    ensure!(ancestor.status.success(), "remote_pull_not_fast_forward");
    let local_branch = initial.branch.unwrap();
    let branch_config = format!(
        "branch.{}.mergeOptions=",
        local_branch
            .strip_prefix("refs/heads/")
            .context("remote_branch_required")?
    );
    // The fetched OID is immutable. FF-only integration cannot create commits.
    run_local(
        path,
        &[
            "-c",
            &branch_config,
            "-c",
            "merge.verifySignatures=false",
            "-c",
            "merge.autoStash=false",
            "merge",
            "--ff-only",
            "--no-edit",
            "--no-verify-signatures",
            &target,
        ],
        true,
    )?;
    set_upstream(path, &local_branch, name, branch).context("remote_outcome_unknown")?;
    Ok(())
}
fn validate_branch(path: &Path, branch: &str) -> Result<()> {
    ensure!(
        !branch.is_empty()
            && branch.len() <= 1024
            && branch.bytes().all(|b| b.is_ascii_graphic())
            && !branch.starts_with('-'),
        "invalid_remote_branch"
    );
    super::validate_branch(path, &format!("refs/heads/{branch}"))
        .map_err(|_| anyhow::anyhow!("invalid_remote_branch"))
}
pub fn push(path: &Path, hash: &str, name: &str, branch: &str) -> Result<()> {
    push_policy(path, hash, name, branch, Policy::Network)
}
fn push_policy(path: &Path, hash: &str, name: &str, branch: &str, policy: Policy) -> Result<()> {
    validate_branch(path, branch)?;
    let initial = expected(path, hash, policy)?;
    let local_branch = initial.branch.clone().context("remote_branch_required")?;
    let oid = initial.head.clone().context("remote_branch_required")?;
    let cfg = config(path)?;
    let (_, url) = reviewed_endpoints(&initial, &cfg, name, policy)?;
    expected(path, hash, policy)?;
    let refspec = format!("{oid}:refs/heads/{branch}");
    network(
        path,
        &[
            "push",
            "--porcelain",
            "--no-follow-tags",
            "--recurse-submodules=no",
            "--signed=false",
            "--",
            &url,
            &refspec,
        ],
        policy,
        true,
    )?;
    // Do not retarget a branch that was changed externally during the network.
    let current = super::snapshot(path).context("remote_outcome_unknown")?;
    if current.branch == local_branch {
        set_upstream(path, &local_branch, name, branch).context("remote_outcome_unknown")?;
    }
    Ok(())
}
fn set_upstream(path: &Path, branch: &str, remote: &str, target: &str) -> Result<()> {
    let branch = branch
        .strip_prefix("refs/heads/")
        .context("remote_branch_required")?;
    run_local(
        path,
        &[
            "config",
            "--local",
            &format!("branch.{branch}.remote"),
            remote,
        ],
        true,
    )?;
    run_local(
        path,
        &[
            "config",
            "--local",
            &format!("branch.{branch}.merge"),
            &format!("refs/heads/{target}"),
        ],
        true,
    )?;
    Ok(())
}
pub fn clone_repository(url: &str, destination: &Path) -> Result<PathBuf> {
    // Leave the native helper time to receive the terminal result before its
    // 360-second deadline; all Git children remain under this tighter budget.
    super::with_deadline(Duration::from_secs(330), || {
        clone_policy(url, destination, Policy::Network)
    })
}
fn clone_policy(url: &str, destination: &Path, policy: Policy) -> Result<PathBuf> {
    validate_url(url, policy)?;
    ensure!(destination.is_absolute(), "invalid_clone_destination");
    let name = destination
        .file_name()
        .context("invalid_clone_destination")?;
    ensure!(name != "." && name != "..", "invalid_clone_destination");
    let parent = fs::canonicalize(destination.parent().context("invalid_clone_destination")?)
        .context("invalid_clone_destination")?;
    let destination = parent.join(name);
    ensure!(
        fs::symlink_metadata(&destination).is_err_and(|e| e.kind() == std::io::ErrorKind::NotFound),
        "clone_destination_exists"
    );
    transport_config(&config(&parent)?)?;
    let mut stage = None;
    for counter in 0..100u32 {
        let candidate = parent.join(format!(
            ".river-clone-{}-{}-{counter}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)?
                .as_nanos()
        ));
        use std::os::unix::fs::DirBuilderExt;
        match fs::DirBuilder::new().mode(0o700).create(&candidate) {
            Ok(()) => {
                stage = Some(candidate);
                break;
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(_) => bail!("clone_staging_failed"),
        }
    }
    let stage = stage.context("clone_staging_failed")?;
    struct OwnedStage(PathBuf);
    impl Drop for OwnedStage {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let owned = OwnedStage(stage.clone());
    let stage_text = stage.to_str().context("unsupported_repo_path_encoding")?;
    network(
        &parent,
        &[
            "clone",
            "--no-checkout",
            "--no-recurse-submodules",
            "--template=",
            "--",
            url,
            stage_text,
        ],
        policy,
        false,
    )?;
    super::root(&stage)?;
    transport_config(&config(&stage)?)?;
    super::no_external_filters(&stage)?;
    let snapshot = super::snapshot(&stage)?;
    if !snapshot.head.is_empty() {
        run_local(
            &stage,
            &[
                "checkout",
                "--force",
                "--no-recurse-submodules",
                "HEAD",
                "--",
            ],
            true,
        )?;
    }
    publish(&stage, &destination)?;
    drop(owned);
    Ok(destination)
}
fn publish(stage: &Path, destination: &Path) -> Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let source = std::ffi::CString::new(stage.as_os_str().as_bytes())
        .context("invalid_clone_destination")?;
    let target = std::ffi::CString::new(destination.as_os_str().as_bytes())
        .context("invalid_clone_destination")?;
    #[cfg(target_os = "macos")]
    let result = unsafe { libc::renamex_np(source.as_ptr(), target.as_ptr(), libc::RENAME_EXCL) };
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            target.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    compile_error!("atomic no-replace directory publication needs a platform implementation");
    ensure!(result == 0, "clone_destination_exists");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;
    fn git(path: &Path, args: &[&str]) -> String {
        let out = Command::new("/usr/bin/git")
            .current_dir(path)
            .args([
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "commit.gpgSign=false",
            ])
            .args(args)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "Git fixture failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        String::from_utf8(out.stdout).unwrap().trim().into()
    }
    struct Fixture {
        _dir: TempDir,
        source: PathBuf,
        bare: PathBuf,
        client: PathBuf,
        url: String,
    }
    impl Fixture {
        fn new() -> Self {
            let dir = TempDir::new().unwrap();
            let source = dir.path().join("source");
            let bare = dir.path().join("server.git");
            let client = dir.path().join("client");
            fs::create_dir(&source).unwrap();
            git(&source, &["init", "-b", "main"]);
            git(&source, &["config", "user.name", "Fixture"]);
            git(&source, &["config", "user.email", "fixture@example.test"]);
            fs::write(source.join("hello.txt"), "one\n").unwrap();
            git(&source, &["add", "."]);
            git(&source, &["commit", "-m", "one"]);
            git(
                dir.path(),
                &[
                    "clone",
                    "--bare",
                    source.to_str().unwrap(),
                    bare.to_str().unwrap(),
                ],
            );
            let url = format!("file://{}", bare.display());
            clone_policy(&url, &client, Policy::Fixture).unwrap();
            git(&client, &["config", "user.name", "Fixture"]);
            git(&client, &["config", "user.email", "fixture@example.test"]);
            Self {
                _dir: dir,
                source,
                bare,
                client,
                url,
            }
        }
        fn state(&self) -> RemoteState {
            state_policy(&self.client, Policy::Fixture).unwrap()
        }
        fn advance(&self) {
            fs::write(self.source.join("hello.txt"), "two\n").unwrap();
            git(&self.source, &["add", "."]);
            git(&self.source, &["commit", "-m", "two"]);
            git(&self.source, &["push", self.bare.to_str().unwrap(), "main"]);
        }
    }
    #[test]
    fn production_urls_and_display_never_accept_credentials_helpers_or_paths() {
        for url in [
            "https://gitlab.com/group/project.git",
            "ssh://git@git.example:2222/group/project.git",
            "git@github.com:owner/repo.git",
            "ssh://git@[::1]:22/a.git",
        ] {
            validate_remote_url(url).unwrap();
        }
        for url in [
            "",
            "/tmp/server.git",
            "../server",
            "file:///tmp/a",
            "ext::sh -c id",
            "https://alice:secret@example.test/a",
            "https://token@example.test/a",
            "ssh://git:secret@host/a",
            "-host:a",
            "git@-host:a",
            "https://host/a?token=secret",
            "git@host:a\n-b",
            "https://host/a#token",
            "https://host/%0afoo",
            "ssh://host:0/a",
            "https://host:/a",
        ] {
            assert!(validate_remote_url(url).is_err(), "accepted {url}");
            assert_eq!(
                display_url(url, Policy::Network),
                "[unsupported or credential-bearing URL]"
            );
        }
    }
    #[test]
    fn unsafe_config_is_rejected_before_any_helper_or_hook_executes() {
        let f = Fixture::new();
        let marker = f._dir.path().join("executed");
        let shell = format!("!touch {}", marker.display());
        git(&f.client, &["config", "credential.helper", &shell]);
        git(
            &f.client,
            &[
                "config",
                "core.sshCommand",
                &format!("touch {}", marker.display()),
            ],
        );
        let command = network_command(&f.client, &["fetch"], Policy::Network);
        let env: BTreeMap<_, _> = command
            .get_envs()
            .map(|(k, v)| {
                (
                    k.to_string_lossy().into_owned(),
                    v.map(|v| v.to_string_lossy().into_owned()),
                )
            })
            .collect();
        assert!(
            env["GIT_SSH_COMMAND"]
                .as_ref()
                .unwrap()
                .starts_with("/usr/bin/ssh -F /dev/null")
        );
        assert_eq!(env["GIT_ASKPASS"].as_deref(), Some("/usr/bin/false"));
        assert!(
            !command
                .get_args()
                .any(|a| a.to_string_lossy().contains("touch"))
        );
        for (key, value) in [
            ("url.https://evil.test/.insteadOf", "https://github.com/"),
            ("remote.origin.vcs", "ext"),
            ("remote.origin.uploadpack", "touch marker"),
            ("remote.origin.receivepack", "touch marker"),
            ("remote.origin.promisor", "true"),
            ("http.sslVerify", "false"),
            ("http.https://host.extraHeader", "Authorization: secret"),
        ] {
            git(&f.client, &["config", key, value]);
            assert!(
                transport_config(&config(&f.client).unwrap()).is_err(),
                "accepted {key}"
            );
            git(&f.client, &["config", "--unset-all", key]);
        }
        assert!(!marker.exists());
        assert!(fetch(&f.client, &state(&f.client).unwrap().state_hash, "origin").is_err());
        assert!(!marker.exists());
        // Exercise a real SSH child: a repository SSH override must never run.
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let endpoint = format!("ssh://git@127.0.0.1:{port}/fixture.git");
        let error = network(
            &f.client,
            &["ls-remote", "--", &endpoint],
            Policy::Network,
            false,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "remote_connection_failed");
        assert!(!marker.exists());
        // Verify Git's helper-reset semantics, including URL-specific helpers,
        // without reading the user's keychain in a unit test.
        git(
            &f.client,
            &[
                "config",
                "credential.https://example.invalid.helper",
                &shell,
            ],
        );
        let mut command = network_command(&f.client, &[], Policy::Network);
        command.args([
            "-c",
            "credential.helper=",
            "-c",
            "credential.helper=/usr/bin/false",
            "credential",
            "fill",
        ]);
        let result = super::super::process::run(
            command,
            Some(b"protocol=https\nhost=example.invalid\n\n"),
            Duration::from_secs(5),
            1024,
        )
        .unwrap();
        assert!(!result.status.success());
        assert!(!marker.exists());
    }
    #[test]
    fn fetch_prunes_only_reviewed_remote_and_state_pins_config_and_source() {
        let f = Fixture::new();
        git(&f.source, &["branch", "gone"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "gone"]);
        fetch_policy(&f.client, &f.state().state_hash, "origin", Policy::Fixture).unwrap();
        let oid = git(&f.client, &["rev-parse", "HEAD"]);
        git(&f.client, &["update-ref", "refs/remotes/other/keep", &oid]);
        git(
            &f.client,
            &[
                "config",
                "remote.origin.fetch",
                "+refs/heads/*:refs/heads/*",
            ],
        );
        git(&f.bare, &["update-ref", "-d", "refs/heads/gone"]);
        fetch_policy(&f.client, &f.state().state_hash, "origin", Policy::Fixture).unwrap();
        assert!(!super::super::ref_exists(&f.client, "refs/remotes/origin/gone").unwrap());
        assert!(super::super::ref_exists(&f.client, "refs/remotes/other/keep").unwrap());
        let stale = f.state().state_hash;
        git(
            &f.client,
            &[
                "config",
                "remote.origin.pushurl",
                "ssh://git@example.test/changed.git",
            ],
        );
        assert_eq!(
            fetch_policy(&f.client, &stale, "origin", Policy::Fixture)
                .unwrap_err()
                .to_string(),
            "stale_remote_state"
        );
        let stale = f.state().state_hash;
        fs::write(f.client.join("untracked"), "external edit").unwrap();
        assert_eq!(
            fetch_policy(&f.client, &stale, "origin", Policy::Fixture)
                .unwrap_err()
                .to_string(),
            "stale_remote_state"
        );
    }
    #[test]
    fn pull_fast_forwards_but_preserves_dirty_or_diverged_work() {
        let f = Fixture::new();
        use std::os::unix::fs::PermissionsExt;
        let hook_marker = f._dir.path().join("hook-executed");
        fs::create_dir_all(f.client.join(".git/hooks")).unwrap();
        for hook in ["post-merge", "reference-transaction", "post-checkout"] {
            let path = f.client.join(".git/hooks").join(hook);
            fs::write(
                &path,
                format!("#!/bin/sh\ntouch '{}'\n", hook_marker.display()),
            )
            .unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        f.advance();
        fs::write(f.client.join("untracked"), "draft").unwrap();
        assert_eq!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap_err()
            .to_string(),
            "remote_worktree_dirty"
        );
        fs::remove_file(f.client.join("untracked")).unwrap();
        pull_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "main",
            Policy::Fixture,
        )
        .unwrap();
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "two\n"
        );
        assert!(f.state().clean);
        fs::write(f.client.join("local"), "local").unwrap();
        git(&f.client, &["add", "."]);
        git(&f.client, &["commit", "-m", "local"]);
        fs::write(f.source.join("remote"), "remote").unwrap();
        git(&f.source, &["add", "."]);
        git(&f.source, &["commit", "-m", "remote"]);
        git(&f.source, &["push", f.bare.to_str().unwrap(), "main"]);
        let head = git(&f.client, &["rev-parse", "HEAD"]);
        assert_eq!(
            pull_policy(
                &f.client,
                &f.state().state_hash,
                "origin",
                "main",
                Policy::Fixture
            )
            .unwrap_err()
            .to_string(),
            "remote_pull_not_fast_forward"
        );
        assert_eq!(git(&f.client, &["rev-parse", "HEAD"]), head);
        assert!(!hook_marker.exists());
    }
    #[test]
    fn pull_rejects_source_and_endpoint_drift_after_fetch() {
        let f = Fixture::new();
        f.advance();
        let initial = f.state();
        let snapshot = super::super::snapshot(&f.client).unwrap();
        let cfg = config(&f.client).unwrap();
        fetch_url(&f.client, &f.url, "origin", Policy::Fixture).unwrap();
        fs::write(f.client.join("hello.txt"), "external edit\n").unwrap();
        assert_eq!(
            integrate_fetched(
                &f.client,
                initial.clone(),
                &snapshot,
                &cfg,
                "origin",
                "main"
            )
            .unwrap_err()
            .to_string(),
            "stale_remote_state"
        );
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "external edit\n"
        );
        fs::write(f.client.join("hello.txt"), "one\n").unwrap();
        git(
            &f.client,
            &["config", "remote.origin.url", "https://host/changed.git"],
        );
        assert_eq!(
            integrate_fetched(&f.client, initial, &snapshot, &cfg, "origin", "main")
                .unwrap_err()
                .to_string(),
            "stale_remote_state"
        );
        assert_eq!(
            fs::read_to_string(f.client.join("hello.txt")).unwrap(),
            "one\n"
        );
    }
    #[test]
    fn push_is_one_exact_branch_and_non_fast_forward_is_explicit_rejection() {
        let f = Fixture::new();
        git(&f.client, &["config", "remote.origin.mirror", "true"]);
        git(&f.client, &["config", "push.default", "matching"]);
        git(&f.client, &["branch", "unselected"]);
        push_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "reviewed",
            Policy::Fixture,
        )
        .unwrap();
        assert_eq!(
            git(&f.bare, &["rev-parse", "refs/heads/reviewed"]),
            git(&f.client, &["rev-parse", "HEAD"])
        );
        assert!(!super::super::ref_exists(&f.bare, "refs/heads/unselected").unwrap());
        assert_eq!(f.state().upstream_branch.as_deref(), Some("reviewed"));
        f.advance();
        let error = push_policy(
            &f.client,
            &f.state().state_hash,
            "origin",
            "main",
            Policy::Fixture,
        )
        .unwrap_err();
        assert_eq!(error.to_string(), "remote_push_rejected");
    }
    #[test]
    fn clone_publishes_new_directory_and_preserves_existing_and_empty_repos() {
        let f = Fixture::new();
        assert_eq!(
            clone_policy(&f.url, &f.client, Policy::Fixture)
                .unwrap_err()
                .to_string(),
            "clone_destination_exists"
        );
        let empty = f._dir.path().join("empty.git");
        git(
            f._dir.path(),
            &["init", "--bare", "-b", "main", empty.to_str().unwrap()],
        );
        let empty_url = format!("file://{}", empty.display());
        let dest = f._dir.path().join("empty-client");
        clone_policy(&empty_url, &dest, Policy::Fixture).unwrap();
        let state = state_policy(&dest, Policy::Fixture).unwrap();
        assert!(state.head.is_none());
        assert!(state.clean);
        let stage = f._dir.path().join("publication-stage");
        let existing = f._dir.path().join("existing-destination");
        fs::create_dir(&stage).unwrap();
        fs::write(stage.join("mine"), "mine").unwrap();
        fs::create_dir(&existing).unwrap();
        assert!(publish(&stage, &existing).is_err());
        assert!(stage.join("mine").exists());
        assert!(fs::read_dir(&existing).unwrap().next().is_none());
        let missing = format!("file://{}/missing.git", f._dir.path().display());
        let failed = f._dir.path().join("failed-clone");
        assert!(clone_policy(&missing, &failed, Policy::Fixture).is_err());
        assert!(!failed.exists());
        assert!(!fs::read_dir(f._dir.path()).unwrap().any(|entry| {
            entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with(".river-clone-")
        }));
    }
    #[test]
    fn remote_configuration_retains_case_and_rejects_unreviewed_changes() {
        let f = Fixture::new();
        let initial = state(&f.client).unwrap();
        configure(
            &f.client,
            &initial.state_hash,
            "add",
            "Company",
            Some("https://gitlab.com/Group/Project.git"),
            Some("git@example.test:Group/Project.git"),
        )
        .unwrap();
        let current = state(&f.client).unwrap();
        assert!(
            current
                .remotes
                .iter()
                .any(|r| r.name == "Company" && r.supported)
        );
        assert_eq!(
            configure(
                &f.client,
                &current.state_hash,
                "add",
                "Company",
                Some("https://host/repo"),
                None
            )
            .unwrap_err()
            .to_string(),
            "remote_name_conflict"
        );
        git(&f.client, &["switch", "-c", "Feature/ABC"]);
        git(
            &f.client,
            &["config", "branch.Feature/ABC.remote", "Company"],
        );
        git(
            &f.client,
            &[
                "config",
                "branch.Feature/ABC.merge",
                "refs/heads/Feature/ABC",
            ],
        );
        let current = state(&f.client).unwrap();
        assert_eq!(current.upstream_remote.as_deref(), Some("Company"));
        assert_eq!(current.upstream_branch.as_deref(), Some("Feature/ABC"));
        configure(
            &f.client,
            &current.state_hash,
            "update",
            "Company",
            Some("https://gitlab.com/Group/New.git"),
            None,
        )
        .unwrap();
        let current = state(&f.client).unwrap();
        let company = current
            .remotes
            .iter()
            .find(|r| r.name == "Company")
            .unwrap();
        assert_eq!(company.fetch_url, company.push_url);
        configure(
            &f.client,
            &current.state_hash,
            "remove",
            "Company",
            None,
            None,
        )
        .unwrap();
        assert!(
            !state(&f.client)
                .unwrap()
                .remotes
                .iter()
                .any(|r| r.name == "Company")
        );
    }
}
