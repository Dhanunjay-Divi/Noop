from __future__ import annotations

import copy
import importlib.util
import json
import tempfile
import unittest
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "github-release-publish.py"
SPEC = importlib.util.spec_from_file_location("github_release_publish", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
PUBLISH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PUBLISH)


REPOSITORY = "Dhanunjay-Divi/Noop"
VERSION = "9.2.1"
TAG = f"v{VERSION}"
SHA = "a" * 40
RELEASE_ID = 42
REQUIRED_CONTEXTS = [
    "android-ci-required",
    "apple-ci-required",
    "health-claims",
    "i18n-coverage",
    "operations-record",
    "release-controls",
    "runtime-license-required",
    "server-ci-required",
    "swift-packages-required",
    "trusted-release-controls",
]
ACTIVATION_CONTRACT = (PUBLISH.GITHUB_ACTIONS_APP_ID, REQUIRED_CONTEXTS)


def release_payload(
    *,
    draft: bool,
    immutable: bool,
    prerelease: bool = False,
    tag: str = TAG,
    version: str = VERSION,
) -> dict[str, Any]:
    return {
        "id": RELEASE_ID,
        "tag_name": tag,
        "draft": draft,
        "prerelease": prerelease,
        "immutable": immutable,
        "name": f"NOOP {tag}",
        "body": f"Synthetic release body for {tag}.\n",
        "target_commitish": SHA,
        "assets": [
            {
                "id": 100 + index,
                "name": name,
                "size": index + 1,
                "state": "uploaded",
                "digest": f"sha256:{index + 1:064x}",
            }
            for index, name in enumerate(
                PUBLISH.expected_asset_names(version)
            )
        ],
    }


