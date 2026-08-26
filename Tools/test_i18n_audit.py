"""Tests for the #540 fix: i18n_audit.py must see UI-text literals hidden
behind if/else, when, and .let — not just literals sitting immediately after
Text(/title=/etc — without also sweeping unrelated nested composable subtrees
(the bug in the first draft of this fix, which produced 489 findings instead
of a few dozen).

Run: python3 -m unittest Tools.test_i18n_audit -v   (from the repo root)
     or: cd Tools && python3 -m unittest test_i18n_audit -v
"""

import json
import tempfile
import unittest
from pathlib import Path

import i18n_audit as ia


def literals(text: str) -> list[str]:
    """Every literal `_extract_literals` finds across the whole snippet,
    content only (offsets aren't interesting for these tests)."""
    return [lit for _offset, lit in ia._extract_literals(text, 0, len(text))]


class AndroidLiteralExtraction(unittest.TestCase):
    def test_plain_literal(self):
        self.assertEqual(literals('Text("Save")'), ["Save"])

    def test_ternary_if_else_expression(self):
        # The issue's exact reported bug (HrvSnapshotScreen.kt:290).
        self.assertEqual(literals('Text(if (saved) "Saved" else "Save")'), ["Saved", "Save"])

    def test_block_bodied_if_else(self):
        # SleepScreen.kt:2249-shaped: braces around each branch.
        text = 'Text(if (session.userEdited) { "Removes edited" } else { "Removes recorded" })'
        self.assertEqual(literals(text), ["Removes edited", "Removes recorded"])

    def test_let_as_null_coalescing_ternary(self):
        # CaffeineLog.kt:297-shaped.
        text = 'Text(estimate?.let { "About it" } ?: "Caffeine may still be active")'
        self.assertEqual(literals(text), ["About it", "Caffeine may still be active"])

    def test_when_with_subject(self):
        text = 'Text(when (stage) { "Awake" -> "Awake now" else -> "Unknown" })'
        self.assertIn("Awake now", literals(text))
        self.assertIn("Unknown", literals(text))

    def test_bare_when(self):
        text = 'Text(when { cond1 -> "a" else -> "b" })'
        self.assertEqual(literals(text), ["a", "b"])

    def test_nested_composable_slot_not_swept(self):
        # A trailing lambda that is NOT if/when/.let is a separate,
        # independently-composed subtree (the 489-finding regression this
        # fix must not reintroduce) — nothing should be found INSIDE it from
        # here; the nested Text(...) is discovered on its own, separate pass.
        text = 'AlertDialog(text = { Column { Text("Unrelated deep content") } })'
        kwarg_start = text.index("{ Column")
        span_end = ia._argument_span_end(text, text.index("=", text.index("text")) + 1)
        self.assertEqual(literals(text[kwarg_start:span_end]), [])

    def test_plus_concatenation_skipped(self):
        # uiString(R.string.x) + "hardcoded suffix" is a real, but explicitly
        # DIFFERENT and out-of-scope bug (partial localization via an
        # engineered prefix) — tracked separately, not by this scanner.
        text = 'Text(uiString(R.string.x) + "hardcoded suffix")'
        self.assertEqual(literals(text), [])

    def test_plus_concatenation_does_not_swallow_a_real_conditional(self):
        # LiveScreen.kt:1068-shaped: the first branch is a real, standalone
        # conditional literal; only the +-joined unit-suffix is excluded.
        text = 'Text(if (empty) "Waiting." else "Recent: " + values.joinToString() + " ms")'
        self.assertEqual(literals(text), ["Waiting.", "Recent: "])

    def test_string_template_interpolation_not_corrupted(self):
        # MindSection.kt:167-shaped pluralization idiom: a nested literal
        # inside ${...} must not be mistaken for the end of the outer one.
        text = 'Text("$left more ${if (left == 1) "day" else "days"} to go.")'
        self.assertEqual(literals(text), ['$left more ${if (left == 1) "day" else "days"} to go.'])


