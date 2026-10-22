#!/usr/bin/env python3
"""Exercise app-owned bootstrap using only new temporary repositories and the packaged helper."""
import hashlib
import json
import os
import shutil
import signal
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def descendants(pid):
    children = subprocess.run(["/usr/bin/pgrep", "-P", str(pid)],
                              capture_output=True, text=True, check=False).stdout.split()
    result = []
    for child in children:
        result.append(int(child))
        result.extend(descendants(int(child)))
    return result


def run(*argv, **kwargs):
    timeout = kwargs.pop("timeout", 30)
    with subprocess.Popen(list(map(str, argv)), stdout=subprocess.PIPE, text=True,
                          start_new_session=True, **kwargs) as process:
        try:
            output, _ = process.communicate(timeout=timeout)
            if process.returncode:
                raise subprocess.CalledProcessError(process.returncode, argv, output)
            return output
        except BaseException:
            # Foundation can put child engines in separate process groups.
            # Enumerate this still-live owned process tree before killing its root.
            owned_children = descendants(process.pid) if process.poll() is None else []
            for child in reversed(owned_children):
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            raise


def snapshot(repo):
    return {
        "head": run("git", "-C", repo, "symbolic-ref", "HEAD"),
        "status": run("git", "--no-optional-locks", "-C", repo, "status", "--porcelain=v1"),
        "files": {str(p.relative_to(repo)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in repo.rglob("*") if p.is_file() and ".git" not in p.relative_to(repo).parts},
        "index": hashlib.sha256((repo / ".git/index").read_bytes()).hexdigest()
                 if (repo / ".git/index").exists() else None,
    }


def main():
    helper = ROOT / "build/macos/River.app/Contents/Helpers/workbench"
    bin_dir = Path(run("swift", "build", "--package-path", ROOT / "apps/macos", "--show-bin-path").strip())
    probe = bin_dir / "workbench-startup-probe"
    # Finder-like launch: no WORKBENCH_SOCKET, WORKBENCH_SERVICE, or developer PATH.
    environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(Path.home()), "LANG": "en_US.UTF-8"}
    with tempfile.TemporaryDirectory(prefix="agw-start-", dir="/tmp") as temporary:
        base = Path(temporary)
        relocated = base / "다른 폴더로 옮긴 앱.app"
        shutil.copytree(helper.parents[2], relocated)
        packaged_probe = relocated / "Contents/MacOS/startup-probe"
        shutil.copy2(probe, packaged_probe)
        fixture = base / "fixture"
        run(helper, "fixture", fixture, env=environment)
        repo = fixture / "ios-app 합성 repo"
        run("git", "-C", repo, "add", "notes.txt")
        empty = base / "empty repository"
        empty.mkdir()
        run("git", "-C", empty, "init", "-b", "main")
        (empty / "README.md").write_text("untracked, before first commit\n")
        reports = []
        for i, selected in enumerate([repo, empty]):
            before = snapshot(selected)
            storage = base / ("긴 앱 데이터 경로 " * 4) / str(i)
            runtime = base / f"s{i}"
            report = json.loads(run(packaged_probe, "--bundled", storage, runtime, selected, env=environment, timeout=45))
            assert snapshot(selected) == before, "Opening modified the selected checkout or index"
            assert report["result"] == "passed" and report["socket_bytes"] < 104
            report["source_head_index_and_files_preserved"] = True
            reports.append(report)
        print(json.dumps({"result": "passed", "packaged_engine": True, "relocated_app_helper_discovery": True,
                          "no_connection_environment": True,
                          "scenarios": reports}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
