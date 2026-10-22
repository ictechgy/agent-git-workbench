#!/usr/bin/env python3
"""Validate the production Swift socket client against a new Rust service and real Git."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(*argv, input=None):
    return subprocess.check_output(list(map(str, argv)), input=input, text=True)


def main():
    binary = ROOT / "target/debug/workbench"
    package = ROOT / "apps/macos"
    bin_dir = Path(run("swift", "build", "--package-path", package, "--show-bin-path").strip())
    probe = bin_dir / "workbench-native-probe"
    assert binary.exists() and probe.exists(), "Build Rust and Swift first"
    with tempfile.TemporaryDirectory(prefix="workbench-native-", dir="/tmp") as directory:
        base = Path(directory)
        fixture = base / "fixture"
        run(binary, "fixture", fixture)
        source = fixture / "ios-app 합성 repo"
        run("git", "-C", source, "stash", "push", "-u", "-m", "Native stash first draft")
        config = source / "Config/Version.xcconfig"
        config.write_text(config.read_text() + "// Native stash review token\n")
        run("git", "-C", source, "stash", "push", "-u", "-m", "Native stash second draft")
        stash_log_before = run("git", "-C", source, "reflog", "show", "refs/stash")
        for recipe in ["api.set-version@1", "ios-app.set-version@1"]:
            run(binary, "trust", fixture / "workspace.json", recipe)
        state = base / "state"
        state.mkdir(mode=0o700)
        socket = state / "service.sock"
        service = subprocess.Popen([str(binary), "serve", str(fixture / "workspace.json"),
                                    str(state / "journal.sqlite"), str(socket)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            until = time.monotonic() + 10
            while not socket.exists():
                assert service.poll() is None and time.monotonic() < until
                time.sleep(.03)
            report = json.loads(run(probe, socket))
            assert report["result"] == "passed"
            assert report["stash_counts"] == {"ios-app": 2, "api": 0}
            assert run("git", "-C", source, "reflog", "show", "refs/stash") == stash_log_before
            for repo_id, path in report["worktrees"].items():
                assert "CURRENT_PROJECT_VERSION = 241" in Path(path, "Config/Version.xcconfig").read_text()
                assert "MARKETING_VERSION = 2.4.0" in Path(path, "Config/Version.xcconfig").read_text()
                head = run("git", "-C", path, "rev-parse", "HEAD").strip()
                if repo_id == "ios-app":
                    assert head == report["committed_head"]
                    assert not run("git", "-C", path, "status", "--porcelain=v1")
                    assert run("git", "-C", path, "log", "-1", "--format=%s").strip() == "Native Swift client commits reviewed version hunk"
                else:
                    assert run("git", "-C", path, "status", "--porcelain=v1").strip() == "M Config/Version.xcconfig"
                    assert not run("git", "-C", path, "diff", "--cached")
            report["independent_git_cross_check"] = True
            print(json.dumps(report, ensure_ascii=False, indent=2))
        finally:
            service.terminate()
            service.wait(timeout=5)


if __name__ == "__main__":
    main()
