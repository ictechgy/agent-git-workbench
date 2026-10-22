#!/usr/bin/env python3
"""Export the approved River artwork to PNG and the native macOS icon sizes."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "apps/macos/Resources"
MASTER = RESOURCES / "Brand/River-G-master.png"
SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def main():
    if not MASTER.is_file():
        raise SystemExit(f"Missing approved icon artwork: {MASTER}")
    with tempfile.TemporaryDirectory(prefix="river-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for name, size in SIZES.items():
            subprocess.run(
                ["/usr/bin/sips", "-z", str(size), str(size), str(MASTER),
                 "--out", str(iconset / name)],
                check=True, stdout=subprocess.DEVNULL,
            )
        native_icon = Path(temporary) / "AppIcon.icns"
        subprocess.run(
            ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(native_icon)],
            check=True,
        )
        shutil.copy2(iconset / "icon_512x512@2x.png", RESOURCES / "AppIcon.png")
        shutil.copy2(native_icon, RESOURCES / "AppIcon.icns")
    print(RESOURCES / "AppIcon.png")
    print(RESOURCES / "AppIcon.icns")


if __name__ == "__main__":
    main()
