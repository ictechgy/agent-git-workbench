#!/usr/bin/env python3
"""Fixed-input adapter for the synthetic FixtureApp / Debug xcconfig only.

This is not a parser for arbitrary Xcode projects or inherited xcconfig files.
The Rust runner independently checks the declared file scope and final values.
"""
import json
import os
from pathlib import Path
import re
import sys
import tempfile

# FIXTURE_GATE

def main():
    if sys.argv[1:] != ["--input-json-stdin"]:
        raise SystemExit("expected --input-json-stdin")
    data = json.load(sys.stdin)
    if set(data) != {"marketing_version", "local_build"}:
        raise SystemExit("unexpected input fields")
    version, build = data["marketing_version"], data["local_build"]
    if not isinstance(version, str) or not re.fullmatch(r"[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}", version):
        raise SystemExit("invalid version")
    if not isinstance(build, str) or not re.fullmatch(r"[0-9]{1,9}", build):
        raise SystemExit("invalid build")
    path = Path("Config/Version.xcconfig")
    if path.is_symlink() or path.parent.is_symlink():
        raise SystemExit("symlink is unsupported")
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    replacements = {"MARKETING_VERSION": version, "CURRENT_PROJECT_VERSION": build}
    counts = dict.fromkeys(replacements, 0)
    result = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            result.append(line)
            continue
        key, sep, _ = line.partition("=")
        key = key.strip()
        if not sep or key not in replacements:
            raise SystemExit("unsupported xcconfig")
        counts[key] += 1
        result.append(f"{key} = {replacements[key]}\n")
    if any(count != 1 for count in counts.values()):
        raise SystemExit("ambiguous or missing key")
    # A cancelled write must leave either the old complete file or the new one.
    # A SIGKILL can leave the temporary file as recovery evidence, never a truncated target.
    descriptor, temporary = tempfile.mkstemp(prefix=".workbench-version-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as target:
            os.fchmod(target.fileno(), path.stat().st_mode & 0o777)
            target.write("".join(result))
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps({"target": "FixtureApp", "configuration": "Debug", **data}))

if __name__ == "__main__":
    main()
