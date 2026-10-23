use std::{fs, path::Path};
use tempfile::TempDir;
use workbench_git as git;

fn committed_repository(path: &Path, marker: &str) {
    fs::create_dir(path).unwrap();
    git::git(path, &["init", "-b", "main"]).unwrap();
    git::git(path, &["config", "user.name", "Path Fixture"]).unwrap();
    git::git(path, &["config", "user.email", "path@example.invalid"]).unwrap();
    fs::write(path.join("sentinel.txt"), marker).unwrap();
    git::git(path, &["add", "--", "sentinel.txt"]).unwrap();
    git::git(path, &["commit", "-m", marker]).unwrap();
}

#[test]
fn repository_root_preserves_terminal_whitespace_next_to_another_repository() {
    for suffix in [" ", "\t", "\r", "\n", "\n\n"] {
        let temp = TempDir::new().unwrap();
        let selected = temp.path().join(format!("project{suffix}"));
        let neighbor = temp.path().join("project");
        committed_repository(&selected, "selected repository\n");
        committed_repository(&neighbor, "neighbor repository\n");
        let before = git::snapshot(&neighbor).unwrap();
        assert_eq!(
            git::root(&selected).unwrap(),
            fs::canonicalize(&selected).unwrap()
        );
        assert_ne!(git::oid(&selected, "HEAD").unwrap(), before.head);
        assert_eq!(git::snapshot(&neighbor).unwrap(), before);
    }
}

#[test]
fn common_directory_keeps_its_terminal_space() {
    let temp = TempDir::new().unwrap();
    let selected = temp.path().join("project");
    fs::create_dir(&selected).unwrap();
    let common = temp.path().join("metadata ");
    git::git(
        &selected,
        &[
            "init",
            "-b",
            "main",
            "--separate-git-dir",
            common.to_str().unwrap(),
        ],
    )
    .unwrap();
    // A plausible trimmed neighbor must never become the repository identity.
    fs::create_dir(temp.path().join("metadata")).unwrap();
    assert_eq!(
        git::common_dir(&selected).unwrap(),
        fs::canonicalize(common).unwrap()
    );
}

#[test]
fn integration_markers_and_checkout_locks_are_checked_under_newline_paths() {
    let temp = TempDir::new().unwrap();
    let selected = temp.path().join("project\r\n\n");
    committed_repository(&selected, "integration fixture\n");
    let head = git::oid(&selected, "HEAD").unwrap();
    git::verify_checkout(&selected, &selected, "refs/heads/main", &head).unwrap();
    for marker in [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
    ] {
        let marker_path = selected.join(".git").join(marker);
        fs::write(&marker_path, format!("{head}\n")).unwrap();
        assert_eq!(
            git::no_conflicts(&selected).unwrap_err().to_string(),
            "integration_in_progress",
            "{marker}"
        );
        fs::remove_file(marker_path).unwrap();
    }
    fs::write(selected.join(".git/locked"), "locked fixture\n").unwrap();
    assert_eq!(
        git::verify_checkout(&selected, &selected, "refs/heads/main", &head)
            .unwrap_err()
            .to_string(),
        "worktree_locked"
    );
}

#[test]
fn newline_linked_worktrees_keep_their_own_integration_markers() {
    let temp = TempDir::new().unwrap();
    let source = temp.path().join("source\n");
    committed_repository(&source, "linked worktree fixture\n");
    let linked = temp.path().join("linked\r\n");
    git::git(
        &source,
        &[
            "worktree",
            "add",
            "-b",
            "linked-fixture",
            linked.to_str().unwrap(),
            "HEAD",
        ],
    )
    .unwrap();
    let head = git::oid(&source, "HEAD").unwrap();
    git::verify_checkout(&linked, &source, "refs/heads/linked-fixture", &head).unwrap();
    let git_dir = git::git_path(&linked, &["rev-parse", "--absolute-git-dir"]).unwrap();
    assert_ne!(git_dir, git::common_dir(&source).unwrap());
    for marker in [
        "MERGE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD",
        "rebase-merge",
        "rebase-apply",
    ] {
        let marker_path = git_dir.join(marker);
        fs::write(&marker_path, format!("{head}\n")).unwrap();
        assert_eq!(
            git::no_conflicts(&linked).unwrap_err().to_string(),
            "integration_in_progress",
            "{marker}"
        );
        git::no_conflicts(&source).unwrap();
        fs::remove_file(marker_path).unwrap();
    }
    git::verify_checkout(&linked, &source, "refs/heads/linked-fixture", &head).unwrap();
}
