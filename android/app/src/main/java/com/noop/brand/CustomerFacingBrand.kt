package com.noop.brand

/**
 * Removes transport-vendor wording from dynamic customer-facing text.
 *
 * Wire identifiers, persisted source IDs, and provenance records remain unchanged. This covers
 * runtime strings such as historical release notes and the user-visible strap log, which cannot rely
 * on Android string-resource overrides.
 */
internal object CustomerFacingBrand {
    private val replacements = listOf(
        Regex("""\bmy-whoop-noop\b""", RegexOption.IGNORE_CASE) to "primary-band-on-device",
        Regex("""\bmy-whoop\b""", RegexOption.IGNORE_CASE) to "primary-band",
        Regex("""\bopenwhoop\b""", RegexOption.IGNORE_CASE) to "NOOP legacy storage",
        Regex("""\bwhoopstore\b""", RegexOption.IGNORE_CASE) to "local store",
        Regex("""\bwhoopimporter\b""", RegexOption.IGNORE_CASE) to "wearable importer",
        Regex("""\bwhoop_live_hr_in_adv_ind_pkt\b""", RegexOption.IGNORE_CASE) to "band broadcast setting",
        Regex("""\bwhoop[- ]compatible\b""", RegexOption.IGNORE_CASE) to "wearable-compatible",
        Regex("""\bwhoop(?=\d\w*[-_])""", RegexOption.IGNORE_CASE) to "band-",
        Regex("""\bwhoop\s*5(?:\.0)?(?:\s*/?\s*mg)?\b""", RegexOption.IGNORE_CASE) to "newer band",
        Regex("""\bwhoop\s*4(?:\.0)?\b""", RegexOption.IGNORE_CASE) to "legacy band",
        Regex("""\bwhoop\s+mg\b""", RegexOption.IGNORE_CASE) to "ECG-capable band",
        Regex("""\bwhoop\s+exports\b""", RegexOption.IGNORE_CASE) to "wearable exports",
        Regex("""\bwhoop\s+export\b""", RegexOption.IGNORE_CASE) to "wearable export",
        Regex("""\bwhoop\s+imports\b""", RegexOption.IGNORE_CASE) to "wearable imports",
        Regex("""\bwhoop\s+import\b""", RegexOption.IGNORE_CASE) to "wearable import",
        Regex("""\bwhoop[-_ ]csv\b""", RegexOption.IGNORE_CASE) to "wearable-csv",
        Regex("""\bwhoop\s+app\b""", RegexOption.IGNORE_CASE) to "band app",
        Regex("""\bwhoop-style\b""", RegexOption.IGNORE_CASE) to "wearable-style",
        Regex("""\bwhoop(?:'s|’s)\b""", RegexOption.IGNORE_CASE) to "the provider's",
        Regex("""\bwhoop(?=\d)""", RegexOption.IGNORE_CASE) to "band-",
        Regex("""whoop""", RegexOption.IGNORE_CASE) to "compatible band",
    )

    fun text(raw: String): String =
        replacements.fold(raw) { value, (pattern, replacement) ->
            value.replace(pattern, replacement)
        }
}
