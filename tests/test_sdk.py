"""Offline contract tests. Synthetic SDK archives do not prove real SDK support."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / "actions/setup-flutter/sdk.py"
spec = importlib.util.spec_from_file_location("sdk", SOURCE)
sdk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sdk)


class SDKTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.release = {"flutter-version": "1.2.3", "dart-version": "4.5.6", "sha256": "a" * 64}
        (self.root / ".fvmrc").write_text('{"flutter":"1.2.3"}')
        self.manifest({"releases": {"1.2.3": {"dart": "4.5.6", "sha256": "a" * 64}}})

    def manifest(self, value):
        (self.root / "releases.json").write_text(json.dumps(value))

    def resolve(self):
        return sdk.resolve_release(self.root, ".fvmrc", "releases.json")

    def archive(self, extra=None, dart="4.5.6", flutter="1.2.3"):
        archive = self.root / "flutter.tar.xz"
        files = {
            "flutter/bin/cache/dart-sdk/bin/dart": f"#!/bin/sh\nprintf 'Dart SDK version: {dart} (stable)\\n'\n",
            "flutter/bin/flutter": f"#!/bin/sh\nprintf 'Flutter {flutter} stable\\n'\n",
        }
        with tarfile.open(archive, "w:xz") as tar:
            for name, text in files.items():
                data = text.encode()
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), 0o755
                tar.addfile(info, io.BytesIO(data))
            if extra:
                tar.addfile(extra)
        self.release["sha256"] = hashlib.sha256(archive.read_bytes()).hexdigest()
        return archive

    def test_resolves_exact_versions(self):
        self.assertEqual(self.resolve(), self.release)

    def test_rejects_floating_partial_and_shell_versions(self):
        for value in ("stable", "3.44", "3.44.0; echo unsafe", "3.44.0\n", "3.44.0-beta.1", 344, None):
            with self.subTest(value=value), self.assertRaises(ValueError):
                sdk.exact_version(value)

    def test_requires_known_release(self):
        self.manifest({"releases": {}})
        with self.assertRaisesRegex(ValueError, "reviewed release"):
            self.resolve()

    def test_requires_digest(self):
        self.manifest({"releases": {"1.2.3": {"dart": "4.5.6"}}})
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            self.resolve()

    def test_requires_exact_bundled_dart(self):
        self.manifest({"releases": {"1.2.3": {"dart": "stable", "sha256": "a" * 64}}})
        with self.assertRaises(ValueError):
            self.resolve()

    def test_rejects_path_escape(self):
        for path in ("../.fvmrc", str(self.root / ".fvmrc")):
            with self.subTest(path=path), self.assertRaises(ValueError):
                sdk.checked_file(self.root, path)

    def test_rejects_symlink_escape(self):
        with tempfile.TemporaryDirectory() as outside:
            file = Path(outside) / "file"
            file.write_text("{}"); (self.root / "link").symlink_to(file)
            with self.assertRaises(ValueError):
                sdk.checked_file(self.root, "link")

    def test_rejects_invalid_json(self):
        (self.root / ".fvmrc").write_text("not json")
        with self.assertRaises(ValueError):
            self.resolve()

    def test_command_file_injection_writes_nothing(self):
        output = self.root / "out"
        with self.assertRaises(ValueError):
            sdk.emit(str(output), {"good": "ok", "bad": "line\nINJECTED=true"})
        self.assertFalse(output.exists())

    def test_verifies_valid_archive_and_sdk(self):
        installed = sdk.install_archive(self.archive(), self.release, self.root / "install")
        self.assertTrue((installed / "bin/flutter").is_file())

    def test_checksum_failure_precedes_execution(self):
        archive = self.archive(); archive.write_bytes(archive.read_bytes() + b"corrupt")
        with patch.object(sdk.subprocess, "run") as execute:
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                sdk.install_archive(archive, self.release, self.root / "install")
        execute.assert_not_called()

    def test_cached_archive_is_reverified(self):
        archive = self.archive()
        sdk.verify_archive(archive, self.release["sha256"])
        archive.write_bytes(b"changed cache")
        with self.assertRaises(ValueError):
            sdk.verify_archive(archive, self.release["sha256"])

    def test_wrong_dart_version_removes_install(self):
        archive = self.archive(dart="4.5.60")
        with self.assertRaisesRegex(ValueError, "version does not match"):
            sdk.install_archive(archive, self.release, self.root / "install")
        self.assertEqual(list((self.root / "install").iterdir()), [])

    def test_wrong_flutter_version_removes_install(self):
        archive = self.archive(flutter="1.2.30")
        with self.assertRaises(ValueError):
            sdk.install_archive(archive, self.release, self.root / "install")
        self.assertEqual(list((self.root / "install").iterdir()), [])

    def test_archive_traversal_is_rejected(self):
        archive = self.archive(tarfile.TarInfo("flutter/../../escaped"))
        with self.assertRaises((ValueError, tarfile.TarError)):
            sdk.install_archive(archive, self.release, self.root / "install")
        self.assertFalse((self.root / "escaped").exists())

    def test_external_symlink_is_rejected(self):
        link = tarfile.TarInfo("flutter/escape")
        link.type, link.linkname = tarfile.SYMTYPE, "/tmp"
        with self.assertRaises(tarfile.TarError):
            sdk.install_archive(self.archive(link), self.release, self.root / "install")

    def test_unexpected_archive_root_is_rejected(self):
        with self.assertRaises(ValueError):
            sdk.install_archive(self.archive(tarfile.TarInfo("other/file")), self.release, self.root / "install")

    def test_resolve_cli_and_outputs(self):
        output = self.root / "output"
        result = subprocess.run([sys.executable, str(SOURCE), "resolve", "--releases-file", "releases.json"],
                                env={**os.environ, "GITHUB_WORKSPACE": str(self.root), "GITHUB_OUTPUT": str(output)},
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("dart-version=4.5.6", output.read_text())

    def test_unsupported_platform_is_rejected(self):
        with patch.object(sdk.platform, "system", return_value="Darwin"), patch.object(sys, "argv", ["sdk.py", "resolve"]):
            self.assertEqual(sdk.main(), 1)

    def test_failed_download_does_not_leave_a_partial(self):
        archive = self.root / "cache" / "flutter.tar.xz"
        with patch.object(sdk.subprocess, "run", side_effect=subprocess.CalledProcessError(22, "curl")):
            with self.assertRaises(subprocess.CalledProcessError):
                sdk.download_archive("1.2.3", archive)
        self.assertEqual(list(archive.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
