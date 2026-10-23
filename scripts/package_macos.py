#!/usr/bin/env python3
"""Build and verify a release DMG; credentials stay in a notarytool Keychain profile."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

from build_macos import (APP_EXECUTABLE, APP_IDENTIFIER, ROOT, signature_details,
                         verify_signature, version_metadata)


INSTALL_README = """River — Install / 설치

English
1. Drag River.app to Applications.
2. Eject this disk image, then open River from Applications.
Requires macOS 14 or later. This is an early alpha release.
Apple command-line Git is required. Check it with /usr/bin/git --version.
If Git is unavailable, run xcode-select --install in Terminal to install Apple's
Command Line Tools. Full Xcode is not required to use River.
The built-in example also requires python3 for its preparation recipes.
Command Line Tools: https://developer.apple.com/documentation/xcode/installing-the-command-line-tools

한국어
1. River.app을 Applications 폴더로 드래그하세요.
2. 이 디스크 이미지를 추출한 뒤 응용 프로그램 폴더에서 River를 여세요.
macOS 14 이상이 필요합니다. 초기 알파 릴리스입니다.
Apple 명령줄 Git이 필요합니다. /usr/bin/git --version으로 확인하세요.
Git을 사용할 수 없으면 터미널에서 xcode-select --install을 실행해 Apple의
Command Line Tools를 설치하세요. River 사용에 전체 Xcode는 필요하지 않습니다.
앱의 기본 예제는 준비 레시피를 실행할 때 python3도 필요합니다.
Command Line Tools 안내: https://developer.apple.com/documentation/xcode/installing-the-command-line-tools

