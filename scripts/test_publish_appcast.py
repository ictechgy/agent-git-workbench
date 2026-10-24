#!/usr/bin/env python3
"""Publisher preflight and non-forced Git Data boundary tests; no network/auth."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import publish_appcast as publisher
from make_appcast import EMPTY_SHA256, SPARKLE_VERSION, SPARKLE_REVISION, SPARKLE_ARCHIVE_URL, SPARKLE_CHECKSUM
from sparkle_support import FEED_URL, update_info

CONFIG = {"feed_url": FEED_URL, "public_ed_key": base64.b64encode(bytes(range(32))).decode("ascii")}
SOURCE = "1" * 40
OLD_COMMIT, OLD_TREE, NEW_COMMIT, NEW_TREE, TAG_OBJECT = [letter * 40 for letter in "23456"]


class FakeGitHub:
    def __init__(self, release, feed=None):
        self.release = release
        self.feed = feed
        self.calls = []
        self.current_commit = OLD_COMMIT if feed is not None else None
        self.race = False
        self.tag_source = SOURCE
        self.changed_release = False
        self.release_reads = 0

    def request(self, method, resource, body=None, *, missing=False):
        self.calls.append((method, resource, body))
        if method == "GET" and resource.startswith("releases/tags/"):
            self.release_reads += 1
            result = json.loads(json.dumps(self.release))
            if self.changed_release and self.release_reads > 1:
                result["assets"][0]["id"] += 100
            return result
        if method == "GET" and resource.startswith("git/ref/tags/"):
            return {"ref": "refs/tags/" + self.release["tag_name"], "object": {"type": "tag", "sha": TAG_OBJECT}}
        if method == "GET" and resource == "git/tags/" + TAG_OBJECT:
            return {"sha": TAG_OBJECT, "object": {"type": "commit", "sha": self.tag_source}}
        if method == "GET" and resource == "git/ref/heads/updates":
            if self.current_commit is None:
                return None
            return {"ref": publisher.UPDATE_REF, "object": {"type": "commit", "sha": self.current_commit}}
        if method == "GET" and resource == "git/commits/" + OLD_COMMIT:
            return {"sha": OLD_COMMIT, "tree": {"sha": OLD_TREE}}
        if method == "GET" and resource == "git/trees/" + OLD_TREE:
            return {"sha": OLD_TREE, "truncated": False, "tree": [
                {"path": "README.md", "mode": "100644", "type": "blob", "sha": "a" * 40},
                {"path": "appcast.xml", "mode": "100644", "type": "blob", "sha": publisher.git_blob_sha(self.feed)}]}
        if method == "GET" and resource == "git/blobs/" + publisher.git_blob_sha(self.feed or b""):
            return {"sha": publisher.git_blob_sha(self.feed), "encoding": "base64", "size": len(self.feed),
                    "content": base64.b64encode(self.feed).decode("ascii")}
        if method == "POST" and resource == "git/blobs":
            return {"sha": publisher.git_blob_sha(base64.b64decode(body["content"]))}
        if method == "POST" and resource == "git/trees":
            return {"sha": NEW_TREE}
        if method == "POST" and resource == "git/commits":
            return {"sha": NEW_COMMIT}
        if (method, resource) in [("POST", "git/refs"), ("PATCH", "git/refs/heads/updates")]:
            if self.race:
                raise publisher.GitHubFailure(422, method + " " + resource)
            self.current_commit = NEW_COMMIT
            return {"ref": publisher.UPDATE_REF, "object": {"type": "commit", "sha": NEW_COMMIT}}
        raise AssertionError((method, resource, body, missing))

    @property
    def mutations(self):
        return [call for call in self.calls if call[0] != "GET"]


class PublicationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="river-publish-tests-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.version = "0.1.0-alpha.6"
        basename = "River-" + self.version + "-macos-arm64"
        self.archive_name = basename + ".dmg"
        self.archive_bytes = b"Owned non-installable archive fixture."
        self.archive_digest = hashlib.sha256(self.archive_bytes).hexdigest()
        manifest = {
            "schema_version": 1, "product": "River",
            "app": {"version": self.version, "short_version": "0.1.0", "build_number": "7", "configuration": "release",
                    "bundle_identifier": "dev.workbench.AgentGitWorkbench", "executable": "AgentGitWorkbench",
                    "architecture": "arm64", "architectures": ["arm64"], "minimum_macos": "14.0",
                    "signing": {"kind": "developer-id", "team_identifier": "J8CB2X29B5"},
                    "updates": update_info(CONFIG), "executable_sha256": "a" * 64, "helper_sha256": "b" * 64,
                    "bundle_tree_sha256": "c" * 64,
                    "sparkle": {"version": SPARKLE_VERSION, "revision": SPARKLE_REVISION, "archive_url": SPARKLE_ARCHIVE_URL,
                                "archive_sha256": SPARKLE_CHECKSUM, "package_resolved_sha256": "d" * 64,
                                "source_framework_tree_sha256": "e" * 64, "signed_framework_tree_sha256": "f" * 64}},
            "disk_image": {"filename": self.archive_name, "format": "UDZO", "signing": "developer-id",
                           "mount_copy_verified": True, "sha256": self.archive_digest, "size_bytes": len(self.archive_bytes)},
            "source_git_commit": SOURCE, "source_tracked_dirty": False,
            "source_provenance": {"kind": "clean-git-build", "git_commit": SOURCE, "tracked_status": "",
                                  "tracked_patch_sha256": EMPTY_SHA256, "untracked_runtime_files": []}}
        self.asset_bytes = {self.archive_name: self.archive_bytes,
                            self.archive_name + ".sha256": f"{self.archive_digest}  {self.archive_name}\n".encode(),
                            basename + ".manifest.json": json.dumps(manifest).encode()}
        self.release = {"id": 123, "tag_name": "v" + self.version, "draft": False,
                        "published_at": "2026-10-24T00:00:00Z", "assets": [
                            {"id": index + 1, "name": name, "size": len(data), "state": "uploaded",
                             "digest": "sha256:" + hashlib.sha256(data).hexdigest(),
                             "browser_download_url": f"https://github.com/ictechgy/river/releases/download/v{self.version}/{name}"}
                            for index, (name, data) in enumerate(self.asset_bytes.items())]}
        self.new_feed = b"new signed feed fixture"
        self.feed_path = self.directory / "appcast.xml"
        self.feed_path.write_bytes(self.new_feed)
        config_path = self.directory / "config.json"
        config_path.write_text(json.dumps(CONFIG))
        self.args = argparse.Namespace(feed=self.feed_path, expected_source=SOURCE, configuration=config_path, publish=False)
        self.previous_build = "6"
        self.verification = patch.object(publisher, "verify_public_key", side_effect=self.verify)
        self.verify_mock = self.verification.start()
        self.addCleanup(self.verification.stop)
        self.downloader = patch.object(publisher, "download", side_effect=self.download)
        self.download_mock = self.downloader.start()
        self.addCleanup(self.downloader.stop)

    def verify(self, _key, *, feed=None, archive=None, signature=None):
        report = {"feed_verified": True, "version": self.version, "build_number": "7",
                  "url": f"https://github.com/ictechgy/river/releases/download/v{self.version}/{self.archive_name}"}
        if feed is not None and Path(feed).name == "previous-appcast.xml":
            report["build_number"] = self.previous_build
        if archive is not None:
            report.update(archive_verified=True, archive_sha256=self.archive_digest, archive_length=len(self.archive_bytes))
        return report

    def download(self, url, destination, maximum):
        data = self.new_feed if url == FEED_URL else self.asset_bytes[url.rsplit("/", 1)[1]]
        self.assertLessEqual(len(data), maximum)
        Path(destination).write_bytes(data)
        return hashlib.sha256(data).hexdigest(), len(data)

    def test_dry_run_validates_public_assets_and_tag_without_any_mutation(self):
        api = FakeGitHub(self.release)
        result = publisher.execute(self.args, api)
        self.assertEqual(result["status"], "verified")
        self.assertFalse(result["published"])
        self.assertEqual(api.mutations, [])
        self.assertEqual(self.download_mock.call_count, 3)
        self.assertEqual(api.release_reads, 2)
        self.assertTrue(any(call.kwargs.get("archive") for call in self.verify_mock.call_args_list))

    def test_invalid_signature_prevents_all_network_and_mutations(self):
        api = FakeGitHub(self.release)
        self.verify_mock.side_effect = ValueError("bad signature")
        with self.assertRaisesRegex(ValueError, "bad signature"):
            publisher.execute(self.args, api)
        self.assertEqual(api.calls, [])
        self.download_mock.assert_not_called()

    def test_public_archive_signature_failure_prevents_all_mutations(self):
        api = FakeGitHub(self.release)
        normal_verifier = self.verify
        def fail_archive(key, **kwargs):
            if kwargs.get("archive") is not None:
                raise ValueError("public archive signature mismatch")
            return normal_verifier(key, **kwargs)
        self.verify_mock.side_effect = fail_archive
        self.args.publish = True
        with self.assertRaisesRegex(ValueError, "archive signature mismatch"):
            publisher.execute(self.args, api)
        self.assertEqual(api.mutations, [])

    def test_existing_feed_wrong_key_prevents_first_mutation(self):
        api = FakeGitHub(self.release, b"old signed feed fixture")
        normal_verifier = self.verify
        def fail_previous(key, **kwargs):
            if Path(kwargs.get("feed", "")).name == "previous-appcast.xml":
                raise ValueError("existing signed feed key mismatch")
            return normal_verifier(key, **kwargs)
        self.verify_mock.side_effect = fail_previous
        self.args.publish = True
        with self.assertRaisesRegex(ValueError, "feed key mismatch"):
            publisher.execute(self.args, api)
        self.assertEqual(api.mutations, [])

    def test_mismatched_source_tag_rejected_before_download(self):
        api = FakeGitHub(self.release)
        api.tag_source = "a" * 40
        with self.assertRaisesRegex(ValueError, "expected source"):
            publisher.execute(self.args, api)
        self.assertEqual(api.mutations, [])
        self.download_mock.assert_not_called()

    def test_mismatched_manifest_source_rejected_before_mutation(self):
        name = next(name for name in self.asset_bytes if name.endswith(".manifest.json"))
        manifest = json.loads(self.asset_bytes[name])
        manifest["source_git_commit"] = "a" * 40
        manifest["source_provenance"]["git_commit"] = "a" * 40
        self.asset_bytes[name] = json.dumps(manifest).encode()
        asset = next(asset for asset in self.release["assets"] if asset["name"] == name)
        asset.update(size=len(self.asset_bytes[name]), digest="sha256:" + hashlib.sha256(self.asset_bytes[name]).hexdigest())
        api = FakeGitHub(self.release)
        with self.assertRaisesRegex(ValueError, "expected source"):
            publisher.execute(self.args, api)
        self.assertEqual(api.mutations, [])

    def test_api_asset_digest_or_size_mismatch_rejected(self):
        for key, value in [("digest", "sha256:" + "0" * 64), ("size", 1)]:
            with self.subTest(key=key):
                release = json.loads(json.dumps(self.release))
                release["assets"][0][key] = value
                api = FakeGitHub(release)
                with self.assertRaisesRegex(ValueError, "actual public release asset"):
                    publisher.execute(self.args, api)
                self.assertEqual(api.mutations, [])

    def test_draft_unpublished_or_extra_assets_rejected(self):
        for mutation in [lambda item: item.update(draft=True), lambda item: item.update(published_at=None),
                         lambda item: item["assets"].append(item["assets"][0])]:
            release = json.loads(json.dumps(self.release))
            mutation(release)
            api = FakeGitHub(release)
            with self.assertRaises(ValueError):
                publisher.execute(self.args, api)
            self.assertEqual(api.mutations, [])

    def test_existing_equal_or_newer_build_cannot_advance_branch(self):
        for previous in ["7", "8"]:
            with self.subTest(previous=previous):
                self.previous_build = previous
                api = FakeGitHub(self.release, b"different old signed feed")
                self.args.publish = True
                with self.assertRaisesRegex(ValueError, "equal or newer"):
                    publisher.execute(self.args, api)
                self.assertEqual(api.mutations, [])

    def test_changed_release_metadata_fails_before_first_mutation(self):
        api = FakeGitHub(self.release)
        api.changed_release = True
        self.args.publish = True
        with self.assertRaisesRegex(ValueError, "release changed"):
            publisher.execute(self.args, api)
        self.assertEqual(api.mutations, [])

    def test_initial_publish_creates_orphan_updates_branch_only(self):
        api = FakeGitHub(self.release)
        self.args.publish = True
        result = publisher.execute(self.args, api)
        self.assertEqual(result["updates_commit"], NEW_COMMIT)
        self.assertEqual([(method, resource) for method, resource, _ in api.mutations], [
            ("POST", "git/blobs"), ("POST", "git/trees"), ("POST", "git/commits"), ("POST", "git/refs")])
        self.assertEqual(api.mutations[2][2]["parents"], [])
        self.assertEqual(api.mutations[-1][2]["ref"], "refs/heads/updates")
        self.assertNotIn("base_tree", api.mutations[1][2])

    def test_existing_publish_preserves_tree_and_uses_nonforced_ref_update(self):
        api = FakeGitHub(self.release, b"old signed feed fixture")
        self.args.publish = True
        result = publisher.execute(self.args, api)
        self.assertEqual(result["status"], "published")
        self.assertEqual(api.mutations[1][2]["base_tree"], OLD_TREE)
        self.assertEqual(api.mutations[2][2]["parents"], [OLD_COMMIT])
        self.assertEqual(api.mutations[-1], ("PATCH", "git/refs/heads/updates", {"sha": NEW_COMMIT, "force": False}))

    def test_non_fast_forward_is_not_retried_or_forced(self):
        api = FakeGitHub(self.release, b"old signed feed fixture")
        api.race = True
        self.args.publish = True
        with self.assertRaises(publisher.GitHubFailure):
            publisher.execute(self.args, api)
        ref_updates = [call for call in api.mutations if call[1] == "git/refs/heads/updates"]
        self.assertEqual(len(ref_updates), 1)
        self.assertFalse(ref_updates[0][2]["force"])
        self.assertEqual(api.current_commit, OLD_COMMIT)

    def test_same_signed_bytes_are_idempotent_without_git_object_writes(self):
        api = FakeGitHub(self.release, self.new_feed)
        self.previous_build = "7"
        self.args.publish = True
        result = publisher.execute(self.args, api)
        self.assertEqual(result["status"], "unchanged")
        self.assertEqual(result["updates_commit"], OLD_COMMIT)
        self.assertEqual(api.mutations, [])

    def test_downloads_must_remain_github_https(self):
        for url in ["http://github.com/file", "https://attacker.invalid/file", "https://user@github.com/file",
                    "https://github.com:8443/file", "file:///etc/passwd"]:
            with self.subTest(url=url), self.assertRaises(ValueError):
                publisher.validate_download_url(url)

    def test_gh_uses_structured_input_and_does_not_echo_auth_diagnostics(self):
        result = subprocess.CompletedProcess(["gh"], 1, "HTTP/2.0 422 Unprocessable Entity\n\n{}", "SECRET diagnostic")
        with patch.object(publisher.subprocess, "run", return_value=result) as run:
            with self.assertRaises(publisher.GitHubFailure) as caught:
                publisher.GitHub().request("PATCH", "git/refs/heads/updates", {"sha": NEW_COMMIT, "force": False})
        self.assertNotIn("SECRET", str(caught.exception))
        self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"sha": NEW_COMMIT, "force": False})
        self.assertIn("--input", run.call_args.args[0])
        self.assertNotIn("shell", run.call_args.kwargs)


if __name__ == "__main__":
    unittest.main()