def policy_responses(
    *,
    testing_snapshot: bool = False,
) -> dict[tuple[str, str], list[Any]]:
    ruleset_name = (
        PUBLISH.TESTING_POLICY_RULESET_NAME
        if testing_snapshot
        else PUBLISH.POLICY_RULESET_NAME
    )
    tag_pattern = (
        PUBLISH.TESTING_POLICY_TAG_PATTERN
        if testing_snapshot
        else PUBLISH.POLICY_TAG_PATTERN
    )
    creation_ruleset_name = (
        PUBLISH.TESTING_POLICY_CREATION_RULESET_NAME
        if testing_snapshot
        else PUBLISH.POLICY_CREATION_RULESET_NAME
    )
    immutable_rules = [{"type": "update"}, {"type": "deletion"}]
    creation_rules = [{"type": "creation"}]
    owner = REPOSITORY.split("/", 1)[0]

    def ruleset_detail(
        ruleset_id: int,
        name: str,
        rules: list[dict[str, str]],
        bypass_actors: list[dict[str, Any]],
        current_user_can_bypass: str,
    ) -> dict[str, Any]:
        return {
            "id": ruleset_id,
            "name": name,
            "target": "tag",
            "source_type": "Repository",
            "source": REPOSITORY,
            "enforcement": "active",
            "conditions": {
                "ref_name": {
                    "include": [tag_pattern],
                    "exclude": [],
                }
            },
            "rules": rules,
            "bypass_actors": bypass_actors,
            "current_user_can_bypass": current_user_can_bypass,
        }

    summaries = [
        {
            "id": 7,
            "name": ruleset_name,
            "target": "tag",
            "enforcement": "active",
        },
        {
            "id": 8,
            "name": creation_ruleset_name,
            "target": "tag",
            "enforcement": "active",
        },
    ]
    owner_collaborators = [
        {
            "login": owner,
            "permissions": {
                "admin": True,
                "maintain": True,
                "push": True,
            },
        },
        {
            "login": "read-only-reviewer",
            "permissions": {
                "admin": False,
                "maintain": False,
                "push": False,
            },
        },
    ]
    return {
        (
            "GET",
            f"/repos/{REPOSITORY}/git/ref/heads/main",
        ): [
            {
                "ref": "refs/heads/main",
                "object": {"type": "commit", "sha": SHA},
            },
            {
                "ref": "refs/heads/main",
                "object": {"type": "commit", "sha": SHA},
            },
        ],
        (
            "GET",
            f"/repos/{REPOSITORY}/branches/main/protection/"
            "required_status_checks",
        ): [
            {
                "strict": True,
                "contexts": REQUIRED_CONTEXTS,
                "checks": [
                    {
                        "app_id": PUBLISH.GITHUB_ACTIONS_APP_ID,
                        "context": context,
                    }
                    for context in REQUIRED_CONTEXTS
                ],
            },
            {
                "strict": True,
                "contexts": REQUIRED_CONTEXTS,
                "checks": [
                    {
                        "app_id": PUBLISH.GITHUB_ACTIONS_APP_ID,
                        "context": context,
                    }
                    for context in REQUIRED_CONTEXTS
                ],
            },
        ],
        ("GET", "/user"): [
            {"login": owner, "type": "User"},
            {"login": owner, "type": "User"},
        ],
        (
            "GET",
            f"/repos/{REPOSITORY}/collaborators?affiliation=all&per_page=100",
        ): [copy.deepcopy(owner_collaborators), copy.deepcopy(owner_collaborators)],
        (
            "GET",
            f"/repos/{REPOSITORY}/immutable-releases",
        ): [{"enabled": True}, {"enabled": True}],
        (
            "GET",
            f"/repos/{REPOSITORY}/rulesets?per_page=100",
        ): [
            copy.deepcopy(summaries),
            copy.deepcopy(summaries),
        ],
        (
            "GET",
            f"/repos/{REPOSITORY}/rulesets/7",
        ): [
            ruleset_detail(7, ruleset_name, immutable_rules, [], "never"),
            ruleset_detail(7, ruleset_name, immutable_rules, [], "never"),
        ],
        (
            "GET",
            f"/repos/{REPOSITORY}/rulesets/8",
        ): [
            ruleset_detail(
                8,
                creation_ruleset_name,
                creation_rules,
                [PUBLISH.ADMIN_BYPASS_ACTOR],
                "always",
            ),
            ruleset_detail(
                8,
                creation_ruleset_name,
                creation_rules,
                [PUBLISH.ADMIN_BYPASS_ACTOR],
                "always",
            ),
        ],
    }


class FakeClient:
    def __init__(
        self,
        responses: dict[tuple[str, str], list[Any]],
    ) -> None:
        self.responses = defaultdict(list, responses)
        self.calls: list[tuple[str, str, dict[str, Any] | None]] = []

    def request(
        self,
        path: str,
        *,
        method: str = "GET",
        payload: dict[str, Any] | None = None,
    ) -> Any:
        self.calls.append((method, path, payload))
        values = self.responses[(method, path)]
        if not values:
            raise AssertionError(f"unexpected request: {method} {path}")
        value = values.pop(0)
        if isinstance(value, Exception):
            raise value
        return value


def successful_client(
    *,
    patch_response: Any | None = None,
    first_live: dict[str, Any] | None = None,
    confirmed_live: dict[str, Any] | None = None,
    prerelease: bool = False,
    tag: str = TAG,
) -> FakeClient:
    responses: dict[tuple[str, str], list[Any]] = {}
    responses[
        ("GET", f"/repos/{REPOSITORY}/releases/tags/{tag}")
    ] = [
        {
            **release_payload(
                draft=True,
                immutable=False,
                prerelease=prerelease,
                tag=tag,
            ),
        }
    ]
    responses[
        ("PATCH", f"/repos/{REPOSITORY}/releases/{RELEASE_ID}")
    ] = [
        patch_response
        if patch_response is not None
        else {
            **release_payload(
                draft=False,
                immutable=True,
                prerelease=prerelease,
                tag=tag,
            ),
        }
    ]
    responses[
        ("GET", f"/repos/{REPOSITORY}/releases/{RELEASE_ID}")
    ] = [
        {
            **release_payload(
                draft=True,
                immutable=False,
                prerelease=prerelease,
                tag=tag,
            ),
        },
        first_live
        if first_live is not None
        else {
            **release_payload(
                draft=False,
                immutable=True,
                prerelease=prerelease,
                tag=tag,
            ),
        },
        confirmed_live
        if confirmed_live is not None
        else {
            **release_payload(
                draft=False,
                immutable=True,
                prerelease=prerelease,
                tag=tag,
            ),
        },
    ]
    return FakeClient(responses)


