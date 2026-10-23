#!/usr/bin/env python3
"""Exercise production remote RPCs and clone boundaries in disposable repositories.

No server writes are performed. --public-url additionally clones/fetches a public
SSH/HTTPS repository using the shipped transport policy.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, default=ROOT / "target/debug/workbench")
    parser.add_argument("--public-url", help="Optional public repository: clone/fetch only")
    args = parser.parse_args()
    binary = args.binary.resolve()
    assert binary.is_file(), "Build the engine first"
    report = {"production_rpc": [], "server_writes": False}
    with tempfile.TemporaryDirectory(prefix="river-remote-", dir="/tmp") as directory:
        base = Path(directory)
        home = base / "home"
        home.mkdir(mode=0o700)
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "LANG": "en_US.UTF-8"}

        def run(*argv, check=True, timeout=360):
            return subprocess.run(list(map(str, argv)), env=env, text=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  check=check, timeout=timeout)

        def git(repo, *argv):
            return run("/usr/bin/git", "-C", repo, "-c", "core.hooksPath=/dev/null", *argv).stdout.strip()

        source = base / "source"
        source.mkdir()
        git(source, "init", "--initial-branch=main", "--template=")
        git(source, "config", "user.name", "River fixture")
        git(source, "config", "user.email", "fixture@example.invalid")
        (source / "README").write_text("Synthetic remote contract fixture\n")
        git(source, "add", "README")
        git(source, "-c", "commit.gpgSign=false", "commit", "-m", "Initial")
        original = (git(source, "rev-parse", "HEAD"), git(source, "status", "--porcelain"))
        config = base / "workspace.json"
        registration = json.loads(run(binary, "workspace", source, config).stdout)
        repo_id = registration["workspace"]["repositories"][0]["id"]
        socket = base / "service.sock"
        service = subprocess.Popen([str(binary), "serve", str(config), str(base / "journal.sqlite"), str(socket)],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            until = time.monotonic() + 10
            while not socket.exists():
                assert service.poll() is None and time.monotonic() < until, "Service startup failed"
                time.sleep(.03)

            def rpc(method, **params):
                request = {"method": method, "params": {"repo_id": repo_id, **params}}
                response = subprocess.run([str(binary), "rpc", str(socket)], input=json.dumps(request),
                                          env=env, text=True, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, timeout=360)
                # Never print URLs, credentials or untrusted diagnostics on failure.
                assert response.stdout, f"No RPC response for {method}"
                return json.loads(response.stdout)

            def state():
                response = rpc("get_remote_state")
                assert response.get("error") is None, response.get("error", {}).get("code")
                return response["result"]

            def expect_ok(response):
                assert response.get("error") is None, response.get("error", {}).get("code")
                return response["result"]

            def expect_error(response):
                assert response.get("error"), "Expected explicit rejection"
                return response["error"]["code"]

            initial = state()
            assert initial["remotes"] == []
            expect_ok(rpc("configure_remote", expected_state_hash=initial["state_hash"], action="add",
                          name="gitlab", url="https://gitlab.com/example/project.git"))
            configured = state()
            assert configured["remotes"][0]["name"] == "gitlab"
            assert configured["state_hash"] != initial["state_hash"]
            assert git(source, "config", "--get", "remote.gitlab.url") == "https://gitlab.com/example/project.git"
            report["production_rpc"].append("provider-neutral remote add/read")

            expect_error(rpc("configure_remote", expected_state_hash=initial["state_hash"], action="remove", name="gitlab"))
            assert state()["remotes"][0]["name"] == "gitlab"
            report["production_rpc"].append("stale configuration rejected without mutation")

            git(source, "config", "remote.gitlab.url", "https://gitlab.com/example/changed.git")
            expect_error(rpc("fetch_remote", expected_state_hash=configured["state_hash"], remote="gitlab"))
            report["production_rpc"].append("endpoint drift rejected before fetch")

            for url in [str(source), "file://" + str(source), "https://user:synthetic-secret@example.invalid/repo.git"]:
                before = state()
                response = rpc("configure_remote", expected_state_hash=before["state_hash"],
                               action="add", name="unsafe", url=url)
                expect_error(response)
                assert "synthetic-secret" not in json.dumps(response)
                assert len(state()["remotes"]) == 1
            report["production_rpc"].append("unsafe/local/credential URLs rejected and redacted")

            expect_error(rpc("fetch_remote", expected_state_hash=state()["state_hash"], remote="gitlab", unexpected=True))
            report["production_rpc"].append("unknown parameters rejected")
            expect_ok(rpc("configure_remote", expected_state_hash=state()["state_hash"], action="remove", name="gitlab"))
            assert state()["remotes"] == []
            assert original == (git(source, "rev-parse", "HEAD"), git(source, "status", "--porcelain"))
            report["production_rpc"].append("remove preserves HEAD and files")
        finally:
            service.terminate()
            service.wait(timeout=10)

        destination = base / "existing"
        destination.mkdir()
        sentinel = destination / "preserve"
        sentinel.write_text("Do not replace\n")
        rejected = run(binary, "clone", str(source), destination, check=False)
        assert rejected.returncode != 0 and sentinel.read_text() == "Do not replace\n"
        assert not list(base.glob(".river-clone-*"))
        report["production_rpc"].append("production clone rejects local transport and preserves destination")

        if args.public_url:
            checkout = base / "public-checkout"
            cloned = json.loads(run(binary, "clone", args.public_url, checkout).stdout)
            assert Path(cloned["path"]).resolve() == checkout.resolve()
            assert (checkout / ".git").is_dir()
            assert git(checkout, "status", "--porcelain") == ""
            report["public_read_only"] = {"clone": "passed", "clean_checkout": True}
            # Fetch through the production service, not an unrestricted Git shell.
            public_config = base / "public-workspace.json"
            info = json.loads(run(binary, "workspace", checkout, public_config).stdout)
            public_id = info["workspace"]["repositories"][0]["id"]
            public_socket = base / "public.sock"
            public_service = subprocess.Popen([str(binary), "serve", str(public_config), str(base / "public.sqlite"), str(public_socket)],
                                              env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            try:
                until = time.monotonic() + 10
                while not public_socket.exists():
                    assert public_service.poll() is None and time.monotonic() < until
                    time.sleep(.03)
                repo_id, socket = public_id, public_socket
                remote_state = state()
                assert remote_state["remotes"][0]["supported"]
                expect_ok(rpc("fetch_remote", expected_state_hash=remote_state["state_hash"], remote="origin"))
                assert git(checkout, "status", "--porcelain") == ""
                report["public_read_only"]["fetch"] = "passed"
            finally:
                public_service.terminate()
                public_service.wait(timeout=10)

    print(json.dumps({"result": "passed", **report}, indent=2))


if __name__ == "__main__":
    main()
