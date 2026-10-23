use std::{fs, path::PathBuf};
use tempfile::TempDir;
use workbench_domain::{digest, hash};
use workbench_git as git;

struct Fixture {
    _temp: TempDir,
    root: PathBuf,
}

impl Fixture {
    fn new(files: &[(&str, &[u8])]) -> Self {
        let temp = TempDir::new().unwrap();
        let root = temp.path().join("repository");
        fs::create_dir(&root).unwrap();
        git::git(&root, &["init", "-b", "main"]).unwrap();
        git::git(&root, &["config", "user.name", "Hunk Fixture"]).unwrap();
        git::git(&root, &["config", "user.email", "hunk@example.invalid"]).unwrap();
        for (name, content) in files {
            let path = root.join(name);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, content).unwrap();
        }
        git::git(&root, &["add", "--all"]).unwrap();
        git::git(
            &root,
            &["commit", "--allow-empty", "-m", "Hunk scope baseline"],
        )
        .unwrap();
        Self { _temp: temp, root }
    }

    fn index(&self, file: &str) -> Vec<u8> {
        git::git_bytes(&self.root, &["show", &format!(":{file}")]).unwrap()
    }

    fn assert_directory_rejected(&self, requested: &str, hunk: usize) {
        let before = git::snapshot(&self.root).unwrap();
        let index_before = fs::read(self.root.join(".git/index")).unwrap();
        let reviewed = git::diff(&self.root, requested, false);
        let (expected, expected_diff) = match &reviewed {
            Ok(diff) => (diff.snapshot_hash.clone(), hash(diff.text.as_bytes())),
            Err(_) => {
                let raw = git::git_bytes(
                    &self.root,
                    &[
                        "diff",
                        "--src-prefix=a/",
                        "--dst-prefix=b/",
                        "--no-ext-diff",
                        "--no-textconv",
                        "--no-renames",
                        "--unified=3",
                        "--",
                        requested,
                    ],
                )
                .unwrap();
                (digest(&before).unwrap(), hash(raw))
            }
        };
        let result = git::stage_hunk(
            &self.root,
            requested,
            false,
            hunk,
            &expected,
            &expected_diff,
        );
        eprintln!(
            "requested={requested:?}, stage_result={result:?}, index_a={:?}, index_b={:?}",
            self.index("directory/a.txt"),
            self.index("directory/b.txt")
        );
        assert!(result.is_err(), "a directory-scoped hunk was applied");
        if let Ok(diff) = reviewed {
            assert!(
                !diff.can_stage_hunks,
                "an aggregate directory diff was editable"
            );
        }
        assert_eq!(
            fs::read(self.root.join(".git/index")).unwrap(),
            index_before
        );
        assert_eq!(git::snapshot(&self.root).unwrap(), before);
    }
}

#[test]
fn directory_hunk_cannot_apply_another_files_change_to_the_first_index_entry() {
    let baseline = b"shared before\nsame old line\nshared after\n";
    let fixture = Fixture::new(&[("directory/a.txt", baseline), ("directory/b.txt", baseline)]);
    fs::write(
        fixture.root.join("directory/a.txt"),
        "shared before\nfirst file edit\nshared after\n",
    )
    .unwrap();
    fs::write(
        fixture.root.join("directory/b.txt"),
        "shared before\nsecond file edit\nshared after\n",
    )
    .unwrap();
    fixture.assert_directory_rejected("directory", 1);
}

#[test]
fn a_directory_with_one_changed_file_is_still_not_a_file_scope() {
    let baseline = b"shared before\nsame old line\nshared after\n";
    let fixture = Fixture::new(&[("directory/a.txt", baseline), ("directory/b.txt", baseline)]);
    fs::write(
        fixture.root.join("directory/a.txt"),
        "shared before\nfirst file edit\nshared after\n",
    )
    .unwrap();
    fixture.assert_directory_rejected("directory", 0);
}

#[test]
fn quoted_unicode_paths_and_crlf_hunks_round_trip_only_the_requested_index_file() {
    let file = "directory/한글 \"quoted\"\t[entry]\nfile.txt";
    let baseline = b"before\r\nsame old line\r\ndiff --git source text\r\nafter\r\n";
    let changed = "before\r\n선택한 변경\r\ndiff --git source text\r\nafter\r\n".as_bytes();
    let fixture = Fixture::new(&[(file, baseline), ("neighbor.txt", baseline)]);
    fs::write(fixture.root.join(file), changed).unwrap();
    let diff = git::diff(&fixture.root, file, false).unwrap();
    assert!(diff.can_stage_hunks);
    git::stage_hunk(
        &fixture.root,
        file,
        false,
        0,
        &diff.snapshot_hash,
        &hash(diff.text.as_bytes()),
    )
    .unwrap();
    assert_eq!(fixture.index(file), changed);
    assert_eq!(fixture.index("neighbor.txt"), baseline);
    let staged = git::diff(&fixture.root, file, true).unwrap();
    git::stage_hunk(
        &fixture.root,
        file,
        true,
        0,
        &staged.snapshot_hash,
        &hash(staged.text.as_bytes()),
    )
    .unwrap();
    assert_eq!(fixture.index(file), baseline);
    assert_eq!(fixture.index("neighbor.txt"), baseline);
    assert_eq!(fs::read(fixture.root.join(file)).unwrap(), changed);
}

