from __future__ import annotations

import copy
import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "trusted-release-controls.py"
SPEC = importlib.util.spec_from_file_location(
    "trusted_release_controls", SCRIPT
)
assert SPEC is not None and SPEC.loader is not None
TRUSTED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(TRUSTED)


class FakeCheckClient:
    def __init__(self) -> None:
        self.repository = ""
        self.payload: dict[str, object] = {}
        self.response_overrides: dict[str, object] = {}

    def create_check(
        self, repository: str, payload: dict[str, object]
    ) -> dict[str, object]:
        self.repository = repository
        self.payload = copy.deepcopy(payload)
        response: dict[str, object] = {
            "id": 123,
            **copy.deepcopy(payload),
            "app": {"id": TRUSTED.GITHUB_ACTIONS_APP_ID},
        }
        response.update(self.response_overrides)
        return response


class TrustedReleaseControlTests(unittest.TestCase):
    def test_repository_self_contract_is_valid(self) -> None:
        TRUSTED.verify_self(ROOT)

    def test_publication_authority_is_protected(self) -> None:
        for path in (
            ".github/workflows/release.yml",
            ".github/workflows/release-controls.yml",
            ".github/workflows/trusted-release-controls.yml",
            "release/required-ci.json",
            "Tools/forgejo-release.sh",
            "Tools/github-release-publish.py",
            "Tools/github-release-tag-gate.py",
            "Tools/homebrew-version-gate.py",
            "Tools/release.sh",
            "Tools/required-ci-gate.py",
            "Tools/trusted-release-controls.py",
            "Tools/update-homebrew-cask.sh",
        ):
            with self.subTest(path=path):
                self.assertTrue(TRUSTED.is_protected_path(path))

    def test_non_owner_cannot_change_a_trust_root(self) -> None:
        with self.assertRaisesRegex(
            TRUSTED.TrustedControlError, "require the repository owner"
        ):
            TRUSTED.authorize_changed_paths(
                ["Tools/github-release-publish.py"],
                repository_owner="Dhanunjay-Divi",
                actor="another-builder",
            )

    def test_repository_owner_can_change_a_trust_root(self) -> None:
        protected = TRUSTED.authorize_changed_paths(
            [
                "Tools/github-release-publish.py",
                "Strand/App/AppModel.swift",
            ],
            repository_owner="Dhanunjay-Divi",
            actor="dhanunjay-divi",
        )
        self.assertEqual(protected, ["Tools/github-release-publish.py"])

    def test_ordinary_candidate_paths_do_not_require_owner(self) -> None:
        protected = TRUSTED.authorize_changed_paths(
            [
                "Strand/App/AppModel.swift",
                "android/app/src/main/java/com/noop/MainActivity.kt",
            ],
            repository_owner="Dhanunjay-Divi",
            actor="another-builder",
        )
        self.assertEqual(protected, [])

    def test_changed_path_inventory_rejects_traversal(self) -> None:
        with self.assertRaisesRegex(
            TRUSTED.TrustedControlError, "inventory is invalid"
        ):
            TRUSTED.authorize_changed_paths(
                ["../Tools/github-release-publish.py"],
                repository_owner="Dhanunjay-Divi",
                actor="another-builder",
            )

    def test_exact_head_success_check_is_bounded_and_app_bound(self) -> None:
        client = FakeCheckClient()
        self.assertTrue(
            TRUSTED.report_exact_check(
                client=client,
                repository="Dhanunjay-Divi/Noop",
                head_sha="a" * 40,
                scope="pull-request",
                validation_result="success",
                run_id=1234,
                run_attempt=2,
            )
        )
        self.assertEqual(client.repository, "Dhanunjay-Divi/Noop")
        self.assertEqual(
            client.payload,
            {
                "name": "trusted-release-controls",
                "head_sha": "a" * 40,
                "status": "completed",
                "conclusion": "success",
                "details_url": (
                    "https://github.com/Dhanunjay-Divi/Noop/"
                    "actions/runs/1234"
                ),
                "external_id": (
                    "trusted-release-controls:pull-request:1234:2:"
                    + "a" * 40
                ),
                "output": {
                    "title": "Protected release controls passed",
                    "summary": (
                        "Protected base authorization accepted the exact "
                        "pull-request head. Candidate release controls are "
                        "enforced separately."
                    ),
                },
            },
        )

    def test_non_success_validation_publishes_failure_then_fails(self) -> None:
        for result in ("failure", "cancelled", "skipped"):
            with self.subTest(result=result):
                client = FakeCheckClient()
                with self.assertRaisesRegex(
                    TRUSTED.TrustedControlError,
                    "exact source did not pass protected release controls",
                ):
                    TRUSTED.report_exact_check(
                        client=client,
                        repository="Dhanunjay-Divi/Noop",
                        head_sha="b" * 40,
                        scope="pull-request",
                        validation_result=result,
                        run_id=5678,
                        run_attempt=1,
                    )
                self.assertEqual(
                    client.payload.get("conclusion"), "failure"
                )

    def test_exact_head_check_rejects_another_app_identity(self) -> None:
        client = FakeCheckClient()
        client.response_overrides["app"] = {"id": 1}
        with self.assertRaisesRegex(
            TRUSTED.TrustedControlError, "identity is invalid"
        ):
            TRUSTED.report_exact_check(
                client=client,
                repository="Dhanunjay-Divi/Noop",
                head_sha="c" * 40,
                scope="pull-request",
                validation_result="success",
                run_id=9012,
                run_attempt=1,
            )

    def test_protected_main_check_is_scope_bound(self) -> None:
        client = FakeCheckClient()
        self.assertTrue(
            TRUSTED.report_exact_check(
                client=client,
                repository="Dhanunjay-Divi/Noop",
                head_sha="d" * 40,
                scope="protected-main",
                validation_result="success",
                run_id=3456,
                run_attempt=3,
            )
        )
        self.assertEqual(
            client.payload.get("external_id"),
            "trusted-release-controls:protected-main:3456:3:" + "d" * 40,
        )
        output = client.payload.get("output")
        self.assertIsInstance(output, dict)
        assert isinstance(output, dict)
        self.assertEqual(
            output.get("summary"),
            "Protected main release controls validated the exact commit.",
        )


if __name__ == "__main__":
    unittest.main()
