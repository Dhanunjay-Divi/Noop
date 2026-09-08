from __future__ import annotations

import copy
import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "required-ci-gate.py"
SPEC = importlib.util.spec_from_file_location("required_ci_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class RequiredCIGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.config = GATE.load_config()

    def green_runs(self) -> list[dict[str, object]]:
        workflow_paths = GATE.required_workflow_paths(self.config)
        return [
            {
                "id": index,
                "name": context,
                "status": "completed",
                "conclusion": "success",
                "app": {"id": self.config["requiredCheckAppId"]},
                "workflowPath": workflow_paths[context],
            }
            for index, context in enumerate(
                self.config["requiredContexts"], start=1
            )
        ]

    def test_repository_required_workflows_fail_closed(self) -> None:
        GATE.check_repository()

    def test_every_reviewed_release_source_matches_its_digest(self) -> None:
        GATE.check_reviewed_release_sources(ROOT)

    def test_publication_authority_cannot_change_outside_reviewed_digest(
        self,
    ) -> None:
        for relative_path in (
            "Tools/github-release-publish.py",
            "Tools/github-release-tag-gate.py",
        ):
            with self.subTest(path=relative_path):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    path = root / relative_path
                    path.parent.mkdir(parents=True)
                    path.write_bytes(
                        (ROOT / relative_path).read_bytes()
                        + b"\n# synthetic direct publication bypass\n"
                    )
                    with self.assertRaisesRegex(
                        GATE.GateError, "reviewed source contract"
                    ):
                        GATE._require_reviewed_source_digest(
                            root, relative_path
                        )

    def test_release_build_uses_only_exact_green_main_source(self) -> None:
        GATE.check_release_workflow(ROOT)
        GATE.check_testing_release_workflow(ROOT)
        GATE.check_altstore_workflow(ROOT)
        GATE.check_forgejo_workflow(ROOT)
        GATE.check_homebrew_workflow(ROOT)
        GATE.check_release_control_test_suite(ROOT)
        GATE.check_local_release_entrypoint(ROOT)

    def test_required_contexts_are_the_protected_merge_contract(self) -> None:
        self.assertEqual(self.config["requiredCheckAppId"], 15368)
        self.assertEqual(
            self.config["requiredContexts"],
            [
                "android-ci-required",
                "apple-ci-required",
                "health-claims",
                "i18n-coverage",
                "operations-record",
                "release-controls",
                "runtime-license-required",
                "server-ci-required",
                "swift-packages-required",
            ],
        )

    def test_each_required_context_has_one_configured_workflow_owner(self) -> None:
        GATE.check_required_context_ownership(ROOT, self.config)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            rogue = root / ".github" / "workflows" / "rogue.yml"
            rogue.write_text(
                "name: Rogue\n"
                "on: [push]\n"
                "jobs:\n"
                "  duplicate:\n"
                "    name: release-controls\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "      - run: true\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "must have exactly one workflow owner"
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_dynamic_job_name_cannot_resolve_to_required_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            workflow = (
                root / ".github" / "workflows" / "release-controls.yml"
            )
            source = workflow.read_text(encoding="utf-8")
            source = source.replace(
                "jobs:\n",
                "jobs:\n"
                "  dynamic-duplicate:\n"
                "    name: ${{ 'release-controls' }}\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "      - run: true\n",
                1,
            )
            workflow.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError,
                "dynamic job name .* can resolve to required context",
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_unrelated_matrix_job_name_remains_allowed(self) -> None:
        self.assertFalse(
            GATE._dynamic_name_can_resolve_to_context(
                "swift-packages (${{ matrix.package }})",
                "swift-packages-required",
            )
        )

    def test_job_id_without_display_name_cannot_duplicate_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            rogue = root / ".github" / "workflows" / "rogue.yml"
            rogue.write_text(
                "name: Rogue\n"
                "on: [push]\n"
                "jobs:\n"
                "  release-controls:\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "      - run: true\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "must have exactly one workflow owner"
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_folded_job_display_name_is_rejected_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            rogue = root / ".github" / "workflows" / "rogue.yml"
            rogue.write_text(
                "name: Rogue\n"
                "on: [push]\n"
                "jobs:\n"
                "  folded:\n"
                "    name: >-\n"
                "      release-controls\n"
                "    runs-on: ubuntu-latest\n"
                "    steps:\n"
                "      - run: true\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "uses an unsupported display name"
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_inline_job_mapping_is_rejected_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            rogue = root / ".github" / "workflows" / "rogue.yml"
            rogue.write_text(
                "name: Rogue\n"
                "on: [push]\n"
                "jobs:\n"
                "  duplicate: {name: release-controls, "
                "runs-on: ubuntu-latest, steps: [{run: true}]}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "canonical two-space block syntax"
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_noncanonical_job_indentation_is_rejected_fail_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(
                ROOT / ".github" / "workflows",
                root / ".github" / "workflows",
            )
            rogue = root / ".github" / "workflows" / "rogue.yml"
            rogue.write_text(
                "name: Rogue\n"
                "on: [push]\n"
                "jobs:\n"
                "    duplicate:\n"
                "      name: release-controls\n"
                "      runs-on: ubuntu-latest\n"
                "      steps:\n"
                "        - run: true\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "canonical two-space block syntax"
            ):
                GATE.check_required_context_ownership(root, self.config)

    def test_noncanonical_job_name_key_is_rejected_fail_closed(self) -> None:
        for name_line in (
            '    "name": release-controls\n',
            "    name : release-controls\n",
        ):
            with self.subTest(name_line=name_line):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    shutil.copytree(
                        ROOT / ".github" / "workflows",
                        root / ".github" / "workflows",
                    )
                    rogue = root / ".github" / "workflows" / "rogue.yml"
                    rogue.write_text(
                        "name: Rogue\n"
                        "on: [push]\n"
                        "jobs:\n"
                        "  duplicate:\n"
                        f"{name_line}"
                        "    runs-on: ubuntu-latest\n"
                        "    steps:\n"
                        "      - run: true\n",
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(
                        GATE.GateError,
                        "must use canonical property key syntax",
                    ):
                        GATE.check_required_context_ownership(
                            root, self.config
                        )

    def test_universal_required_workflow_cannot_be_path_filtered(self) -> None:
        workflow = self.config["universalWorkflows"][2]
        source = (ROOT / workflow["path"]).read_text(encoding="utf-8")
        source = source.replace(
            "  push:\n    branches: [main]\n",
            "  push:\n    branches: [main]\n    paths: ['docs/ops/**']\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / workflow["path"]
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "universal check cannot use event-level path filters"
            ):
                GATE.check_universal_workflow(root, workflow)

    def test_event_level_path_filter_is_rejected(self) -> None:
        workflow = self.config["workflows"][0]
        source = (ROOT / workflow["path"]).read_text(encoding="utf-8")
        source = source.replace(
            "  pull_request:\n    branches: [main]\n",
            "  pull_request:\n    branches: [main]\n    paths: ['android/**']\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / workflow["path"]
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "event-level path filters"
            ):
                GATE.check_workflow(root, workflow)

    def test_apple_scope_covers_every_xcode_target_and_lock_input(self) -> None:
        text = (ROOT / ".github/workflows/app-build.yml").read_text(
            encoding="utf-8"
        )
        for marker in (
            "NOOPWatch|NOOPWatchComplications",
            "Strand\\.xcodeproj/project\\.xcworkspace/xcshareddata/swiftpm/"
            "Package\\.resolved",
            "LICENSE|NOTICE|ATTRIBUTION\\.md|DISCLAIMER\\.md|TERMS\\.md",
        ):
            self.assertIn(marker, text)

    def test_applicability_consumes_both_rename_paths_before_matching(self) -> None:
        for workflow in self.config["workflows"]:
            text = (ROOT / workflow["path"]).read_text(encoding="utf-8")
            section = GATE._job_section(text, workflow["applicabilityJob"])
            self.assertIn(
                'git diff --no-renames --name-only "$BASE_SHA" "$GITHUB_SHA"',
                section,
            )
            self.assertIn('> "$CHANGED_FILES"', section)
            self.assertNotRegex(
                section,
                r"git diff[^\n]*--name-only[^\n]*\|\s*\n\s*grep\s+-[A-Za-z]*q",
            )

    def test_release_dispatch_is_bound_to_the_verified_source_sha(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        dispatcher = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        self.assertIn("release_sha:", workflow)
        self.assertIn(
            "EXPECTED_RELEASE_SHA: ${{ github.event.inputs.release_sha }}",
            workflow,
        )
        self.assertIn('test "$GITHUB_SHA" = "$EXPECTED_RELEASE_SHA"', workflow)
        self.assertIn('--field "release_sha=$SOURCE_SHA"', dispatcher)
        self.assertIn('gh run watch "$RUN_ID"', dispatcher)
        self.assertIn('--tag "v${VERSION}"', dispatcher)
        self.assertNotIn("publish_altstore:", workflow)
        self.assertNotIn(
            "uses: ./.github/workflows/altstore-source.yml",
            workflow,
        )
        altstore = (
            ROOT / ".github/workflows/altstore-source.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("workflow_call:", altstore)
        self.assertNotIn("workflow_dispatch:", altstore)

    def test_altstore_channel_recovers_only_a_marked_initial_asset(self) -> None:
        text = (ROOT / ".github/workflows/altstore-source.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('select(.name == "altstore-source.json")', text)
        self.assertIn('INITIALIZING_MARKER="NOOP_ALTSTORE_STATE=initializing"', text)
        self.assertIn(
            'grep -Fq "$INITIALIZING_MARKER" <<<"$CHANNEL_BODY"',
            text,
        )
        self.assertIn('cp altstore-source.json "$MANIFEST"', text)

    def test_altstore_channel_preserves_history_before_clobber(self) -> None:
        text = (ROOT / ".github/workflows/altstore-source.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn('select(.name == "altstore-source.previous.json")', text)
        self.assertIn('elif [ "$SOURCE_ASSET_COUNT" = "0" ] &&', text)
        self.assertIn('BASE_SOURCE="backup"', text)
        backup_upload = text.index(
            'gh release upload "$CHANNEL_TAG" "$BACKUP"'
        )
        source_upload = text.index(
            'gh release upload "$CHANNEL_TAG" "$MANIFEST"'
        )
        self.assertLess(backup_upload, source_upload)

    def test_homebrew_opt_in_reaches_a_retryable_verified_workflow(self) -> None:
        release = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        dispatcher = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        homebrew = (ROOT / ".github/workflows/homebrew-cask.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("uses: ./.github/workflows/homebrew-cask.yml", release)
        self.assertIn(
            "gh workflow run homebrew-cask.yml",
            dispatcher,
        )
        self.assertIn(
            '--field "publish_forgejo=$PUBLISH_HOMEBREW_FORGEJO"',
            dispatcher,
        )
        self.assertIn("workflow_dispatch:", homebrew)
        self.assertIn("publish_forgejo:", homebrew)
        self.assertIn("timeout-minutes: 20", homebrew)
        self.assertIn("Tools/required-ci-gate.py verify-github", homebrew)
        self.assertIn("Tools/update-homebrew-cask.sh", homebrew)
        self.assertIn(
            "NOOP_HOMEBREW_FORGE_TOKEN: ${{ "
            "inputs.publish_forgejo && "
            "secrets.NOOP_HOMEBREW_FORGE_TOKEN || '' }}",
            homebrew,
        )
        helper = (ROOT / "Tools/update-homebrew-cask.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("Tools/homebrew-version-gate.py", helper)
        self.assertIn("http.lowSpeedLimit=1024", helper)
        self.assertIn("run_git_bounded", helper)

    def test_release_history_excludes_nonproduction_before_limit(self) -> None:
        release = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("--exclude-drafts --exclude-pre-releases --limit 1", release)
        self.assertEqual(release.count("gh release list"), 1)
        self.assertIn('PREV="$PREV_TAG"', release)
        self.assertNotIn("map(select(.isPrerelease", release)

    def test_forgejo_opt_in_reaches_a_retryable_verified_workflow(self) -> None:
        release = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        dispatcher = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        forgejo = (ROOT / ".github/workflows/forgejo-release.yml").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("uses: ./.github/workflows/forgejo-release.yml", release)
        self.assertIn(
            "gh workflow run forgejo-release.yml",
            dispatcher,
        )
        self.assertIn("workflow_dispatch:", forgejo)
        self.assertIn("timeout-minutes: 45", forgejo)
        self.assertIn("Tools/required-ci-gate.py verify-github", forgejo)
        self.assertIn("Tools/forgejo-release.sh", forgejo)

    def test_release_controls_run_publication_safety_tests(self) -> None:
        workflow = (ROOT / ".github/workflows/release-controls.yml").read_text(
            encoding="utf-8"
        )
        for module in (
            "Tools.tests.test_forgejo_release_helper",
            "Tools.tests.test_forgejo_version_gate",
            "Tools.tests.test_github_release_publish",
            "Tools.tests.test_github_release_tag_gate",
            "Tools.tests.test_homebrew_helper",
            "Tools.tests.test_homebrew_version_gate",
            "Tools.tests.test_testing_release_workflow",
            "Tools.tests.test_trusted_release_controls",
        ):
            self.assertIn(module, workflow)
        self.assertIn(
            "bash -n Tools/release.sh Tools/publish-testing-snapshot.sh",
            workflow,
        )
        self.assertIn(
            "shellcheck Tools/release.sh Tools/publish-testing-snapshot.sh",
            workflow,
        )

    def test_release_shell_validation_is_required(self) -> None:
        source = (
            ROOT / ".github/workflows/release-controls.yml"
        ).read_text(encoding="utf-8")
        for command in (
            "bash -n Tools/release.sh Tools/publish-testing-snapshot.sh",
            "shellcheck Tools/release.sh Tools/publish-testing-snapshot.sh",
        ):
            with self.subTest(command=command):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    path = root / ".github/workflows/release-controls.yml"
                    path.parent.mkdir(parents=True)
                    path.write_text(
                        source.replace(command, "echo skipped", 1),
                        encoding="utf-8",
                    )
                    with self.assertRaisesRegex(
                        GATE.GateError, "does not run"
                    ):
                        GATE.check_release_control_test_suite(root)

    def test_release_workflow_can_only_record_the_exact_draft(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        ready = GATE._job_section(source, "ready")
        checks_step = GATE._named_step(
            ready, "Reverify required checks for exact candidate"
        )
        self.assertEqual(
            GATE._folded_run_command(
                checks_step, "Reverify required checks for exact candidate"
            ),
            'python3 Tools/required-ci-gate.py verify-github '
            '--repository "$GITHUB_REPOSITORY" '
            '--sha "$RELEASE_SHA"',
        )
        self.assertEqual(
            GATE._step_environment(
                checks_step, "Reverify required checks for exact candidate"
            ),
            {
                "GH_TOKEN": "${{ github.token }}",
                "RELEASE_SHA": "${{ needs.bump.outputs.sha }}",
            },
        )
        draft_step = GATE._named_step(ready, "Record exact release draft")
        self.assertEqual(
            GATE._folded_run_command(
                draft_step, "Record exact release draft"
            ),
            'python3 Tools/github-release-publish.py '
            '--repository "$GITHUB_REPOSITORY" '
            '--tag "$TAG" '
            '--version "$VER" '
            '--expected-sha "$RELEASE_SHA" '
            '--expected-name "NOOP $VER" '
            '--expected-body-sha256 "$BODY_SHA" '
            '--expected-target "$RELEASE_SHA" '
            '--verify-draft-only '
            '--write-manifest "$RUNNER_TEMP/release-candidate.json" '
            '--run-id "$GITHUB_RUN_ID" '
            '--run-attempt "$GITHUB_RUN_ATTEMPT"',
        )
        self.assertEqual(
            GATE._step_environment(
                draft_step, "Record exact release draft"
            ),
            {
                "GH_TOKEN": "${{ github.token }}",
                "TAG": "${{ needs.bump.outputs.tag }}",
                "VER": "${{ needs.bump.outputs.ver }}",
                "RELEASE_SHA": "${{ needs.bump.outputs.sha }}",
                "BODY_SHA": "${{ needs.bump.outputs.bodySha }}",
            },
        )

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(
                source.replace(
                    '--expected-sha "$RELEASE_SHA"',
                    '--expected-sha "$(git rev-parse HEAD)"',
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "exact draft verifier"
            ):
                GATE.check_release_workflow(root)

        for step_name, command in (
            (
                "Reverify required checks for exact candidate",
                "          python3 Tools/required-ci-gate.py verify-github",
            ),
            (
                "Record exact release draft",
                "          python3 Tools/github-release-publish.py",
            ),
        ):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / ".github/workflows/release.yml"
                path.parent.mkdir(parents=True)
                path.write_text(
                    source.replace(
                        f"      - name: {step_name}\n",
                        f"      - name: {step_name}\n        if: false\n",
                        1,
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    GATE.GateError, "only canonical env and run"
                ):
                    GATE.check_release_workflow(root)
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / ".github/workflows/release.yml"
                path.parent.mkdir(parents=True)
                path.write_text(
                    source.replace(command, "          echo bypassed", 1),
                    encoding="utf-8",
                )
                with self.assertRaises(GATE.GateError):
                    GATE.check_release_workflow(root)

        for property_line in ("    if: false\n", "    continue-on-error: true\n"):
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                path = root / ".github/workflows/release.yml"
                path.parent.mkdir(parents=True)
                path.write_text(
                    source.replace(
                        "  ready:\n"
                        "    name: release-candidate-ready\n"
                        "    needs: [bump, android, macos, ios]\n"
                        "    runs-on: ubuntu-latest\n",
                        "  ready:\n"
                        "    name: release-candidate-ready\n"
                        "    needs: [bump, android, macos, ios]\n"
                        "    runs-on: ubuntu-latest\n"
                        + property_line,
                        1,
                    ),
                    encoding="utf-8",
                )
                with self.assertRaisesRegex(
                    GATE.GateError, "canonical required properties"
                ):
                    GATE.check_release_workflow(root)

    def test_release_workflow_rejects_an_extra_write_capable_job(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        source = source.replace(
            "jobs:\n",
            "jobs:\n"
            "  ship:\n"
            "    permissions:\n"
            "      contents: write\n"
            "    runs-on: ubuntu-latest\n"
            "    steps:\n"
            "      - run: gh api --method PATCH "
            "repos/example/project/releases/1 -f draft=false\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "exact allowlist"
            ):
                GATE.check_release_workflow(root)

    def test_release_signing_secrets_are_environment_scoped(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        bump = GATE._job_section(source, "bump")
        android = GATE._job_section(source, "android")
        self.assertNotIn("ANDROID_STAGING_KEYSTORE_BASE64", bump)
        self.assertIn("    environment: staging\n", android)
        for secret in (
            "ANDROID_STAGING_KEYSTORE_BASE64",
            "ANDROID_STAGING_STORE_PASSWORD",
            "ANDROID_STAGING_KEY_ALIAS",
            "ANDROID_STAGING_KEY_PASSWORD",
        ):
            self.assertIn(secret, android)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(
                source.replace("    environment: staging\n", "", 1),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                GATE.GateError, "protected staging environment"
            ):
                GATE.check_release_workflow(root)

    def test_release_workflow_rejects_direct_release_api_mutation(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        source = source.replace(
            "\n  android_tests:\n",
            "      - name: Direct publication bypass\n"
            "        run: gh api --method PATCH "
            "repos/example/project/releases/1 -f draft=false\n"
            "\n  android_tests:\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "direct release API mutation|draft publication"
            ):
                GATE.check_release_workflow(root)

    def test_testing_workflow_rejects_direct_release_api_mutation(self) -> None:
        source = (ROOT / ".github/workflows/testing-build.yml").read_text(
            encoding="utf-8"
        )
        source = source.replace(
            "\n  android:\n",
            "      - name: Direct publication bypass\n"
            "        run: gh api -X PATCH "
            "repos/example/project/releases/1 -f draft=false\n"
            "\n  android:\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/testing-build.yml"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "direct release API mutation|draft publication"
            ):
                GATE.check_testing_release_workflow(root)

    def test_obfuscated_publication_command_breaks_reviewed_source(self) -> None:
        cases = (
            (
                ".github/workflows/release.yml",
                "\n  android_tests:\n",
                "      - name: Obfuscated publication bypass\n"
                "        run: g\"\"h api -X PATCH "
                "repos/example/project/releases/1 -f draf\"\"t=false\n"
                "\n  android_tests:\n",
                GATE.check_release_workflow,
            ),
            (
                ".github/workflows/testing-build.yml",
                "\n  android:\n",
                "      - name: Obfuscated publication bypass\n"
                "        run: g\"\"h api -X PATCH "
                "repos/example/project/releases/1 -f draf\"\"t=false\n"
                "\n  android:\n",
                GATE.check_testing_release_workflow,
            ),
        )
        for relative_path, marker, replacement, check in cases:
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                source = source.replace(marker, replacement, 1)
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    path = root / relative_path
                    path.parent.mkdir(parents=True)
                    path.write_text(source, encoding="utf-8")
                    with self.assertRaisesRegex(
                        GATE.GateError, "reviewed source contract"
                    ):
                        check(root)

    def test_testing_cleanup_is_an_exact_reviewed_source_contract(self) -> None:
        relative_path = ".github/workflows/testing-build.yml"
        source = (ROOT / relative_path).read_text(encoding="utf-8")
        source = source.replace(
            "\n  cleanup:\n",
            "\n  cleanup:\n"
            "    # Synthetic unrelated release mutation.\n"
            "    # gh release delete v9.1.1 --repo \"$GITHUB_REPOSITORY\" --yes\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / relative_path
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "reviewed source contract"
            ):
                GATE.check_testing_release_workflow(root)

    def test_required_job_cannot_ignore_a_heavy_job(self) -> None:
        workflow = self.config["workflows"][0]
        source = (ROOT / workflow["path"]).read_text(encoding="utf-8")
        source = source.replace(
            "${{ needs.production-shell.result }}",
            "ignored-production-shell-result",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / workflow["path"]
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(GATE.GateError, "ignores production-shell"):
                GATE.check_workflow(root, workflow)

    def test_android_infrastructure_retry_is_bounded_and_fail_closed(self) -> None:
        source = (ROOT / ".github/workflows/android.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("timeout-minutes: 70", source)
        self.assertEqual(source.count("continue-on-error: true"), 1)
        self.assertIn("Tools/android-managed-device-retry.py", source)
        self.assertEqual(source.count("Tools/run-bounded-command.py"), 5)
        self.assertEqual(source.count("--timeout-seconds 720"), 2)
        self.assertEqual(source.count("--timeout-seconds 900"), 2)
        self.assertEqual(source.count("--timeout-seconds 180"), 1)
        self.assertEqual(source.count("--status-file "), 5)
        self.assertEqual(source.count("app/build/noop-managed-device-status/"), 7)
        self.assertEqual(source.count("--no-configuration-cache"), 5)
        self.assertIn("test_run_bounded_command.py", source)
        self.assertIn("test_android_managed_device_retry.py", source)
        self.assertIn("assembleFullDebugAndroidTest", source)
        self.assertIn("pixel2Api35Setup", source)
        self.assertIn("cleanManagedDevices", source)
        self.assertIn("--bounded-status-file ", source)
        self.assertIn(
            "android.testInstrumentationRunnerArguments.notClass="
            "com.noop.ui.ReviewSampleInstrumentedTest",
            source,
        )
        self.assertIn(
            "steps.review_sample_first.outcome == 'failure'",
            source,
        )
        self.assertIn(
            "steps.review_sample_retry.outputs.retry == 'true'",
            source,
        )
        self.assertNotIn("--rerun-tasks", source)
        self.assertIn(
            "Tools/(android-managed-device-retry|run-bounded-command)\\.py$",
            source,
        )

    def test_latest_check_run_must_be_completed_success(self) -> None:
        runs = self.green_runs()
        GATE.evaluate_check_runs(self.config, runs)
        runs.append(
            {
                "id": 1000,
                "name": "release-controls",
                "status": "completed",
                "conclusion": "failure",
                "app": {"id": self.config["requiredCheckAppId"]},
                "workflowPath": GATE.required_workflow_paths(self.config)[
                    "release-controls"
                ],
            }
        )
        with self.assertRaisesRegex(
            GATE.GateError, "release-controls=completed/failure"
        ):
            GATE.evaluate_check_runs(self.config, runs)

    def test_missing_required_check_is_rejected(self) -> None:
        config = copy.deepcopy(self.config)
        with self.assertRaisesRegex(GATE.GateError, "android-ci-required=missing"):
            GATE.evaluate_check_runs(config, [])

    def test_same_named_check_from_another_app_is_rejected(self) -> None:
        runs = self.green_runs()
        runs = [
            run for run in runs if run["name"] != "release-controls"
        ]
        runs.append(
            {
                "id": 1000,
                "name": "release-controls",
                "status": "completed",
                "conclusion": "success",
                "app": {"id": 1},
            }
        )
        with self.assertRaisesRegex(
            GATE.GateError, "release-controls=missing"
        ):
            GATE.evaluate_check_runs(self.config, runs)

    def test_required_check_from_another_workflow_is_rejected(self) -> None:
        runs = self.green_runs()
        for run in runs:
            if run["name"] == "release-controls":
                run["workflowPath"] = ".github/workflows/rogue.yml"
        with self.assertRaisesRegex(
            GATE.GateError, "release-controls=unexpected-workflow"
        ):
            GATE.evaluate_check_runs(self.config, runs)

    def test_workflow_run_url_is_repository_and_job_bound(self) -> None:
        url = (
            "https://github.com/Dhanunjay-Divi/Noop/"
            "actions/runs/34166917443/job/101879686504"
        )
        self.assertEqual(
            GATE._workflow_run_id(url, "Dhanunjay-Divi/Noop"),
            34166917443,
        )
        for invalid in (
            "http://github.com/Dhanunjay-Divi/Noop/actions/runs/1/job/2",
            "https://github.com/other/Noop/actions/runs/1/job/2",
            "https://github.com/Dhanunjay-Divi/Noop/actions/runs/1",
            "https://example.com/Dhanunjay-Divi/Noop/actions/runs/1/job/2",
        ):
            with self.assertRaisesRegex(GATE.GateError, "no valid run URL"):
                GATE._workflow_run_id(invalid, "Dhanunjay-Divi/Noop")

    def test_workflow_run_payload_is_bound_to_exact_sha(self) -> None:
        sha = "a" * 40
        payload = {
            "id": 123,
            "head_sha": sha,
            "path": ".github/workflows/release-controls.yml",
        }
        self.assertEqual(
            GATE._workflow_path_from_run(payload, 123, sha),
            ".github/workflows/release-controls.yml",
        )
        with self.assertRaisesRegex(GATE.GateError, "identity is invalid"):
            GATE._workflow_path_from_run(payload, 123, "b" * 40)

    def test_trusted_exact_head_check_is_bound_to_run_attempt_and_sha(
        self,
    ) -> None:
        sha = "a" * 40
        check = {
            "details_url": (
                "https://github.com/Dhanunjay-Divi/Noop/actions/runs/123"
            ),
            "external_id": (
                f"trusted-release-controls:pull-request:123:2:{sha}"
            ),
        }
        self.assertEqual(
            GATE._trusted_workflow_run_identity(
                check, "Dhanunjay-Divi/Noop", sha
            ),
            ("pull-request", 123, 2),
        )
        canonical_check = {
            **check,
            "id": 789,
            "details_url": (
                "https://github.com/Dhanunjay-Divi/Noop/runs/789"
            ),
        }
        self.assertEqual(
            GATE._trusted_workflow_run_identity(
                canonical_check, "Dhanunjay-Divi/Noop", sha
            ),
            ("pull-request", 123, 2),
        )
        payload = {
            "id": 123,
            "run_attempt": 2,
            "event": "pull_request_target",
            "status": "completed",
            "path": ".github/workflows/trusted-release-controls.yml",
            "head_repository": {"full_name": "Dhanunjay-Divi/Noop"},
        }
        self.assertEqual(
            GATE._workflow_path_from_trusted_run(
                payload,
                scope="pull-request",
                run_id=123,
                run_attempt=2,
                repository="Dhanunjay-Divi/Noop",
                expected_sha=sha,
            ),
            ".github/workflows/trusted-release-controls.yml",
        )
        for invalid in (
            {
                **check,
                "external_id": (
                    "trusted-release-controls:pull-request:123:2:"
                    + "b" * 40
                ),
            },
            {
                **check,
                "details_url": (
                    "https://github.com/Dhanunjay-Divi/Noop/"
                    "actions/runs/124"
                ),
            },
            {
                **canonical_check,
                "details_url": (
                    "https://github.com/Dhanunjay-Divi/Noop/runs/790"
                ),
            },
        ):
            with self.assertRaises(GATE.GateError):
                GATE._trusted_workflow_run_identity(
                    invalid, "Dhanunjay-Divi/Noop", sha
                )

    def test_trusted_workflow_has_no_branch_dispatch_bypass(self) -> None:
        source = (
            ROOT / ".github/workflows/trusted-release-controls.yml"
        ).read_text(encoding="utf-8")
        self.assertNotIn("workflow_dispatch:", source)
        self.assertIn("checks: write", source)
        self.assertIn(
            "Tools/trusted-release-controls.py report-check", source
        )
        self.assertNotIn("\n    name: trusted-release-controls\n", source)
        GATE.check_trusted_release_workflow(ROOT)

    def test_trusted_custom_context_is_ready_for_second_phase(self) -> None:
        config = copy.deepcopy(self.config)
        config["requiredContexts"].append("trusted-release-controls")
        config["requiredContexts"].sort()
        trusted = {
            "path": ".github/workflows/trusted-release-controls.yml",
            "pullRequestEvent": "pull_request_target",
            "requiredJob": "trusted-release-controls",
        }
        config["universalWorkflows"].append(trusted)
        GATE.check_universal_workflow(ROOT, trusted)
        GATE.check_required_context_ownership(ROOT, config)

    def test_protected_main_trusted_run_is_exact_sha_bound(self) -> None:
        sha = "c" * 40
        payload = {
            "id": 456,
            "run_attempt": 3,
            "event": "push",
            "status": "completed",
            "path": ".github/workflows/trusted-release-controls.yml",
            "head_sha": sha,
            "head_repository": {"full_name": "Dhanunjay-Divi/Noop"},
        }
        self.assertEqual(
            GATE._workflow_path_from_trusted_run(
                payload,
                scope="protected-main",
                run_id=456,
                run_attempt=3,
                repository="Dhanunjay-Divi/Noop",
                expected_sha=sha,
            ),
            ".github/workflows/trusted-release-controls.yml",
        )
        with self.assertRaisesRegex(GATE.GateError, "identity is invalid"):
            GATE._workflow_path_from_trusted_run(
                payload,
                scope="protected-main",
                run_id=456,
                run_attempt=3,
                repository="Dhanunjay-Divi/Noop",
                expected_sha="d" * 40,
            )

    def test_pull_request_trust_cannot_satisfy_release_verification(
        self,
    ) -> None:
        config = copy.deepcopy(self.config)
        config["requiredContexts"].append("trusted-release-controls")
        config["requiredContexts"].sort()
        config["universalWorkflows"].append(
            {
                "path": ".github/workflows/trusted-release-controls.yml",
                "pullRequestEvent": "pull_request_target",
                "requiredJob": "trusted-release-controls",
            }
        )
        workflow_paths = GATE.required_workflow_paths(config)
        runs = [
            {
                "id": index,
                "name": context,
                "status": "completed",
                "conclusion": "success",
                "app": {"id": config["requiredCheckAppId"]},
                "workflowPath": workflow_paths[context],
                **(
                    {"trustedScope": "pull-request"}
                    if context == "trusted-release-controls"
                    else {}
                ),
            }
            for index, context in enumerate(
                config["requiredContexts"], start=1
            )
        ]
        with self.assertRaisesRegex(
            GATE.GateError, "trusted-release-controls=missing"
        ):
            GATE.evaluate_check_runs(config, runs)
        runs[-1]["trustedScope"] = "protected-main"
        GATE.evaluate_check_runs(config, runs)

    def test_release_workflow_cannot_push_directly_to_main(self) -> None:
        source = (ROOT / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        source = source.replace(
            "name: Community release build\n",
            "name: Community release build\n"
            "# git push origin HEAD:refs/heads/main\n",
            1,
        )
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / ".github/workflows/release.yml"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "cannot push directly to main"
            ):
                GATE.check_release_workflow(root)

    def test_local_release_entrypoint_cannot_bypass_the_publisher(self) -> None:
        source = (ROOT / "Tools/release.sh").read_text(encoding="utf-8")
        source += "\ngh release upload v1.2.3 app.ipa\n"
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            path = root / "Tools/release.sh"
            path.parent.mkdir(parents=True)
            path.write_text(source, encoding="utf-8")
            with self.assertRaisesRegex(
                GATE.GateError, "retains direct publication"
            ):
                GATE.check_local_release_entrypoint(root)

    def test_owner_entrypoints_reject_raw_release_api_mutation(self) -> None:
        cases = (
            (
                "Tools/release.sh",
                GATE.check_local_release_entrypoint,
            ),
            (
                "Tools/publish-testing-snapshot.sh",
                GATE.check_local_testing_entrypoint,
            ),
        )
        for relative_path, check in cases:
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                source += (
                    "\ngh api --method PATCH "
                    "repos/example/project/releases/1 -f draft=false\n"
                )
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    path = root / relative_path
                    path.parent.mkdir(parents=True)
                    path.write_text(source, encoding="utf-8")
                    with self.assertRaisesRegex(
                        GATE.GateError, "raw GitHub API mutation"
                    ):
                        check(root)

    def test_owner_entrypoints_reject_obfuscated_mutation(self) -> None:
        cases = (
            (
                "Tools/release.sh",
                GATE.check_local_release_entrypoint,
            ),
            (
                "Tools/publish-testing-snapshot.sh",
                GATE.check_local_testing_entrypoint,
            ),
        )
        for relative_path, check in cases:
            with self.subTest(path=relative_path):
                source = (ROOT / relative_path).read_text(encoding="utf-8")
                source += (
                    "\ng\"\"h api -X PATCH "
                    "repos/example/project/releases/1 -f draf\"\"t=false\n"
                )
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    path = root / relative_path
                    path.parent.mkdir(parents=True)
                    path.write_text(source, encoding="utf-8")
                    with self.assertRaisesRegex(
                        GATE.GateError, "reviewed source contract"
                    ):
                        check(root)


if __name__ == "__main__":
    unittest.main()
