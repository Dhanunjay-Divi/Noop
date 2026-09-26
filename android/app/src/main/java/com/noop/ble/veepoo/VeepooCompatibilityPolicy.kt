package com.noop.ble.veepoo

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener
import java.io.InputStream

internal enum class VeepooCompatibilityDecision {
    APPROVED,
    QUALIFICATION_APPROVED,
    UNAPPROVED,
    INVALID_POLICY,
}

/**
 * Exact supplier product compatibility allowlist.
 *
 * The manifest is application-owned release input. Supplier callbacks cannot establish their own
 * compatibility, and transport addresses never participate in this decision.
 */
class VeepooCompatibilityPolicy private constructor(
    private val approvedBands: Set<ApprovedBand>,
    private val valid: Boolean,
    private val allowUnlistedQualification: Boolean,
) {
    internal fun evaluate(identity: VeepooIdentity): VeepooCompatibilityDecision {
        if (!valid) return VeepooCompatibilityDecision.INVALID_POLICY
        val observed = ApprovedBand(
            platform = ANDROID_PLATFORM,
            modelCode = identity.modelCode,
            hardwareRevision = identity.hardwareRevision,
            firmwareRevision = identity.firmwareVersion,
            protocolVersion = PROTOCOL_VERSION,
            wrapperRevision = WRAPPER_REVISION,
        )
        if (!observed.isValid()) return VeepooCompatibilityDecision.UNAPPROVED
        return when {
            observed in approvedBands -> VeepooCompatibilityDecision.APPROVED
            approvedBands.none { it.platform == ANDROID_PLATFORM } &&
                allowUnlistedQualification ->
                VeepooCompatibilityDecision.QUALIFICATION_APPROVED
            else -> VeepooCompatibilityDecision.UNAPPROVED
        }
    }

    private data class ApprovedBand(
        val platform: String,
        val modelCode: String,
        val hardwareRevision: String,
        val firmwareRevision: String,
        val protocolVersion: String,
        val wrapperRevision: String,
    ) {
        fun isValid(): Boolean =
            fields().all(::validField) &&
                protocolVersion == PROTOCOL_VERSION &&
                SUPPORTED_WRAPPER_BY_PLATFORM[platform] == wrapperRevision

        fun fields(): List<String> = listOf(
            platform,
            modelCode,
            hardwareRevision,
            firmwareRevision,
            protocolVersion,
            wrapperRevision,
        )
    }

    companion object {
        const val ASSET_NAME = "noop-band-compatibility.json"
        const val PROTOCOL_VERSION = "noop-band-v1"
        const val WRAPPER_REVISION = "veepoo-android-display-v2"

        private const val SCHEMA_VERSION = 1
        private const val ANDROID_PLATFORM = "android"
        private const val MAX_MANIFEST_BYTES = 64 * 1024
        private const val MAX_APPROVED_BANDS = 256
        private const val MAX_FIELD_LENGTH = 64
        private val REJECTED_PLACEHOLDERS =
            setOf("all", "any", "default", "unknown")
        private val SUPPORTED_WRAPPER_BY_PLATFORM = mapOf(
            "android" to WRAPPER_REVISION,
            "apple" to "veepoo-apple-display-v1",
        )
        private val TOP_LEVEL_KEYS = setOf("schemaVersion", "approvedBands")
        private val BAND_KEYS = setOf(
            "platform",
            "modelCode",
            "hardwareRevision",
            "firmwareRevision",
            "protocolVersion",
            "wrapperRevision",
        )

        internal fun loadFromAssets(
            context: Context,
            allowUnlistedQualification: Boolean = false,
        ): VeepooCompatibilityPolicy =
            load(allowUnlistedQualification) { context.assets.open(ASSET_NAME) }

        internal fun load(
            allowUnlistedQualification: Boolean = false,
            openManifest: () -> InputStream,
        ): VeepooCompatibilityPolicy =
            try {
                val raw = openManifest().use(::readBoundedUtf8)
                parse(raw, allowUnlistedQualification)
            } catch (_: Exception) {
                invalid()
            }

        internal fun parse(
            raw: String,
            allowUnlistedQualification: Boolean = false,
        ): VeepooCompatibilityPolicy {
            return try {
                if (raw.toByteArray(Charsets.UTF_8).size > MAX_MANIFEST_BYTES) return invalid()
                val tokens = JSONTokener(raw)
                val root = tokens.nextValue() as? JSONObject ?: return invalid()
                if (tokens.nextClean() != '\u0000') return invalid()
                if (root.keysSet() != TOP_LEVEL_KEYS) return invalid()
                if (root.opt("schemaVersion") !is Int || root.getInt("schemaVersion") != SCHEMA_VERSION) {
                    return invalid()
                }
                val rows = root.opt("approvedBands") as? JSONArray ?: return invalid()
                if (rows.length() > MAX_APPROVED_BANDS) return invalid()

                val approved = linkedSetOf<ApprovedBand>()
                for (index in 0 until rows.length()) {
                    val row = rows.opt(index) as? JSONObject ?: return invalid()
                    if (row.keysSet() != BAND_KEYS) return invalid()
                    val band = ApprovedBand(
                        platform = row.strictString("platform") ?: return invalid(),
                        modelCode = row.strictString("modelCode") ?: return invalid(),
                        hardwareRevision =
                            row.strictString("hardwareRevision") ?: return invalid(),
                        firmwareRevision =
                            row.strictString("firmwareRevision") ?: return invalid(),
                        protocolVersion =
                            row.strictString("protocolVersion") ?: return invalid(),
                        wrapperRevision =
                            row.strictString("wrapperRevision") ?: return invalid(),
                    )
                    if (!band.isValid() || !approved.add(band)) return invalid()
                }
                VeepooCompatibilityPolicy(
                    approved,
                    valid = true,
                    allowUnlistedQualification = allowUnlistedQualification,
                )
            } catch (_: Exception) {
                invalid()
            }
        }

        internal fun invalid(): VeepooCompatibilityPolicy =
            VeepooCompatibilityPolicy(
                emptySet(),
                valid = false,
                allowUnlistedQualification = false,
            )

        private fun JSONObject.keysSet(): Set<String> {
            val result = linkedSetOf<String>()
            val iterator = keys()
            while (iterator.hasNext()) result += iterator.next()
            return result
        }

        private fun JSONObject.strictString(key: String): String? =
            (opt(key) as? String)?.takeIf(::validField)

        private fun validField(value: String): Boolean =
            value.isNotBlank() &&
                value.length <= MAX_FIELD_LENGTH &&
                value == value.trim() &&
                value.none { it == '*' || it == '?' } &&
                value.lowercase() !in REJECTED_PLACEHOLDERS &&
                value.all { it.code in 0x20..0x7e }

        private fun readBoundedUtf8(input: InputStream): String {
            val bytes = ByteArray(MAX_MANIFEST_BYTES + 1)
            var offset = 0
            while (offset < bytes.size) {
                val read = input.read(bytes, offset, bytes.size - offset)
                if (read < 0) break
                if (read == 0) continue
                offset += read
            }
            if (offset > MAX_MANIFEST_BYTES || input.read() >= 0) {
                throw IllegalArgumentException("compatibility manifest exceeds size limit")
            }
            return bytes.copyOf(offset).toString(Charsets.UTF_8)
        }
    }
}
