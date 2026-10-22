"""Run with Python + PyYAML, Cargo, and jq: python3 cargo-publish-dry-run/test_registry.py."""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


ACTION = Path(__file__).with_name("action.yml")


class RegistryTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.action = yaml.safe_load(ACTION.read_text())
        cls.steps = cls.action["runs"]["steps"]

    def test_all_source_overrides_use_the_registry_input(self):
        # Cover every vendored-source consumer, including optional target checks.
        consumers = [step for step in self.steps if "replace-with" in step.get("run", "")]
        self.assertEqual(len(consumers), 8)
        for step in consumers:
            with self.subTest(step=step["name"]):
                self.assertEqual(step["env"]["REGISTRY_NAME"], "${{ inputs.registry-name }}")
                self.assertIn("source.${REGISTRY_NAME}.replace-with", step["run"])
                self.assertNotIn("source.thruput.replace-with", step["run"])

    def test_every_resolving_cargo_command_is_locked(self):
        # The action must build exactly the caller's committed Cargo.lock.
        resolving = re.compile(r"^\s*cargo (vendor|package|hack|publish|clippy|doc|build|test|check)\b")
        commands = []
        for step in self.steps:
            # Join backslash-continued lines so each command is one string.
            for command in step.get("run", "").replace("\\\n", " ").splitlines():
                if resolving.match(command):
                    commands.append(command)
        self.assertEqual(len(commands), 9)
        for command in commands:
            with self.subTest(command=command.strip()):
                self.assertIn("--locked", command.split())

    def test_offline_vendored_dependency_with_default_and_explicit_registry(self):
        self.assertEqual(self.action["inputs"]["registry-name"]["default"], "thruput")
        step = next(step for step in self.steps if step["name"] == "Build documentation")
        for inputs in ({}, {"registry-name": "other-registry"}):
            registry = inputs.get("registry-name", self.action["inputs"]["registry-name"]["default"])
            with self.subTest(inputs=inputs), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                (root / "src").mkdir()
                (root / "src/lib.rs").write_text("pub fn value() -> u32 { fixture_dep::value() }\n")
                (root / "Cargo.toml").write_text(
                    '[package]\nname = "registry-consumer"\nversion = "0.1.0"\nedition = "2021"\n'
                    f'publish = ["{registry}"]\n[dependencies]\n'
                    f'fixture-dep = {{ version = "=0.1.0", registry = "{registry}" }}\n'
                )
                (root / ".cargo").mkdir()
                index = "sparse+https://registry.invalid/index/"
                (root / ".cargo/config.toml").write_text(
                    f'[registries.{registry}]\nindex = "{index}"\n'
                    f'[source.{registry}]\nregistry = "{index}"\n'
                )
                vendor = root / "vendor/fixture-dep-0.1.0"
                (vendor / "src").mkdir(parents=True)
                (vendor / "Cargo.toml").write_text(
                    '[package]\nname = "fixture-dep"\nversion = "0.1.0"\nedition = "2021"\n'
                )
                (vendor / "src/lib.rs").write_text("pub fn value() -> u32 { 1 }\n")
                (vendor / ".cargo-checksum.json").write_text(json.dumps({"files": {}}))
                bindings = {
                    "${{ inputs.registry-name }}": registry,
                    "${{ inputs.cargo-toml-path }}": str(root / "Cargo.toml"),
                    "${{ steps.list-packages.outputs.packages }}": "registry-consumer",
                    "${{ inputs.arch-only-packages }}": "",
                }
                env = os.environ.copy()
                for name, expression in step["env"].items():
                    env[name] = bindings[expression]
                # No registry access or inherited target output can satisfy the test.
                env["CARGO_NET_OFFLINE"] = "true"
                env["CARGO_TARGET_DIR"] = str(root / "target")
                # The step builds --locked, so the fixture commits a lockfile
                # like every caller must.
                subprocess.run(
                    ["cargo", "generate-lockfile",
                     "--config", f"source.{registry}.replace-with = 'vendored-sources'",
                     "--config", "source.vendored-sources.directory = 'vendor'"],
                    cwd=root, env=env, check=True, capture_output=True, timeout=60,
                )
                lockfile = (root / "Cargo.lock").read_text()
                result = subprocess.run(
                    ["bash", "-c", step["run"]], cwd=root, env=env,
                    capture_output=True, text=True, timeout=60,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertTrue((root / "target/doc/registry_consumer/index.html").is_file())
                self.assertIn(index, lockfile)
                self.assertEqual((root / "Cargo.lock").read_text(), lockfile)


if __name__ == "__main__":
    unittest.main(verbosity=2)
