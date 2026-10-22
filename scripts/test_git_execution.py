#!/usr/bin/env python3
"""Check fixture bootstrap against an isolated synthetic Git global configuration."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class GitExecutionBoundaryTests(unittest.TestCase):
    def test_global_clean_filter_cannot_execute_during_fixture_creation(self):
        with tempfile.TemporaryDirectory(prefix="agw-config-", dir="/tmp") as temporary:
            base = Path(temporary)
            test_profile = base / "synthetic-profile"
            test_profile.mkdir()
            marker = base / "filter-executed"
            program = base / "filter-program"
            program.write_text(f"#!/bin/sh\ntouch '{marker}'\ncat\n")
            program.chmod(0o755)
            attributes = base / "attributes"
            attributes.write_text("* filter=untrusted\n")
            (test_profile / ".gitconfig").write_text(
                f'[core]\n attributesFile = {attributes}\n[filter "untrusted"]\n clean = {program}\n')
            # This child has only a synthetic profile; the current process and
            # actual user settings/environment are neither read nor changed.
            environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                           "HOME": str(test_profile), "XDG_CONFIG_HOME": str(base / "xdg"),
                           "LANG": "en_US.UTF-8"}
            result = subprocess.run([str(ROOT / "target/debug/workbench"), "fixture", str(base / "fixture")],
                                    env=environment, capture_output=True, timeout=10, check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(result.stderr)["error"]["code"], "unsupported_external_filter")
            self.assertFalse(marker.exists(), "fixture ran a global filter before recipe trust")


if __name__ == "__main__":
    unittest.main()
