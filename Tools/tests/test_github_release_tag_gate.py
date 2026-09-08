from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "github-release-tag-gate.py"
SPEC = importlib.util.spec_from_file_location("github_release_tag_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class GitHubReleaseTagGateTests(unittest.TestCase):
    def test_lightweight_tag_targets_exact_commit(self) -> None:
        sha = "a" * 40
        payload = {
            "ref": "refs/tags/v9.2.1",
            "object": {"type": "commit", "sha": sha},
        }
        self.assertEqual(
            GATE.resolve_tag_target(payload, "v9.2.1", lambda _: {}),
            sha,
        )

    def test_annotated_tag_chain_resolves_to_commit(self) -> None:
        first = "a" * 40
        second = "b" * 40
        commit = "c" * 40
        payloads = {
            first: {
                "sha": first,
                "object": {"type": "tag", "sha": second},
            },
            second: {
                "sha": second,
                "object": {"type": "commit", "sha": commit},
            },
        }
        ref = {
            "ref": "refs/tags/v9.2.1",
            "object": {"type": "tag", "sha": first},
        }
        self.assertEqual(
            GATE.resolve_tag_target(ref, "v9.2.1", payloads.__getitem__),
            commit,
        )

    def test_reference_identity_must_be_exact(self) -> None:
        payload = {
            "ref": "refs/tags/v9.2.10",
            "object": {"type": "commit", "sha": "a" * 40},
        }
        with self.assertRaisesRegex(GATE.GateError, "identity is invalid"):
            GATE.resolve_tag_target(payload, "v9.2.1", lambda _: {})

    def test_live_tag_mismatch_is_rejected(self) -> None:
        paths: list[str] = []

        def fetch(path: str) -> object:
            paths.append(path)
            return {
                "ref": "refs/tags/v9.2.1",
                "object": {"type": "commit", "sha": "b" * 40},
            }

        with self.assertRaisesRegex(
            GATE.GateError, "points to a different commit"
        ):
            GATE.verify_remote_tag(
                "Dhanunjay-Divi/Noop",
                "v9.2.1",
                "a" * 40,
                "synthetic-token",
                fetch,
            )
        self.assertEqual(
            paths,
            ["/repos/Dhanunjay-Divi/Noop/git/ref/tags/v9.2.1"],
        )

    def test_annotated_tag_cycle_is_rejected(self) -> None:
        tag_object = "a" * 40
        ref = {
            "ref": "refs/tags/v9.2.1",
            "object": {"type": "tag", "sha": tag_object},
        }
        payload = {
            "sha": tag_object,
            "object": {"type": "tag", "sha": tag_object},
        }
        with self.assertRaisesRegex(GATE.GateError, "contains a cycle"):
            GATE.resolve_tag_target(ref, "v9.2.1", lambda _: payload)

    def test_inputs_are_strictly_validated(self) -> None:
        with self.assertRaisesRegex(GATE.GateError, "repository"):
            GATE.verify_remote_tag(
                "owner/repo/path",
                "v9.2.1",
                "a" * 40,
                "synthetic-token",
                lambda _: {},
            )
        with self.assertRaisesRegex(GATE.GateError, "release tag"):
            GATE.verify_remote_tag(
                "owner/repo",
                "latest",
                "a" * 40,
                "synthetic-token",
                lambda _: {},
            )


if __name__ == "__main__":
    unittest.main()
