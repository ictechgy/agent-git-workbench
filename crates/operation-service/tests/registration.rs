use std::fs;
use tempfile::TempDir;
use workbench_domain::{Mode, TaskRequest};
use workbench_git as git;
use workbench_service::{Request, Service, fixtures, load_workspace, registration};

#[test]
fn selected_folder_cannot_register_a_redirected_worktree() {
    let temp = TempDir::new().unwrap();
    let ws = fixtures::create(&temp.path().join("fixture")).unwrap();
    let source = &ws.repo("ios-app").unwrap().path;
    let other = &ws.repo("api").unwrap().path;
    let original_other = git::snapshot(other).unwrap();
    git::git(
        source,
        &["config", "core.worktree", other.to_str().unwrap()],
    )
    .unwrap();
    assert_eq!(
        registration::inspect(source).unwrap_err().to_string(),
        "unsafe_source_repository"
    );
    let config = temp.path().join("new/workspace.json");
    assert!(registration::create(source, &config).is_err());
    assert!(!config.exists());
    assert_eq!(
        registration::inspect(&other.join("Config")).unwrap().path,
        *other
    );
    assert_eq!(git::snapshot(other).unwrap(), original_other);
    // An ancestor check alone also accepts a redirected nested .git inside a
    // separately versioned parent (for example a dotfiles-managed home).
    let nested = other.join("nested-project");
    fs::create_dir(&nested).unwrap();
    git::git(&nested, &["init", "-b", "main"]).unwrap();
    git::git(
        &nested,
        &["config", "core.worktree", other.to_str().unwrap()],
    )
    .unwrap();
    assert_eq!(
        registration::inspect(&nested).unwrap_err().to_string(),
        "unsafe_source_repository"
    );
    git::git(
        &nested,
        &["config", "core.worktree", temp.path().to_str().unwrap()],
    )
    .unwrap();
    assert_eq!(
        registration::inspect(&nested).unwrap_err().to_string(),
        "unsafe_source_repository"
    );
}

#[test]
fn selected_repository_registration_preserves_dirty_checkout_and_never_trusts_code() {
    let temp = TempDir::new().unwrap();
    let fixture = temp.path().join("fixture");
    let ws = fixtures::create(&fixture).unwrap();
    let source = &ws.repo("ios-app").unwrap().path;
    git::git(source, &["add", "notes.txt"]).unwrap();
    let before = git::snapshot(source).unwrap();
    let config = temp.path().join("app data/workspace.json");
    let registered = registration::create(&source.join("Config"), &config).unwrap();
    assert!(registered.recipes.is_empty());
    assert_eq!(registered.repositories[0].path, *source);
    assert_eq!(
        registered.policy.base_ref.as_deref(),
        Some("refs/heads/main")
    );
    assert_eq!(before, git::snapshot(source).unwrap());
    load_workspace(&config).unwrap();
    let saved = fs::read(&config).unwrap();
    assert!(registration::create(source, &config).is_err());
    assert_eq!(saved, fs::read(config).unwrap());
}

#[test]
fn empty_repository_can_be_opened_before_first_commit() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("새 저장소");
    fs::create_dir(&source).unwrap();
    git::git(&source, &["init", "-b", "main"]).unwrap();
    fs::write(source.join("README.md"), "new work").unwrap();
    let config = temp.path().join("app/workspace.json");
    registration::create(&source, &config).unwrap();
    let view = git::view(&source).unwrap();
    assert!(view.snapshot.head.is_empty());
    assert!(view.graph.is_empty());
    assert_eq!(view.files[0].path, "README.md");
    assert!(!source.join(".git/index").exists());
}

#[test]
fn relative_config_destination_produces_a_loadable_absolute_worktree_root() {
    let temp = TempDir::new_in(".").unwrap();
    let source = temp.path().join("source");
    fs::create_dir(&source).unwrap();
    git::git(&source, &["init", "-b", "main"]).unwrap();
    let config =
        std::path::PathBuf::from(temp.path().file_name().unwrap()).join("nested/workspace.json");
    assert!(config.is_relative());
    let workspace = registration::create(&source, &config).unwrap();
    assert!(workspace.worktree_root.is_absolute());
    assert_eq!(
        load_workspace(&config).unwrap().worktree_root,
        workspace.worktree_root
    );
}

#[test]
fn selected_repository_registration_preserves_terminal_path_whitespace() {
    for suffix in [" ", "\t", "\r", "\n", "\n\n"] {
        let temp = TempDir::new().unwrap();
        let source = temp.path().join(format!("project{suffix}"));
        let neighbor = temp.path().join("project");
        for (path, sentinel) in [
            (&source, "selected repository\n"),
            (&neighbor, "neighbor repository\n"),
        ] {
            fs::create_dir(path).unwrap();
            git::git(path, &["init", "-b", "main"]).unwrap();
            fs::write(path.join("sentinel.txt"), sentinel).unwrap();
        }
        let selected_before = git::snapshot(&source).unwrap();
        let neighbor_before = git::snapshot(&neighbor).unwrap();
        let selected_path = fs::canonicalize(&source).unwrap();
        let child = source.join("nested folder");
        fs::create_dir(&child).unwrap();
        assert_eq!(registration::inspect(&child).unwrap().path, selected_path);
        let config = temp.path().join("app/workspace.json");
        let registered = registration::create(&source, &config).unwrap();
        assert_eq!(registered.repositories[0].path, selected_path);
        assert_eq!(
            load_workspace(&config).unwrap().repositories[0].path,
            selected_path
        );
        assert_eq!(git::snapshot(&source).unwrap(), selected_before);
        assert_eq!(git::snapshot(&neighbor).unwrap(), neighbor_before);
        assert_eq!(
            fs::read(source.join("sentinel.txt")).unwrap(),
            b"selected repository\n"
        );
        assert_eq!(
            fs::read(neighbor.join("sentinel.txt")).unwrap(),
            b"neighbor repository\n"
        );
    }
}

