"""Shared, fail-closed Sparkle configuration and SwiftPM artifact validation."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
from urllib.parse import urlsplit

SPARKLE_VERSION = "2.10.0"
SPARKLE_BUILD = "2064"
SPARKLE_LICENSE_SHA256 = "389a4e4e9a32f059775b13a06e25a591445ba229d2838d26dd3e7c0c45127cfe"
SPARKLE_REVISION = "eef1a539a373c1f1a320624b1130fc5de7b2e100"
SPARKLE_URL = "https://github.com/sparkle-project/Sparkle"
SPARKLE_ARCHIVE_URL = (SPARKLE_URL + "/releases/download/2.10.0/"
                       "Sparkle-for-Swift-Package-Manager.zip")
SPARKLE_CHECKSUM = "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
FEED_URL = "https://raw.githubusercontent.com/ictechgy/river/updates/appcast.xml"


def sha256_file(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_update_configuration(path):
    path = Path(path)
    if path.is_symlink():
        raise ValueError("update configuration must be a regular file, not a symlink")
    config = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(config, dict) or set(config) != {"feed_url", "public_ed_key"}:
        raise ValueError("update configuration requires only feed_url and public_ed_key")
    if not isinstance(config["feed_url"], str):
        raise ValueError("update feed URL must be a string")
    url = urlsplit(config["feed_url"])
    if config["feed_url"] != FEED_URL or url.scheme != "https" or url.username or url.password:
        raise ValueError("update configuration must use the official HTTPS River appcast")
    key = config["public_ed_key"]
    try:
        decoded = base64.b64decode(key, validate=True)
    except (ValueError, TypeError) as error:
        raise ValueError("update public key must be a canonical 32-byte base64 Ed25519 key") from error
    if len(decoded) != 32 or base64.b64encode(decoded).decode("ascii") != key or not any(decoded):
        raise ValueError("update public key must be a canonical 32-byte base64 Ed25519 key")
    return config


def update_info(config):
    return {"SUFeedURL": config["feed_url"], "SUPublicEDKey": config["public_ed_key"],
            "SUEnableAutomaticChecks": True, "SUAllowsAutomaticUpdates": False,
            "SUAutomaticallyUpdate": False, "SUVerifyUpdateBeforeExtraction": True,
            "SURequireSignedFeed": True, "SUSignedFeedFailureExpirationInterval": 0,
            "SUEnableSystemProfiling": False, "SUScheduledCheckInterval": 86400}


def validate_framework_tree(framework):
    """Allow Apple's versioned symlinks, never links escaping the framework."""
    framework = Path(framework)
    if framework.is_symlink() or not framework.is_dir():
        raise ValueError("Sparkle framework is missing or is a symlink")
    root = framework.resolve()
    for entry in framework.rglob("*"):
        if entry.is_symlink():
            target = os.readlink(entry)
            if Path(target).is_absolute() or not entry.resolve().is_relative_to(root) or not entry.exists():
                raise ValueError("Sparkle framework contains an unsafe or broken symlink")
        elif not entry.is_file() and not entry.is_dir():
            raise ValueError("Sparkle framework contains an unsupported filesystem entry")
    with (framework / "Resources/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != "org.sparkle-project.Sparkle" or info.get("CFBundleShortVersionString") != SPARKLE_VERSION:
        raise ValueError("Sparkle framework version or identifier does not match the pinned dependency")
    if info.get("CFBundleVersion") != SPARKLE_BUILD:
        raise ValueError("Sparkle framework build version does not match the pinned dependency")
    for relative in ["Sparkle", "Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer",
                     "Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader",
                     "Versions/B/Autoupdate", "Versions/B/Updater.app/Contents/MacOS/Updater"]:
        if not (framework / relative).is_file():
            raise ValueError(f"Sparkle framework is missing required code: {relative}")


def tree_digest(directory):
    """Include names, file modes, bytes and symlink targets, without following links."""
    root = Path(directory)
    digest = hashlib.sha256()
    for entry in sorted(root.rglob("*")):
        relative = entry.relative_to(root).as_posix()
        if entry.is_symlink():
            record = [relative, "link", os.readlink(entry)]
        elif entry.is_file():
            record = [relative, "file", entry.stat().st_mode & 0o777, sha256_file(entry)]
        elif entry.is_dir():
            record = [relative, "directory", entry.stat().st_mode & 0o777]
        else:
            raise ValueError("bundle contains unsupported filesystem entries")
        digest.update((json.dumps(record, separators=(",", ":"), ensure_ascii=False) + "\n").encode())
    return digest.hexdigest()


def locate_sparkle_framework(package):
    """Use this package's resolved remote artifact, never a stale build-dir glob."""
    package = Path(package)
    resolved = json.loads((package / "Package.resolved").read_text())
    pins = [pin for pin in resolved.get("pins", []) if pin.get("identity") == "sparkle"]
    if len(pins) != 1 or pins[0].get("location", "").removesuffix(".git") != SPARKLE_URL or pins[0].get("state") != {"revision": SPARKLE_REVISION, "version": SPARKLE_VERSION}:
        raise ValueError("Sparkle Package.resolved pin does not match the reviewed dependency")
    state = json.loads((package / ".build/workspace-state.json").read_text()).get("object")
    if not isinstance(state, dict):
        raise ValueError("SwiftPM workspace artifact manifest is invalid")
    dependencies = [item for item in state.get("dependencies", []) if item.get("packageRef", {}).get("identity") == "sparkle"]
    if len(dependencies) != 1 or dependencies[0].get("state", {}).get("checkoutState") != pins[0]["state"]:
        raise ValueError("SwiftPM Sparkle checkout does not match Package.resolved")
    artifacts = [item for item in state.get("artifacts", [])
                 if item.get("packageRef", {}).get("identity") == "sparkle" and item.get("targetName") == "Sparkle"]
    if len(artifacts) != 1:
        raise ValueError("SwiftPM did not resolve exactly one Sparkle binary artifact")
    artifact = artifacts[0]
    source = artifact.get("source", {})
    if source.get("url") != SPARKLE_ARCHIVE_URL or source.get("checksum") != SPARKLE_CHECKSUM or source.get("type") != "remote":
        raise ValueError("SwiftPM Sparkle artifact URL/checksum does not match the reviewed dependency")
    if not isinstance(artifact.get("path"), str):
        raise ValueError("SwiftPM Sparkle artifact path is missing")
    artifact_path = Path(artifact["path"])
    if not artifact_path.is_absolute():
        artifact_path = package / ".build" / artifact_path
    if artifact_path.is_symlink() or not artifact_path.resolve().is_relative_to((package / ".build/artifacts").resolve()):
        raise ValueError("SwiftPM Sparkle artifact is outside the package artifact directory")
    with (artifact_path / "Info.plist").open("rb") as file:
        info = plistlib.load(file)
    libraries = [item for item in info.get("AvailableLibraries", []) if item.get("SupportedPlatform") == "macos" and not item.get("SupportedPlatformVariant")]
    if len(libraries) != 1 or libraries[0].get("LibraryPath") != "Sparkle.framework":
        raise ValueError("SwiftPM Sparkle artifact has no unique macOS framework")
    library = libraries[0]
    if not {"arm64", "x86_64"} <= set(library.get("SupportedArchitectures", [])):
        raise ValueError("Sparkle macOS artifact does not support arm64 and x86_64")
    identifier = library.get("LibraryIdentifier")
    if not isinstance(identifier, str) or Path(identifier).name != identifier or identifier in {".", ".."}:
        raise ValueError("Sparkle macOS library identifier is invalid")
    framework = artifact_path / identifier / library["LibraryPath"]
    if not framework.resolve().is_relative_to(artifact_path.resolve()):
        raise ValueError("Sparkle library path escapes the resolved artifact")
    validate_framework_tree(framework)
    return framework


def framework_provenance(package, framework):
    return {"version": SPARKLE_VERSION, "revision": SPARKLE_REVISION,
            "archive_url": SPARKLE_ARCHIVE_URL, "archive_sha256": SPARKLE_CHECKSUM,
            "package_resolved_sha256": sha256_file(Path(package) / "Package.resolved"),
            "source_framework_tree_sha256": tree_digest(framework)}


def sparkle_signing_paths(bundle):
    framework = Path(bundle) / "Contents/Frameworks/Sparkle.framework"
    validate_framework_tree(framework)
    return [framework / "Versions/B/XPCServices/Installer.xpc",
            framework / "Versions/B/XPCServices/Downloader.xpc", framework / "Versions/B/Autoupdate",
            framework / "Versions/B/Updater.app", framework]


# Public spelling also used by release-feed tooling.
read_update_configuration = load_update_configuration
