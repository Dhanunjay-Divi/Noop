package com.noop.data

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.temporal.ChronoUnit
import java.util.UUID

/** One current medication. Text stays encrypted locally; analytics receives no name, dose, or timing. */
data class MedicationEntry(
    val id: String = UUID.randomUUID().toString(),
    val name: String,
    val details: String = "",
    /** Optional ISO local day on which the medication was started or its dose changed. */
    val changeDay: String? = null,
)

/** Pure, testable recency rule for medication context. */
object MedicationContextPolicy {
    const val RECENT_CHANGE_DAYS = 14L

    fun hasRecentChange(
        entries: List<MedicationEntry>,
        asOfDay: LocalDate,
    ): Boolean = entries.any { entry ->
        val changed = entry.changeDay?.let { parseDay(it) } ?: return@any false
        val age = ChronoUnit.DAYS.between(changed, asOfDay)
        age in 0L..RECENT_CHANGE_DAYS
    }

    fun validDay(value: String): Boolean = parseDay(value) != null

    private fun parseDay(value: String): LocalDate? =
        runCatching { LocalDate.parse(value) }.getOrNull()
}

/**
 * Keystore-backed active-medication storage. It is deliberately outside Room, ordinary preferences,
 * portable backup, self-hosted sync, Coach context, analytics, and logs.
 */
object MedicationStore {
    private const val FILE_NAME = "noop_medication_secure_prefs"
    private const val KEY_ENTRIES = "active_medications"
    private const val MAXIMUM_ENTRIES = 30
    private const val MAXIMUM_NAME_CHARACTERS = 120
    private const val MAXIMUM_DETAILS_CHARACTERS = 240
    private val lock = Any()
    @Volatile private var cachedEntries: List<MedicationEntry>? = null

    fun active(context: Context): List<MedicationEntry> {
        cachedEntries?.let { return it }
        return synchronized(lock) {
            cachedEntries ?: runCatching {
                val raw = SecurePrefs.of(context, FILE_NAME).getString(KEY_ENTRIES, null)
                    ?: return@runCatching emptyList()
                decode(raw)
            }.getOrDefault(emptyList()).also { cachedEntries = it }
        }
    }

    fun hasRecentChange(
        context: Context,
        asOfDay: LocalDate = LocalDate.now(),
    ): Boolean = MedicationContextPolicy.hasRecentChange(active(context), asOfDay)

    fun upsert(context: Context, entry: MedicationEntry): Boolean = synchronized(lock) {
        val clean = normalize(entry) ?: return false
        val entries = active(context).toMutableList()
        val index = entries.indexOfFirst { it.id == clean.id }
        if (index >= 0) {
            entries[index] = clean
        } else {
            if (entries.size >= MAXIMUM_ENTRIES) return false
            entries.add(clean)
        }
        return save(context, entries)
    }

    fun remove(context: Context, id: String): Boolean = synchronized(lock) {
        val entries = active(context)
        val updated = entries.filterNot { it.id == id }
        if (updated.size == entries.size) return true
        return save(context, updated)
    }

    private fun save(context: Context, entries: List<MedicationEntry>): Boolean {
        val clean = normalize(entries)
        val saved = runCatching {
            SecurePrefs.of(context, FILE_NAME)
            .edit()
            .putString(KEY_ENTRIES, encode(clean))
            .commit()
        }.getOrDefault(false)
        if (saved) cachedEntries = clean
        return saved
    }

    private fun normalize(entries: List<MedicationEntry>): List<MedicationEntry> {
        val seen = HashSet<String>()
        return entries.asSequence()
            .mapNotNull(::normalize)
            .filter { seen.add(it.id) }
            .take(MAXIMUM_ENTRIES)
            .toList()
    }

    private fun normalize(entry: MedicationEntry): MedicationEntry? {
        val id = runCatching { UUID.fromString(entry.id).toString() }.getOrNull() ?: return null
        val name = entry.name.trim().take(MAXIMUM_NAME_CHARACTERS)
        if (name.isEmpty()) return null
        val details = entry.details.trim().take(MAXIMUM_DETAILS_CHARACTERS)
        val changeDay = entry.changeDay?.takeIf(MedicationContextPolicy::validDay)
        return MedicationEntry(id, name, details, changeDay)
    }

    private fun encode(entries: List<MedicationEntry>): String {
        val array = JSONArray()
        entries.forEach { entry ->
            array.put(JSONObject().apply {
                put("id", entry.id)
                put("name", entry.name)
                put("details", entry.details)
                put("changeDay", entry.changeDay ?: JSONObject.NULL)
            })
        }
        return array.toString()
    }

    private fun decode(raw: String): List<MedicationEntry> {
        val array = JSONArray(raw)
        val entries = ArrayList<MedicationEntry>(array.length())
        for (index in 0 until array.length()) {
            val value = array.optJSONObject(index) ?: continue
            entries.add(
                MedicationEntry(
                    id = value.optString("id"),
                    name = value.optString("name"),
                    details = value.optString("details"),
                    changeDay = if (value.isNull("changeDay")) null else value.optString("changeDay"),
                )
            )
        }
        return normalize(entries)
    }
}