def publish_release(*args: Any, **kwargs: Any) -> None:
    repository, tag, version, sha = args[:4]
    kwargs.setdefault("run_id", 12345)
    kwargs.setdefault("run_attempt", 1)
    kwargs.setdefault(
        "candidate_manifest",
        PUBLISH.create_candidate_manifest(
            release_payload(
                draft=True,
                immutable=False,
                tag=tag,
                version=version,
            ),
            repository=repository,
            tag=tag,
            version=version,
            expected_sha=sha,
            run_id=kwargs["run_id"],
            run_attempt=kwargs["run_attempt"],
            prerelease=False,
        ),
    )
    kwargs.setdefault("policy_verifier", lambda: None)
    kwargs.setdefault("tag_absence_verifier", lambda: None)
    PUBLISH.publish_release(*args, **kwargs)


def publish_testing_snapshot(*args: Any, **kwargs: Any) -> None:
    repository, tag, version, sha = args[:4]
    kwargs.setdefault("run_id", 12345)
    kwargs.setdefault("run_attempt", 2)
    kwargs.setdefault(
        "candidate_manifest",
        PUBLISH.create_candidate_manifest(
            release_payload(
                draft=True,
                immutable=False,
                prerelease=True,
                tag=tag,
                version=version,
            ),
            repository=repository,
            tag=tag,
            version=version,
            expected_sha=sha,
            run_id=kwargs["run_id"],
            run_attempt=kwargs["run_attempt"],
            prerelease=True,
        ),
    )
    kwargs.setdefault("policy_verifier", lambda: None)
    kwargs.setdefault("tag_absence_verifier", lambda: None)
    PUBLISH.publish_testing_snapshot(*args, **kwargs)


