"""Offline tests for cargo-publish's validation steps, run straight from
action.yml the way cargo-publish-dry-run/test_registry.py runs its steps.

Run with Python + PyYAML, Cargo, git and jq:
    python3 cargo-publish/test_action_steps.py
"""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml


ACTION = Path(__file__).with_name("action.yml")
CARGO_TOML = "${{ inputs.cargo-toml-path }}"
PACKAGES = "${{ steps.list-packages.outputs.packages }}"
TAG_VERSION = "${{ steps.extract-version.outputs.version }}"
GIT_TAG = "${{ inputs.git-tag }}"
TAG_PREFIX = "${{ inputs.tag-prefix }}"
PACKAGES_INPUT = "${{ inputs.packages }}"


def git(cwd, *args):
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
        cwd=cwd, check=True, capture_output=True,
    )


class StepTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.steps = yaml.safe_load(ACTION.read_text())["runs"]["steps"]

    def run_step(self, name, cwd, bindings, extra_env=None):
        step = next(step for step in self.steps if step["name"] == name)
        env = os.environ.copy()
        env.update(extra_env or {})
        for var, expression in step["env"].items():
            env[var] = bindings[expression]
        env["GITHUB_OUTPUT"] = str(Path(cwd) / "github_output")
        Path(env["GITHUB_OUTPUT"]).write_text("")
        result = subprocess.run(
            ["bash", "-c", step["run"]], cwd=cwd, env=env,
            capture_output=True, text=True, timeout=120,
        )
        outputs = dict(
            line.split("=", 1) for line in Path(env["GITHUB_OUTPUT"]).read_text().splitlines()
        )
        return result.returncode, result.stdout + result.stderr, outputs

    def workspace(self, version, a_requirement):
        """A two-crate workspace at `version`; b depends on a by path with
        `a_requirement` as the version requirement. Committed, with the
        release tag on HEAD and a branch named like a later tag."""
        root = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(root)]))
        for crate in ("a", "b"):
            (root / crate / "src").mkdir(parents=True)
            (root / crate / "src/lib.rs").write_text("")
        (root / "Cargo.toml").write_text(
            '[workspace]\nresolver = "2"\nmembers = ["a", "b"]\n'
        )
        metadata = (
            f'version = "{version}"\nedition = "2021"\nlicense = "MIT"\n'
            'description = "d"\nrepository = "https://example.invalid/r"\n'
        )
        (root / "a/Cargo.toml").write_text(f'[package]\nname = "a"\n{metadata}')
        (root / "b/Cargo.toml").write_text(
            f'[package]\nname = "b"\n{metadata}'
            f'[dependencies]\na = {{ path = "../a", version = "{a_requirement}" }}\n'
        )
        git(root, "init", "-q")
        git(root, "add", "-A")
        git(root, "commit", "-qm", "release")
        git(root, "tag", f"v{version}")
        git(root, "branch", "v9.9.9")
        return root

    def dependency_check(self, version, a_requirement):
        root = self.workspace(version, a_requirement)
        return self.run_step(
            "Validate workspace dependency versions", root,
            {CARGO_TOML: "./Cargo.toml", PACKAGES: "a b", TAG_VERSION: version},
        )

    def test_matching_pre_release_requirement_passes(self):
        code, log, _ = self.dependency_check("0.15.1-rc.1", "=0.15.1-rc.1")
        self.assertEqual(code, 0, log)
        self.assertIn("correct version: =0.15.1-rc.1", log)

    def test_stale_pre_release_requirement_fails(self):
        # The regression: this used to fall through to "OK: ... with
        # requirement" because the requirement didn't look like X.Y.Z.
        code, log, _ = self.dependency_check("0.15.1-rc.1", "=0.15.1-rc.0")
        self.assertEqual(code, 1, log)
        self.assertIn("DEPENDENCY VERSION MISMATCH in package 'b'", log)

    def test_stable_requirement_still_checked(self):
        code, log, _ = self.dependency_check("0.15.1", "0.15.1")
        self.assertEqual(code, 0, log)
        self.assertIn("correct version: ^0.15.1", log)
        code, log, _ = self.dependency_check("0.15.1", "0.15.0")
        self.assertEqual(code, 1, log)

    def test_non_exact_requirement_passes_through(self):
        # Documented: only a single X.Y.Z (with optional pre-release) is
        # compared; anything else is reported and allowed.
        code, log, _ = self.dependency_check("0.15.1", "0.15")
        self.assertEqual(code, 0, log)
        self.assertIn("with requirement: ^0.15", log)

    def test_tag_check_ignores_a_branch_of_the_same_name(self):
        root = self.workspace("1.2.3", "1.2.3")
        code, log, _ = self.run_step(
            "Verify current commit is tagged", root, {GIT_TAG: "v9.9.9"})
        self.assertEqual(code, 1, log)
        self.assertIn("does not exist", log)
        code, log, _ = self.run_step(
            "Verify current commit is tagged", root, {GIT_TAG: "v1.2.3"})
        self.assertEqual(code, 0, log)

    def test_tag_check_rejects_a_tag_on_another_commit(self):
        root = self.workspace("1.2.3", "1.2.3")
        (root / "a/src/lib.rs").write_text("// moved on\n")
        git(root, "commit", "-qam", "later")
        code, log, _ = self.run_step(
            "Verify current commit is tagged", root, {GIT_TAG: "v1.2.3"})
        self.assertEqual(code, 1, log)
        self.assertIn("Current commit is not tagged", log)

    def test_prefix_is_stripped_literally(self):
        root = self.workspace("1.2.3", "1.2.3")
        code, log, outputs = self.run_step(
            "Extract version from tag", root, {GIT_TAG: "v*1.2.3", TAG_PREFIX: "v*"})
        self.assertEqual(code, 0, log)
        self.assertEqual(outputs["version"], "1.2.3")

    def test_multi_line_packages_input_is_normalized(self):
        # A YAML block input arrives with newlines; GITHUB_OUTPUT takes one line.
        root = self.workspace("1.2.3", "1.2.3")
        code, log, outputs = self.run_step(
            "List workspace packages", root, {CARGO_TOML: "./Cargo.toml", PACKAGES_INPUT: "a\n  b\n"})
        self.assertEqual(code, 0, log)
        self.assertEqual(outputs["packages"], "a b")

    def test_discovery_skips_publish_false_crates(self):
        root = self.workspace("1.2.3", "1.2.3")
        (root / "xtask/src").mkdir(parents=True)
        (root / "xtask/src/main.rs").write_text("fn main() {}\n")
        (root / "xtask/Cargo.toml").write_text(
            '[package]\nname = "xtask"\nversion = "0.0.0"\nedition = "2021"\npublish = false\n'
        )
        (root / "Cargo.toml").write_text(
            '[workspace]\nresolver = "2"\nmembers = ["a", "b", "xtask"]\n'
        )
        code, log, outputs = self.run_step(
            "List workspace packages", root, {CARGO_TOML: "./Cargo.toml", PACKAGES_INPUT: ""})
        self.assertEqual(code, 0, log)
        self.assertEqual(outputs["packages"].split(), ["a", "b"])

    def publish_with(self, cargo_publish_output, exit_code=101):
        """Run the publish step with `cargo publish` stubbed to print the
        given output and exit with exit_code; every other cargo subcommand
        goes to the real cargo. Returns (step exit code, log)."""
        root = self.workspace("1.2.3", "1.2.3")
        real_cargo = shutil.which("cargo")
        stub_dir = root / "stub-bin"
        stub_dir.mkdir()
        (stub_dir / "cargo").write_text(
            "#!/usr/bin/env bash\n"
            'if [ "$1" = publish ]; then\n'
            '  printf \'%s\\n\' "$STUB_PUBLISH_OUTPUT"\n'
            '  exit "$STUB_PUBLISH_EXIT"\n'
            "fi\n"
            f'exec "{real_cargo}" "$@"\n'
        )
        (stub_dir / "cargo").chmod(0o755)
        code, log, _ = self.run_step(
            "Publish to registry", root, {
                "${{ inputs.registry-name }}": "thruput",
                "${{ inputs.registry-token }}": "t",
                CARGO_TOML: "./Cargo.toml",
                PACKAGES: "a b",
                "${{ inputs.publish-delay-seconds }}": "0",
                "${{ inputs.no-verify }}": "true",
            },
            extra_env={
                "PATH": f"{stub_dir}:{os.environ['PATH']}",
                "STUB_PUBLISH_OUTPUT": cargo_publish_output,
                "STUB_PUBLISH_EXIT": str(exit_code),
            })
        return code, log

    def test_publish_skips_only_on_the_registry_version_exists_answer(self):
        for message in (
            "error: failed to publish to registry at https://example.invalid\n\n"
            "Caused by:\n  the remote server responded with an error: crate version `1.2.3` is already uploaded",
            "error: crate a@1.2.3 already exists on crates.io index",
        ):
            with self.subTest(message=message):
                code, log = self.publish_with(message)
                self.assertEqual(code, 0, log)
                self.assertIn("SKIP: Package a version 1.2.3 is already published", log)
                self.assertIn("Skipped: 2 package(s)", log)

    def test_publish_does_not_skip_on_an_unrelated_already_exists(self):
        # std's io::ErrorKind::AlreadyExists, as a build script or cargo
        # itself may print it during the verify build.
        code, log = self.publish_with(
            "error: failed to verify package tarball\n\nCaused by:\n"
            "  failed to create directory `/tmp/x`: entity already exists")
        self.assertEqual(code, 101, log)
        self.assertIn("::error::Failed to publish a version 1.2.3", log)
        self.assertNotIn("SKIP", log)

    def test_publish_success_is_counted(self):
        code, log = self.publish_with("    Uploaded a v1.2.3", exit_code=0)
        self.assertEqual(code, 0, log)
        self.assertIn("Published: 2 package(s)", log)

    def test_package_names_match_exactly(self):
        root = self.workspace("1.2.3", "1.2.3")
        code, log, outputs = self.run_step(
            "List workspace packages", root, {CARGO_TOML: "./Cargo.toml", PACKAGES_INPUT: "a b"})
        self.assertEqual(code, 0, log)
        self.assertEqual(outputs["packages"], "a b")
        # "." is a regex that would match any one-letter package name.
        code, log, _ = self.run_step(
            "List workspace packages", root, {CARGO_TOML: "./Cargo.toml", PACKAGES_INPUT: "."})
        self.assertEqual(code, 1, log)
        self.assertIn("Package '.' not found", log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