Signing / 서명: {signing}
{gatekeeper}
"""


def run(*argv, **kwargs):
    return subprocess.run(list(map(str, argv)), check=True, **kwargs)


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@contextmanager
def output_lock(output):
    # Keep this file: unlinking a locked inode would let a new process bypass it.
    with (output / ".river-package.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("another packager is using this --output-dir") from None
        try:
            yield
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


def source_snapshot(root=None):
    root = ROOT if root is None else root
    head = run("git", "rev-parse", "HEAD", cwd=root, capture_output=True, text=True).stdout.strip()
    status = run("git", "status", "--porcelain=v1", "-z", "--untracked-files=no", cwd=root,
                 capture_output=True).stdout
    patch = run("git", "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD", "--",
                cwd=root, capture_output=True).stdout
    # Include ignored files here too: an ignored Swift/Rust file can still enter a build.
    untracked = run("git", "ls-files", "--others", "-z", "--", "apps/macos/Sources", "crates",
                    cwd=root, capture_output=True).stdout
    if run("git", "rev-parse", "HEAD", cwd=root,
           capture_output=True, text=True).stdout.strip() != head:
        raise ValueError("source HEAD changed while capturing build provenance")
    return {"kind": "clean-git-build", "git_commit": head, "tracked_status": os.fsdecode(status),
            "tracked_patch_sha256": hashlib.sha256(patch).hexdigest(),
            "untracked_runtime_files": [os.fsdecode(path) for path in untracked.split(b"\0") if path]}


def clean_source_snapshot(root=None):
    initial = source_snapshot(root)
    if initial["tracked_status"]:
        raise ValueError("release packaging requires a clean tracked source tree; commit changes first")
    if initial["untracked_runtime_files"]:
        raise ValueError("release packaging requires tracked runtime files under apps/macos/Sources and crates")
    return initial


def verify_source_unchanged(initial, root=None):
    if source_snapshot(root) != initial:
        raise ValueError("source changed during packaging; no release artifacts were published")


def architectures(path):
    result = run("/usr/bin/lipo", "-archs", path, capture_output=True, text=True)
    values = set(result.stdout.split())
    if not values or not values <= {"arm64", "x86_64"}:
        raise ValueError(f"unsupported binary architecture: {sorted(values)}")
    return values


def bundle_metadata(bundle, expected=None):
    with (bundle / "Contents/Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundleIdentifier") != APP_IDENTIFIER or info.get("CFBundleExecutable") != APP_EXECUTABLE:
        raise ValueError("unexpected app identifier or executable")
    if info.get("RiverBuildConfiguration") != "release":
        raise ValueError("DMG packaging requires a release bundle")
    version = version_metadata(info.get("RiverReleaseVersion", ""), info.get("CFBundleVersion", ""))
    if any(info.get(key) != value for key, value in version.items()):
        raise ValueError("app version metadata is inconsistent")
    if expected and any(info.get(key) != value for key, value in expected.items()):
        raise ValueError("app version/build does not match requested release")
    executable = bundle / "Contents/MacOS" / APP_EXECUTABLE
    helper = bundle / "Contents/Helpers/workbench"
    app_archs, helper_archs = architectures(executable), architectures(helper)
    if app_archs != helper_archs:
        raise ValueError("app and bundled helper architectures differ")
    verify_signature(bundle)
    signatures = [signature_details(path) for path in [helper, bundle]]
    if all(details.get("Signature") == ["adhoc"] for details in signatures):
        signing = {"kind": "ad-hoc", "team_identifier": None}
    else:
        for details in signatures:
            if not any(authority.startswith("Developer ID Application:")
                       for authority in details.get("Authority", [])):
                raise ValueError("app and helper must both use ad-hoc or Developer ID Application signatures")
            if not any("(runtime)" in value for value in details.get("CodeDirectory v", [])):
                raise ValueError("Developer ID signature is missing hardened runtime")
            if "Timestamp" not in details:
                raise ValueError("Developer ID signature is missing a secure timestamp")
        teams = [details.get("TeamIdentifier", [None])[0] for details in signatures]
        if not teams[0] or teams[0] == "not set" or teams[0] != teams[1]:
            raise ValueError("app and helper signing teams differ")
        signing = {"kind": "developer-id", "team_identifier": teams[0]}
    return {"version": info["RiverReleaseVersion"], "short_version": info["CFBundleShortVersionString"],
            "build_number": info["CFBundleVersion"], "configuration": "release",
            "bundle_identifier": APP_IDENTIFIER, "executable": APP_EXECUTABLE,
            "minimum_macos": info.get("LSMinimumSystemVersion"),
            "architecture": "universal2" if len(app_archs) == 2 else next(iter(app_archs)),
            "architectures": sorted(app_archs), "signing": signing,
            "executable_sha256": sha256(executable), "helper_sha256": sha256(helper)}


def verify_dmg(dmg, expected=None):
    """Validate the actual mounted payload and its copy, as a Finder install would."""
    run("/usr/bin/hdiutil", "verify", dmg)
    image_info = plistlib.loads(run("/usr/bin/hdiutil", "imageinfo", "-plist", dmg,
                                   capture_output=True).stdout)
    if image_info.get("Format") != "UDZO":
        raise ValueError("release disk image must use UDZO compression")
    try:
        signature_details(dmg)
    except subprocess.CalledProcessError as error:
        if "code object is not signed at all" not in (error.stderr or ""):
            raise
    else:
        run("/usr/bin/codesign", "--verify", "--strict", dmg)
    with tempfile.TemporaryDirectory(prefix="river-dmg-verify-") as temporary:
        directory = Path(temporary)
        mount = directory / "mounted"
        mount.mkdir()
        attached = False
        try:
            run("/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", mount,
                "-plist", dmg, capture_output=True)
            attached = True
            applications = mount / "Applications"
            if not applications.is_symlink() or os.readlink(applications) != "/Applications":
                raise ValueError("DMG is missing its Applications installation link")
            readme = (mount / "READ ME - INSTALL.txt").read_text(encoding="utf-8")
            if "English" not in readme or "한국어" not in readme:
                raise ValueError("DMG is missing bilingual installation instructions")
            copied = directory / "installed/River.app"
            run("/usr/bin/ditto", mount / "River.app", copied)
            metadata = bundle_metadata(copied)
            if expected and metadata != expected:
                raise ValueError("mounted/copied app differs from the packaged release bundle")
            return metadata
        finally:
            if attached:
                run("/usr/bin/hdiutil", "detach", mount)


def notarize(dmg, profile):
    # Do not echo argv, profile data, credential errors, or raw notary responses.
    result = subprocess.run(["/usr/bin/xcrun", "notarytool", "submit", str(dmg),
                             "--keychain-profile", profile, "--wait", "--timeout", "30m",
                             "--output-format", "json"], capture_output=True, text=True)
    if result.returncode:
        raise ValueError("notarytool submission failed; no release artifacts were published")
    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise ValueError("notarytool returned an invalid report") from error
    if report.get("status") != "Accepted" or not report.get("id"):
        raise ValueError("notarization was not accepted; no release artifacts were published")
    for operation in ["staple", "validate"]:
        result = subprocess.run(["/usr/bin/xcrun", "stapler", operation, str(dmg)],
                                capture_output=True, text=True)
        if result.returncode:
            raise ValueError(f"notarization ticket {operation} failed; no release artifacts were published")
    run("/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
    return {"status": "accepted", "submission_id": report["id"], "stapled": True}


def verify_distribution_image_signature(dmg, team_identifier):
    run("/usr/bin/codesign", "--verify", "--strict", dmg)
    details = signature_details(dmg)
    if not any(authority.startswith("Developer ID Application:")
               for authority in details.get("Authority", [])):
        raise ValueError("disk image requires a Developer ID Application signature")
    if "Timestamp" not in details:
        raise ValueError("disk image signature is missing a secure timestamp")
    if details.get("TeamIdentifier") != [team_identifier]:
        raise ValueError("disk image and app signing teams differ")


def package(args):
    expected = version_metadata(args.version, args.build_number)
    if args.notary_profile and (not args.sign_identity or args.sign_identity == "-"):
        raise ValueError("--notary-profile requires --sign-identity with a Developer ID Application identity")
    output = args.output_dir.expanduser().resolve()
    output.mkdir(parents=True, exist_ok=True)
    with output_lock(output):
        package_locked(args, output, expected)


def package_locked(args, output, expected):
    initial_source = clean_source_snapshot() if not args.app else {"kind": "provided-app"}
    with tempfile.TemporaryDirectory(prefix=".river-release-", dir=output) as temporary:
        workspace = Path(temporary)
        staging = workspace / "payload"
        staging.mkdir()
        app = staging / "River.app"
        if args.app:
            source_app = args.app.expanduser().resolve()
            run("/usr/bin/ditto", source_app, app)
        else:
            run(sys.executable, ROOT / "scripts/build_macos.py", "--configuration", "release",
                "--version", args.version, "--build-number", args.build_number,
                "--output", app, "--sign-identity", args.sign_identity or "-", cwd=ROOT)
        metadata = bundle_metadata(app, expected)
        developer_id = metadata["signing"]["kind"] == "developer-id"
        if args.sign_identity not in (None, "-") and not developer_id:
            raise ValueError("requested Developer ID signing requires a Developer ID signed app and helper")
        if args.notary_profile and not developer_id:
            raise ValueError("notarization requires a Developer ID signed app and helper")
        basename = f"River-{args.version}-macos-{metadata['architecture']}"
        names = [basename + ".dmg", basename + ".dmg.sha256", basename + ".manifest.json"]
        if any((output / name).exists() for name in names):
            raise ValueError("release artifacts already exist; choose a new --output-dir or version")
        (staging / "Applications").symlink_to("/Applications", target_is_directory=True)
        gatekeeper = ("This image is notarized by Apple. / Apple 공증을 받은 이미지입니다."
                      if args.notary_profile else
                      "This image is not notarized by Apple. macOS may block opening this alpha.\n"
                      "If you trust this download, attempt to open River, then use\n"
                      "System Settings > Privacy & Security > Open Anyway and confirm Open.\n"
                      "Apple 공증을 받지 않은 이미지입니다. macOS가 이 알파 앱 실행을 차단할 수 있습니다.\n"
                      "다운로드 출처를 신뢰한다면 River 실행을 한 번 시도한 뒤\n"
                      "시스템 설정 > 개인정보 보호 및 보안 > 확인 없이 열기(Open Anyway)에서 허용하고\n"
                      "열기를 확인하세요.\n"
                      "Apple's guide / Apple 안내: https://support.apple.com/en-us/102445")
        (staging / "READ ME - INSTALL.txt").write_text(INSTALL_README.format(
            signing="Developer ID" if developer_id else "ad-hoc / 임시 서명", gatekeeper=gatekeeper),
            encoding="utf-8")
        dmg = workspace / names[0]
        run("/usr/bin/hdiutil", "create", "-volname", "River", "-srcfolder", staging,
            "-format", "UDZO", "-fs", "HFS+", dmg)
        if developer_id and args.sign_identity:
            run("/usr/bin/codesign", "--force", "--sign", args.sign_identity, "--timestamp", dmg)
            verify_distribution_image_signature(dmg, metadata["signing"]["team_identifier"])
        notarization = {"status": "not-requested", "stapled": False}
        if args.notary_profile:
            notarization = notarize(dmg, args.notary_profile)
        verified = verify_dmg(dmg, metadata)
        checksum = sha256(dmg)
        manifest = {"schema_version": 1, "product": "River", "app": verified,
                    "disk_image": {"filename": names[0], "format": "UDZO", "sha256": checksum,
                                   "size_bytes": dmg.stat().st_size,
                                   "signing": "developer-id" if developer_id and args.sign_identity else "unsigned",
                                   "mount_copy_verified": True}, "notarization": notarization,
                    "source_provenance": initial_source}
        if not args.app:
            manifest["source_git_commit"] = initial_source["git_commit"]
            manifest["source_tracked_dirty"] = False
        (workspace / names[1]).write_text(f"{checksum}  {names[0]}\n", encoding="utf-8")
        (workspace / names[2]).write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n",
                                          encoding="utf-8")
        if not args.app:
            verify_source_unchanged(initial_source)
        for name in names:
            (workspace / name).rename(output / name)
    for name in names:
        print(output / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", default="0.1.0-alpha.1")
    parser.add_argument("--build-number", default="2")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "dist")
    parser.add_argument("--app", type=Path, help="package an existing release bundle; preserve its signature")
    parser.add_argument("--sign-identity", help="Developer ID Application identity; default is ad-hoc")
    parser.add_argument("--notary-profile", help="existing notarytool Keychain profile (requires Developer ID)")
    parser.add_argument("--verify-dmg", type=Path, help="only verify and mount/copy an existing DMG")
    args = parser.parse_args()
    try:
        if args.verify_dmg:
            print(json.dumps(verify_dmg(args.verify_dmg.expanduser().resolve()), indent=2))
        else:
            package(args)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
