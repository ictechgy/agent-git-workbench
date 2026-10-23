#!/usr/bin/env python3
"""Launch a new synthetic workspace, Rust service, and native SwiftUI macOS app."""
import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", action="store_true", help="compatibility flag; the app is always native")
    parser.parse_args()
    binary = ROOT / "target/debug/workbench"
    if not binary.exists():
        raise SystemExit("Run cargo build --workspace first")
    package = ROOT / "apps/macos"
    subprocess.run(["swift", "build", "--package-path", str(package), "--product", "AgentGitWorkbench"], check=True)
    bin_dir = Path(subprocess.check_output(["swift", "build", "--package-path", str(package), "--show-bin-path"], text=True).strip())
    base = Path(tempfile.mkdtemp(prefix="workbench-demo-", dir="/tmp"))
    fixture = base / "fixture"
    state = base / "state"
    state.mkdir(mode=0o700)
    subprocess.run([str(binary), "fixture", str(fixture)], check=True, stdout=subprocess.DEVNULL)
    for recipe in ["api.set-version@1", "ios-app.set-version@1"]:
        subprocess.run([str(binary), "trust", str(fixture / "workspace.json"), recipe],
                       check=True, stdout=subprocess.DEVNULL)
    socket = state / "service.sock"
    service = subprocess.Popen([str(binary), "serve", str(fixture / "workspace.json"),
                                str(state / "journal.sqlite"), str(socket)], start_new_session=True)
    ui = None
    try:
        until = time.monotonic() + 10
        while not socket.exists():
            assert service.poll() is None, "service exited"
            assert time.monotonic() < until, "service startup timeout"
            time.sleep(.05)
        print(json.dumps({"fixture": str(fixture), "socket": str(socket),
                          "app": str(bin_dir / "AgentGitWorkbench"),
                          "note": "Native SwiftUI/AppKit app. Generated fixture recipes are trusted for this demo. Ctrl-C stops processes; files are preserved."},
                         ensure_ascii=False, indent=2), flush=True)
        command = [str(bin_dir / "AgentGitWorkbench")]
        ui = subprocess.Popen(command,
                              env={**os.environ, "WORKBENCH_SOCKET": str(socket)}, start_new_session=True)
        ui.wait()
    except KeyboardInterrupt:
        pass
    finally:
        for process in [ui, service]:
            if process is not None and process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=5)
        print(f"Synthetic demo files preserved at {base}", flush=True)


if __name__ == "__main__":
    main()
