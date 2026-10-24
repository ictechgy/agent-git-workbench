#!/usr/bin/env python3
"""Run Sparkle's read-only informational feed check against an isolated app copy.

This never launches River, downloads an update archive, installs an update, or
changes River's preferences. A signed appcast must pass Sparkle's own verifier.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import uuid

from build_macos import sign_bundle
from package_macos import bundle_metadata
from sparkle_support import FEED_URL, sha256_file, tree_digest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="release app; read only")
    parser.add_argument("--probe", type=Path, required=True, help="built workbench-update-probe executable")
    parser.add_argument("--output", type=Path, required=True, help="JSON evidence output")
    parser.add_argument("--older-host", action="store_true", help="set only the owned fixture's build to 1")
    parser.add_argument("--expect", choices=["available", "up_to_date", "any"], default="any")
    args = parser.parse_args()
    source = args.app.expanduser().resolve(strict=True)
    probe = args.probe.expanduser().resolve(strict=True)
    output = args.output.expanduser().absolute()
    if source.suffix != ".app" or probe.name != "workbench-update-probe" or not probe.is_file():
        parser.error("use a release .app and the dedicated workbench-update-probe executable")
    if output.resolve().is_relative_to(source) or probe.is_relative_to(source):
        parser.error("probe and evidence must be outside the original app")
    metadata = bundle_metadata(source)
    if metadata["updates"]["SUFeedURL"] != FEED_URL:
        parser.error("app must use the production signed River appcast")
    before = tree_digest(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    record = {"schema_version": 1, "kind": "real-sparkle-informational-check",
              "original_app": str(source), "original_app_tree_sha256": before,
              "probe_sha256": sha256_file(probe), "feed_url": FEED_URL,
              "public_key": metadata["updates"]["SUPublicEDKey"],
              "older_host_fixture": args.older_host, "original_build": metadata["build_number"],
              "download_install_relaunch_tested": False}
    exit_code = 1
    try:
        with tempfile.TemporaryDirectory(prefix="river-update-smoke-", dir="/tmp") as temporary:
            directory = Path(temporary)
            fixture = directory / "River.app"
            subprocess.run(["/usr/bin/ditto", str(source), str(fixture)], check=True)
            info_path = fixture / "Contents/Info.plist"
            info = plistlib.loads(info_path.read_bytes())
            domain = "dev.workbench.update-probe." + str(uuid.uuid4())
            # These two fixture-only changes isolate preferences and scheduling;
            # the production feed, public key and signature policy stay exact.
            info["SUDefaultsDomain"] = domain
            info["SUEnableAutomaticChecks"] = False
            if args.older_host:
                info["CFBundleVersion"] = "1"
            info_path.write_bytes(plistlib.dumps(info))
            sign_bundle(fixture, "-")
            home = directory / "preferences"
            home.mkdir(mode=0o700)
            environment = dict(os.environ)
            environment["CFFIXED_USER_HOME"] = str(home)
            environment["DYLD_FRAMEWORK_PATH"] = str(fixture / "Contents/Frameworks")
            result = subprocess.run([str(probe), "--app", str(fixture)], env=environment,
                                    capture_output=True, text=True, timeout=105)
            output.with_suffix(".stdout.log").write_text(result.stdout)
            output.with_suffix(".stderr.log").write_text(result.stderr)
            record["probe_exit_code"] = result.returncode
            record["isolated_preference_domain"] = domain
            record["fixture_tree_sha256"] = tree_digest(fixture)
            parsed = json.loads(result.stdout)
            record["sparkle_result"] = parsed
            expected = (args.expect == "any" or
                        (args.expect == "available" and parsed.get("status") == "update_available") or
                        (args.expect == "up_to_date" and parsed.get("status") == "no_update"
                         and parsed.get("no_update_reason") == 1))
            exit_code = 0 if result.returncode == 0 and parsed.get("accepted") is True and expected else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        record["error"] = str(error)
    finally:
        record["original_app_unchanged"] = tree_digest(source) == before
        if not record["original_app_unchanged"]:
            exit_code = 1
        record["passed"] = exit_code == 0
        output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
