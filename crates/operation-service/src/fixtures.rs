//! Generates only new synthetic repositories. Never accepts an existing repository.
use anyhow::{Result, ensure};
use std::{fs, path::Path, process::Command};
use workbench_domain::*;
use workbench_git as git;

pub const VERSION_SCRIPT: &str = include_str!("../../../adapters/ios-version/set_ios_version.py");
pub fn create(parent: &Path) -> Result<Workspace> {
    ensure!(!parent.exists(), "fixture_destination_exists");
    fs::create_dir_all(parent)?;
    let parent = fs::canonicalize(parent)?;
    let python = Command::new("python3")
        .args(["-c", "import sys; print(sys.executable)"])
        .output()?;
    ensure!(python.status.success(), "python_unavailable");
    let python = fs::canonicalize(String::from_utf8(python.stdout)?.trim())?;
    let mut repositories = vec![];
    let mut recipes = vec![];
    for repo_id in ["ios-app", "api"] {
        let path = parent.join(format!("{repo_id} 합성 repo"));
        fs::create_dir(&path)?;
        git::git(&path, &["init", "-b", "main"])?;
        git::git(&path, &["config", "user.name", "Workbench Fixture"])?;
        git::git(&path, &["config", "user.email", "fixture@example.invalid"])?;
        git::git(&path, &["config", "commit.gpgsign", "false"])?;
        fs::create_dir(path.join("Config"))?;
        fs::create_dir(path.join("scripts"))?;
        fs::write(
            path.join("Config/Version.xcconfig"),
            "// Synthetic FixtureApp / Debug\nMARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n",
        )?;
        fs::write(path.join("scripts/set_ios_version.py"), VERSION_SCRIPT)?;
        fs::write(
            path.join("notes.txt"),
            (1..=40).map(|n| format!("line {n}\n")).collect::<String>(),
        )?;
        git::git(&path, &["add", "--all"])?;
        git::git(&path, &["commit", "-m", "Initial synthetic fixture"])?;
        git::git(&path, &["branch", "release/2.4"])?;
        // An external sentinel makes one repo fail without changing trusted code.
        // The failure script is part of this generated repo and its trust pin.
        let script=VERSION_SCRIPT.replace("# FIXTURE_GATE",&format!("from pathlib import Path\nimport time\ngate = Path({:?})\nif gate.with_suffix('.sleep').exists(): time.sleep(30)\nif gate.exists(): raise SystemExit(23)",parent.join(format!("{repo_id}.fail")).to_string_lossy()));
        fs::write(path.join("scripts/set_ios_version.py"), script)?;
        git::git(&path, &["add", "scripts/set_ios_version.py"])?;
        git::git(&path, &["commit", "-m", "Install synthetic failure gate"])?;
        git::git(&path, &["branch", "-f", "release/2.4", "HEAD"])?;
        fs::write(
            path.join("notes.txt"),
            "original dirty worktree — preserve me\n",
        )?;
        fs::write(path.join("local-only.txt"), "untracked user edit\n")?;
        let recipe = Recipe {
            id: format!("{repo_id}.set-version@1"),
            repo_id: repo_id.into(),
            revision: 1,
            executable: python.clone(),
            script: "scripts/set_ios_version.py".into(),
            writes: vec!["Config/Version.xcconfig".into()],
            timeout_seconds: 3,
            target: "FixtureApp".into(),
            configuration: "Debug".into(),
            trusted_hash: None,
        };
        repositories.push(Repository {
            id: repo_id.into(),
            path,
        });
        recipes.push(recipe);
    }
    let workspace = Workspace {
        schema_version: 1,
        id: "synthetic-workspace".into(),
        worktree_root: parent.join("worktrees"),
        user_defaults: Policy::default(),
        policy: Policy {
            base_ref: Some("refs/heads/main".into()),
            branch_pattern: Some("feature/{task_slug}".into()),
            ..Default::default()
        },
        repositories,
        groups: vec![
            BranchGroup {
                id: "mobile".into(),
                parent_group_id: None,
                template_id: Some("ios-with-api".into()),
                policy: Policy {
                    inputs: Some(IosInputs {
                        marketing_version: "2.4.0".into(),
                        local_build: "241".into(),
                    }),
                    ..Default::default()
                },
            },
            BranchGroup {
                id: "ios-2-4".into(),
                parent_group_id: Some("mobile".into()),
                template_id: None,
                policy: Policy {
                    base_ref: Some("refs/heads/release/2.4".into()),
                    branch_pattern: Some("feature/2.4/{task_slug}".into()),
                    ..Default::default()
                },
            },
        ],
        templates: vec![TaskTemplate {
            id: "ios-with-api".into(),
            repos: recipes
                .iter()
                .map(|r| {
                    (
                        r.repo_id.clone(),
                        Policy {
                            recipe: Some(r.id.clone()),
                            ..Default::default()
                        },
                    )
                })
                .collect(),
        }],
        recipes,
    };
    workspace.validate()?;
    fs::write(
        parent.join("workspace.json"),
        serde_json::to_vec_pretty(&workspace)?,
    )?;
    Ok(workspace)
}
pub fn trust(config: &Path, recipe_id: &str) -> Result<String> {
    let mut workspace: Workspace = serde_json::from_slice(&fs::read(config)?)?;
    workspace.validate()?;
    let recipe = workspace.recipe(recipe_id)?.clone();
    let hash = workbench_runner::trust_hash(&recipe, &workspace.repo(&recipe.repo_id)?.path)?;
    workspace
        .recipes
        .iter_mut()
        .find(|r| r.id == recipe_id)
        .expect("validated recipe")
        .trusted_hash = Some(hash.clone());
    let temporary = config.with_extension("json.tmp");
    fs::write(&temporary, serde_json::to_vec_pretty(&workspace)?)?;
    fs::rename(temporary, config)?;
    Ok(hash)
}
