from __future__ import annotations

import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "Tools" / "health_claims_gate.py"
SPEC = importlib.util.spec_from_file_location("health_claims_gate", SCRIPT)
assert SPEC is not None and SPEC.loader is not None
GATE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GATE
SPEC.loader.exec_module(GATE)


class HealthClaimsGateTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, contents: str) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
        return path

    def rules(self) -> set[str]:
        findings, _ = GATE.scan(self.root)
        return {finding.rule for finding in findings}

    def test_affirmative_claims_are_found_in_every_user_facing_surface(self) -> None:
        self.write(
            "Strand/Screens/RhythmView.swift",
            'let subtitle = String(localized: "NOOP detects AFib from your wrist.")\n',
        )
        self.write(
            "android/app/src/main/java/com/noop/ui/Health.kt",
            'val detail = "NOOP measures blood pressure continuously."\n',
        )
        self.write(
            "Strand/Resources/Localizable.xcstrings",
            '{"sourceLanguage":"en","strings":{"Active fall detection":{"localizations":{}}}}',
        )
        self.write(
            "marketing/index.html",
            "<h2>Clinical-grade health intelligence</h2>",
        )
        self.write(
            "server/app/static/app.js",
            'const promise = "Background sync is guaranteed.";',
        )

        self.assertEqual(
            self.rules(),
            {
                "afib-detection",
                "background-sync-guarantee",
                "blood-pressure",
                "fall-detection",
                "regulated-grade",
            },
        )

    def test_negated_disclaimers_pass(self) -> None:
        self.write(
            "marketing/safety.html",
            """
            <p>NOOP does not diagnose or detect AFib.</p>
            <p>NOOP does not measure or estimate blood pressure.</p>
            <p>No active fall detection is available.</p>
            <p>NOOP is not FDA-cleared, medical-grade, or clinical-grade.</p>
            <p>Background synchronization is not guaranteed.</p>
            <p>iOS does not guarantee background sync.</p>
            """,
        )

        findings, scanned = GATE.scan(self.root)
        self.assertEqual(scanned, 1)
        self.assertEqual(findings, [])

    def test_adversative_clause_does_not_hide_affirmative_claim(self) -> None:
        self.write(
            "marketing/unsafe.html",
            "NOOP does not import ECG diagnoses, but detects atrial fibrillation.",
        )

        findings, _ = GATE.scan(self.root)
        self.assertEqual([finding.rule for finding in findings], ["afib-detection"])

    def test_swift_and_kotlin_comments_and_identifiers_are_not_release_copy(self) -> None:
        self.write(
            "Strand/Internal.swift",
            """
            // NOOP diagnoses AFib and has guaranteed background sync.
            func detectsAFibProtocolCode() {}
            let safe = "NOOP does not detect AFib."
            """,
        )
        self.write(
            "android/app/src/main/java/com/noop/Internal.kt",
            """
            /* Active fall detection. NOOP measures blood pressure. */
            fun measureBloodPressurePacket() = Unit
            val copy = "NOOP cannot measure blood pressure."
            """,
        )

        findings, scanned = GATE.scan(self.root)
        self.assertEqual(scanned, 2)
        self.assertEqual(findings, [])

    def test_multiline_and_escaped_string_claims_are_scanned(self) -> None:
        self.write(
            "Strand/Claim.swift",
            'let copy = """\nNOOP diagnoses atrial fibrillation.\n"""\n',
        )
        self.write(
            "android/app/src/main/java/com/noop/Claim.kt",
            'val copy = "Guaranteed\\nbackground sync"\n',
        )

        self.assertEqual(
            self.rules(), {"afib-detection", "background-sync-guarantee"}
        )

    def test_non_claim_health_copy_and_manual_imports_pass(self) -> None:
        self.write(
            "android/app/src/main/res/values/strings.xml",
            """
            <resources>
              <string name="bp">Enter a blood pressure reading from your cuff.</string>
              <string name="ecg">Import an AFib result recorded by your clinician.</string>
              <string name="sync">Background sync is best effort and may be delayed.</string>
            </resources>
            """,
        )
        self.write(
            "marketing/research.html",
            "Research-only fall detection is disabled and does not detect falls.",
        )

        findings, scanned = GATE.scan(self.root)
        self.assertEqual(scanned, 2)
        self.assertEqual(findings, [])

    def test_docs_tests_and_server_application_code_are_out_of_scope(self) -> None:
        self.write("docs/draft.md", "NOOP detects AFib.")
        self.write("StrandTests/ClaimTests.swift", 'let fixture = "Medical-grade"')
        self.write("server/app/service.py", 'copy = "NOOP measures blood pressure"')
        self.write("server/app/static/index.html", "A private wellness dashboard.")

        findings, scanned = GATE.scan(self.root)
        self.assertEqual(scanned, 1)
        self.assertEqual(findings, [])

    def test_run_returns_nonzero_and_prints_actionable_location(self) -> None:
        self.write(
            "android/app/src/main/res/values/strings.xml",
            '<resources><string name="claim">FDA approved</string></resources>',
        )
        output = io.StringIO()

        result = GATE.run(self.root, output=output)

        self.assertEqual(result, 1)
        rendered = output.getvalue()
        self.assertIn("health-claims gate: blocked", rendered)
        self.assertIn("strings.xml:1:", rendered)
        self.assertIn("[regulated-grade]", rendered)


if __name__ == "__main__":
    unittest.main()
