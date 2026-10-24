#!/usr/bin/env python3
"""Validate a public River release and optionally advance only its updates branch."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import quote, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from build_macos import ROOT
from make_appcast import (MAX_ARCHIVE_BYTES, MAX_FEED_BYTES, bounded_read, hexadecimal,
                          load_release, require, verify_public_key)
from sparkle_support import FEED_URL, load_update_configuration

REPOSITORY = "repos/ictechgy/river"
UPDATE_REF = "refs/heads/updates"
USER_AGENT = "River-release-feed-verifier"


class GitHubFailure(ValueError):
    def __init__(self, status, operation):
        self.status = status
        super().__init__(f"GitHub {operation} failed (HTTP {status}); no forced or automatic retry was attempted")


class GitHub:
    """Structured Git Data API calls; credentials stay inside gh, never in logs."""
    def request(self, method, resource, body=None, *, missing=False):
        argv = ["gh", "api", "--hostname", "github.com", "--include", "--method", method,
                "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28",
                f"{REPOSITORY}/{resource}"]
        if body is not None:
            argv.extend(["--input", "-"])
        result = subprocess.run(argv, input=json.dumps(body) if body is not None else None,
                                capture_output=True, text=True, timeout=120)
        # Parse the status without echoing raw headers, auth/tool diagnostics or
        # GitHub's error response. No shell or token-bearing argv is involved.
        headers, separator, payload = result.stdout.partition("\n\n")
        match = re.match(r"HTTP/[^ ]+ ([0-9]{3})", headers)
        status = int(match[1]) if match else 0
        if missing and status == 404:
            return None
        if result.returncode != 0 or not separator or not 200 <= status < 300:
            raise GitHubFailure(status, method + " " + resource)
        require(len(payload.encode("utf-8")) <= 4 * MAX_FEED_BYTES, "GitHub API response exceeds the size limit")
        try:
            value = json.loads(payload)
            require(isinstance(value, dict), "GitHub returned a non-object response")
            return value
        except json.JSONDecodeError as error:
            raise ValueError("GitHub returned invalid JSON") from error


class HTTPSOnlyRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        validate_download_url(new_url)
        return super().redirect_request(request, response, code, message, headers, new_url)


def validate_download_url(url):
    parts = urlsplit(url)
    require(parts.scheme == "https" and parts.hostname in {
                "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com", "raw.githubusercontent.com"}
            and parts.username is None and parts.password is None and parts.port in (None, 443),
            "download redirected outside GitHub HTTPS")


def download(url, destination, maximum):
    """Anonymous bounded HTTPS download. Starting URLs are fixed separately."""
    validate_download_url(url)
    opener = build_opener(HTTPSOnlyRedirects())
    digest, length = hashlib.sha256(), 0
    deadline = time.monotonic() + 180
    with opener.open(Request(url, headers={"User-Agent": USER_AGENT}), timeout=30) as response:
        content_length = response.headers.get("Content-Length")
        if content_length is not None:
            require(content_length.isdigit() and 0 < int(content_length) <= maximum,
                    "public download exceeds its size limit or is empty")
        with Path(destination).open("xb") as output:
            while True:
                require(time.monotonic() < deadline, "public download exceeded its time limit")
                block = response.read(min(1024 * 1024, maximum - length + 1))
                if not block:
                    break
                length += len(block)
                require(length <= maximum, "public download exceeds its size limit")
                digest.update(block)
                output.write(block)
    require(length > 0 and (content_length is None or length == int(content_length)),
            "public download is empty or truncated")
    return digest.hexdigest(), length


def published_release(api, version):
    release = api.request("GET", "releases/tags/" + quote("v" + version, safe=""))
    require(release.get("tag_name") == "v" + version and release.get("draft") is False and
            isinstance(release.get("published_at"), str) and release["published_at"] and
            type(release.get("id")) is int and release["id"] > 0,
            "release must already be publicly published with the expected tag")
    basename = f"River-{version}-macos-arm64"
    expected = {basename + ".dmg": MAX_ARCHIVE_BYTES, basename + ".dmg.sha256": 1024,
                basename + ".manifest.json": MAX_FEED_BYTES}
    assets = release.get("assets", [])
    require(isinstance(assets, list) and len(assets) == 3 and all(isinstance(asset, dict) for asset in assets) and
            {asset.get("name") for asset in assets} == set(expected),
            "public release must contain exactly its DMG, checksum and manifest")
    for asset in assets:
        name = asset["name"]
        require(asset.get("state") == "uploaded" and type(asset.get("id")) is int and asset["id"] > 0 and
                type(asset.get("size")) is int and 0 < asset["size"] <= expected[name] and
                asset.get("browser_download_url") == f"https://github.com/ictechgy/river/releases/download/v{version}/{name}" and
                isinstance(asset.get("digest"), str) and re.fullmatch(r"sha256:[0-9a-f]{64}", asset["digest"]) is not None,
                "public release asset identity, digest or size is invalid")
    return release, expected


def release_identity(release):
    return {"id": release["id"], "tag_name": release["tag_name"], "draft": release["draft"],
            "published_at": release["published_at"], "assets": sorted([
                {key: asset[key] for key in ["id", "name", "size", "digest", "state", "browser_download_url"]}
                for asset in release["assets"]], key=lambda item: item["name"])}


def validate_tag(api, version, expected_source):
    reference = api.request("GET", "git/ref/tags/" + quote("v" + version, safe=""))
    require(reference.get("ref") == "refs/tags/v" + version, "unexpected release tag reference")
    target = reference.get("object", {})
    seen = set()
    while target.get("type") == "tag":
        sha = target.get("sha")
        require(hexadecimal(sha, 40) and sha not in seen and len(seen) < 5, "invalid or cyclic annotated tag")
        seen.add(sha)
        tag = api.request("GET", "git/tags/" + sha)
        require(tag.get("sha") == sha, "annotated tag identity differs")
        target = tag.get("object", {})
    require(target.get("type") == "commit" and target.get("sha") == expected_source,
            "release tag does not resolve to the expected source commit")


def git_blob_sha(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode("ascii") + b"\0" + data).hexdigest()


def branch_state(api, directory, public_key):
    reference = api.request("GET", "git/ref/heads/updates", missing=True)
    if reference is None:
        return {"commit": None, "tree": None, "feed": None, "report": None}
    require(reference.get("ref") == UPDATE_REF and reference.get("object", {}).get("type") == "commit",
            "updates reference must point to a commit")
    sha = reference["object"].get("sha")
    require(hexadecimal(sha, 40), "invalid updates commit")
    commit = api.request("GET", "git/commits/" + sha)
    tree_sha = commit.get("tree", {}).get("sha")
    require(commit.get("sha") == sha and hexadecimal(tree_sha, 40), "invalid updates tree")
    tree = api.request("GET", "git/trees/" + tree_sha)
    require(tree.get("sha") == tree_sha and tree.get("truncated") is False and isinstance(tree.get("tree"), list) and
            all(isinstance(entry, dict) for entry in tree["tree"]),
            "updates tree is incomplete or invalid")
    matches = [entry for entry in tree["tree"] if entry.get("path") == "appcast.xml"]
    require(len(matches) <= 1, "updates tree contains duplicate appcast entries")
    state = {"commit": sha, "tree": tree_sha, "feed": None, "report": None}
    if not matches:
        return state
    entry = matches[0]
    require(entry.get("mode") == "100644" and entry.get("type") == "blob" and hexadecimal(entry.get("sha"), 40),
            "existing appcast must be a regular blob")
    blob = api.request("GET", "git/blobs/" + entry["sha"])
    require(blob.get("encoding") == "base64" and type(blob.get("size")) is int and
            0 < blob["size"] <= MAX_FEED_BYTES and isinstance(blob.get("content"), str), "invalid existing appcast blob")
    try:
        data = base64.b64decode("".join(blob["content"].split()), validate=True)
    except ValueError as error:
        raise ValueError("invalid existing appcast base64") from error
    require(len(data) == blob["size"] and git_blob_sha(data) == entry["sha"] and blob.get("sha") == entry["sha"],
            "existing appcast bytes differ from their Git object")
    previous = directory / "previous-appcast.xml"
    previous.write_bytes(data)
    state["feed"] = data
    state["report"] = verify_public_key(public_key, feed=previous)
    return state


def publish_ref(api, feed, report, state):
    blob = api.request("POST", "git/blobs", {"content": base64.b64encode(feed).decode("ascii"), "encoding": "base64"})
    require(blob.get("sha") == git_blob_sha(feed), "GitHub created an unexpected appcast blob")
    tree_body = {"tree": [{"path": "appcast.xml", "mode": "100644", "type": "blob", "sha": blob["sha"]}]}
    if state["tree"]:
        tree_body["base_tree"] = state["tree"]
    tree = api.request("POST", "git/trees", tree_body)
    require(hexadecimal(tree.get("sha"), 40), "GitHub created an invalid appcast tree")
    commit = api.request("POST", "git/commits", {
        "message": f"Publish signed River {report['version']} update (build {report['build_number']})",
        "tree": tree["sha"], "parents": [state["commit"]] if state["commit"] else []})
    require(hexadecimal(commit.get("sha"), 40), "GitHub created an invalid updates commit")
    if state["commit"]:
        result = api.request("PATCH", "git/refs/heads/updates", {"sha": commit["sha"], "force": False})
    else:
        result = api.request("POST", "git/refs", {"ref": UPDATE_REF, "sha": commit["sha"]})
    require(result.get("ref") == UPDATE_REF and result.get("object", {}).get("sha") == commit["sha"],
            "updates reference did not resolve to the created commit")
    return commit["sha"]


def verify_publication(api, directory, feed, public_key, commit):
    # raw.githubusercontent.com can lag the successful Git ref update. Reads
    # alone are retried for at most 30 seconds; ref mutations are never retried.
    deadline = time.monotonic() + 30
    attempt = 0
    while True:
        downloaded = directory / f"published-appcast-{attempt}.xml"
        try:
            download(FEED_URL, downloaded, MAX_FEED_BYTES)
            actual = bounded_read(downloaded, MAX_FEED_BYTES)
        except (OSError, ValueError):
            actual = None
        if actual == feed:
            verify_public_key(public_key, feed=downloaded)
            reference = api.request("GET", "git/ref/heads/updates")
            require(reference.get("ref") == UPDATE_REF and reference.get("object", {}).get("sha") == commit,
                    "updates branch advanced after publishing; public feed was not overwritten")
            return
        require(time.monotonic() < deadline, "updates ref was written but the public raw feed did not converge; do not republish blindly")
        time.sleep(1)
        attempt += 1


def execute(args, api=None):
    require(hexadecimal(args.expected_source, 40), "--expected-source must be a lowercase 40-character Git commit")
    configuration = load_update_configuration(args.configuration)
    feed = bounded_read(args.feed, MAX_FEED_BYTES)
    initial_feed_report = verify_public_key(configuration["public_ed_key"], feed=args.feed)
    require(initial_feed_report.get("feed_verified") is True, "signed feed verification was not completed")
    api = api or GitHub()
    with tempfile.TemporaryDirectory(prefix="river-public-appcast-") as temporary:
        directory = Path(temporary)
        release, limits = published_release(api, initial_feed_report["version"])
        validate_tag(api, initial_feed_report["version"], args.expected_source)
        for asset in release["assets"]:
            digest, size = download(asset["browser_download_url"], directory / asset["name"], limits[asset["name"]])
            require(size == asset["size"] and "sha256:" + digest == asset["digest"],
                    "actual public release asset differs from GitHub's size or digest")
        archive = directory / Path(initial_feed_report["url"]).name
        checked = verify_public_key(configuration["public_ed_key"], feed=args.feed, archive=archive)
        require(checked.get("feed_verified") is True and checked.get("archive_verified") is True,
                "actual public archive did not pass public-key verification")
        metadata = load_release(directory, configuration, verify_payload=False)
        require(metadata["manifest"]["source_git_commit"] == args.expected_source and
                checked.get("version") == metadata["version"] and checked.get("build_number") == metadata["build_number"] and
                checked.get("url") == metadata["url"] and checked.get("archive_sha256") == metadata["sha256"] and
                checked.get("archive_length") == metadata["length"],
                "signed public update differs from expected source or release manifest")
        state = branch_state(api, directory, configuration["public_ed_key"])
        same = state["feed"] == feed
        if state["report"] is not None and not same:
            require(int(checked["build_number"]) > int(state["report"]["build_number"]),
                    "updates branch already has an equal or newer signed build")
        # Re-read mutable release/tag metadata immediately before any server
        # mutation. Validation does not create even unreachable Git objects.
        latest, _ = published_release(api, checked["version"])
        require(release_identity(latest) == release_identity(release), "release changed during public validation")
        validate_tag(api, checked["version"], args.expected_source)
        require(bounded_read(args.feed, MAX_FEED_BYTES) == feed, "local feed changed during validation")
        result = {"status": "unchanged" if same else "verified", "published": False,
                  "version": checked["version"], "build_number": checked["build_number"],
                  "source_git_commit": args.expected_source, "feed_url": FEED_URL,
                  "feed_sha256": hashlib.sha256(feed).hexdigest(), "previous_updates_commit": state["commit"],
                  "verification": "public Ed25519 feed/archive, API asset digests and manifest; native mount verification belongs to packaging"}
        if not args.publish:
            return result
        commit = state["commit"] if same else publish_ref(api, feed, checked, state)
        verify_publication(api, directory, feed, configuration["public_ed_key"], commit)
        return {**result, "status": "unchanged" if same else "published", "published": True, "updates_commit": commit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--feed", type=Path, required=True)
    parser.add_argument("--expected-source", required=True)
    parser.add_argument("--configuration", type=Path, default=ROOT / "apps/macos/Resources/UpdateConfiguration.json")
    parser.add_argument("--publish", action="store_true", help="advance only the updates branch after all public checks pass")
    args = parser.parse_args()
    try:
        print(json.dumps(execute(args), sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError) as error:
        parser.exit(1, f"Appcast publication failed: {error}\n")


if __name__ == "__main__":
    main()
