use std::fs;
use tempfile::TempDir;
use workbench_git as git;
use workbench_service::{fixtures, load_workspace, registration};

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
