from __future__ import annotations

import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "Tools" / "validate-launch-gate-isolation.py"
SPEC = importlib.util.spec_from_file_location("validate_launch_gate_isolation", TOOL)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LaunchGateIsolationTests(unittest.TestCase):
    def test_setting_parser_discards_values(self) -> None:
        names = MODULE.setting_names(
            """
                APP_GROUP_ID = group.example
                NOOP_LAUNCH_GATE_SALT_HEX = should-never-be-returned
            """
        )
        self.assertEqual(
            names,
            frozenset({"APP_GROUP_ID", "NOOP_LAUNCH_GATE_SALT_HEX"}),
        )
        self.assertNotIn("should-never-be-returned", names)

    def test_target_parser_groups_names_without_values(self) -> None:
        grouped = MODULE.target_setting_names(
            """
Build settings for action build and target NOOPiOS:
    APP_GROUP_ID = group.example
    NOOP_LAUNCH_GATE_SALT_HEX = should-never-be-returned
Build settings for action build and target NOOPiOSWidgets:
    APP_GROUP_ID = group.example.widgets
    NOOP_LAUNCH_GATE_REQUIRED = YES
Build settings for action build and target Unrelated:
    NOOP_LAUNCH_GATE_VERIFIER_HEX = ignored
            """,
            (MODULE.IPHONE_TARGET, *MODULE.EXTENSION_TARGETS),
        )
        self.assertEqual(
            grouped[MODULE.IPHONE_TARGET],
            frozenset({"APP_GROUP_ID", "NOOP_LAUNCH_GATE_SALT_HEX"}),
        )
        self.assertEqual(
            grouped["NOOPiOSWidgets"],
            frozenset({"APP_GROUP_ID", "NOOP_LAUNCH_GATE_REQUIRED"}),
        )
        self.assertNotIn("Unrelated", grouped)
        self.assertNotIn("should-never-be-returned", repr(grouped))

    def test_extensions_reject_every_iPhone_only_setting(self) -> None:
        names = MODULE.PUBLIC_SETTINGS | MODULE.IPHONE_ONLY_SETTINGS
        for target in MODULE.EXTENSION_TARGETS:
            errors = MODULE.target_errors(target, names)
            self.assertEqual(len(errors), 1)
            for private_name in MODULE.IPHONE_ONLY_SETTINGS:
                self.assertIn(private_name, errors[0])

    def test_iPhone_requires_public_and_private_settings(self) -> None:
        self.assertEqual(
            MODULE.target_errors(
                MODULE.IPHONE_TARGET,
                MODULE.PUBLIC_SETTINGS | MODULE.IPHONE_ONLY_SETTINGS,
            ),
            [],
        )
        errors = MODULE.target_errors(MODULE.IPHONE_TARGET, MODULE.PUBLIC_SETTINGS)
        self.assertEqual(len(errors), 1)

    def test_clean_checkout_may_omit_iPhone_secrets(self) -> None:
        self.assertEqual(
            MODULE.target_errors(
                MODULE.IPHONE_TARGET,
                MODULE.PUBLIC_SETTINGS,
                require_iphone_private=False,
            ),
            [],
        )

    def test_extensions_accept_only_public_settings(self) -> None:
        for target in MODULE.EXTENSION_TARGETS:
            self.assertEqual(MODULE.target_errors(target, MODULE.PUBLIC_SETTINGS), [])


if __name__ == "__main__":
    unittest.main()