#[test]
fn deleted_tracked_files_remain_reviewable_on_both_sides_without_hunk_mutation() {
    let fixture = Fixture::new(&[
        ("deleted.txt", b"deleted file baseline\n"),
        ("neighbor.txt", b"keep me\n"),
    ]);
    fs::remove_file(fixture.root.join("deleted.txt")).unwrap();
    for staged in [false, true] {
        if staged {
            git::git(&fixture.root, &["add", "--", "deleted.txt"]).unwrap();
        }
        let before = git::snapshot(&fixture.root).unwrap();
        let raw_index = fs::read(fixture.root.join(".git/index")).unwrap();
        let diff = git::diff(&fixture.root, "deleted.txt", staged).unwrap();
        assert!(diff.text.contains("deleted file mode"));
        assert!(!diff.can_stage_hunks);
        assert!(
            git::stage_hunk(
                &fixture.root,
                "deleted.txt",
                staged,
                0,
                &diff.snapshot_hash,
                &hash(diff.text.as_bytes())
            )
            .is_err()
        );
        assert_eq!(
            fs::read(fixture.root.join(".git/index")).unwrap(),
            raw_index
        );
        assert_eq!(git::snapshot(&fixture.root).unwrap(), before);
    }
    // The other side of a fully staged deletion remains a valid empty review.
    assert!(
        git::diff(&fixture.root, "deleted.txt", false)
            .unwrap()
            .text
            .is_empty()
    );
    assert_eq!(fixture.index("neighbor.txt"), b"keep me\n");
}

#[test]
fn symlink_target_hunks_preserve_existing_file_scope_support() {
    use std::os::unix::fs::symlink;
    let fixture = Fixture::new(&[
        ("target-a", b"first target\n"),
        ("target-b", b"second target\n"),
    ]);
    symlink("target-a", fixture.root.join("link")).unwrap();
    git::git(&fixture.root, &["add", "--", "link"]).unwrap();
    git::git(&fixture.root, &["commit", "-m", "Track a symlink"]).unwrap();
    fs::remove_file(fixture.root.join("link")).unwrap();
    symlink("target-b", fixture.root.join("link")).unwrap();
    let diff = git::diff(&fixture.root, "link", false).unwrap();
    assert!(diff.can_stage_hunks);
    git::stage_hunk(
        &fixture.root,
        "link",
        false,
        0,
        &diff.snapshot_hash,
        &hash(diff.text.as_bytes()),
    )
    .unwrap();
    assert_eq!(fixture.index("link"), b"target-b");
    assert_eq!(fixture.index("target-a"), b"first target\n");
    assert_eq!(fixture.index("target-b"), b"second target\n");
    assert_eq!(
        fs::read_link(fixture.root.join("link")).unwrap(),
        PathBuf::from("target-b")
    );
}

#[test]
fn intent_to_add_still_reviews_the_new_file_as_read_only() {
    let fixture = Fixture::new(&[]);
    fs::write(fixture.root.join("pending.txt"), "pending addition\n").unwrap();
    git::git(&fixture.root, &["add", "-N", "--", "pending.txt"]).unwrap();
    let diff = git::diff(&fixture.root, "pending.txt", false).unwrap();
    assert!(diff.text.contains("new file mode"));
    assert!(!diff.can_stage_hunks);
    let before = git::snapshot(&fixture.root).unwrap();
    assert!(
        git::stage_hunk(
            &fixture.root,
            "pending.txt",
            false,
            0,
            &diff.snapshot_hash,
            &hash(diff.text.as_bytes())
        )
        .is_err()
    );
    assert_eq!(git::snapshot(&fixture.root).unwrap(), before);
}

#[test]
fn unborn_staged_additions_remain_reviewable_and_read_only() {
    let temp = TempDir::new().unwrap();
    let root = temp.path();
    git::git(root, &["init", "-b", "main"]).unwrap();
    fs::write(root.join("first.txt"), "first addition\n").unwrap();
    git::git(root, &["add", "--", "first.txt"]).unwrap();
    let diff = git::diff(root, "first.txt", true).unwrap();
    assert!(diff.text.contains("new file mode"));
    assert!(!diff.can_stage_hunks);
    let before = git::snapshot(root).unwrap();
    assert!(before.head.is_empty());
    assert!(
        git::stage_hunk(
            root,
            "first.txt",
            true,
            0,
            &diff.snapshot_hash,
            &hash(diff.text.as_bytes())
        )
        .is_err()
    );
    assert_eq!(git::snapshot(root).unwrap(), before);
}
