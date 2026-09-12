import importlib.util
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("smoke", ROOT / "tool/melos_smoke.py")
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class WorktreeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        for args in (("init", "--quiet"), ("config", "user.name", "Fixture"),
                     ("config", "user.email", "fixture@example.invalid")):
            self.git(*args)
        (self.root / "source").write_text("reviewed")
        (self.root / ".gitignore").write_text("ignored/\n")
        self.git("add", ".")
        self.git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture")

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.root, check=True, capture_output=True)

    def check(self):
        return subprocess.run(["bash", str(ROOT / "actions/check-worktree/check.sh")],
                              cwd=self.root, capture_output=True, text=True)

    def test_clean_tree_passes(self):
        self.assertEqual(self.check().returncode, 0)

    def test_modified_source_fails_without_restoring(self):
        (self.root / "source").write_text("changed")
        self.assertEqual(self.check().returncode, 1)
        self.assertEqual((self.root / "source").read_text(), "changed")

    def test_staged_changes_fail(self):
        (self.root / "source").write_text("staged")
        self.git("add", "source")
        self.assertEqual(self.check().returncode, 1)

    def test_untracked_source_fails_without_deleting(self):
        (self.root / "generated.dart").write_text("generated")
        self.assertEqual(self.check().returncode, 1)
        self.assertTrue((self.root / "generated.dart").exists())

    def test_ignored_build_outputs_pass(self):
        (self.root / "ignored").mkdir()
        (self.root / "ignored/file").write_text("build output")
        self.assertEqual(self.check().returncode, 0)


class FixtureTests(unittest.TestCase):
    def test_supported_melos_fixtures(self):
        for version in smoke.SUPPORTED:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                smoke.populate(root, version)
                pubspec = (root / "pubspec.yaml").read_text()
                self.assertIn(f"melos: {version}", pubspec)
                self.assertEqual((root / "melos.yaml").exists(), version.startswith("6."))
                self.assertEqual("workspace:" in pubspec, not version.startswith("6."))

    def test_arbitrary_melos_version_rejected(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaises(ValueError):
            smoke.populate(Path(directory), "latest")

    def test_validation_workflows_cannot_request_oidc(self):
        for name in ("ci-verified.yml", "foundation-tests.yml"):
            text = (ROOT / ".github/workflows" / name).read_text()
            self.assertNotIn("id-token:", text)
            self.assertNotIn("secrets:", text)
            self.assertIn("contents: read", text)
            self.assertIn("persist-credentials: false", text)

    def test_no_step_output_in_pr_title_default(self):
        text = (ROOT / ".github/workflows/pr-title-check.yml").read_text()
        inputs = text.split("permissions:", 1)[0]
        self.assertNotIn("steps.", inputs)
        self.assertIn("LINT_ERROR: ${{ steps.lint_pr_title.outputs.error_message }}", text)

    def test_new_remote_actions_are_immutable(self):
        paths = [ROOT / ".github/workflows" / name for name in (
            "ci-verified.yml", "foundation-tests.yml", "pr-title-check.yml")]
        paths += list((ROOT / "actions").glob("*/action.yml"))
        for path in paths:
            for reference in re.findall(r"\buses:\s+(\S+)", path.read_text()):
                if reference.startswith("./"):
                    continue
                self.assertRegex(reference, r"^[\w./-]+@[0-9a-f]{40}$", f"Unpinned reference in {path}")


if __name__ == "__main__":
    unittest.main()
