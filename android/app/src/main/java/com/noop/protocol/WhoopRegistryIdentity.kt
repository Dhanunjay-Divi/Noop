package com.noop.protocol

/**
 * Evidence-safe conversion between BLE identity and the historical labels stored in `pairedDevice`.
 *
 * A 5-family GATT service proves only that the strap speaks the shared WHOOP 5/MG protocol. It cannot
 * prove which physical variant is attached, so the service-level label deliberately remains
 * [WHOOP_FIVE_FAMILY]. Only positive Device Information Service evidence may write [WHOOP_FIVE] or
 * [WHOOP_MG]. Unknown or contradictory DIS evidence produces no label and therefore no registry write.
 */
object WhoopRegistryIdentity {
    const val WHOOP_FOUR = "WHOOP 4.0"
    const val WHOOP_FIVE_FAMILY = "WHOOP 5.0 / MG"
    const val WHOOP_FIVE = "WHOOP 5.0"
    const val WHOOP_MG = "WHOOP MG"

    /** Resolve only labels that positively identify a family. Unknown labels stay null (no guess). */
    fun positivelyIdentifiedFamily(model: String?): DeviceFamily? = when (normalized(model)) {
        "4.0", WHOOP_FOUR -> DeviceFamily.WHOOP4
        "5.0", WHOOP_FIVE,
        "MG", WHOOP_MG,
        "5.0 MG", "5.0 / MG", "5/MG",
        "WHOOP 5.0 MG", WHOOP_FIVE_FAMILY, "WHOOP 5/MG" -> DeviceFamily.WHOOP5
        else -> null
    }

    /**
     * Registry repair justified by an actually advertised/discovered connectable service.
     *
     * An already-correct exact 5.0 or MG label is preserved when the common 5-family service is seen;
     * the service has less information than DIS and must never erase that exact identity.
     */
    fun modelUpdateFromService(currentModel: String?, family: DeviceFamily): String? {
        if (positivelyIdentifiedFamily(currentModel) == family) return null
        return when (family) {
            DeviceFamily.WHOOP4 -> WHOOP_FOUR
            DeviceFamily.WHOOP5 -> WHOOP_FIVE_FAMILY
        }
    }

    /** Exact model label from positive DIS evidence; UNKNOWN is deliberately non-mutating. */
    fun exactModelFromDis(variant: Whoop5Variant): String? = when (variant) {
        Whoop5Variant.MG -> WHOOP_MG
        Whoop5Variant.FIVE_ZERO -> WHOOP_FIVE
        Whoop5Variant.UNKNOWN -> null
    }

    private fun normalized(model: String?): String = model
        ?.trim()
        ?.uppercase()
        ?.replace(Regex("\\s+"), " ")
        ?: ""
}
