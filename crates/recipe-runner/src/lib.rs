use anyhow::{Context, Result, bail, ensure};
use std::{
    fs,
    io::{Read, Write},
    os::fd::AsRawFd,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};
use workbench_domain::{IosInputs, Recipe, Snapshot, digest, hash, safe_relative};

pub fn contained_file(root: &Path, relative: &str) -> Result<PathBuf> {
    safe_relative(relative)?;
    let root = fs::canonicalize(root)?;
    let mut path = root.clone();
    for part in Path::new(relative).components() {
        path.push(part);
        ensure!(
            !fs::symlink_metadata(&path)
                .context("missing_recipe_file")?
                .file_type()
                .is_symlink(),
            "recipe_symlink"
        );
    }
    ensure!(
        fs::canonicalize(&path)?.starts_with(&root) && path.is_file(),
        "unsafe_recipe_file"
    );
    Ok(path)
}
pub fn trust_hash(recipe: &Recipe, root: &Path) -> Result<String> {
    let script = contained_file(root, &recipe.script)?;
    for file in &recipe.writes {
        contained_file(root, file)?;
    }
    let mut contract = recipe.clone();
    contract.trusted_hash = None;
    ensure!(
        fs::metadata(&recipe.executable)?.permissions().mode() & 0o111 != 0,
        "executable_unavailable"
    );
    digest(&(
        contract,
        hash(fs::read(script)?),
        hash(fs::read(&recipe.executable)?),
    ))
}
pub fn trusted(recipe: &Recipe, root: &Path) -> Result<String> {
    let actual = trust_hash(recipe, root)?;
    ensure!(
        recipe.trusted_hash.as_ref() == Some(&actual),
        "untrusted_recipe"
    );
    Ok(actual)
}
pub fn inspect(root: &Path) -> Result<IosInputs> {
    let text = fs::read_to_string(contained_file(root, "Config/Version.xcconfig")?)?;
    let mut values = std::collections::BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with("//") {
            continue;
        }
        let (key, value) = line.split_once('=').context("unsupported_xcconfig")?;
        ensure!(
            ["MARKETING_VERSION", "CURRENT_PROJECT_VERSION"].contains(&key.trim()),
            "unsupported_xcconfig"
        );
        ensure!(
            values.insert(key.trim(), value.trim()).is_none(),
            "ambiguous_xcconfig"
        );
    }
    let inputs = IosInputs {
        marketing_version: values
            .get("MARKETING_VERSION")
            .context("missing_version_key")?
            .to_string(),
        local_build: values
            .get("CURRENT_PROJECT_VERSION")
            .context("missing_build_key")?
            .to_string(),
    };
    inputs.validate()?;
    Ok(inputs)
}
pub fn postcondition(
    recipe: &Recipe,
    root: &Path,
    expected: &IosInputs,
    baseline: &Snapshot,
) -> Result<Snapshot> {
    trusted(recipe, root)?;
    let after = workbench_git::preparation_snapshot(root)?;
    ensure!(
        baseline.head == after.head
            && baseline.branch == after.branch
            && baseline.index_hash == after.index_hash,
        "unexpected_git_change"
    );
    let all: std::collections::BTreeSet<_> =
        baseline.files.keys().chain(after.files.keys()).collect();
    ensure!(
        all.into_iter()
            .all(|p| baseline.files.get(p) == after.files.get(p) || recipe.writes.contains(p)),
        "unexpected_changes"
    );
    ensure!(&inspect(root)? == expected, "postcondition_failed");
    Ok(after)
}
pub fn run(
    recipe: &Recipe,
    root: &Path,
    inputs: &IosInputs,
    cancelled: Arc<AtomicBool>,
) -> Result<()> {
    inputs.validate()?;
    trusted(recipe, root)?;
    // The first adapter has no secret fields. Stdout/stderr are deliberately discarded,
    // so untrusted script output cannot leak into the journal or error response.
    let mut cmd = Command::new(&recipe.executable);
    cmd.arg("-I")
        .arg(contained_file(root, &recipe.script)?)
        .arg("--input-json-stdin")
        .current_dir(root)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0);
    let mut child = cmd.spawn().context("recipe_spawn_failed")?;
    let stdout = child.stdout.take().context("recipe_stdout")?;
    let stderr = child.stderr.take().context("recipe_stderr")?;
    // Drain the pipes with bounded retained output (zero), including noisy scripts.
    let stdout_fd = stdout.as_raw_fd();
    let stderr_fd = stderr.as_raw_fd();
    let drain_done = Arc::new(AtomicBool::new(false));
    let readers: Vec<_> = [
        (stdout.map_reader(), stdout_fd),
        (stderr.map_reader(), stderr_fd),
    ]
    .into_iter()
    .map(|(mut r, fd)| {
        let done = drain_done.clone();
        thread::spawn(move || {
            let mut buf = [0; 4096];
            while !done.load(Ordering::SeqCst) {
                let mut descriptor = libc::pollfd {
                    fd,
                    events: libc::POLLIN,
                    revents: 0,
                };
                let ready = unsafe { libc::poll(&mut descriptor, 1, 20) };
                if ready > 0 && r.read(&mut buf).unwrap_or(0) == 0 {
                    break;
                }
            }
        })
    })
    .collect();
    let payload = serde_json::to_vec(inputs)?;
    let write_result = child
        .stdin
        .take()
        .context("recipe_stdin")?
        .write_all(&payload);
    let start = Instant::now();
    let mut stopped = None;
    let status = loop {
        // Observe exit without reaping: the leader's PID/PGID cannot be reused
        // until descendants are signalled and Child::wait finally reaps it.
        let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
        let result = unsafe {
            libc::waitid(
                libc::P_PID,
                child.id(),
                &mut info,
                libc::WEXITED | libc::WNOHANG | libc::WNOWAIT,
            )
        };
        ensure!(result == 0, "recipe_wait_failed");
        if info.si_pid == child.id() as i32 {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            break child.wait()?;
        }
        let stop = cancelled.load(Ordering::SeqCst)
            || start.elapsed() >= Duration::from_secs(recipe.timeout_seconds)
            || write_result.is_err();
        if stop && stopped.is_none() {
            stopped = Some(Instant::now());
            // Separate process group; do not signal the workbench itself.
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGTERM);
            }
        }
        if stopped.is_some_and(|s| s.elapsed() >= Duration::from_millis(500)) {
            unsafe {
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
        }
        thread::sleep(Duration::from_millis(20));
    };
    // An escaped descendant may retain a pipe. It cannot hold preparation open
    // after the trusted leader exited; output is deliberately not retained.
    drain_done.store(true, Ordering::SeqCst);
    for reader in readers {
        let _ = reader.join();
    }
    if cancelled.load(Ordering::SeqCst) {
        bail!("cancelled");
    }
    ensure!(stopped.is_none(), "recipe_timeout");
    write_result.context("recipe_stdin_failed")?;
    ensure!(status.success(), "recipe_failed: exit {:?}", status.code());
    Ok(())
}

trait BoxReader {
    fn map_reader(self) -> Box<dyn Read + Send>;
}
impl<T: Read + Send + 'static> BoxReader for T {
    fn map_reader(self) -> Box<dyn Read + Send> {
        Box::new(self)
    }
}