class ArgumentSpanDetection(unittest.TestCase):
    """`AndroidLiteralExtraction` above hands `_extract_literals` a span that is
    already correct, so it never exercises `_argument_span_end` — the function
    that decides where a `Text(...)` argument actually ends in real source, and
    the piece most likely to break under future edits (nested bracket balancing
    plus transparent-vs-opaque brace classification).

    Both tests use a multi-arg call whose first argument has braced branches, so
    they fail in BOTH directions: stopping one brace early truncates the span
    mid-conditional, and running past the top-level comma swallows the sibling
    arguments.
    """

    # `if (x) { … } else { … }` (not the flat ternary) is deliberate: without a
    # brace in the argument, an early-stopping regression is invisible.
    SOURCE = 'Text(if (x) { "Saved" } else { "Save" }, modifier = Modifier.testTag("hrv_row"))'

    def test_span_ends_at_top_level_comma_not_at_a_nested_brace(self):
        start = self.SOURCE.index("(") + 1
        end = ia._argument_span_end(self.SOURCE, start)
        self.assertEqual(self.SOURCE[start:end], 'if (x) { "Saved" } else { "Save" }')

    def test_extraction_over_the_real_span_excludes_sibling_arguments(self):
        # `hrv_row` is the overrun canary: it is only reachable if the span runs
        # past the comma. (It could not do this job through `scan_android()` —
        # `is_probably_ui_text` filters snake_case testTags out again.)
        start = self.SOURCE.index("(") + 1
        end = ia._argument_span_end(self.SOURCE, start)
        found = [lit for _offset, lit in ia._extract_literals(self.SOURCE, start, end)]
        self.assertEqual(found, ["Saved", "Save"])


class MaskComments(unittest.TestCase):
    def test_line_comment_blanked(self):
        text = 'val x = 1 // "Take over this ring?"\nText("Real")'
        masked = ia._mask_comments(text)
        self.assertNotIn("Take over", masked)
        self.assertIn('Text("Real")', masked)
        self.assertEqual(len(masked), len(text))  # offsets/line numbers preserved

    def test_block_comment_blanked(self):
        text = 'Text(/* "fake" */ "Real")'
        masked = ia._mask_comments(text)
        self.assertNotIn("fake", masked)
        self.assertIn("Real", masked)

    def test_comment_marker_inside_string_not_treated_as_comment(self):
        text = 'Text("http://example.com // not a comment")'
        masked = ia._mask_comments(text)
        self.assertIn("not a comment", masked)


class FormatSpecExclusion(unittest.TestCase):
    def test_pure_format_spec_excluded(self):
        self.assertFalse(ia.is_probably_ui_text("%.1f"))
        self.assertFalse(ia.is_probably_ui_text("%02d"))
        self.assertFalse(ia.is_probably_ui_text("%+.2f"))

    def test_format_spec_with_real_text_kept(self):
        self.assertTrue(ia.is_probably_ui_text("%.1f br/min"))


class AppleFormatCoverage(unittest.TestCase):
    @staticmethod
    def catalog(key: str, english: str | None, translation: str) -> dict:
        localizations = {
            "de": {
                "stringUnit": {
                    "state": "translated",
                    "value": translation,
                }
            }
        }
        if english is not None:
            localizations["en"] = {
                "stringUnit": {
                    "state": "translated",
                    "value": english,
                }
            }
        return {"strings": {key: {"localizations": localizations}}}

    def test_named_key_uses_english_localization_as_format_source(self):
        cat = self.catalog(
            "safety.duration.hours",
            "%1$lld hr",
            "%1$lld Std.",
        )
        self.assertEqual(ia.apple_format_gaps(cat, "de"), [])

    def test_named_key_still_rejects_a_dropped_placeholder(self):
        cat = self.catalog(
            "safety.location.accuracy_format",
            "Captured at %1$@, about %2$lld m.",
            "Erfasst um %1$@.",
        )
        self.assertEqual(
            ia.apple_format_gaps(cat, "de"),
            ["safety.location.accuracy_format"],
        )

    def test_literal_key_remains_the_source_without_english_override(self):
        cat = self.catalog("%lld days", None, "%lld Tage")
        self.assertEqual(ia.apple_format_gaps(cat, "de"), [])


