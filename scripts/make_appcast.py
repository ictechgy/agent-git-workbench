#!/usr/bin/env python3
"""Create a signed River Sparkle feed from a verified release, without publishing it."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
from email.utils import format_datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from build_macos import ROOT, APP_IDENTIFIER, APP_EXECUTABLE, version_metadata
from package_macos import verify_dmg, verify_distribution_image_signature
from sparkle_support import (SPARKLE_VERSION, SPARKLE_REVISION, SPARKLE_ARCHIVE_URL,
                             SPARKLE_CHECKSUM, load_update_configuration, update_info)

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DOWNLOAD_PREFIX = "https://github.com/ictechgy/river/releases/download/"
TEAM_IDENTIFIER = "J8CB2X29B5"
DEFAULT_ACCOUNT = APP_IDENTIFIER + ".sparkle"
MAX_ARCHIVE_BYTES = 2_147_483_648
MAX_FEED_BYTES = 1_048_576
EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()
ET.register_namespace("sparkle", SPARKLE)


def bounded_read(path, maximum):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"expected a regular file: {path.name}")
    with path.open("rb") as source:
        data = source.read(maximum + 1)
    if not data or len(data) > maximum:
        raise ValueError(f"file is empty or exceeds its size limit: {path.name}")
    return data


def file_sha256(path):
    digest = hashlib.sha256()
    size = 0
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            size += len(block)
            if size > MAX_ARCHIVE_BYTES:
                raise ValueError("update archive exceeds the size limit")
            digest.update(block)
    return digest.hexdigest(), size


def require(condition, message):
    if not condition:
        raise ValueError(message)


def hexadecimal(value, length):
    return isinstance(value, str) and re.fullmatch(f"[0-9a-f]{{{length}}}", value) is not None


def load_release(directory, configuration, *, verify_payload=True):
    """Check release bytes/metadata; by default also mount and verify native code.

    Public feed publication may skip the repeated native mount only after the
    actual downloaded archive passes the signed feed's public-key verification.
    """
    directory = Path(directory)
    manifests = sorted(directory.glob("*.manifest.json"))
    require(len(manifests) == 1, "release directory must contain exactly one manifest")
    manifest = json.loads(bounded_read(manifests[0], MAX_FEED_BYTES))
    require(isinstance(manifest, dict), "release manifest must be an object")
    require(type(manifest.get("schema_version")) is int and manifest["schema_version"] == 1 and manifest.get("product") == "River",
            "unsupported release manifest")
    app = manifest.get("app", {})
    require(isinstance(app, dict), "release app metadata must be an object")
    require(isinstance(app.get("version"), str) and isinstance(app.get("build_number"), str),
            "release version and build number must be strings")
    metadata = version_metadata(app["version"], app["build_number"])
    build_number = metadata["CFBundleVersion"]
    require(int(build_number) <= 2_147_483_647, "build number exceeds the supported numeric range")
    require(len(app["version"]) <= 128, "release version exceeds the supported length")
    require(app.get("short_version") == metadata["CFBundleShortVersionString"] and
            app.get("configuration") == "release" and app.get("bundle_identifier") == APP_IDENTIFIER and
            app.get("executable") == APP_EXECUTABLE, "release app identity or version is inconsistent")
    require(app.get("architecture") == "arm64" and app.get("architectures") == ["arm64"] and
            app.get("minimum_macos") == "14.0", "update must target arm64 and macOS 14.0")
    require(app.get("signing") == {"kind": "developer-id", "team_identifier": TEAM_IDENTIFIER},
            "update requires River's Developer ID signing team")
    require(app.get("updates") == update_info(configuration),
            "packaged update key, feed URL or update policy differs from configuration")
    sparkle = app.get("sparkle", {})
    require(isinstance(sparkle, dict), "Sparkle metadata must be an object")
    expected_sparkle = {"version": SPARKLE_VERSION, "revision": SPARKLE_REVISION,
                        "archive_url": SPARKLE_ARCHIVE_URL, "archive_sha256": SPARKLE_CHECKSUM}
    require(all(sparkle.get(key) == value for key, value in expected_sparkle.items()),
            "packaged Sparkle dependency differs from its reviewed pin")
    for key in ["package_resolved_sha256", "source_framework_tree_sha256", "signed_framework_tree_sha256"]:
        require(hexadecimal(sparkle.get(key), 64), "invalid packaged Sparkle provenance digest")
    for key in ["executable_sha256", "helper_sha256", "bundle_tree_sha256"]:
        require(hexadecimal(app.get(key), 64), "invalid packaged app digest")
    source = manifest.get("source_provenance", {})
    require(isinstance(source, dict), "source provenance must be an object")
    require(source.get("kind") == "clean-git-build" and source.get("tracked_status") == "" and
            source.get("tracked_patch_sha256") == EMPTY_SHA256 and source.get("untracked_runtime_files") == [] and
            hexadecimal(source.get("git_commit"), 40) and
            manifest.get("source_git_commit") == source.get("git_commit") and
            manifest.get("source_tracked_dirty") is False,
            "update requires a clean, identified Git build")
    version = app["version"]
    basename = f"River-{version}-macos-arm64"
    filename = basename + ".dmg"
    require(manifests[0].name == basename + ".manifest.json", "manifest filename differs from release version")
    image = manifest.get("disk_image", {})
    require(isinstance(image, dict), "disk image metadata must be an object")
    require(image.get("filename") == filename and image.get("format") == "UDZO" and
            image.get("signing") == "developer-id" and image.get("mount_copy_verified") is True,
            "disk image identity, format or signing metadata is inconsistent")
    archive = directory / filename
    require(not archive.is_symlink() and archive.is_file(), "update archive is missing or a symlink")
    require(0 < archive.stat().st_size <= MAX_ARCHIVE_BYTES, "update archive exceeds the size limit or is empty")
    digest, length = file_sha256(archive)
    require(length > 0 and type(image.get("size_bytes")) is int and image["size_bytes"] == length and
            image.get("sha256") == digest, "disk image bytes differ from the manifest")
    checksum = bounded_read(directory / (filename + ".sha256"), 1024)
    require(checksum == f"{digest}  {filename}\n".encode("ascii"), "checksum sidecar differs from actual archive bytes")
    # Verify the file we will actually sign, including its mounted/copied app,
    # nested framework/helper code, update configuration and complete tree hash.
    if verify_payload:
        verify_distribution_image_signature(archive, TEAM_IDENTIFIER)
        require(verify_dmg(archive, app) == app, "mounted update payload differs from its manifest")
    return {"manifest": manifest, "archive": archive, "version": version, "build_number": build_number,
            "sha256": digest, "length": length, "url": DOWNLOAD_PREFIX + f"v{version}/{filename}"}


def canonical_signature(value):
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("sign_update returned an invalid signature") from error
    require(len(decoded) == 64 and base64.b64encode(decoded).decode("ascii") == value,
            "sign_update returned a noncanonical signature")
    return value


def run_signer(tool, account, path, *, archive=False):
    argv = [str(tool), "--account", account, "-p", str(path)]
    result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    # Never echo raw signing-tool output or a Keychain diagnostic. Only public
    # signatures are accepted from the archive signer; XML is modified in place.
    require(result.returncode == 0, "Sparkle signing failed; output was not replaced")
    if archive:
        return canonical_signature(result.stdout.strip())
    require(not result.stdout.strip(), "unexpected output while signing appcast")
    return None


def verify_public_key(public_key, *, feed=None, archive=None, signature=None):
    argv = ["/usr/bin/xcrun", "swift", str(ROOT / "scripts/verify_update.swift"), "--public-key", public_key]
    for name, value in [("--feed", feed), ("--archive", archive), ("--signature", signature)]:
        if value is not None:
            argv.extend([name, str(value)])
    result = subprocess.run(argv, capture_output=True, text=True, timeout=120)
    require(result.returncode == 0, "public-key-only update verification failed")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("public-key verifier returned an invalid report") from error


def build_feed(release, signature, notes, date=None):
    require(isinstance(notes, str) and 0 < len(notes.encode("utf-8")) <= 32_768,
            "release notes must contain 1 to 32768 UTF-8 bytes")
    require(all(character in "\n\t" or ord(character) >= 32 for character in notes),
            "release notes contain XML control characters")
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "River Updates"
    ET.SubElement(channel, "link").text = "https://github.com/ictechgy/river"
    ET.SubElement(channel, "description").text = "Signed River updates for macOS"
    ET.SubElement(channel, "language").text = "en"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = "River " + release["version"]
    ET.SubElement(item, "pubDate").text = format_datetime(date or datetime.now(timezone.utc), usegmt=True)
    ET.SubElement(item, f"{{{SPARKLE}}}version").text = release["build_number"]
    ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = release["version"]
    ET.SubElement(item, f"{{{SPARKLE}}}minimumSystemVersion").text = "14.0"
    ET.SubElement(item, f"{{{SPARKLE}}}hardwareRequirements").text = "arm64"
    ET.SubElement(item, "description", {f"{{{SPARKLE}}}format": "plain-text"}).text = notes
    ET.SubElement(item, "enclosure", {"url": release["url"], "length": str(release["length"]),
                  "type": "application/octet-stream", f"{{{SPARKLE}}}os": "macos",
                  f"{{{SPARKLE}}}edSignature": canonical_signature(signature)})
    ET.indent(rss, space="  ")
    return ET.tostring(rss, encoding="utf-8", xml_declaration=True) + b"\n"


@contextmanager
def feed_lock(output):
    # Preserve the lock inode so another writer cannot bypass an active lock.
    with (output.parent / ("." + output.name + ".lock")).open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("another appcast generator is using this output") from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def generate(args):
    configuration = load_update_configuration(args.configuration)
    require(args.keychain_account == DEFAULT_ACCOUNT,
            "use River's dedicated Sparkle Keychain account")
    tool = args.tools_directory.expanduser().resolve() / "sign_update"
    require(tool.is_file() and os.access(tool, os.X_OK), "Sparkle sign_update tool is missing or not executable")
    output = args.output.expanduser().absolute()
    require(output.name == "appcast.xml" and not output.is_symlink(), "output must be a regular appcast.xml file")
    output.parent.mkdir(parents=True, exist_ok=True)
    with feed_lock(output):
        previous = bounded_read(output, MAX_FEED_BYTES) if output.exists() else None
        previous_report = (verify_public_key(configuration["public_ed_key"], feed=output)
                           if previous is not None else None)
        release = load_release(args.release_directory.expanduser().resolve(), configuration)
        if previous_report:
            require(int(release["build_number"]) > int(previous_report["build_number"]),
                    "new build number must be greater than the existing signed feed")
        notarization = release["manifest"].get("notarization", {})
        notary_text = ("notarized by Apple" if notarization.get("status") == "accepted" and
                       notarization.get("stapled") is True else "not notarized by Apple")
        notes = (bounded_read(args.notes_file, 32_768).decode("utf-8") if args.notes_file else
                 f"River {release['version']} for macOS.\nThis is an early alpha release. "
                 f"The update is Developer ID signed and is {notary_text}.")
        signature = run_signer(tool, args.keychain_account, release["archive"], archive=True)
        archive_report = verify_public_key(configuration["public_ed_key"], archive=release["archive"], signature=signature)
        require(archive_report.get("archive_verified") is True and
                archive_report.get("archive_sha256") == release["sha256"] and
                archive_report.get("archive_length") == release["length"], "archive changed during signing")
        with tempfile.TemporaryDirectory(prefix=".river-appcast-", dir=output.parent) as temporary:
            candidate = Path(temporary) / "appcast.xml"
            candidate.write_bytes(build_feed(release, signature, notes))
            run_signer(tool, args.keychain_account, candidate)
            signed = bounded_read(candidate, MAX_FEED_BYTES)
            report = verify_public_key(configuration["public_ed_key"], feed=candidate, archive=release["archive"])
            require(report.get("feed_verified") is True and report.get("archive_verified") is True and
                    report.get("build_number") == release["build_number"] and report.get("version") == release["version"] and
                    report.get("url") == release["url"] and report.get("archive_sha256") == release["sha256"] and
                    report.get("archive_length") == release["length"], "signed update differs from verified release")
            require(file_sha256(release["archive"]) == (release["sha256"], release["length"]),
                    "archive changed before appcast publication")
            require((bounded_read(output, MAX_FEED_BYTES) if output.exists() else None) == previous,
                    "existing feed changed while signing; output was not replaced")
            require(candidate.read_bytes() == signed, "signed feed changed while verifying")
            os.replace(candidate, output)
    return {"appcast": str(output), "appcast_sha256": hashlib.sha256(signed).hexdigest(),
            "build_number": release["build_number"], "version": release["version"],
            "archive_sha256": release["sha256"], "url": release["url"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-directory", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tools-directory", type=Path, required=True, help="validated Sparkle 2.10.0 bin directory")
    parser.add_argument("--keychain-account", default=DEFAULT_ACCOUNT)
    parser.add_argument("--configuration", type=Path, default=ROOT / "apps/macos/Resources/UpdateConfiguration.json")
    parser.add_argument("--notes-file", type=Path, help="optional embedded plain text notes; never loaded over the network")
    args = parser.parse_args()
    try:
        print(json.dumps(generate(args), sort_keys=True))
    except (ValueError, OSError, subprocess.SubprocessError, KeyError, TypeError) as error:
        parser.exit(1, f"Appcast generation failed: {error}\n")


if __name__ == "__main__":
    main()
