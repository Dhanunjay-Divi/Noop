from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest import mock
import urllib.request


ROOT = Path(__file__).resolve().parents[2]


def load_script(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {relative_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pilot = load_script(
    "noop_manage_native_pilot",
    "infra/gcp/scripts/manage-native-pilot.py",
)
relay = load_script(
    "noop_private_native_relay",
    "infra/gcp/scripts/private-native-relay.py",
)


class NativePilotToolTests(unittest.TestCase):
    def test_google_oauth_control_request_sets_quota_project(self) -> None:
        response = mock.MagicMock()
        response.status = 200
        response.read.return_value = b"{}"
        response.__enter__.return_value = response
        with mock.patch.object(
            urllib.request,
            "urlopen",
            return_value=response,
        ) as opened:
            self.assertEqual(
                pilot.google_request(
                    "identitytoolkit.googleapis.com",
                    "/admin/v2/projects/project/config",
                    operation="identity_config",
                    method="GET",
                    oauth_token="access-token",
                    quota_project="project",
                ),
                {},
            )
        request = opened.call_args.args[0]
        self.assertEqual(request.get_header("X-goog-user-project"), "project")
        self.assertEqual(request.get_header("Authorization"), "Bearer access-token")

    def test_relay_accepts_only_private_cloud_run_origin(self) -> None:
        expected = "https://noop-managed-example.asia-south1.run.app"
        self.assertEqual(
            relay.validated_target({"public": False, "uri": expected}),
            expected,
        )
        for value in [
            {"public": True, "uri": expected},
            {"public": False, "uri": "http://noop-managed-example.run.app"},
            {"public": False, "uri": "https://user@noop-managed-example.run.app"},
            {"public": False, "uri": "https://noop-managed-example.run.app/path"},
            {"public": False, "uri": "https://noop.example"},
        ]:
            with self.assertRaises(relay.RelayFailure):
                relay.validated_target(value)

    def test_relay_request_allowlist_rejects_external_or_fragment_targets(self) -> None:
        for value in [
            "/v1/managed/enroll",
            "/v1/managed/restore?cursor=opaque",
            "/healthz",
            "/readyz",
        ]:
            self.assertTrue(relay.allowed_request_target(value))
        for value in [
            "https://example.test/v1/managed/enroll",
            "//example.test/v1/managed/enroll",
            "/v1/managed/enroll#fragment",
            "/v1/public/enroll",
            "/" + ("x" * 4096),
        ]:
            self.assertFalse(relay.allowed_request_target(value))

    def test_relay_never_follows_upstream_redirects(self) -> None:
        handler = relay.NoRedirectHandler()
        request = mock.Mock()
        self.assertIsNone(
            handler.redirect_request(
                request,
                None,
                302,
                "Found",
                {},
                "https://outside.example",
            )
        )

    def test_debug_state_is_mode_bounded_and_strict(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "debug-resources.json"
            row = {
                "platform": "apple",
                "resource": "projects/example/apps/app/debugTokens/token",
            }
            state.write_text(json.dumps([row]), encoding="utf-8")
            state.chmod(0o600)
            with mock.patch.object(pilot, "DEBUG_STATE", state):
                self.assertEqual(pilot.debug_state(), [row])

            state.write_text(json.dumps([{"platform": "apple"}]), encoding="utf-8")
            state.chmod(0o600)
            with mock.patch.object(pilot, "DEBUG_STATE", state):
                with self.assertRaises(pilot.PilotFailure):
                    pilot.debug_state()

            state.write_text(json.dumps([row]), encoding="utf-8")
            state.chmod(0o644)
            self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o644)
            with mock.patch.object(pilot, "DEBUG_STATE", state):
                with self.assertRaises(pilot.PilotFailure):
                    pilot.debug_state()

    def test_partial_debug_cleanup_preserves_only_failed_resources(self) -> None:
        rows = [
            {
                "platform": "apple",
                "resource": "projects/example/apps/apple/debugTokens/one",
            },
            {
                "platform": "android",
                "resource": "projects/example/apps/android/debugTokens/two",
            },
        ]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "debug-resources.json"

            def delete(resource: str, access_token: str, project_id: str) -> None:
                self.assertEqual(access_token, "access-token")
                self.assertEqual(project_id, "project")
                if resource.endswith("/two"):
                    raise pilot.PilotFailure("bounded failure")

            with (
                mock.patch.object(pilot, "DEBUG_STATE", state),
                mock.patch.object(pilot, "preflight", return_value=("project", {}, {})),
                mock.patch.object(pilot, "debug_state", return_value=rows),
                mock.patch.object(pilot, "command", return_value="access-token"),
                mock.patch.object(pilot, "delete_debug_token", side_effect=delete),
            ):
                with self.assertRaises(pilot.PilotFailure):
                    pilot.cleanup_debug()

            self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o600)
            self.assertEqual(
                json.loads(state.read_text(encoding="utf-8")),
                [rows[1]],
            )


if __name__ == "__main__":
    unittest.main()
