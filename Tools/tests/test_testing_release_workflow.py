from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "fork-testing-build.yml"


class TestingReleaseWorkflowTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.text = WORKFLOW.read_text(encoding="utf-8")
        cls.promote = cls.text[cls.text.index("\n  promote:\n") :]

    def test_builds_upload_only_to_a_run_specific_draft(self) -> None:
        before_promote = self.text[: self.text.index("\n  promote:\n")]
        self.assertIn(
            'TAG="testing-candidate-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"',
            before_promote,
        )
        self.assertIn('gh release create "$TAG"', before_promote)
        self.assertIn("--draft --prerelease", before_promote)
        self.assertNotIn('TAG="testing-latest"', before_promote)
        self.assertNotIn('gh release delete "testing-latest"', before_promote)

    def test_promotion_waits_for_every_platform_and_verifies_before_swap(self) -> None:
        self.assertIn("needs: [meta, android, macos, ios]", self.promote)
        verify = self.promote.index("does not contain exactly the five expected artifacts")
        byte_checks = self.promote.index("sha256sum --check")
        swap = self.promote.index("SWAP_ARMED=1")
        old_release_mutation = self.promote.index(
            'gh release edit "$PUBLIC_TAG" --repo "$GITHUB_REPOSITORY"'
        )
        self.assertLess(verify, byte_checks)
        self.assertLess(byte_checks, swap)
        self.assertLess(swap, old_release_mutation)

    def test_failure_path_retains_and_restores_the_previous_release(self) -> None:
        self.assertIn('BACKUP_TAG: testing-rollback-${{ github.run_id }}-', self.promote)
        self.assertIn("trap rollback EXIT", self.promote)
        self.assertIn("trap 'exit 130' INT TERM", self.promote)
        self.assertIn('restored_id" = "$OLD_RELEASE_ID', self.promote)
        self.assertIn("The previous release remains under $BACKUP_TAG", self.promote)

    def test_cleanup_can_never_name_the_public_release(self) -> None:
        cleanup = self.text[self.text.index("\n  cleanup:\n") :]
        self.assertIn("if: ${{ always() }}", cleanup)
        self.assertIn("CANDIDATE_TAG: ${{ needs.meta.outputs.tag }}", cleanup)
        self.assertNotIn("testing-latest", cleanup)
        self.assertIn("cancel-in-progress: false", self.text)


if __name__ == "__main__":
    unittest.main()
