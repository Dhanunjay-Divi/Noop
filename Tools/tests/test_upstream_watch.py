import importlib.util
import sys
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).resolve().parents[1] / "upstream_watch.py"
SPEC = importlib.util.spec_from_file_location("upstream_watch", MODULE_PATH)
assert SPEC and SPEC.loader
upstream_watch = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = upstream_watch
SPEC.loader.exec_module(upstream_watch)


def observation(**overrides):
    values = {
        "repository": "ryanbr/noop",
        "default_branch": "main",
        "head": "abc",
        "archived": False,
        "latest_release": "v9.3.1",
        "advisory_ids": (),
        "open_pr_digest": "digest",
        "open_pr_count": 1,
        "open_prs": (
            {
                "number": 7,
                "title": "A fix",
                "head": "def",
                "draft": False,
                "url": "https://github.com/ryanbr/noop/pull/7",
            },
        ),
    }
    values.update(overrides)
    return upstream_watch.Observation(**values)


class UpstreamWatchTests(unittest.TestCase):
    def test_matching_baseline_is_clear(self):
        item = observation()
        baseline = {
            "reviewed_at": "2026-08-11",
            "repositories": {item.repository: item.comparable()},
        }
        changed, report, _ = upstream_watch.compare(baseline, [item])
        self.assertFalse(changed)
        self.assertIn("no drift", report)

    def test_head_or_public_advisory_change_requires_review(self):
        item = observation(head="new", advisory_ids=("GHSA-test",))
        expected = observation().comparable()
        baseline = {"repositories": {item.repository: expected}}
        changed, report, _ = upstream_watch.compare(baseline, [item])
        self.assertTrue(changed)
        self.assertIn("`head` changed", report)
        self.assertIn("GHSA-test", report)

    def test_open_pr_fingerprint_ignores_api_order(self):
        first = {
            "number": 2,
            "title": "Two",
            "head": {"sha": "b"},
            "draft": False,
            "html_url": "https://example.test/2",
        }
        second = {
            "number": 1,
            "title": "One",
            "head": {"sha": "a"},
            "draft": True,
            "html_url": "https://example.test/1",
        }
        digest_a, stable = upstream_watch._pr_fingerprint([first, second])
        digest_b, _ = upstream_watch._pr_fingerprint([second, first])
        self.assertEqual(digest_a, digest_b)
        self.assertEqual([1, 2], [item["number"] for item in stable])


if __name__ == "__main__":
    unittest.main()
