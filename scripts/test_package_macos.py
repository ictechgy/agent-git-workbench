#!/usr/bin/env python3
"""Focused tests for release identity, architecture, and fail-closed notarization."""
import json
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import build_macos
import package_macos


class PackagingTests(unittest.TestCase):
    def package_args(self, output, app=Path("provided.app")):
        return SimpleNamespace(version="0.1.0-alpha.1", build_number="2", output_dir=output,
                               app=app, sign_identity=None, notary_profile=None)

    def test_prerelease_has_separate_numeric_apple_version(self):
        self.assertEqual(build_macos.version_metadata("0.1.0-alpha.1", "2"), {
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "2",
            "RiverReleaseVersion": "0.1.0-alpha.1"})
        for invalid in ["v0.1.0", "../0.1.0", "0.1.0-alpha.01", "01.1.0", "0.1"]:
            with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                build_macos.version_metadata(invalid, "2")
        with self.assertRaises(ValueError):
            build_macos.version_metadata("0.1.0", "0")

    def test_developer_signs_helper_then_bundle_with_runtime_and_timestamp(self):
        details = {"Authority": ["Developer ID Application: Test"], "Timestamp": ["today"],
                   "CodeDirectory v": ["20500 flags=0x10000(runtime)"]}
        with patch.object(build_macos.subprocess, "run") as run, \
                patch.object(build_macos, "signature_details", return_value=details):
            build_macos.sign_bundle(Path("River.app"), "identity")
        signed = [call.args[0] for call in run.call_args_list if "--sign" in call.args[0]]
        self.assertEqual([command[-1] for command in signed],
                         ["River.app/Contents/Helpers/workbench", "River.app"])
        for command in signed:
            self.assertIn("--timestamp", command)
            self.assertEqual(command[command.index("--options") + 1], "runtime")

    def test_signing_failure_propagates_without_signing_outer_bundle(self):
        with patch.object(build_macos.subprocess, "run", side_effect=
                          subprocess.CalledProcessError(1, ["codesign"])) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                build_macos.sign_bundle(Path("River.app"), "identity")
        self.assertEqual(run.call_count, 1)

    def test_same_team_image_signature_still_requires_developer_id_and_timestamp(self):
        cases = [({"Authority": ["Apple Development: Test"], "TeamIdentifier": ["TEAM"],
                   "Timestamp": ["today"]}, "Developer ID Application"),
                 ({"Authority": ["Developer ID Application: Test"], "TeamIdentifier": ["TEAM"]},
                  "secure timestamp")]
        for details, message in cases:
            with self.subTest(message=message), patch.object(package_macos, "run"), \
                    patch.object(package_macos, "signature_details", return_value=details):
                with self.assertRaisesRegex(ValueError, message):
                    package_macos.verify_distribution_image_signature(Path("River.dmg"), "TEAM")

    def test_bundle_requires_matching_binary_architectures_and_release_metadata(self):
        with tempfile.TemporaryDirectory() as temporary:
            bundle = Path(temporary) / "River.app"
            (bundle / "Contents").mkdir(parents=True)
            info = {"CFBundleIdentifier": build_macos.APP_IDENTIFIER,
                    "CFBundleExecutable": build_macos.APP_EXECUTABLE,
                    "RiverBuildConfiguration": "release",
                    **build_macos.version_metadata("0.1.0-alpha.1", "2")}
            with (bundle / "Contents/Info.plist").open("wb") as target:
                plistlib.dump(info, target)
            with patch.object(package_macos, "architectures", side_effect=[{"arm64"}, {"x86_64"}]), \
                    patch.object(package_macos, "verify_signature") as verify:
                with self.assertRaisesRegex(ValueError, "architectures differ"):
                    package_macos.bundle_metadata(bundle)
                verify.assert_not_called()
            info["RiverBuildConfiguration"] = "debug"
            with (bundle / "Contents/Info.plist").open("wb") as target:
                plistlib.dump(info, target)
            with self.assertRaisesRegex(ValueError, "release bundle"):
                package_macos.bundle_metadata(bundle)

    def test_notarization_rejection_even_with_success_exit_does_not_staple(self):
        result = subprocess.CompletedProcess([], 0, json.dumps({"status": "Invalid", "id": "id"}), "")
        with patch.object(package_macos.subprocess, "run", return_value=result) as run:
            with self.assertRaisesRegex(ValueError, "not accepted"):
                package_macos.notarize(Path("River.dmg"), "profile")
        self.assertEqual(run.call_count, 1)

    def test_notarization_credentials_error_is_not_echoed(self):
        result = subprocess.CompletedProcess([], 1, "", "sensitive credential error")
        with patch.object(package_macos.subprocess, "run", return_value=result):
            with self.assertRaises(ValueError) as failure:
                package_macos.notarize(Path("River.dmg"), "profile")
        self.assertNotIn("sensitive", str(failure.exception))

    def test_stapling_failure_does_not_report_notarization_success(self):
        accepted = subprocess.CompletedProcess([], 0, json.dumps({"status": "Accepted", "id": "id"}), "")
        failed = subprocess.CompletedProcess([], 1, "", "")
        with patch.object(package_macos.subprocess, "run", side_effect=[accepted, failed]) as run:
            with self.assertRaisesRegex(ValueError, "staple failed"):
                package_macos.notarize(Path("River.dmg"), "profile")
        self.assertEqual(run.call_count, 2)

    def test_competing_cli_fails_without_touching_outputs_and_lock_file_persists(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            existing = output / "River-0.1.0-alpha.1-macos-arm64.dmg"
            existing.write_bytes(b"existing release")
            with package_macos.output_lock(output):
                result = subprocess.run([sys.executable, str(Path(package_macos.__file__).resolve()),
                                         "--version", "0.1.0-alpha.1", "--build-number", "2",
                                         "--app", "/nonexistent/River.app", "--output-dir", str(output)],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("another packager", result.stderr)
                self.assertEqual(existing.read_bytes(), b"existing release")
                self.assertFalse(list(output.glob(".river-release-*")))
            self.assertTrue((output / ".river-package.lock").is_file())
            with package_macos.output_lock(output):
                self.assertEqual(existing.read_bytes(), b"existing release")

    def test_packaging_requires_an_explicit_release_identity(self):
        for identity in [[], ["--version", "0.1.0-alpha.3"], ["--build-number", "4"]]:
            with self.subTest(identity=identity):
                result = subprocess.run([sys.executable, str(Path(package_macos.__file__).resolve()),
                                         *identity, "--app", "/nonexistent/River.app"],
                                        capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("--version and --build-number are required", result.stderr)
        with patch.object(sys, "argv", ["package_macos.py", "--verify-dmg", "existing.dmg"]), \
                patch.object(package_macos, "verify_dmg", return_value={}) as verify, \
                patch("builtins.print"):
            package_macos.main()
        verify.assert_called_once()

    def test_cargo_reported_executable_is_bundled_with_target_directory_overrides(self):
        # Exercise Cargo itself: its executable moves with both env and config,
        # while an obsolete binary remains at the previously hard-coded path.
        for override in ["environment", "config", "target"]:
            with self.subTest(override=override), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "src").mkdir()
                (root / "src/main.rs").write_text('fn main() { println!("current engine"); }\n')
                (root / "Cargo.toml").write_text(
                    '[package]\nname="workbench-cli"\nversion="0.1.0"\nedition="2024"\n'
                    '[[bin]]\nname="workbench"\npath="src/main.rs"\n')
                stale = root / "target/debug/workbench"
                stale.parent.mkdir(parents=True)
                stale.write_bytes(b"obsolete engine must not be packaged")
                environment = {key: value for key, value in os.environ.items()
                               if not key.startswith("CARGO_")}
                if override == "environment":
                    environment["CARGO_TARGET_DIR"] = str(root / "other-target")
                elif override == "config":
                    (root / ".cargo").mkdir()
                    (root / ".cargo/config.toml").write_text('[build]\ntarget-dir="other-target"\n')
                else:
                    host = subprocess.check_output(["rustc", "-vV"], text=True)
                    environment["CARGO_BUILD_TARGET"] = next(
                        line.split(": ", 1)[1] for line in host.splitlines() if line.startswith("host: "))
                swift = root / "swift"
                swift.mkdir()
                (swift / build_macos.APP_EXECUTABLE).write_bytes(b"swift app")
                package = root / "package"
                (package / "Resources").mkdir(parents=True)
                (package / "Resources/AppIcon.icns").write_bytes(b"icon")
                with patch.object(build_macos, "ROOT", root), patch.dict(os.environ, environment, clear=True):
                    engine = build_macos.build_engine("debug")
                    bundle = root / "River.app"
                    with patch.object(build_macos, "sign_bundle"):
                        build_macos.assemble_bundle(bundle, swift, engine, package, "debug", {}, "-")
                bundled = bundle / "Contents/Helpers/workbench"
                self.assertNotEqual(engine, stale)
                self.assertEqual(bundled.read_bytes(), engine.read_bytes())
                self.assertEqual(subprocess.check_output([bundled], text=True), "current engine\n")

    def test_provenance_ignores_foreign_git_environment_and_rejects_untracked_cargo_config(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "actual"
            foreign = Path(temporary) / "foreign"
            for repository in [root, foreign]:
                repository.mkdir()
                subprocess.run(["git", "init", "-q", repository], check=True)
                (repository / "source").write_text("original\n")
                subprocess.run(["git", "-C", repository, "add", "."], check=True)
                subprocess.run(["git", "-C", repository, "-c", "user.name=Packaging Test",
                                "-c", "user.email=packaging@example.invalid", "-c", "commit.gpgsign=false",
                                "-c", "core.hooksPath=/dev/null", "commit", "-qm", repository.name], check=True)
            initial = package_macos.clean_source_snapshot(root)
            with patch.dict(os.environ, {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                                         "GIT_INDEX_FILE": str(foreign / ".git/index")}):
                self.assertEqual(package_macos.clean_source_snapshot(root), initial)
                (root / "source").write_text("dirty actual source\n")
                with self.assertRaisesRegex(ValueError, "clean tracked source"):
                    package_macos.clean_source_snapshot(root)
            (root / "source").write_text("original\n")
            (root / ".git/info/exclude").write_text(".cargo/\n")
            (root / ".cargo").mkdir()
            (root / ".cargo/config.toml").write_text('[build]\nrustflags=["--cfg", "untracked"]\n')
            with self.assertRaisesRegex(ValueError, "untracked build inputs"):
                package_macos.clean_source_snapshot(root)

    def test_existing_artifact_set_cannot_be_overwritten(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            names = ["River-0.1.0-alpha.1-macos-arm64" + suffix
                     for suffix in [".dmg", ".dmg.sha256", ".manifest.json"]]
            for name in names:
                (output / name).write_bytes(name.encode())
            metadata = {"architecture": "arm64", "signing": {"kind": "ad-hoc"}}
            with patch.object(package_macos, "run"), \
                    patch.object(package_macos, "bundle_metadata", return_value=metadata):
                with self.assertRaisesRegex(ValueError, "already exist"):
                    package_macos.package(self.package_args(output))
            for name in names:
                self.assertEqual((output / name).read_bytes(), name.encode())

    def test_clean_provenance_ignores_archive_but_rejects_runtime_and_tracked_drift(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "crates/cli/src/main.rs"
            source.parent.mkdir(parents=True)
            source.write_text("fn main() {}\n")
            (root / ".gitignore").write_text("*.swift\n")

            def git(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True)

            git("init", "-q")
            git("config", "user.name", "Packaging Test")
            git("config", "user.email", "packaging@example.invalid")
            git("add", ".")
            git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit", "-qm", "fixture")
            initial = package_macos.clean_source_snapshot(root)
            self.assertEqual(initial["tracked_patch_sha256"], hashlib.sha256(b"").hexdigest())
            (root / "archive").mkdir()
            (root / "archive/historical.txt").write_text("untracked history\n")
            self.assertEqual(package_macos.clean_source_snapshot(root), initial)
            ignored_source = root / "apps/macos/Sources/Ignored.swift"
            ignored_source.parent.mkdir(parents=True)
            ignored_source.write_text("// ignored but buildable\n")
            with self.assertRaisesRegex(ValueError, "untracked build inputs"):
                package_macos.clean_source_snapshot(root)
            ignored_source.unlink()
            source.write_text("fn main() { println!(\"changed\"); }\n")
            changed = package_macos.source_snapshot(root)
            self.assertNotEqual(changed["tracked_patch_sha256"], initial["tracked_patch_sha256"])
            with self.assertRaisesRegex(ValueError, "clean tracked source"):
                package_macos.clean_source_snapshot(root)
            with self.assertRaisesRegex(ValueError, "source changed"):
                package_macos.verify_source_unchanged(initial, root)
            source.write_text("fn main() {}\n")
            git("-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "commit",
                "--allow-empty", "-qm", "HEAD drift")
            with self.assertRaisesRegex(ValueError, "source changed"):
                package_macos.verify_source_unchanged(initial, root)

    def test_source_drift_after_build_publishes_no_artifacts(self):
        initial = {"kind": "clean-git-build", "git_commit": "initial", "tracked_status": "",
                   "tracked_patch_sha256": hashlib.sha256(b"").hexdigest(), "untracked_runtime_files": []}
        changed = {**initial, "git_commit": "changed"}
        metadata = {"architecture": "arm64", "signing": {"kind": "ad-hoc"}}
        readmes = []

        def fake_run(*argv, **kwargs):
            if argv[:2] == ("/usr/bin/hdiutil", "create"):
                readmes.append((Path(argv[-1]).parent / "payload/READ ME - INSTALL.txt").read_text())
                Path(argv[-1]).write_bytes(b"verified image for publication regression")

        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with patch.object(package_macos, "run", side_effect=fake_run), \
                    patch.object(package_macos, "bundle_metadata", return_value=metadata), \
                    patch.object(package_macos, "verify_dmg", return_value=metadata), \
                    patch.object(package_macos, "source_snapshot", side_effect=[initial, changed]):
                with self.assertRaisesRegex(ValueError, "source changed"):
                    package_macos.package(self.package_args(output, app=None))
            self.assertEqual([path.name for path in output.iterdir()], [".river-package.lock"])
        for required in ["/usr/bin/git --version", "xcode-select --install", "python3",
                         "Remote operations require Apple Git 2.41 or later",
                         "원격 작업에는 Apple Git 2.41 이상이 필요합니다",
                         "Full Xcode is not required", "전체 Xcode는 필요하지 않습니다",
                         "System Settings > Privacy & Security > Open Anyway",
                         "시스템 설정 > 개인정보 보호 및 보안 > 확인 없이 열기",
                         "https://support.apple.com/en-us/102445"]:
            self.assertIn(required, readmes[0])


if __name__ == "__main__":
    unittest.main()