class GitHubReleasePublishTests(unittest.TestCase):
    def test_candidate_manifest_binds_release_metadata(self) -> None:
        payload = release_payload(draft=True, immutable=False)
        manifest = PUBLISH.create_candidate_manifest(
            payload,
            repository=REPOSITORY,
            tag=TAG,
            version=VERSION,
            expected_sha=SHA,
            run_id=12345,
            run_attempt=1,
            prerelease=False,
        )
        self.assertEqual(manifest["name"], payload["name"])
        self.assertEqual(manifest["targetCommitish"], SHA)
        self.assertEqual(
            manifest["bodySha256"],
            PUBLISH.hashlib.sha256(payload["body"].encode("utf-8")).hexdigest(),
        )

    def test_exact_release_is_published_and_freshly_confirmed(self) -> None:
        client = successful_client()
        tag_checks = 0
        absence_checks = 0

        def verify_tag() -> None:
            nonlocal tag_checks
            tag_checks += 1

        def verify_tag_absent() -> None:
            nonlocal absence_checks
            absence_checks += 1

        publish_release(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_verifier=verify_tag,
            tag_absence_verifier=verify_tag_absent,
            sleeper=lambda _: None,
        )
        self.assertEqual(tag_checks, 1)
        self.assertEqual(absence_checks, 2)
        self.assertEqual(
            [
                call
                for call in client.calls
                if call[0] == "PATCH"
            ],
            [
                (
                    "PATCH",
                    f"/repos/{REPOSITORY}/releases/{RELEASE_ID}",
                    {
                        "draft": False,
                        "prerelease": False,
                        "make_latest": "true",
                    },
                )
            ],
        )
        self.assertEqual(
            len(
                [
                    call
                    for call in client.calls
                    if call[:2]
                    == (
                        "GET",
                        f"/repos/{REPOSITORY}/releases/{RELEASE_ID}",
                    )
                ]
            ),
            3,
        )

    def test_ambiguous_patch_succeeds_only_when_live_release_is_exact(self) -> None:
        client = successful_client(
            patch_response=PUBLISH.PublishError("synthetic timeout")
        )
        publish_release(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_verifier=lambda: None,
            sleeper=lambda _: None,
        )

    def test_final_draft_reread_rejects_metadata_change(self) -> None:
        client = successful_client()
        changed = release_payload(draft=True, immutable=False)
        changed["body"] = "Changed after the candidate manifest.\n"
        client.responses[
            ("GET", f"/repos/{REPOSITORY}/releases/{RELEASE_ID}")
        ][0] = changed
        with self.assertRaisesRegex(PUBLISH.PublishError, "metadata changed"):
            publish_release(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_verifier=lambda: None,
                sleeper=lambda _: None,
            )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))

    def test_draft_verification_rejects_noncanonical_metadata(self) -> None:
        payload = release_payload(draft=True, immutable=False)
        client = FakeClient(
            {
                (
                    "GET",
                    f"/repos/{REPOSITORY}/releases/tags/{TAG}",
                ): [payload]
            }
        )
        with self.assertRaisesRegex(PUBLISH.PublishError, "metadata changed"):
            PUBLISH.verify_draft_candidate(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_absence_verifier=lambda: None,
                expected_name="NOOP wrong",
                expected_body_sha256=PUBLISH.hashlib.sha256(
                    payload["body"].encode("utf-8")
                ).hexdigest(),
                expected_target=SHA,
            )

    def test_post_publish_asset_change_is_rejected(self) -> None:
        changed = release_payload(draft=False, immutable=True)
        changed["assets"] = changed["assets"][:-1]
        client = successful_client(first_live=changed)
        client.responses[
            ("GET", f"/repos/{REPOSITORY}/releases/{RELEASE_ID}")
        ] = [
            release_payload(draft=True, immutable=False),
            changed,
            changed,
            changed,
        ]
        with self.assertRaisesRegex(PUBLISH.PublishError, "asset set"):
            publish_release(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_verifier=lambda: None,
                sleeper=lambda _: None,
            )

    def test_stale_post_publish_state_is_retried(self) -> None:
        stale = release_payload(draft=True, immutable=False)
        exact = release_payload(draft=False, immutable=True)
        client = successful_client(first_live=stale, confirmed_live=exact)
        client.responses[
            ("GET", f"/repos/{REPOSITORY}/releases/{RELEASE_ID}")
        ].append(exact)
        publish_release(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_verifier=lambda: None,
            sleeper=lambda _: None,
        )

    def test_open_asset_is_rejected_before_publication(self) -> None:
        responses: dict[tuple[str, str], list[Any]] = {}
        draft = release_payload(draft=True, immutable=False)
        draft["assets"][0]["state"] = "open"
        responses[
            ("GET", f"/repos/{REPOSITORY}/releases/tags/{TAG}")
        ] = [draft]
        client = FakeClient(responses)
        with self.assertRaisesRegex(PUBLISH.PublishError, "asset inventory"):
            publish_release(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_verifier=lambda: None,
            )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))

    def test_published_release_must_report_immutable(self) -> None:
        client = successful_client(
            first_live=release_payload(draft=False, immutable=False)
        )
        mutable = release_payload(draft=False, immutable=False)
        client.responses[
            ("GET", f"/repos/{REPOSITORY}/releases/{RELEASE_ID}")
        ] = [
            release_payload(draft=True, immutable=False),
            mutable,
            mutable,
            mutable,
        ]
        with self.assertRaisesRegex(PUBLISH.PublishError, "not immutable"):
            publish_release(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_verifier=lambda: None,
                sleeper=lambda _: None,
            )

    def test_disabled_immutable_releases_fail_before_mutation(self) -> None:
        responses = policy_responses()
        responses[
            ("GET", f"/repos/{REPOSITORY}/immutable-releases")
        ] = [{"enabled": False}]
        client = FakeClient(responses)
        with self.assertRaisesRegex(PUBLISH.PublishError, "not enabled"):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_ruleset_bypass_fails_before_mutation(self) -> None:
        responses = policy_responses()
        detail_key = ("GET", f"/repos/{REPOSITORY}/rulesets/7")
        detail = responses[detail_key][0]
        detail["current_user_can_bypass"] = "always"
        client = FakeClient(responses)
        with self.assertRaisesRegex(PUBLISH.PublishError, "not fail closed"):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_ruleset_rules_must_be_exact_and_unique(self) -> None:
        baseline = policy_responses()
        detail_key = ("GET", f"/repos/{REPOSITORY}/rulesets/7")
        for rules in (
            [
                {"type": "update"},
                {"type": "deletion"},
                {"type": "update"},
            ],
            [
                {"type": "update"},
                {"type": "deletion", "parameters": {}},
            ],
            [{"type": "update"}, "deletion"],
        ):
            with self.subTest(rules=rules):
                responses = copy.deepcopy(baseline)
                responses[detail_key][0]["rules"] = rules
                client = FakeClient(responses)
                with self.assertRaisesRegex(
                    PUBLISH.PublishError, "lacks exact controls"
                ):
                    PUBLISH.verify_repository_policy(
                        client,
                        REPOSITORY,
                        activation_contract=ACTIVATION_CONTRACT,
                    )

    def test_owner_only_creation_ruleset_is_required(self) -> None:
        responses = policy_responses()
        inventory_key = (
            "GET",
            f"/repos/{REPOSITORY}/rulesets?per_page=100",
        )
        responses[inventory_key][0] = responses[inventory_key][0][:1]
        client = FakeClient(responses)
        with self.assertRaisesRegex(
            PUBLISH.PublishError, "immutable and creation"
        ):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_creation_bypass_must_be_admin_role_only(self) -> None:
        responses = policy_responses()
        detail_key = ("GET", f"/repos/{REPOSITORY}/rulesets/8")
        responses[detail_key][0]["bypass_actors"] = []
        client = FakeClient(responses)
        with self.assertRaisesRegex(
            PUBLISH.PublishError, "creation ruleset is not fail closed"
        ):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_non_owner_writer_blocks_publication(self) -> None:
        responses = policy_responses()
        collaborator_key = (
            "GET",
            f"/repos/{REPOSITORY}/collaborators?affiliation=all&per_page=100",
        )
        responses[collaborator_key][0][1]["permissions"]["push"] = True
        client = FakeClient(responses)
        with self.assertRaisesRegex(PUBLISH.PublishError, "only writer"):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_ruleset_inventory_must_fit_one_complete_page(self) -> None:
        responses = policy_responses()
        inventory_key = (
            "GET",
            f"/repos/{REPOSITORY}/rulesets?per_page=100",
        )
        responses[inventory_key][0] = [
            {
                "id": index + 1,
                "name": f"ruleset-{index}",
                "target": "branch",
                "enforcement": "active",
            }
            for index in range(100)
        ]
        client = FakeClient(responses)
        with self.assertRaisesRegex(PUBLISH.PublishError, "ambiguous"):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_tag_failure_stops_before_publication(self) -> None:
        responses = policy_responses()
        responses[
            ("GET", f"/repos/{REPOSITORY}/releases/tags/{TAG}")
        ] = [release_payload(draft=True, immutable=False)]
        client = FakeClient(responses)

        def reject_tag_absence() -> None:
            raise PUBLISH.TAG_GATE.GateError(
                "release tag already exists before publication"
            )

        with self.assertRaisesRegex(PUBLISH.PublishError, "already exists"):
            publish_release(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_absence_verifier=reject_tag_absence,
            )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))

    def test_testing_snapshot_is_published_as_immutable_prerelease(self) -> None:
        testing_tag = "testing-snapshot-12345-2"
        client = successful_client(prerelease=True, tag=testing_tag)
        publish_testing_snapshot(
            REPOSITORY,
            testing_tag,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_verifier=lambda: None,
            sleeper=lambda _: None,
        )
        patch = next(call for call in client.calls if call[0] == "PATCH")
        self.assertEqual(
            patch[2],
            {
                "draft": False,
                "prerelease": True,
                "make_latest": "false",
            },
        )

    def test_inputs_are_strict(self) -> None:
        with self.assertRaisesRegex(PUBLISH.PublishError, "do not match"):
            publish_release(
                REPOSITORY,
                TAG,
                "9.2.2",
                SHA,
                "synthetic-token",
                client=FakeClient({}),
                tag_verifier=lambda: None,
            )

    def test_publication_rechecks_policy_immediately_before_mutation(self) -> None:
        client = successful_client()
        checks = 0

        def verify_policy() -> None:
            nonlocal checks
            checks += 1

        PUBLISH.publish_release(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            candidate_manifest=PUBLISH.create_candidate_manifest(
                release_payload(draft=True, immutable=False),
                repository=REPOSITORY,
                tag=TAG,
                version=VERSION,
                expected_sha=SHA,
                run_id=12345,
                run_attempt=1,
                prerelease=False,
            ),
            run_id=12345,
            run_attempt=1,
            client=client,
            tag_verifier=lambda: None,
            tag_absence_verifier=lambda: None,
            policy_verifier=verify_policy,
            sleeper=lambda _: None,
        )
        self.assertEqual(checks, 4)

    def test_final_draft_is_the_last_api_read_before_publication(self) -> None:
        client = successful_client()
        publish_release(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_verifier=lambda: None,
            sleeper=lambda _: None,
        )
        patch_index = next(
            index
            for index, call in enumerate(client.calls)
            if call[0] == "PATCH"
        )
        self.assertEqual(
            client.calls[patch_index - 1][:2],
            (
                "GET",
                f"/repos/{REPOSITORY}/releases/{RELEASE_ID}",
            ),
        )

    def test_exact_immutable_release_retry_is_idempotent(self) -> None:
        published = release_payload(draft=False, immutable=True)
        responses = {
            (
                "GET",
                f"/repos/{REPOSITORY}/releases/tags/{TAG}",
            ): [published],
            (
                "GET",
                f"/repos/{REPOSITORY}/releases/{RELEASE_ID}",
            ): [published],
        }
        client = FakeClient(responses)
        publish_release(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_verifier=lambda: None,
            sleeper=lambda _: None,
        )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))

    def test_testing_snapshot_uses_the_testing_tag_verifier(self) -> None:
        testing_tag = "testing-snapshot-12345-2"
        client = successful_client(prerelease=True, tag=testing_tag)
        ref_path = (
            f"/repos/{REPOSITORY}/git/ref/tags/{testing_tag}"
        )
        ref = {
            "ref": f"refs/tags/{testing_tag}",
            "object": {"type": "commit", "sha": SHA},
        }
        client.responses[("GET", ref_path)] = [ref, ref, ref, ref]
        publish_testing_snapshot(
            REPOSITORY,
            testing_tag,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            sleeper=lambda _: None,
        )

    def test_testing_tag_must_match_manifest_run_identity(self) -> None:
        testing_tag = "testing-snapshot-12345-2"
        with self.assertRaisesRegex(
            PUBLISH.PublishError, "does not match the workflow run"
        ):
            PUBLISH.create_candidate_manifest(
                release_payload(
                    draft=True,
                    immutable=False,
                    prerelease=True,
                    tag=testing_tag,
                ),
                repository=REPOSITORY,
                tag=testing_tag,
                version=VERSION,
                expected_sha=SHA,
                run_id=12346,
                run_attempt=2,
                prerelease=True,
            )

    def test_testing_policy_requires_the_testing_ruleset(self) -> None:
        client = FakeClient(policy_responses(testing_snapshot=True))
        PUBLISH.verify_repository_policy(
            client,
            REPOSITORY,
            testing_snapshot=True,
            activation_contract=ACTIVATION_CONTRACT,
        )

    def test_activation_requires_the_trusted_context(self) -> None:
        payload = {
            "schemaVersion": 2,
            "sourceBranch": "main",
            "requiredCheckAppId": PUBLISH.GITHUB_ACTIONS_APP_ID,
            "requiredContexts": REQUIRED_CONTEXTS[:-1],
            "universalWorkflows": [],
            "workflows": [],
        }
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "required-ci.json"
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(
                PUBLISH.PublishError, "activation is not complete"
            ):
                PUBLISH.load_release_activation_contract(path)

            payload["requiredContexts"] = REQUIRED_CONTEXTS
            payload["universalWorkflows"] = [
                {
                    "path": (
                        ".github/workflows/trusted-release-controls.yml"
                    ),
                    "pullRequestEvent": "pull_request_target",
                    "requiredJob": "trusted-release-controls",
                }
            ]
            path.write_text(json.dumps(payload), encoding="utf-8")
            self.assertEqual(
                PUBLISH.load_release_activation_contract(path),
                ACTIVATION_CONTRACT,
            )

    def test_live_branch_protection_must_match_activation_contract(
        self,
    ) -> None:
        responses = policy_responses()
        branch_key = (
            "GET",
            f"/repos/{REPOSITORY}/branches/main/protection/"
            "required_status_checks",
        )
        responses[branch_key][0]["checks"] = responses[branch_key][0][
            "checks"
        ][:-1]
        client = FakeClient(responses)
        with self.assertRaisesRegex(
            PUBLISH.PublishError, "does not enforce the exact release checks"
        ):
            PUBLISH.verify_repository_policy(
                client,
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
            )

    def test_policy_binds_the_exact_protected_main_commit(self) -> None:
        responses = policy_responses()
        client = FakeClient(responses)
        PUBLISH.verify_repository_policy(
            client,
            REPOSITORY,
            activation_contract=ACTIVATION_CONTRACT,
            protected_main_sha=SHA,
        )

        responses = policy_responses()
        main_key = (
            "GET",
            f"/repos/{REPOSITORY}/git/ref/heads/main",
        )
        responses[main_key][0]["object"]["sha"] = "b" * 40
        with self.assertRaisesRegex(PUBLISH.PublishError, "advanced"):
            PUBLISH.verify_repository_policy(
                FakeClient(responses),
                REPOSITORY,
                activation_contract=ACTIVATION_CONTRACT,
                protected_main_sha=SHA,
            )

    def test_draft_verification_never_mutates(self) -> None:
        responses = {
            (
                "GET",
                f"/repos/{REPOSITORY}/releases/tags/{TAG}",
            ): [release_payload(draft=True, immutable=False)],
        }
        client = FakeClient(responses)
        PUBLISH.verify_draft_candidate(
            REPOSITORY,
            TAG,
            VERSION,
            SHA,
            "synthetic-token",
            client=client,
            tag_absence_verifier=lambda: None,
        )
        self.assertTrue(all(call[0] == "GET" for call in client.calls))

    def test_changed_server_digest_is_rejected_before_publication(self) -> None:
        client = successful_client()
        draft_key = (
            "GET",
            f"/repos/{REPOSITORY}/releases/tags/{TAG}",
        )
        changed = release_payload(draft=True, immutable=False)
        changed["assets"][0]["digest"] = f"sha256:{'f' * 64}"
        client.responses[draft_key] = [changed]
        with self.assertRaisesRegex(PUBLISH.PublishError, "digest changed"):
            publish_release(
                REPOSITORY,
                TAG,
                VERSION,
                SHA,
                "synthetic-token",
                client=client,
                tag_verifier=lambda: None,
            )
        self.assertFalse(any(call[0] == "PATCH" for call in client.calls))


if __name__ == "__main__":
    unittest.main()
