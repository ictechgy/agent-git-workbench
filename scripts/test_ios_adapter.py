#!/usr/bin/env python3
"""Deterministic interruption probes; only fresh synthetic xcconfig files."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "ios_adapter", Path(__file__).resolve().parents[1] / "adapters/ios-version/set_ios_version.py")
ADAPTER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ADAPTER)
INPUT = {"marketing_version": "2.4.0", "local_build": "241"}


class AtomicAdapterTests(unittest.TestCase):
    def test_interruption_boundaries_preserve_complete_target_and_allow_retry(self):
        for boundary in ("before", "after", "none"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as folder:
                original_directory = Path.cwd()
                try:
                    os.chdir(folder)
                    Path("Config").mkdir()
                    target = Path("Config/Version.xcconfig")
                    original = "// 한글 주석\nMARKETING_VERSION = 1.0.0\nCURRENT_PROJECT_VERSION = 1\n"
                    expected = "// 한글 주석\nMARKETING_VERSION = 2.4.0\nCURRENT_PROJECT_VERSION = 241\n"
                    target.write_text(original, encoding="utf-8")
                    target.chmod(0o644)
                    real_replace = os.replace

                    def interrupt(source, destination):
                        self.assertEqual(target.read_text(encoding="utf-8"), original)
                        self.assertEqual(Path(source).read_text(encoding="utf-8"), expected)
                        if boundary == "before":
                            raise InterruptedError("synthetic interruption before replacement")
                        real_replace(source, destination)
                        if boundary == "after":
                            raise InterruptedError("synthetic interruption after replacement")

                    with patch("sys.argv", ["adapter", "--input-json-stdin"]), \
                            patch("sys.stdin", io.StringIO(json.dumps(INPUT))), \
                            patch.object(ADAPTER.os, "replace", interrupt), \
                            contextlib.redirect_stdout(io.StringIO()):
                        if boundary == "none":
                            ADAPTER.main()
                        else:
                            with self.assertRaises(InterruptedError):
                                ADAPTER.main()
                    self.assertEqual(target.read_text(encoding="utf-8"), original if boundary == "before" else expected)
                    self.assertEqual(list(Path("Config").glob(".workbench-version-*")), [])
                    with patch("sys.argv", ["adapter", "--input-json-stdin"]), \
                            patch("sys.stdin", io.StringIO(json.dumps(INPUT))), \
                            contextlib.redirect_stdout(io.StringIO()):
                        ADAPTER.main()
                    self.assertEqual(target.read_text(encoding="utf-8"), expected)
                    self.assertEqual(target.stat().st_mode & 0o777, 0o644)
                finally:
                    os.chdir(original_directory)


if __name__ == "__main__":
    unittest.main()
