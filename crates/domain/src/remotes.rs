use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoteBranch {
    pub name: String,
    pub oid: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoteInfo {
    pub name: String,
    /// Display-safe URLs; credentials and control characters must never be returned.
    pub fetch_url: String,
    pub push_url: String,
    pub supported: bool,
    pub problem: Option<String>,
    pub branches: Vec<RemoteBranch>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoteState {
    pub state_hash: String,
    pub repository_path: String,
    /// Full local branch reference, or None for detached/unborn state.
    pub branch: Option<String>,
    pub head: Option<String>,
    pub clean: bool,
    pub remotes: Vec<RemoteInfo>,
    pub upstream_remote: Option<String>,
    /// Short remote branch name, without refs/heads/.
    pub upstream_branch: Option<String>,
    pub ahead: Option<u64>,
    pub behind: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct RemoteMutationResult {
    pub state: Option<RemoteState>,
    pub refresh_required: bool,
    pub message: String,
}
