"""Offline tests for rust-dependency-policy's git dependency token: the input
guard and the URL rewrite, run straight from the workflow the way
cargo-publish/test_action_steps.py runs its steps. A stand-in for cargo
reports how git expands each URL instead of running cargo-deny.

Run with Python + PyYAML and git:
    python3 .github/workflows/test_rust_dependency_policy.py
"""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

import yaml


WORKFLOW = Path(__file__).with_name("rust-dependency-policy.yml")
TOKEN = "dummy-token"
OWNER = "thruputchain"
WITH_TOKEN = f"https://x-access-token:{TOKEN}@github.com/{OWNER}/dep.git"

OWNER_URLS = [
    f"ssh://git@github.com/{OWNER}/dep.git",
    f"git@github.com:{OWNER}/dep.git",
    f"https://github.com/{OWNER}/dep.git",
]
OTHER_URLS = [
    "https://github.com/rustsec/advisory-db",
    "ssh://git@github.com/other/dep.git",
    "git@github.com:other/dep.git",
    "https://github.com/other/dep.git",
]

FAKE_CARGO = """#!/bin/sh
echo "fetch-with-cli=${CARGO_NET_GIT_FETCH_WITH_CLI:-}"
for url in $URLS; do
  echo "$url $(git ls-remote --get-url "$url")"
done
"""


def condition_holds(condition, inputs):
    """Evaluates an `if:` made of `inputs.<name> (==|!=) ''` terms joined
    by `&&`, the only form these steps use."""
    for term in condition.split("&&"):
        match = re.fullmatch(r"inputs\.([\w-]+) (==|!=) ''", term.strip())
        if match is None:
            raise ValueError(f"unsupported condition term: {term!r}")
        empty = inputs.get(match[1], "") == ""
        if empty != (match[2] == "=="):
            return False
    return True


class GitTokenTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = yaml.safe_load(WORKFLOW.read_text())
        cls.steps = workflow["jobs"]["dependency-policy"]["steps"]

    def step(self, name):
        return next(step for step in self.steps if step["name"] == name)

    def run_check(self, token):
        """Runs the check step with the fake cargo and returns, per URL,
        what git fetches instead, plus CARGO_NET_GIT_FETCH_WITH_CLI."""
        step = self.step("Check dependency policy")
        bindings = {
            "${{ inputs.toolchain }}": "stable",
            "${{ inputs.checks }}": "",
            "${{ inputs.registry-name }}": "",
            "${{ secrets.registry-token }}": "",
            "${{ steps.git-app-token.outputs.token }}": token,
            "${{ github.repository_owner }}": OWNER,
        }
        bin_dir = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: subprocess.run(["rm", "-rf", str(bin_dir)]))
        cargo = bin_dir / "cargo"
        cargo.write_text(FAKE_CARGO)
        cargo.chmod(0o755)
        env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_CONFIG")
        }
        env.update(
            {var: bindings[expression] for var, expression in step["env"].items()},
            PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}",
            GIT_CONFIG_GLOBAL=os.devnull,
            GIT_CONFIG_NOSYSTEM="1",
            URLS=" ".join(OWNER_URLS + OTHER_URLS),
        )
        result = subprocess.run(
            ["bash", "-c", step["run"]], env=env,
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = result.stdout.splitlines()
        fetch_with_cli = lines[0].split("=", 1)[1]
        fetched = dict(line.split(" ", 1) for line in lines[1:])
        return fetched, fetch_with_cli

    def test_owner_urls_fetch_with_token(self):
        fetched, fetch_with_cli = self.run_check(TOKEN)
        self.assertEqual(fetch_with_cli, "true")
        for url in OWNER_URLS:
            self.assertEqual(fetched[url], WITH_TOKEN, url)

    def test_other_urls_untouched(self):
        fetched, _ = self.run_check(TOKEN)
        for url in OTHER_URLS:
            self.assertEqual(fetched[url], url)

    def test_no_token_no_rewrite(self):
        fetched, fetch_with_cli = self.run_check("")
        self.assertEqual(fetch_with_cli, "")
        for url in OWNER_URLS + OTHER_URLS:
            self.assertEqual(fetched[url], url)

    def test_guard_stops_a_token_for_the_whole_installation(self):
        names = [step["name"] for step in self.steps]
        guard = self.step("Check git dependency inputs")
        token = self.step("Generate git dependency token")
        self.assertLess(names.index(guard["name"]), names.index(token["name"]))
        app = {"git-app-id": "123"}
        self.assertTrue(condition_holds(guard["if"], app))
        self.assertFalse(condition_holds(guard["if"], {**app, "git-repositories": "dep"}))
        self.assertFalse(condition_holds(guard["if"], {}))
        self.assertTrue(condition_holds(token["if"], app))
        self.assertFalse(condition_holds(token["if"], {}))
        result = subprocess.run(
            ["bash", "-c", guard["run"]], capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("git-repositories is empty", result.stdout)


if __name__ == "__main__":
    unittest.main()
