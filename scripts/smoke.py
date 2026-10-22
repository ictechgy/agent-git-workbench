#!/usr/bin/env python3
"""Real CLI + private Unix socket scenario; only creates synthetic temp repos."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
BIN = ROOT / "target/debug/workbench"


def command(*argv, input=None):
    return subprocess.run(list(map(str, argv)), input=input, text=True,
                          capture_output=True, check=True).stdout


def main():
    if not BIN.exists():
        raise SystemExit("Run cargo build --workspace first")
    with tempfile.TemporaryDirectory(prefix="workbench-smoke-", dir="/tmp") as directory:
        parent = Path(directory)
        fixture = parent / "fixture"
        command(BIN, "fixture", fixture)
        config = fixture / "workspace.json"
        for recipe in ["api.set-version@1", "ios-app.set-version@1"]:
            command(BIN, "trust", config, recipe)
        state = parent / "state"
        state.mkdir(mode=0o700)
        socket = state / "service.sock"
        journal = state / "journal.sqlite"
        service = subprocess.Popen([str(BIN), "serve", str(config), str(journal), str(socket)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        def rpc(method, **params):
            response = json.loads(command(BIN, "rpc", socket,
                                          input=json.dumps({"method": method, "params": params})))
            if "error" in response:
                raise AssertionError(response["error"])
            return response["result"]

        def wait(op_id):
            until = time.monotonic() + 20
            while time.monotonic() < until:
                op = rpc("get_operation", op_id=op_id)
                if op["status"] not in {"queued", "running"}:
                    return op
                time.sleep(.03)
            raise AssertionError("operation timeout")

        try:
            until = time.monotonic() + 10
            while not socket.exists():
                assert service.poll() is None, "service exited"
                assert time.monotonic() < until
                time.sleep(.03)
            assert socket.stat().st_mode & 0o777 == 0o600
            workspace = rpc("list_workspaces")[0]
            originals = {r["id"]: rpc("get_repo_status", repo_id=r["id"])
                         for r in workspace["repositories"]}
            plan = rpc("plan_task", group_id="ios-2-4", label="CLI 합성 검증",
                       task_slug="cli-smoke", mode="branch_only")
            op = rpc("execute_plan", plan_id=plan["id"], idempotency_key="cli-one-request")
            op = wait(op["id"])
            assert op["status"] == "waiting_for_worktree", op
            assert all(not Path(r["plan"]["worktree_path"]).exists() for r in op["repos"])
            assert rpc("execute_plan", plan_id=plan["id"], idempotency_key="cli-one-request")["id"] == op["id"]
            (fixture / "api.fail").write_text("synthetic failure")
            rpc("materialize", op_id=op["id"])
            partial = wait(op["id"])
            assert partial["status"] == "partial_failure", partial
            (fixture / "api.fail").unlink()
            rpc("retry_operation", op_id=op["id"])
            ready = wait(op["id"])
            assert ready["status"] == "ready", ready
            results = []
            for r in ready["repos"]:
                repo_id = r["plan"]["repo_id"]
                view = rpc("get_repo_status", repo_id=repo_id, op_id=op["id"])
                diff = rpc("get_diff", repo_id=repo_id, op_id=op["id"], path="Config/Version.xcconfig")
                original = rpc("get_repo_status", repo_id=repo_id)
                assert original["snapshot"] == originals[repo_id]["snapshot"]
                assert view["snapshot"]["head"] == r["plan"]["base_oid"]
                assert view["snapshot"]["branch"] == r["plan"]["branch_ref"]
                assert [f["path"] for f in view["files"]] == ["Config/Version.xcconfig"]
                assert "+CURRENT_PROJECT_VERSION = 241" in diff["text"]
                assert not command("git", "-C", view["path"], "diff", "--cached")
                worktrees = command("git", "-C", original["path"], "worktree", "list", "--porcelain")
                assert worktrees.count("worktree ") == 2
                results.append({"repo_id": repo_id, "state": r["state"], "script_attempts": r["attempts"],
                                "postcondition": r["postcondition"], "original_snapshot_preserved": True,
                                "head_index_status_worktrees_cross_checked": True})
            assert next(r for r in results if r["repo_id"] == "ios-app")["script_attempts"] == 1
            events = rpc("events", cursor=0)
            assert events and not rpc("events", cursor=events[-1]["sequence"])
            print(json.dumps({"scenario": "P0 CLI over Unix socket", "result": "passed",
                              "git": command("git", "--version").strip(),
                              "checks": ["branch_only", "materialize", "partial_failure", "retry",
                                         "idempotency", "dirty_original_preservation", "event_cursor"],
                              "repos": results}, ensure_ascii=False, indent=2))
        finally:
            service.terminate()
            try:
                service.wait(timeout=5)
            except subprocess.TimeoutExpired:
                service.kill()
                service.wait(timeout=5)


if __name__ == "__main__":
    main()