class CustomerFacingBrandAudit(unittest.TestCase):
    def test_legacy_catalog_key_is_safe_with_neutral_english_override(self):
        cat = {
            "strings": {
                "Import WHOOP export": {
                    "localizations": {
                        "en": {"stringUnit": {"state": "translated", "value": "Import wearable export"}},
                        "de": {"stringUnit": {"state": "translated", "value": "Wearable-Export importieren"}},
                    }
                }
            }
        }
        self.assertEqual(ia.apple_catalog_brand_violations(cat), [])

    def test_legacy_catalog_key_without_english_override_is_rejected(self):
        cat = {"strings": {"Import WHOOP export": {"shouldTranslate": False}}}
        self.assertEqual(
            ia.apple_catalog_brand_violations(cat),
            ["<catalog> :: source 'Import WHOOP export'"],
        )

    def test_forbidden_translated_value_is_rejected(self):
        cat = {
            "strings": {
                "import.source": {
                    "localizations": {
                        "en": {"stringUnit": {"state": "translated", "value": "WHOOP import"}},
                    }
                }
            }
        }
        violations = ia.apple_catalog_brand_violations(cat)
        self.assertEqual(len(violations), 1)
        self.assertIn("WHOOP import", violations[0])

    def test_android_resource_names_are_ignored_but_values_are_checked(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "strings.xml"
            path.write_text(
                '<resources><string name="whoop_internal_key">Noop Band</string>'
                '<string name="unsafe">WHOOP import</string></resources>',
                encoding="utf-8",
            )
            violations = ia.android_resource_file_brand_violations(path)
        self.assertEqual(len(violations), 1)
        self.assertIn("unsafe", violations[0])

    def test_internal_interpolation_identifier_is_not_rendered_text(self):
        literal = "${WhoopModel.CUSTOMER_NAME} (Live Bluetooth)"
        self.assertEqual(ia._static_literal_text(literal, "android"), " (Live Bluetooth)")

    def source_violations(self, source: str, platform: str, rel: str) -> list[str]:
        suffix = ".swift" if platform == "ios" else ".kt"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / f"Screen{suffix}"
            path.write_text(source, encoding="utf-8")
            return ia.source_file_brand_violations(path, platform, rel=rel)

    def test_plain_custom_view_copy_is_rejected_even_outside_text_call(self):
        violations = self.source_violations(
            'ComingSoon(what: "Import your WHOOP export first.")',
            "ios",
            "Strand/Screens/ExampleView.swift",
        )
        self.assertEqual(len(violations), 1)
        self.assertIn("customer UI source", violations[0])

    def test_catalog_override_does_not_hide_authored_normal_ui_vendor_copy(self):
        violations = self.source_violations(
            'Text(String(localized: "Import WHOOP export"))',
            "ios",
            "Strand/Screens/ExampleView.swift",
        )
        self.assertEqual(len(violations), 1)

    def test_internal_source_ids_and_symbols_remain_allowed(self):
        violations = self.source_violations(
            'let source = "my-whoop"\nlet key = "selectedWhoopModel"\nlet family = "WHOOP"',
            "ios",
            "Strand/Screens/ExampleView.swift",
        )
        self.assertEqual(violations, [])

    def test_internal_interpolation_symbol_is_not_authored_copy(self):
        violations = self.source_violations(
            'Text("Revision \\(WhoopImporter.schemaRevision) is current")',
            "ios",
            "Strand/Screens/ExampleView.swift",
        )
        self.assertEqual(violations, [])

    def test_comments_do_not_trigger_source_brand_gate(self):
        violations = self.source_violations(
            '// Text("WHOOP should not count")\nText("Noop Band")',
            "ios",
            "Strand/Screens/ExampleView.swift",
        )
        self.assertEqual(violations, [])

    def test_test_centre_diagnostics_are_explicitly_exempt(self):
        violations = self.source_violations(
            'Text("WHOOP protocol frame")',
            "ios",
            "Strand/Screens/TestCentreView.swift",
        )
        self.assertEqual(violations, [])

    def test_android_customer_copy_is_rejected_but_source_id_is_retained(self):
        violations = self.source_violations(
            'val source = "my-whoop"\nText("WHOOP import")',
            "android",
            "android/app/src/main/java/com/noop/ui/ExampleScreen.kt",
        )
        self.assertEqual(len(violations), 1)
        self.assertIn("WHOOP import", violations[0])


class ScanAndroidEndToEnd(unittest.TestCase):
    """Exercises scan_android() against real files on disk (its actual
    contract), not just the pure-function helpers above."""

    def setUp(self):
        # Must live under ia.ROOT: scan_android() reports paths via
        # `path.relative_to(ROOT)`, which raises for anything outside it.
        self.tmp = tempfile.TemporaryDirectory(dir=ia.ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.ui_dir = Path(self.tmp.name) / "ui"
        self.ui_dir.mkdir()
        self._orig_dirs = ia.ANDROID_DIRS
        ia.ANDROID_DIRS = [self.ui_dir]
        self.addCleanup(setattr, ia, "ANDROID_DIRS", self._orig_dirs)

    def write(self, name: str, content: str) -> None:
        (self.ui_dir / name).write_text(content, encoding="utf-8")

    def test_conditional_literal_found(self):
        self.write("Screen.kt", 'Text(if (saved) "Saved" else "Save")')
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Saved", "Save"})

    def test_alert_dialog_kwarg_conditional_found(self):
        self.write(
            "Screen.kt",
            'AlertDialog(onDismissRequest = {}, title = { Text(if (x) "A" else "B") })',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"A", "B"})

    def test_local_val_declaration_not_scanned_as_kwarg(self):
        # `val text = when { ... }` is a local declaration, not a composable
        # kwarg — ANDROID_KWARG_PATTERN's `text=` must not treat its `when`
        # branch match-keys as UI-text findings.
        self.write(
            "Screen.kt",
            'val text = when (stage) {\n    "Awake" -> "Awake now"\n    else -> "Unknown"\n}\n',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_no_explosion_from_nested_slot_lambda(self):
        # The 489-finding regression guard: a huge, unrelated nested
        # composable subtree inside a title=/text= slot must not get swept.
        self.write(
            "Wizard.kt",
            "AlertDialog(\n"
            "    onDismissRequest = {},\n"
            "    text = {\n"
            "        Column {\n"
            '            Text("First deep child")\n'
            '            Text("Second deep child")\n'
            "        }\n"
            "    },\n"
            ")",
        )
        found = [lit for _p, _l, lit in ia.scan_android()]
        # Both literals are still found — but because the file-wide scan
        # reaches each nested Text(...) call directly, not because the
        # outer AlertDialog's text= span was swept.
        self.assertEqual(sorted(found), ["First deep child", "Second deep child"])

    # --- #571: contentDescription assigned inside a `semantics {}` lambda ---

    def test_content_description_in_semantics_lambda_found(self):
        # The standard Compose a11y idiom: the `{` is not an arg boundary, so the
        # general kwarg pass skips it — the dedicated assignment pass must catch it.
        self.write(
            "A.kt",
            'Modifier.semantics { contentDescription = if (hr) "Recovery ready" else "Recovery, no data yet" }',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Recovery ready", "Recovery, no data yet"})

    def test_content_description_multiline_semantics_found(self):
        self.write(
            "A.kt",
            "Modifier.semantics {\n    contentDescription = \"Charge calibrating tonight\"\n}",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Charge calibrating tonight"})

    def test_content_description_pass_excludes_decl_and_member_read(self):
        # A `val` local decl and a `.member ==` comparison are NOT a11y UI-text sites;
        # neither may be flagged (guards the pass against false positives).
        self.write(
            "A.kt",
            'val contentDescription = "local decl not ui"\n'
            'if (view.contentDescription == "compare not ui") doThing()\n',
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_content_description_lambda_does_not_reopen_unrelated_slot(self):
        # The a11y pass must not resurrect the 489-explosion: an unrelated slot
        # lambda beside a contentDescription assignment stays scanned only on its own.
        self.write(
            "A.kt",
            'Box(Modifier.semantics { contentDescription = "Tap target" }) {\n'
            '    AlertDialog(text = { Column { Text("Deep child") } })\n'
            "}",
        )
        found = sorted(lit for _p, _l, lit in ia.scan_android())
        self.assertEqual(found, ["Deep child", "Tap target"])

    def test_content_description_follows_visible_local_val(self):
        # The remaining #571 case: the a11y assignment contains only a
        # reference, while its visible local initializer carries the UI copy.
        self.write(
            "Coupled.kt",
            "fun Hero() {\n"
            "    val a11y = when {\n"
            '        ready -> "Recovery $score percent"\n'
            '        calibrating -> "Recovery calibrating, $n nights"\n'
            '        else -> "Recovery, no data yet"\n'
            "    }\n"
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(
            found,
            {
                "Recovery $score percent",
                "Recovery calibrating, $n nights",
                "Recovery, no data yet",
            },
        )

    def test_content_description_does_not_follow_parameter(self):
        self.write(
            "Component.kt",
            "fun Label(content: String) {\n"
            "    Box(Modifier.semantics { contentDescription = content })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_content_description_respects_val_scope(self):
        self.write(
            "Sibling.kt",
            "fun Screen() {\n"
            "    if (condition) {\n"
            '        val a11y = "Sibling-only text"\n'
            "    }\n"
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_content_description_uses_nearest_shadowing_val(self):
        self.write(
            "Shadowed.kt",
            "fun Screen() {\n"
            '    val a11y = "Outer hardcoded text"\n'
            "    if (condition) {\n"
            "        val a11y = uiString(R.string.localized)\n"
            "        Box(Modifier.semantics { contentDescription = a11y })\n"
            "    }\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, set())

    def test_val_initializer_does_not_sweep_following_statements(self):
        self.write(
            "Bounded.kt",
            "fun Screen() {\n"
            '    val a11y = "Target text"\n'
            '    val internal = "Not accessibility text"\n'
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(found, {"Target text"})

    def test_val_initializer_follows_explicit_line_continuation(self):
        self.write(
            "Continued.kt",
            "fun Screen() {\n"
            '    val a11y = "Workout row" +\n'
            "        if (selected) {\n"
            '            ". Selected."\n'
            "        } else {\n"
            '            ". Not selected."\n'
            "        }\n"
            "    Box(Modifier.semantics { contentDescription = a11y })\n"
            "}\n",
        )
        found = {lit for _p, _l, lit in ia.scan_android()}
        self.assertEqual(
            found,
            {"Workout row", ". Selected.", ". Not selected."},
        )


class Baseline(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self._orig_path = ia.BASELINE_PATH
        ia.BASELINE_PATH = Path(self.tmp.name) / "baseline.json"
        self.addCleanup(setattr, ia, "BASELINE_PATH", self._orig_path)

    def test_missing_baseline_is_empty(self):
        self.assertEqual(ia.load_baseline(), {"android": set(), "ios": set()})

    def test_round_trip(self):
        ia.BASELINE_PATH.write_text(
            json.dumps({"android": [["Screen.kt", "Old"]], "ios": []}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        self.assertEqual(baseline["android"], {("Screen.kt", "Old")})
        self.assertEqual(baseline["ios"], set())

    def test_baseline_keyed_by_path_and_literal_not_line(self):
        # A baseline entry must keep suppressing a finding whose line number
        # shifted from an unrelated edit elsewhere in the same file.
        ia.BASELINE_PATH.write_text(
            json.dumps({"android": [["Screen.kt", "Save"]], "ios": []}), encoding="utf-8"
        )
        baseline = ia.load_baseline()
        finding = ("Screen.kt", 999, "Save")  # line number drifted
        self.assertIn((finding[0], finding[2]), baseline["android"])


if __name__ == "__main__":
    unittest.main()
