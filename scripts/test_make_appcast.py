#!/usr/bin/env python3
"""Release/feed trust-boundary regressions; normal tests never access a Keychain."""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import make_appcast as appcast
from sparkle_support import SPARKLE_VERSION, SPARKLE_REVISION, SPARKLE_ARCHIVE_URL, SPARKLE_CHECKSUM, update_info


SIGNATURE = base64.b64encode(bytes(range(64))).decode("ascii")
CONFIGURATION = {"feed_url": "https://raw.githubusercontent.com/ictechgy/river/updates/appcast.xml",
                 "public_ed_key": base64.b64encode(bytes(range(32))).decode("ascii")}


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="river-appcast-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.version = "0.1.0-alpha.6"
        self.basename = f"River-{self.version}-macos-arm64"
        self.archive = self.directory / (self.basename + ".dmg")
        self.archive.write_bytes(b"Owned test data, not an installable disk image.\n")
        self.digest = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        self.manifest_path = self.directory / (self.basename + ".manifest.json")
        self.sidecar = self.directory / (self.archive.name + ".sha256")
        self.sidecar.write_text(f"{self.digest}  {self.archive.name}\n")
        self.manifest = {
            "schema_version": 1, "product": "River",
            "app": {"version": self.version, "short_version": "0.1.0", "build_number": "7",
                    "configuration": "release", "bundle_identifier": appcast.APP_IDENTIFIER,
                    "executable": appcast.APP_EXECUTABLE, "architecture": "arm64", "architectures": ["arm64"],
                    "minimum_macos": "14.0", "signing": {"kind": "developer-id", "team_identifier": appcast.TEAM_IDENTIFIER},
                    "updates": update_info(CONFIGURATION), "executable_sha256": "a" * 64,
                    "helper_sha256": "b" * 64, "bundle_tree_sha256": "c" * 64,
                    "sparkle": {"version": SPARKLE_VERSION, "revision": SPARKLE_REVISION,
                                "archive_url": SPARKLE_ARCHIVE_URL, "archive_sha256": SPARKLE_CHECKSUM,
                                "package_resolved_sha256": "d" * 64, "source_framework_tree_sha256": "e" * 64,
                                "signed_framework_tree_sha256": "f" * 64}},
            "disk_image": {"filename": self.archive.name, "format": "UDZO", "signing": "developer-id",
                           "mount_copy_verified": True, "sha256": self.digest, "size_bytes": self.archive.stat().st_size},
            "source_provenance": {"kind": "clean-git-build", "tracked_status": "", "tracked_patch_sha256": appcast.EMPTY_SHA256,
                                  "untracked_runtime_files": [], "git_commit": "1" * 40},
            "source_git_commit": "1" * 40, "source_tracked_dirty": False,
        }
        self.write_manifest()
        self.apple = patch.object(appcast, "verify_distribution_image_signature")
        self.apple_mock = self.apple.start()
        self.addCleanup(self.apple.stop)
        self.mount = patch.object(appcast, "verify_dmg", side_effect=lambda _path, app: app)
        self.mount_mock = self.mount.start()
        self.addCleanup(self.mount.stop)

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def release(self):
        return appcast.load_release(self.directory, CONFIGURATION)

    def arguments(self):
        configuration = self.directory / "configuration.json"
        configuration.write_text(json.dumps(CONFIGURATION))
        tools = self.directory / "bin"
        tools.mkdir(exist_ok=True)
        signer = tools / "sign_update"
        signer.write_text("#!/bin/sh\nexit 1\n")
        signer.chmod(0o700)
        return argparse.Namespace(configuration=configuration, keychain_account=appcast.DEFAULT_ACCOUNT,
                                  tools_directory=tools, release_directory=self.directory,
                                  output=self.directory / "feed/appcast.xml", notes_file=None)

    def archive_report(self):
        return {"archive_verified": True, "archive_sha256": self.digest,
                "archive_length": self.archive.stat().st_size}

    def test_valid_release_checks_actual_payload_and_signature(self):
        release = self.release()
        self.assertEqual(release["url"], appcast.DOWNLOAD_PREFIX + f"v{self.version}/{self.archive.name}")
        self.apple_mock.assert_called_once_with(self.archive, appcast.TEAM_IDENTIFIER)
        self.mount_mock.assert_called_once_with(self.archive, self.manifest["app"])

    def test_rejects_untrusted_manifest_metadata(self):
        mutations = [
            (("source_tracked_dirty",), True), (("source_git_commit",), "2" * 40),
            (("source_provenance", "kind"), "provided-app"),
            (("source_provenance", "tracked_status"), " M app.swift"),
            (("source_provenance", "untracked_runtime_files"), ["hidden.swift"]),
            (("app", "signing", "team_identifier"), "OTHERTEAM"),
            (("app", "signing", "kind"), "ad-hoc"), (("app", "architecture"), "x86_64"),
            (("app", "minimum_macos"), "12.0"), (("app", "build_number"), "0"),
            (("app", "build_number"), "2147483648"), (("app", "short_version"), "0.2.0"),
            (("app", "version"), "0.1.0-alpha.01"),
            (("app", "updates", "SUPublicEDKey"), "wrong"),
            (("app", "updates", "SUFeedURL"), "https://attacker.invalid/appcast.xml"),
            (("app", "sparkle", "revision"), "0" * 40),
            (("disk_image", "filename"), "../../outside.dmg"), (("disk_image", "size_bytes"), True),
            (("disk_image", "signing"), "unsigned"), (("disk_image", "mount_copy_verified"), False),
        ]
        original = json.loads(json.dumps(self.manifest))
        for location, value in mutations:
            with self.subTest(location=location, value=value):
                self.manifest = json.loads(json.dumps(original))
                container = self.manifest
                for key in location[:-1]:
                    container = container[key]
                container[location[-1]] = value
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.release()

    def test_archive_tampering_rejected_before_signing_or_mounting(self):
        original = self.archive.read_bytes()
        self.archive.write_bytes(b"X" + original[1:])
        with self.assertRaisesRegex(ValueError, "bytes differ"):
            self.release()
        self.apple_mock.assert_not_called()
        self.mount_mock.assert_not_called()

    def test_checksum_sidecar_must_name_exact_archive(self):
        self.sidecar.write_text(f"{self.digest}  unrelated.dmg\n")
        with self.assertRaisesRegex(ValueError, "sidecar"):
            self.release()

    def test_symlink_archives_and_manifests_rejected(self):
        actual = self.archive.with_suffix(".bytes")
        self.archive.rename(actual)
        self.archive.symlink_to(actual.name)
        with self.assertRaisesRegex(ValueError, "symlink"):
            self.release()
        self.archive.unlink()
        actual.rename(self.archive)
        actual_manifest = self.manifest_path.with_suffix(".bytes")
        self.manifest_path.rename(actual_manifest)
        self.manifest_path.symlink_to(actual_manifest.name)
        with self.assertRaisesRegex(ValueError, "regular file"):
            self.release()

    def test_payload_or_apple_signature_failure_rejected(self):
        self.mount_mock.return_value = None
        self.mount_mock.side_effect = None
        with self.assertRaisesRegex(ValueError, "mounted update payload"):
            self.release()
        self.apple_mock.side_effect = subprocess.CalledProcessError(1, "codesign")
        with self.assertRaises(subprocess.CalledProcessError):
            self.release()

    def test_multiple_manifests_rejected(self):
        (self.directory / "other.manifest.json").write_text("{}")
        with self.assertRaisesRegex(ValueError, "exactly one manifest"):
            self.release()

    def test_plain_notes_are_escaped_and_no_external_notes_are_added(self):
        release = self.release()
        body = appcast.build_feed(release, SIGNATURE, '<script src="https://example.invalid">& plain',
                                  datetime(2026, 10, 24, tzinfo=timezone.utc))
        root = ET.fromstring(body)
        item = root.find("channel/item")
        description = item.find("description")
        self.assertEqual(description.get(f"{{{appcast.SPARKLE}}}format"), "plain-text")
        self.assertEqual(description.text, '<script src="https://example.invalid">& plain')
        self.assertEqual(len(description), 0)
        self.assertNotIn(b"releaseNotesLink", body)
        self.assertNotIn(b"<script", body)
        self.assertEqual(item.find(f"{{{appcast.SPARKLE}}}hardwareRequirements").text, "arm64")

    def test_invalid_notes_or_signatures_are_rejected(self):
        release = self.release()
        for notes in ["", "x" * 32_769, "\x01bad"]:
            with self.subTest(notes_length=len(notes)), self.assertRaises(ValueError):
                appcast.build_feed(release, SIGNATURE, notes)
        for signature in ["bad", " " + SIGNATURE, SIGNATURE + "\n", base64.b64encode(b"short").decode()]:
            with self.subTest(signature=signature), self.assertRaises(ValueError):
                appcast.build_feed(release, signature, "notes")

    def test_signer_failure_does_not_echo_private_diagnostics(self):
        result = subprocess.CompletedProcess(["sign_update"], 1, "private diagnostic", "private diagnostic")
        with patch.object(appcast.subprocess, "run", return_value=result):
            with self.assertRaises(ValueError) as caught:
                appcast.run_signer(Path("sign_update"), appcast.DEFAULT_ACCOUNT, self.archive, archive=True)
        self.assertNotIn("private diagnostic", str(caught.exception))

    def test_signer_requires_a_canonical_signature(self):
        result = subprocess.CompletedProcess(["sign_update"], 0, "not a signature", "")
        with patch.object(appcast.subprocess, "run", return_value=result):
            with self.assertRaises(ValueError):
                appcast.run_signer(Path("sign_update"), appcast.DEFAULT_ACCOUNT, self.archive, archive=True)

    def test_previous_build_cannot_be_replaced_with_same_or_lower_build(self):
        args = self.arguments()
        args.output.parent.mkdir()
        args.output.write_bytes(b"existing signed feed fixture")
        for previous_build in ["7", "8"]:
            with self.subTest(previous_build=previous_build), \
                    patch.object(appcast, "verify_public_key", return_value={"build_number": previous_build}), \
                    patch.object(appcast, "run_signer") as signer:
                with self.assertRaisesRegex(ValueError, "must be greater"):
                    appcast.generate(args)
                signer.assert_not_called()
        self.assertEqual(args.output.read_bytes(), b"existing signed feed fixture")

    def test_feed_signing_failure_preserves_previous_feed_atomically(self):
        args = self.arguments()
        args.output.parent.mkdir()
        args.output.write_bytes(b"existing signed feed fixture")
        reports = [{"build_number": "6"}, self.archive_report()]
        with patch.object(appcast, "verify_public_key", side_effect=reports), \
                patch.object(appcast, "run_signer", side_effect=[SIGNATURE, ValueError("signing failed")]):
            with self.assertRaisesRegex(ValueError, "signing failed"):
                appcast.generate(args)
        self.assertEqual(args.output.read_bytes(), b"existing signed feed fixture")
        self.assertFalse(list(args.output.parent.glob(".river-appcast-*")))

    def test_wrong_key_verification_failure_never_creates_feed(self):
        args = self.arguments()
        with patch.object(appcast, "run_signer", return_value=SIGNATURE), \
                patch.object(appcast, "verify_public_key", side_effect=ValueError("wrong public key")):
            with self.assertRaisesRegex(ValueError, "wrong public key"):
                appcast.generate(args)
        self.assertFalse(args.output.exists())

    def test_archive_changes_after_signature_never_creates_feed(self):
        args = self.arguments()
        wrong = {**self.archive_report(), "archive_sha256": "0" * 64}
        with patch.object(appcast, "run_signer", return_value=SIGNATURE), \
                patch.object(appcast, "verify_public_key", return_value=wrong):
            with self.assertRaisesRegex(ValueError, "changed during signing"):
                appcast.generate(args)
        self.assertFalse(args.output.exists())

    def test_real_cryptokit_roundtrips_wrong_keys_tampering_and_malformed_feeds(self):
        result = subprocess.run(["/usr/bin/xcrun", "swift", str(appcast.ROOT / "scripts/verify_update.swift"), "--self-test"],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("rejected invalid inputs", result.stdout)


if __name__ == "__main__":
    unittest.main()
