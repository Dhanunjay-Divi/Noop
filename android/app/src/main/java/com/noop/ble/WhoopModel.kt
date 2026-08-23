package com.noop.ble

import java.util.UUID

/**
 * Internal transport family for compatible band hardware. Customer UI always says [CUSTOMER_NAME];
 * this enum remains separate from the protocol-layer DeviceFamily, which carries framing details.
 */
enum class WhoopModel(val service: UUID) {
    WHOOP4(WhoopBleClient.WHOOP4_SERVICE),
    WHOOP5_MG(WhoopBleClient.WHOOP5_SERVICE);

    /** Hardware generation stays internal; the product name is stable across compatible transports. */
    val displayName: String get() = CUSTOMER_NAME

    /** Diagnostic-only transport identity. Never use this on ordinary customer setup or status screens. */
    val transportName: String
        get() = when (this) {
            WHOOP4 -> "WHOOP 4.0"
            WHOOP5_MG -> "WHOOP 5.0 / MG"
        }

    /** Existing registry schema value. Kept stable so upgrades do not orphan paired hardware or data. */
    val registryModel: String
        get() = when (this) {
            WHOOP4 -> "4.0"
            WHOOP5_MG -> "5.0 MG"
        }

    /**
     * The OTHER WHOOP family to try when a service-filtered scan for this model finds nothing. A
     * stale/missing persisted preference (after an update or restore) can point the scan at the wrong
     * service so it runs forever with the strap right there; rotating to the other family — and
     * persisting whichever one actually advertises — recovers reconnect automatically. Mirrors macOS
     * `WhoopModel.fallbackScanModel`. (PR#195)
     */
    val fallbackScanModel: WhoopModel
        get() = when (this) {
            WHOOP4 -> WHOOP5_MG
            WHOOP5_MG -> WHOOP4
        }

    companion object {
        const val CUSTOMER_NAME = "Noop Band"

        /** Every compatible service used by the generation-agnostic setup scan. */
        val compatibleServices: List<UUID>
            get() = entries.map { it.service }

        /** Resolve the actual transport family from advertisement evidence, never from a stale preference. */
        fun fromAdvertisedServiceUuids(serviceUuids: Iterable<String>): WhoopModel? =
            serviceUuids.firstNotNullOfOrNull { advertised ->
                entries.firstOrNull { it.service.toString().equals(advertised, ignoreCase = true) }
            }
    }
}
