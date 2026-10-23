#!/usr/bin/env python3
"""Focused tests for release identity, architecture, and fail-closed notarization."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_macos
import package_macos


class PackagingTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
