#!/usr/bin/env python3
"""Build a native .app bundle using SwiftPM and the bundled Rust engine."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_IDENTIFIER = "dev.workbench.AgentGitWorkbench"
APP_EXECUTABLE = "AgentGitWorkbench"


def version_metadata(version, build_number):
    """Keep the user-facing SemVer separate from Apple's numeric version."""
    match = re.fullmatch(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
                         r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
                         r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?", version)
    if not match or (match[4] and any(part.isdigit() and len(part) > 1 and part[0] == "0"
                                    for part in match[4].split("."))):
        raise ValueError("version must be SemVer, for example 0.1.0-alpha.1")
    if not re.fullmatch(r"[1-9]\d*", str(build_number)):
        raise ValueError("build number must be a positive integer")
    return {"CFBundleShortVersionString": ".".join(match.groups()[:3]),
            "CFBundleVersion": str(build_number), "RiverReleaseVersion": version}


def signature_details(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", "--verbose=4", str(path)],
                            check=True, capture_output=True, text=True)
    details = {}
    for line in result.stderr.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            details.setdefault(key, []).append(value)
    return details


def verify_signature(bundle):
    for path in [bundle / "Contents/Helpers/workbench", bundle]:
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(path)], check=True)


def sign_bundle(bundle, identity):
    # Sign inside out; --deep signing can conceal incorrectly signed nested code.
    options = [] if identity == "-" else ["--options", "runtime", "--timestamp"]
    for path in [bundle / "Contents/Helpers/workbench", bundle]:
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, *options, str(path)],
                       check=True)
    verify_signature(bundle)
    if identity != "-":
        for path in [bundle / "Contents/Helpers/workbench", bundle]:
            details = signature_details(path)
            if not any(authority.startswith("Developer ID Application:")
                       for authority in details.get("Authority", [])):
                raise ValueError("distribution signing requires a Developer ID Application identity")
            if not any("(runtime)" in value for value in details.get("CodeDirectory v", [])):
                raise ValueError("Developer ID signature is missing hardened runtime")
            if "Timestamp" not in details:
                raise ValueError("Developer ID signature is missing a secure timestamp")


def build_engine(configuration):
    # Cargo owns artifact layout (target-dir and target-triple may be configured).
    # Use the executable from this invocation, never an older default target path.
    argv = ["cargo", "build", "-p", "workbench-cli", "--bin", "workbench",
            "--message-format=json-render-diagnostics"]
    if configuration == "release":
        argv.extend(["--release", "--locked"])
    result = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, text=True)
    executables = set()
    for line in result.stdout.splitlines():
        message = json.loads(line)
        if message.get("reason") == "compiler-message":
            rendered = message.get("message", {}).get("rendered")
            if rendered:
                print(rendered, end="", file=sys.stderr)
        target = message.get("target", {})
        if (message.get("reason") == "compiler-artifact" and target.get("name") == "workbench"
                and "bin" in target.get("kind", []) and message.get("executable")):
            executables.add(Path(message["executable"]))
    result.check_returncode()
    if len(executables) != 1:
        raise ValueError("Cargo did not report exactly one workbench executable")
    executable = executables.pop()
    if not executable.is_absolute():
        executable = ROOT / executable
    if not executable.is_file():
        raise ValueError("Cargo reported a missing workbench executable")
    return executable


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--build-number", default="1")
    parser.add_argument("--output", type=Path, default=ROOT / "build/macos/River.app")
    parser.add_argument("--sign-identity", default="-", help="codesign identity; '-' is ad-hoc (default)")
    args = parser.parse_args()
    try:
        metadata = version_metadata(args.version, args.build_number)
    except ValueError as error:
        parser.error(str(error))
    bundle = args.output.expanduser().absolute()
    if bundle.suffix != ".app" or bundle.is_symlink():
        parser.error("--output must be a .app directory, not a symlink")
    engine = build_engine(args.configuration)
    package = ROOT / "apps/macos"
    subprocess.run(["swift", "build", "--package-path", str(package), "-c", args.configuration,
                    "--product", APP_EXECUTABLE], cwd=ROOT, check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--package-path", str(package),
                    "-c", args.configuration, "--show-bin-path"], cwd=ROOT, text=True).strip())
    bundle.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="river-build-", dir=bundle.parent) as temporary:
        staged = Path(temporary) / "River.app"
        assemble_bundle(staged, binary_dir, engine, package, args.configuration, metadata, args.sign_identity)
        if bundle.exists():
            shutil.rmtree(bundle)
        staged.rename(bundle)
    print(bundle)


def assemble_bundle(bundle, binary_dir, engine, package, configuration, metadata, identity):
    executable = bundle / "Contents/MacOS"
    resources = bundle / "Contents/Resources"
    helpers = bundle / "Contents/Helpers"
    executable.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    helpers.mkdir(parents=True, exist_ok=True)
    shutil.copy2(engine, helpers / "workbench")
    shutil.copy2(binary_dir / APP_EXECUTABLE, executable / APP_EXECUTABLE)
    icon = package / "Resources/AppIcon.icns"
    if configuration == "release" and not icon.is_file():
        raise ValueError("release bundle requires Resources/AppIcon.icns")
    if icon.exists():
        shutil.copy2(icon, resources / "AppIcon.icns")
    info = {"CFBundleExecutable": APP_EXECUTABLE, "CFBundleIdentifier": APP_IDENTIFIER,
            "CFBundleName": "River", "CFBundleDisplayName": "River",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication"}
    info.update(metadata)
    info["RiverBuildConfiguration"] = configuration
    with (bundle / "Contents/Info.plist").open("wb") as target:
        plistlib.dump(info, target)
    sign_bundle(bundle, identity)


if __name__ == "__main__":
    main()
