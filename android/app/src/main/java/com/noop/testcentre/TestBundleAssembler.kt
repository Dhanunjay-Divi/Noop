package com.noop.testcentre

import android.content.Context
import android.os.Build
import com.noop.BuildConfig
import com.noop.CrashCapture
import com.noop.ble.redactStrapLogPii
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets

/**
 * Twin of the Swift TestBundleAssembler: gathers the bundle files, re-runs the redaction pass over EVERY
 * file, applies the 20 MB cap, and hands the entries to LogExport.exportBundle.
 *
 * The CRITICAL fix (spec section 5.3): today only the WhoopBleClient.log() sink scrubs, so a serial
 * embedded in raw-capture console text would ship unredacted. We re-run the file-scope redactStrapLogPii
 * over every entry here, the single scrub point, and stamp meta.redaction = "v2".
 */
object TestBundleAssembler {

    const val REDACTION_VERSION = "v2"

    /** Output of the standalone diagnostics-only privacy boundary. Normal user health-data export does
     * not use this type and keeps its existing purpose-built consent/export behavior. */
    data class PreparedDiagnostics(
        val entries: List<Pair<String, ByteArray>>,
        val truncated: Boolean,
    )

    /**
     * Re-run the redaction sink over every entry. Text entries are decoded UTF-8, scrubbed via the same
     * redactStrapLogPii used by the live log sink, and re-encoded. raw-capture is where the embedded
     * serials live; report.txt and meta.json have no PII shapes so they pass through unchanged.
     */
    fun redactEntries(entries: List<Pair<String, ByteArray>>): List<Pair<String, ByteArray>> =
        entries.map { (name, data) ->
            // BINARY entries (the Display mode's screenshot.png) must NOT be decoded as text and re-encoded
            // - that would corrupt the PNG. Redaction scrubs text identifiers, not pixels, so a binary
            // entry passes through untouched (the Swift twin guards the same way via the UTF-8 decode
            // returning nil). Only text entries are scrubbed.
            if (isBinaryEntry(name)) {
                name to data
            } else {
                name to redactStrapLogPii(String(data)).toByteArray()
            }
        }

    /**
     * Fail-closed redaction and total-size bounding for standalone raw/log/support *text* exports.
     * A binary or malformed UTF-8 payload is rejected instead of being silently handed to ACTION_SEND.
     * Oversized entries share the cap proportionally and retain their newest complete-line tails with an
     * explicit marker. Callers must stage/share only the returned bytes.
     */
    fun prepareDiagnostics(
        entries: List<Pair<String, ByteArray>>,
        capBytes: Int = 20 * 1024 * 1024,
    ): PreparedDiagnostics? {
        if (entries.isEmpty() || capBytes <= 0 || entries.any { !isReviewableUtf8(it.second) }) return null
        val redacted = redactEntries(entries)
        val total = redacted.sumOf { it.second.size.toLong() }
        if (total <= capBytes.toLong()) return PreparedDiagnostics(redacted, truncated = false)

        var remaining = capBytes
        var remainingOriginal = total
        val bounded = ArrayList<Pair<String, ByteArray>>(redacted.size)
        redacted.forEachIndexed { index, (name, data) ->
            val budget = if (index == redacted.lastIndex) {
                remaining
            } else if (remainingOriginal > 0) {
                minOf(remaining, (remaining.toLong() * data.size.toLong() / remainingOriginal).toInt())
            } else {
                0
            }
            bounded += name to boundedDiagnosticText(data, budget)
            remaining -= budget
            remainingOriginal -= data.size.toLong()
        }
        return PreparedDiagnostics(bounded, truncated = true)
    }

