from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "testing-build.yml"


class TestingReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.ready = cls.text[cls.text.index("\n  ready:\n") :]

    def test_builds_upload_only_to_a_run_specific_draft(self) -> None:
        before_ready = self.text[: self.text.index("\n  ready:\n")]
        self.assertIn(
            'TAG="testing-snapshot-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
            before_ready,
        )
        self.assertIn('gh release create "$TAG"', before_ready)
        self.assertIn("--draft --prerelease", before_ready)
        self.assertIn('--title "$TITLE" --notes-file "$BODY"', before_ready)
        self.assertNotIn("testing-latest", self.text)

    def test_testing_source_and_signing_are_protected(self) -> None:
        self.assertIn(
            "run-name: NOOP testing candidate @ ${{ github.sha }}",
            self.text,
        )
        self.assertIn('test "$GITHUB_REF" = "refs/heads/main"', self.text)
        self.assertIn('test "$MAIN_SHA" = "$GITHUB_SHA"', self.text)
        android = self.text[
            self.text.index("\n  android:\n") : self.text.index("\n  macos:\n")
        ]
        self.assertIn("    environment: staging", android)
        self.assertIn(
            "Require protected staging signing secrets",
            android,
        )
        meta = self.text[
            self.text.index("\n  meta:\n") : self.text.index("\n  android:\n")
        ]
        self.assertNotIn("ANDROID_STAGING_KEYSTORE_BASE64", meta)
        self.assertNotIn("refs/heads/noop-staging", self.text)

    def test_readiness_waits_for_every_platform_and_verifies_bytes(self) -> None:
        self.assertIn("needs: [meta, android, macos, ios]", self.ready)
        verify = self.ready.index(
            "does not contain exactly the five expected artifacts"
        )
        byte_checks = self.ready.index("sha256sum --check")
        draft_gate = self.ready.index(
            "python3 Tools/github-release-publish.py"
        )
        self.assertLess(verify, byte_checks)
        self.assertLess(byte_checks, draft_gate)
        self.assertIn('.state == "uploaded"', self.ready)

    def test_workflow_retains_a_unique_verified_draft(self) -> None:
        ready_only = self.ready[: self.ready.index("\n  cleanup:\n")]
        self.assertIn("--testing-snapshot", ready_only)
        self.assertIn("--verify-draft-only", ready_only)
        self.assertIn(
            '--write-manifest "$RUNNER_TEMP/testing-release-candidate.json"',
            ready_only,
        )
        self.assertIn('--run-id "$GITHUB_RUN_ID"', ready_only)
        self.assertIn('--run-attempt "$GITHUB_RUN_ATTEMPT"', ready_only)
        self.assertIn(
            "testing-release-candidate-${{ github.run_id }}-"
            "${{ github.run_attempt }}",
            ready_only,
        )
        self.assertIn(
            "actions/upload-artifact@"
            "043fb46d1a93c77aae656e7c1c64a875d1fc6a0a",
            ready_only,
        )
        self.assertIn('--tag "$CANDIDATE_TAG"', ready_only)
        self.assertIn('--expected-sha "$TARGET_SHA"', ready_only)
        self.assertIn('--expected-name "$EXPECTED_NAME"', ready_only)
        self.assertIn(
            '--expected-body-sha256 "$EXPECTED_BODY_SHA"',
            ready_only,
        )
        self.assertIn('--expected-target "$TARGET_SHA"', ready_only)
        self.assertNotIn("gh release edit", ready_only)
        self.assertNotIn("git/refs/tags", ready_only)
        self.assertNotIn("BACKUP_TAG", ready_only)

    def test_cleanup_retains_success_and_fails_closed_on_lookup_error(self) -> None:
        cleanup = self.text[self.text.index("\n  cleanup:\n") :]
        self.assertIn("if: ${{ always() }}", cleanup)
        self.assertIn("CANDIDATE_TAG: ${{ needs.meta.outputs.tag }}", cleanup)
        self.assertIn("READY_RESULT: ${{ needs.ready.result }}", cleanup)
        self.assertNotIn("testing-latest", cleanup)
        self.assertIn('if [ "$READY_RESULT" = "success" ]', cleanup)
        self.assertIn('if [ "$(jq -r \'.draft\' <<<"$RELEASE")" = "true" ]', cleanup)
        self.assertIn("Could not inspect failed testing candidate", cleanup)
        self.assertNotIn("git/refs/tags", cleanup)
        self.assertIn("cancel-in-progress: false", self.text)


if __name__ == "__main__":
    unittest.main()
