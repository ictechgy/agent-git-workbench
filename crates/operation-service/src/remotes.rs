use super::*;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Target {
    repo_id: String,
    op_id: Option<String>,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "snake_case")]
enum ConfigureAction {
    Add,
    Update,
    Remove,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_post_write_refresh_failure_does_not_relabel_the_completed_mutation() {
        let temp = tempfile::TempDir::new().unwrap();
        let home = temp.path().join("workspace");
        let workspace = fixtures::create(&home).unwrap();
        let path = workspace.repo("ios-app").unwrap().path.clone();
        let service = Service::open(workspace, &home.join("journal.sqlite")).unwrap();
        let state = git::remotes::state(&path).unwrap();
        let result = service
            .remote_mutation(
                "ios-app",
                None,
                &state.state_hash,
                "Mutation completed.",
                |path| {
                    // Simulate the repository becoming unavailable after a
                    // successful write, before presentation data can be refreshed.
                    fs::rename(path.join(".git"), path.join("saved-git-metadata"))?;
                    Ok(())
                },
            )
            .unwrap();
        assert_eq!(result["refresh_required"], true);
        assert_eq!(result["state"], Value::Null);
        assert_eq!(result["message"], "Mutation completed.");
    }
}
impl ConfigureAction {
    fn as_str(&self) -> &'static str {
        match self {
            Self::Add => "add",
            Self::Update => "update",
            Self::Remove => "remove",
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Configure {
    repo_id: String,
    op_id: Option<String>,
    expected_state_hash: String,
    action: ConfigureAction,
    name: String,
    url: Option<String>,
    push_url: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Fetch {
    repo_id: String,
    op_id: Option<String>,
    expected_state_hash: String,
    remote: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Transfer {
    repo_id: String,
    op_id: Option<String>,
    expected_state_hash: String,
    remote: String,
    branch: String,
}

fn decode<T: serde::de::DeserializeOwned>(params: Value) -> Result<T> {
    serde_json::from_value(params)
        .map_err(|_| anyhow::anyhow!("invalid_parameter: invalid remote request"))
}

fn bounded(value: &str, maximum: usize) -> Result<()> {
    ensure!(
        !value.trim().is_empty() && value.len() <= maximum && !value.chars().any(char::is_control),
        "invalid_parameter: invalid remote request value"
    );
    Ok(())
}

fn target_parameters(repo_id: &str, op_id: Option<&str>) -> Result<()> {
    bounded(repo_id, 256)?;
    if let Some(op_id) = op_id {
        bounded(op_id, 128)?;
    }
    Ok(())
}

fn expected_hash(hash: &str) -> Result<()> {
    ensure!(
        hash.len() == 64 && hash.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "invalid_parameter: expected_state_hash must be a SHA-256 digest"
    );
    Ok(())
}

impl Service {
    pub(super) fn handle_remotes(&self, method: &str, params: Value) -> Result<Value> {
        match method {
            "get_remote_state" => {
                let p: Target = decode(params)?;
                target_parameters(&p.repo_id, p.op_id.as_deref())?;
                let path = self.target(&p.repo_id, p.op_id.as_deref())?;
                Ok(serde_json::to_value(git::remotes::state(&path)?)?)
            }
            "configure_remote" => {
                let p: Configure = decode(params)?;
                target_parameters(&p.repo_id, p.op_id.as_deref())?;
                expected_hash(&p.expected_state_hash)?;
                bounded(&p.name, 200)?;
                match p.action {
                    ConfigureAction::Add | ConfigureAction::Update => {
                        bounded(
                            p.url
                                .as_deref()
                                .context("invalid_parameter: remote URL required")?,
                            8192,
                        )?;
                        if let Some(url) = &p.push_url {
                            bounded(url, 8192)?;
                        }
                    }
                    ConfigureAction::Remove => ensure!(
                        p.url.is_none() && p.push_url.is_none(),
                        "invalid_parameter: remove does not accept URLs"
                    ),
                }
                self.remote_mutation(
                    &p.repo_id,
                    p.op_id.as_deref(),
                    &p.expected_state_hash,
                    "Remote configuration saved.",
                    |path| {
                        git::remotes::configure(
                            path,
                            &p.expected_state_hash,
                            p.action.as_str(),
                            &p.name,
                            p.url.as_deref(),
                            p.push_url.as_deref(),
                        )
                    },
                )
            }
            "fetch_remote" => {
                let p: Fetch = decode(params)?;
                target_parameters(&p.repo_id, p.op_id.as_deref())?;
                expected_hash(&p.expected_state_hash)?;
                bounded(&p.remote, 200)?;
                self.remote_mutation(
                    &p.repo_id,
                    p.op_id.as_deref(),
                    &p.expected_state_hash,
                    "Remote branches fetched.",
                    |path| git::remotes::fetch(path, &p.expected_state_hash, &p.remote),
                )
            }
            "pull_remote" | "push_remote" => {
                let p: Transfer = decode(params)?;
                target_parameters(&p.repo_id, p.op_id.as_deref())?;
                expected_hash(&p.expected_state_hash)?;
                bounded(&p.remote, 200)?;
                bounded(&p.branch, 1024)?;
                let message = if method == "pull_remote" {
                    "Branch updated with a fast-forward pull."
                } else {
                    "Branch pushed."
                };
                self.remote_mutation(
                    &p.repo_id,
                    p.op_id.as_deref(),
                    &p.expected_state_hash,
                    message,
                    |path| {
                        if method == "pull_remote" {
                            git::remotes::pull(path, &p.expected_state_hash, &p.remote, &p.branch)
                        } else {
                            git::remotes::push(path, &p.expected_state_hash, &p.remote, &p.branch)
                        }
                    },
                )
            }
            _ => bail!("unknown_method"),
        }
    }

    fn remote_mutation(
        &self,
        repo_id: &str,
        op_id: Option<&str>,
        expected_state: &str,
        message: &str,
        mutate: impl FnOnce(&Path) -> Result<()>,
    ) -> Result<Value> {
        let _guard = self
            .mutations
            .try_lock()
            .map_err(|_| anyhow::anyhow!("repository_busy"))?;
        ensure!(!self.is_stopping(), "service_stopping");
        if let Some(op_id) = op_id {
            let op = self.operation_summary(op_id)?;
            let repo = op
                .repos
                .iter()
                .find(|repo| repo.plan.repo_id == repo_id)
                .context("unknown_task_repo")?;
            ensure!(repo.state == RepoState::Ready, "task_not_ready");
        }
        let path = self.target(repo_id, op_id)?;
        let _lock = repo_lock(&path)?;
        let path = self.target(repo_id, op_id)?;
        ensure!(
            git::remotes::state(&path)?.state_hash == expected_state,
            "stale_remote_state"
        );
        mutate(&path)?;
        // A completed remote write must remain successful when its optional
        // presentation refresh fails. The caller can reload without replaying.
        let state = git::fresh_deadline(std::time::Duration::from_secs(15), || {
            git::remotes::state(&path)
        })
        .ok();
        Ok(serde_json::to_value(RemoteMutationResult {
            refresh_required: state.is_none(),
            state,
            message: message.into(),
        })?)
    }
}