#[test]
fn whitespace_paths_keep_task_worktree_identity_and_mutations_in_the_selected_repository() {
    use serde_json::json;
    use std::time::{Duration, Instant};

    for suffix in [" ", "\r\n\n"] {
        let temp = TempDir::new().unwrap();
        let source = temp.path().join(format!("project{suffix}"));
        let neighbor = temp.path().join("project");
        for (path, sentinel) in [
            (&source, "selected repository\n"),
            (&neighbor, "neighbor repository\n"),
        ] {
            fs::create_dir(path).unwrap();
            git::git(path, &["init", "-b", "main"]).unwrap();
            git::git(path, &["config", "user.name", "Path Fixture"]).unwrap();
            git::git(path, &["config", "user.email", "path@example.invalid"]).unwrap();
            fs::write(path.join("sentinel.txt"), sentinel).unwrap();
            git::git(path, &["add", "--", "sentinel.txt"]).unwrap();
            git::git(path, &["commit", "-m", sentinel]).unwrap();
        }
        let source_before = git::snapshot(&source).unwrap();
        let neighbor_before = git::snapshot(&neighbor).unwrap();
        let config = temp.path().join("app/workspace.json");
        let mut workspace = registration::create(&source, &config).unwrap();
        workspace.worktree_root = fs::canonicalize(temp.path())
            .unwrap()
            .join("worktrees \r\n");
        fs::write(&config, serde_json::to_vec(&workspace).unwrap()).unwrap();
        let workspace = load_workspace(&config).unwrap();
        let repo_id = workspace.repositories[0].id.clone();
        let service = Service::open(workspace, &temp.path().join("journal.sqlite")).unwrap();
        let plan = service
            .plan(TaskRequest {
                group_id: "개발".into(),
                label: "Path identity fixture".into(),
                task_slug: "path-identity".into(),
                mode: Mode::Materialize,
                repo_overrides: Default::default(),
            })
            .unwrap();
        let started = service.execute(&plan.id, "path-identity").unwrap();
        let began = Instant::now();
        let operation = loop {
            let operation = service.operation(&started.id).unwrap();
            if !matches!(operation.status.as_str(), "queued" | "running") {
                break operation;
            }
            assert!(
                began.elapsed() < Duration::from_secs(20),
                "worktree preparation timed out"
            );
            std::thread::sleep(Duration::from_millis(10));
        };
        assert_eq!(operation.status, "ready", "{operation:?}");
        let linked = &operation.repos[0].plan.worktree_path;
        let rpc = |method: &str, params| {
            let response = service.dispatch(Request {
                method: method.into(),
                params,
            });
            assert!(response.error.is_none(), "{method}: {:?}", response.error);
            response.result.unwrap()
        };
        let remote = git::remotes::state(linked).unwrap();
        assert_eq!(remote.repository_path, linked.to_str().unwrap());
        assert_eq!(git::root(linked).unwrap(), *linked);
        assert_eq!(
            git::common_dir(linked).unwrap(),
            git::common_dir(&source).unwrap()
        );
        fs::write(linked.join("sentinel.txt"), "selected task change\n").unwrap();
        let diff = rpc(
            "get_diff",
            json!({"repo_id":repo_id,"op_id":operation.id,"path":"sentinel.txt"}),
        );
        let staged = rpc(
            "stage_hunk",
            json!({"repo_id":repo_id,"op_id":operation.id,"path":"sentinel.txt","hunk_index":0,"snapshot_hash":diff["snapshot_hash"],"diff_hash":workbench_domain::hash(diff["text"].as_str().unwrap().as_bytes())}),
        );
        let committed = rpc(
            "commit",
            json!({"repo_id":repo_id,"op_id":operation.id,"message":"Commit to the exact worktree","snapshot_hash":staged["view"]["snapshot_hash"]}),
        );
        assert_eq!(committed["status"], "committed");
        assert_eq!(
            fs::read(linked.join("sentinel.txt")).unwrap(),
            b"selected task change\n"
        );
        assert_ne!(git::oid(linked, "HEAD").unwrap(), source_before.head);
        // A modified backlink must not gain authority by trimming a different
        // path into the expected .git control file.
        let git_dir = git::git_path(linked, &["rev-parse", "--absolute-git-dir"]).unwrap();
        let backlink = git_dir.join("gitdir");
        let backlink_before = fs::read(&backlink).unwrap();
        let mut changed_backlink = backlink_before.strip_suffix(b"\n").unwrap().to_vec();
        changed_backlink.extend_from_slice(b" \n");
        fs::write(&backlink, changed_backlink).unwrap();
        let blocked = service.dispatch(Request {
            method: "get_repo_status".into(),
            params: json!({"repo_id":repo_id,"op_id":operation.id}),
        });
        assert!(
            blocked.error.is_some(),
            "a different backlink path was accepted"
        );
        fs::write(backlink, backlink_before).unwrap();
        rpc(
            "get_repo_status",
            json!({"repo_id":repo_id,"op_id":operation.id}),
        );
        assert_eq!(git::snapshot(&source).unwrap(), source_before);
        assert_eq!(git::snapshot(&neighbor).unwrap(), neighbor_before);
    }
}
