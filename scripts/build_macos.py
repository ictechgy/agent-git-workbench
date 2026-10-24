#!/usr/bin/env python3
"""Build a native .app bundle using SwiftPM and the bundled Rust engine."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

from sparkle_support import (SPARKLE_LICENSE_SHA256, framework_provenance, load_update_configuration,
                             locate_sparkle_framework, sparkle_signing_paths, tree_digest, update_info)

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


def signature_entitlements(path):
    result = subprocess.run(["/usr/bin/codesign", "--display", "--entitlements", ":-", str(path)],
                            check=True, capture_output=True)
    if not result.stdout:
        return {}
    entitlements = plistlib.loads(result.stdout)
    if not isinstance(entitlements, dict):
        raise ValueError("code signature entitlements must be a dictionary")
    return entitlements


def signed_code_paths(bundle):
    return [*sparkle_signing_paths(bundle), bundle / "Contents/Helpers/workbench", bundle]


def verify_signature(bundle):
    for path in signed_code_paths(bundle):
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(path)], check=True)


def signing_metadata(bundle):
    paths = signed_code_paths(bundle)
    signatures = [signature_details(path) for path in paths]
    if all(details.get("Signature") == ["adhoc"] for details in signatures):
        return {"kind": "ad-hoc", "team_identifier": None}
    teams = []
    for path, details in zip(paths, signatures):
        if not any(authority.startswith("Developer ID Application:")
                   for authority in details.get("Authority", [])):
            raise ValueError("all nested code requires a Developer ID Application identity")
        if not any("(runtime)" in value for value in details.get("CodeDirectory v", [])):
            raise ValueError("Developer ID signature is missing hardened runtime")
        if "Timestamp" not in details:
            raise ValueError("Developer ID signature is missing a secure timestamp")
        entitlements = signature_entitlements(path)
        if entitlements.get("com.apple.security.cs.disable-library-validation"):
            raise ValueError("distribution signatures must retain library validation")
        teams.append(details.get("TeamIdentifier", [None])[0])
    if not teams[0] or teams[0] == "not set" or len(set(teams)) != 1:
        raise ValueError("app, engine and Sparkle signing teams differ")
    return {"kind": "developer-id", "team_identifier": teams[0]}


def verify_original_framework(framework):
    # Validate the upstream sealed framework before replacing its signatures.
    subprocess.run(["/usr/bin/codesign", "--verify", "--strict", "--deep", str(framework)], check=True)


def sign_bundle(bundle, identity):
    # Preserve Sparkle's existing entitlements. Sign each nested object
    # explicitly inside out; --deep signing obscures nested signing failures.
    options = [] if identity == "-" else ["--options", "runtime", "--timestamp"]
    paths = signed_code_paths(bundle)
    original_entitlements = {path: signature_entitlements(path) for path in paths[:-2]}
    for path in paths:
        preserve = ["--preserve-metadata=entitlements"] if path in paths[:-2] else []
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", identity, *options,
                        *preserve, str(path)], check=True)
        if path in original_entitlements and signature_entitlements(path) != original_entitlements[path]:
            raise ValueError("Sparkle nested code entitlements were not preserved")
    verify_signature(bundle)
    if identity != "-":
        signing_metadata(bundle)


def verify_sparkle_linkage(executable):
    libraries = subprocess.check_output(["/usr/bin/otool", "-L", str(executable)], text=True)
    sparkle = [line.strip().split(" (", 1)[0] for line in libraries.splitlines()
               if "Sparkle.framework/" in line]
    if sparkle != ["@rpath/Sparkle.framework/Versions/B/Sparkle"]:
        raise ValueError("app must link exactly the embedded Sparkle framework via @rpath")
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(executable)], text=True)
    if not re.search(r"cmd LC_RPATH\s+cmdsize \d+\s+path @executable_path/\.\./Frameworks \(offset", commands):
        raise ValueError("app is missing its explicit embedded-framework runtime search path")


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
                    "--product", APP_EXECUTABLE, "--disable-automatic-resolution",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                   cwd=ROOT, check=True)
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
    config_path = package / "Resources/UpdateConfiguration.json"
    config = load_update_configuration(config_path)
    framework = locate_sparkle_framework(package)
    destination = bundle / "Contents/Frameworks/Sparkle.framework"
    destination.parent.mkdir(parents=True, exist_ok=True)
    license_path = framework.parents[2] / "LICENSE"
    if license_path.is_symlink() or not license_path.is_file():
        raise ValueError("Sparkle artifact is missing its license")
    license_bytes = license_path.read_bytes()
    if hashlib.sha256(license_bytes).hexdigest() != SPARKLE_LICENSE_SHA256:
        raise ValueError("Sparkle license does not match the pinned artifact")
    (resources / "Sparkle-LICENSE.txt").write_bytes(license_bytes)
    provenance = framework_provenance(package, framework)
    provenance["license_sha256"] = hashlib.sha256(license_bytes).hexdigest()
    shutil.copytree(framework, destination, symlinks=True)
    if tree_digest(destination) != provenance["source_framework_tree_sha256"]:
        raise ValueError("Sparkle framework changed while being copied")
    verify_original_framework(destination)
    shutil.copy2(config_path, resources / "UpdateConfiguration.json")
    (resources / "SparkleProvenance.json").write_text(
        json.dumps(provenance, indent=2) + "\n", encoding="utf-8")
    verify_sparkle_linkage(executable / APP_EXECUTABLE)
    info = {"CFBundleExecutable": APP_EXECUTABLE, "CFBundleIdentifier": APP_IDENTIFIER,
            "CFBundleName": "River", "CFBundleDisplayName": "River",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication"}
    info.update(metadata)
    info.update(update_info(config))
    info["RiverBuildConfiguration"] = configuration
    with (bundle / "Contents/Info.plist").open("wb") as target:
        plistlib.dump(info, target)
    sign_bundle(bundle, identity)


if __name__ == "__main__":
    main()
