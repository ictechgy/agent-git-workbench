#!/usr/bin/env python3
"""Build a local native .app bundle using SwiftPM. No installer, notarization or upload."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--configuration", choices=["debug", "release"], default="debug")
    args = parser.parse_args()
    cargo_args = ["cargo", "build", "-p", "workbench-cli"]
    if args.configuration == "release":
        cargo_args.append("--release")
    subprocess.run(cargo_args, cwd=ROOT, check=True)
    package = ROOT / "apps/macos"
    subprocess.run(["swift", "build", "--package-path", str(package), "-c", args.configuration,
                    "--product", "AgentGitWorkbench"], check=True)
    binary_dir = Path(subprocess.check_output(["swift", "build", "--package-path", str(package),
                    "-c", args.configuration, "--show-bin-path"], text=True).strip())
    bundle = ROOT / "build/macos/Agent Git Workbench.app"
    executable = bundle / "Contents/MacOS"
    resources = bundle / "Contents/Resources"
    helpers = bundle / "Contents/Helpers"
    executable.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    helpers.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "target" / args.configuration / "workbench", helpers / "workbench")
    shutil.copy2(binary_dir / "AgentGitWorkbench", executable / "AgentGitWorkbench")
    icon = package / "Resources/AppIcon.icns"
    if icon.exists():
        shutil.copy2(icon, resources / "AppIcon.icns")
    info = {"CFBundleExecutable": "AgentGitWorkbench", "CFBundleIdentifier": "dev.workbench.AgentGitWorkbench",
            "CFBundleName": "Agent Git Workbench", "CFBundleDisplayName": "Agent Git Workbench",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1",
            "CFBundleIconFile": "AppIcon", "LSMinimumSystemVersion": "14.0", "NSHighResolutionCapable": True,
            "NSPrincipalClass": "NSApplication"}
    with (bundle / "Contents/Info.plist").open("wb") as target:
        plistlib.dump(info, target)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(helpers / "workbench")], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(bundle)], check=True)
    print(bundle)


if __name__ == "__main__":
    main()