    private fun isReviewableUtf8(data: ByteArray): Boolean = runCatching {
        val decoded = StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(data))
        decoded.none { ch -> (ch.code < 0x20 && ch != '\n' && ch != '\r' && ch != '\t') || ch.code == 0x7F }
    }.getOrDefault(false)

    /** Keep a valid UTF-8 newest-line tail within [budget]. The newline boundary discards any leading
     * partial UTF-8 scalar and partial JSONL/CSV/log record from the byte suffix. */
    private fun boundedDiagnosticText(data: ByteArray, budget: Int): ByteArray {
        if (budget <= 0) return byteArrayOf()
        if (data.size <= budget) return data
        val marker = "# NOOP diagnostic export truncated: older content was removed before sharing.\n".toByteArray()
        if (budget <= marker.size) return marker.copyOf(budget)
        val rawTail = data.copyOfRange(data.size - (budget - marker.size), data.size)
        val newline = rawTail.indexOf('\n'.code.toByte())
        val tail = if (newline >= 0 && newline + 1 < rawTail.size) {
            rawTail.copyOfRange(newline + 1, rawTail.size)
        } else {
            byteArrayOf()
        }
        return marker + tail
    }

    /** A bundle entry that is binary (image bytes), never text to scrub. screenshot.png is the only one
     *  today; raw-capture.jsonl stays text (JSON lines) and is still scrubbed. */
    private fun isBinaryEntry(name: String): Boolean = name == DisplayScreenshot.BUNDLE_NAME

    /**
     * Hard cap the bundle at [capBytes] (20 MB default, under GitHub's 25 MB; spec section 5.4). The
     * strap-log tail is already bounded, so only raw-capture can exceed. Keep the MOST-RECENT tail of
     * raw-capture.jsonl and trim from the front. Returns the capped entries plus whether truncation
     * happened, which the caller writes to meta.truncated.
     */
    fun capEntries(
        entries: List<Pair<String, ByteArray>>,
        capBytes: Int = 20 * 1024 * 1024,
    ): Pair<List<Pair<String, ByteArray>>, Boolean> {
        val total = entries.sumOf { it.second.size }
        if (total <= capBytes) return entries to false
        val rawName = "raw-capture.jsonl"
        val nonRaw = entries.filter { it.first != rawName }.sumOf { it.second.size }
        val budget = maxOf(0, capBytes - nonRaw)
        var truncated = false
        val capped = entries.map { (name, data) ->
            if (name == rawName && data.size > budget) {
                truncated = true
                name to data.copyOfRange(data.size - budget, data.size)  // keep the tail
            } else {
                name to data
            }
        }
        return capped to truncated
    }

    // assemble (the entrypoint behind the Report button, the Group D integration seam) ----------------

    /**
     * Gather the report files for [profile], redact EVERY file, cap the bundle, then build and append
     * meta.json (carrying the truncated flag from the cap) and redact-pass it too. Returns the final,
     * already-redacted + already-capped entries ready for LogExport.exportBundle.
     *
     * Group B left this entrypoint to Group D (the Test Centre IA) on purpose: it is the one place that
     * reaches into the live app (the strap log, the crash capture, the diagnostics, TestCentre) to gather
     * the actual bytes, so it lives with the screen that binds the Report button. The pure primitives
     * (redactEntries, capEntries) stay where Group B shipped them; this just composes them in order.
     *
     * [logText] is the live strap-log tail (vm.ble.exportLogText()) so the assembler stays off the BLE
     * client and is testable; the header and last crash are added here to match the strap-log file.
     *
     * [storage] / [strapModel] (#1002): the REAL probes, gathered by the caller (the row counts are
     * suspend store reads, so the sync assembler can't run them itself). null means the probe could not
     * run - meta then carries the zeroed block, which stays honest: zeros are "nothing readable", never
     * a made-up figure. Twin of the Swift assembler's parameters.
     */
    fun assemble(
        context: Context,
        profile: TestDomain,
        logText: String,
        storage: TestBundleMeta.Storage? = null,
        strapModel: String? = null,
    ): List<Pair<String, ByteArray>> {
        val tc = TestCentre.from(context)
        // The set of currently-active domains drives the report-completeness guard. MASTER turns every
        // domain on (TestCentre.active resolves that), so a master report checks every mapped trace.
        val activeDomains = ReportCompleteness.killerTokens.keys
            .filter { tc.active(it) }
            .toSet()

        // 1. report.txt: header (app + Android diagnostics) + the strap-log body, the same shape the
        //    strap-log share writes. Already scrubbed by the log() sink; the redactEntries pass re-scrubs.
        val header = buildString {
            appendLine("Noop Band log")
            appendLine("App:     ${BuildConfig.VERSION_NAME} (${BuildConfig.TIER})")
            for (line in AndroidDiagnostics.summaryLines(context)) appendLine(line)
            appendLine("-".repeat(40))
        }
        val body = logText.ifBlank {
            "(strap log is empty, connect to your strap, reproduce the issue, then report again)"
        }
        // CAPTURE-completeness: append the "Capture check" section so report.txt itself states, per active
        // domain, whether its killer trace landed. Computed over the header+body that will ship (the guard
        // reads exactly what the maintainer reads). Byte-identical section to the Swift twin.
        val reportBody = header + "\n" + body
        val captureCheck = ReportCompleteness.captureCheckSection(reportBody, activeDomains)
        val reportText = reportBody + "\n" + captureCheck
        val entries = ArrayList<Pair<String, ByteArray>>()
        entries.add("report.txt" to reportText.toByteArray())

        // last-crash.txt: only if a crash was captured (degrade gracefully, never fabricate).
        var crashWasCaptured = false
        CrashCapture.lastCrash(context)?.let { crash ->
            entries.add("last-crash.txt" to crash.toByteArray())
            crashWasCaptured = true
        }

        // 1b. Display & Performance: capture a screenshot for the DISPLAY profile (or any mode that declares
        //     includesScreenshot) as screenshot.png. The binary PNG is kept OUT of the redact pass (redaction
        //     scrubs text identifiers, not pixels). The screenshot is still covered by the mandatory
        //     review-before-share gate, which names the attachment. A capture only happens for the gated
        //     profile, so a non-display report never grabs a shot. Mirrors the Swift assembler.
        val wantsShot = profile == TestDomain.DISPLAY ||
            (TestModeRegistry.mode(profile)?.includesScreenshot == true)
        val shot: Pair<String, ByteArray>? = if (wantsShot) {
            DisplayScreenshot.capturePNG(context)?.let { png -> DisplayScreenshot.BUNDLE_NAME to png }
        } else {
            null
        }

        // 2. Redact every gathered TEXT file, then cap. The screenshot is included in the cap input (NOT the
        //    redact input) so its bytes COUNT against the 20 MB cap: capEntries budgets raw-capture as
        //    capBytes - (everything else), so a large/retina PNG shrinks the raw-capture tail rather than
        //    breaching the cap. Only raw-capture is trimmed; report.txt is bounded and the PNG is kept whole.
        val redacted = redactEntries(entries)
        val (capped, truncated) = capEntries(redacted + listOfNotNull(shot))
        val out = ArrayList(capped)

        // 3. meta.json: the machine-readable tie. Answers + startedAt come off the single TestCentre
        //    surface. Storage + strapModel (#1002) are the caller's REAL probes (Phase 1 shipped
        //    hardcoded zeros here, so every meta.json read "db_bytes: 0" even on a multi-GB library and
        //    maintainers triaged blind); a null probe falls back to the zeroed block - zeros mean
        //    "unreadable", we still never fabricate. The Android build is unsigned-flavour, channel "GitHub".
        val started = tc.startedAt(profile)?.let {
            java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", java.util.Locale.US)
                .format(java.util.Date(it * 1000L))
        }
        val meta = TestBundleMeta(
            schema = 1,
            appVersion = BuildConfig.VERSION_NAME,
            platform = "Android",
            osVersion = Build.VERSION.RELEASE ?: "?",
            strapModel = strapModel,
            source = listOf("Live Bluetooth"),
            testProfile = profile.id,
            profileStartedAt = started,
            questionnaire = tc.answers(profile),
            build = TestBundleMeta.Build(channel = "GitHub", signed = false),
            storage = storage ?: TestBundleMeta.Storage(dbBytes = 0, rows = emptyMap(), rawCaptureBytes = 0),
            redaction = REDACTION_VERSION,
            truncated = truncated,
            // The same completeness guard, machine-readable. Computed over the SHIPPING report.txt (the
            // capped, redacted one) so meta.capture_check and the report.txt section can never disagree:
            // a non-MASTER report keeps report.txt small, and the cap only ever trims raw-capture, so the
            // report body the guard read above is byte-identical to the one in `capped`.
            captureCheck = ReportCompleteness.captureCheckMeta(reportText, activeDomains).let {
                TestBundleMeta.CaptureCheck(traces = it.traces, complete = it.complete)
            },
        )
        // meta.json has no PII shapes, but route it through the same sink so the whole bundle has passed
        // one scrub point (5.3).
        out += redactEntries(listOf("meta.json" to meta.encoded().toByteArray()))

        // 4. Bundle robustness check (twin of the Swift assembler's): the last-line verifier over the FINAL
        //    bytes about to ship. Confirms report.txt + meta.json are present/non-empty, the screenshot is
        //    honoured when expected, a captured crash is attached, and - the #453 / 5.3 net - that no raw
        //    MAC / serial survived redaction in any text entry. We append its PII-free summary line to the
        //    report.txt so a maintainer reads the verdict ("bundle ok ... leaks=0") in the report itself; a
        //    failure is surfaced, never silently shipped. Re-redact only the rewritten report.txt entry (its
        //    summary line is fixed-format and PII-free, but route it through the same sink for the 5.3
        //    guarantee). The robustness scan reads the bundle WITHOUT the summary line, so it can never
        //    self-reference.
        val robustness = BundleRobustness.verify(
            entries = out,
            expectScreenshot = wantsShot,
            crashWasCaptured = crashWasCaptured,
        )
        val reportIdx = out.indexOfFirst { it.first == "report.txt" }
        if (reportIdx >= 0) {
            val withVerdict = String(out[reportIdx].second) + "\n" + robustness.summaryLine(out.size)
            out[reportIdx] = redactEntries(listOf("report.txt" to withVerdict.toByteArray())).first()
        }
        return out
    }
}
