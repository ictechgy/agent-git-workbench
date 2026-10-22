//! Local desktop bootstrap: register a selected repository without editing its checkout.
use anyhow::{Context, Result, ensure};
use std::{collections::BTreeMap, fs, io::Write, path::Path};
use workbench_domain::*;
use workbench_git as git;

pub fn inspect(selected: &Path) -> Result<Repository> {
    let selected = fs::canonicalize(selected).context("invalid_repo_path")?;
    ensure!(selected.is_dir(), "invalid_repo_path");
    let path = fs::canonicalize(
        git::git(&selected, &["rev-parse", "--show-toplevel"])
            .context("not_a_repository")?
            .trim(),
    )?;
    let name = path
        .file_name()
        .and_then(|n| n.to_str())
        .unwrap_or("Repository")
        .to_string();
    ensure!(selected.starts_with(&path), "unsafe_source_repository");
    ensure!(
        git::common_dir(&selected).context("unsafe_source_repository")?
            == git::common_dir(&path).context("unsafe_source_repository")?,
        "unsafe_source_repository"
    );
    Ok(Repository { id: name, path })
}

pub fn create(selected: &Path, destination: &Path) -> Result<Workspace> {
    let repository = inspect(selected)?;
    let path = repository.path;
    let name = repository.id;
    let current = git::git(&path, &["symbolic-ref", "-q", "HEAD"]).unwrap_or_default();
    let base_ref = if current.trim().is_empty() {
        git::git(
            &path,
            &["for-each-ref", "--format=%(refname)", "refs/heads"],
        )?
        .lines()
        .next()
        .unwrap_or("refs/heads/main")
        .to_string()
    } else {
        current.trim().to_string()
    };
    let parent = destination
        .parent()
        .context("invalid_workspace_destination")?;
    let parent = if parent.as_os_str().is_empty() {
        Path::new(".")
    } else {
        parent
    };
    fs::create_dir_all(parent)?;
    let parent = fs::canonicalize(parent)?;
    let workspace = Workspace {
        schema_version: 1,
        id: name.clone(),
        worktree_root: parent.join("worktrees"),
        user_defaults: Policy::default(),
        policy: Policy {
            base_ref: Some(base_ref),
            branch_pattern: Some("feature/{task_slug}".into()),
            ..Default::default()
        },
        repositories: vec![Repository {
            id: name.clone(),
            path,
        }],
        groups: vec![BranchGroup {
            id: "개발".into(),
            parent_group_id: None,
            template_id: Some("standard".into()),
            policy: Policy::default(),
        }],
        templates: vec![TaskTemplate {
            id: "standard".into(),
            repos: BTreeMap::from([(name, Policy::default())]),
        }],
        recipes: vec![],
    };
    workspace.validate()?;
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(destination)
        .context("workspace_destination_exists")?;
    file.write_all(&serde_json::to_vec_pretty(&workspace)?)?;
    file.sync_all()?;
    Ok(workspace)
}
