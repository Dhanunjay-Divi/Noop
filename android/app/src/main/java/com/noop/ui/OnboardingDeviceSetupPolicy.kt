package com.noop.ui

import com.noop.ble.SourceCoordinator
import com.noop.data.DeviceStatus
import com.noop.data.PairedDeviceRow
import com.noop.data.SourceKind

/** Chooses only a durable, usable band registration for first-run progress. */
internal fun onboardingCompletedDeviceSetupSource(
    devices: List<PairedDeviceRow>,
    supplierAvailable: Boolean,
    supplierRegistrationUsable: (String) -> Boolean,
): SourceKind? {
    fun eligibleSource(device: PairedDeviceRow): SourceKind? {
        if (
            device.status != DeviceStatus.active.name &&
            device.status != DeviceStatus.paired.name
        ) {
            return null
        }
        val source = SourceKind.entries.firstOrNull {
            it.name == device.sourceKind
        } ?: return null
        if (
            source == SourceKind.cloudImport ||
            source == SourceKind.fileImport ||
            source == SourceKind.activityFile
        ) {
            return null
        }
        if (device.id == "my-whoop" && device.peripheralId.isNullOrBlank()) {
            return null
        }
        if (source == SourceKind.veepoo && !supplierAvailable) return null
        if (device.peripheralId.isNullOrBlank()) return null

        val usesCompatibleTransport =
            source == SourceKind.liveBLE || source == SourceKind.historyBLE
        val isCompatibleBand =
            SourceCoordinator.isWhoop(device) && usesCompatibleTransport
        val isAccountLinkedBand =
            supplierAvailable &&
                source == SourceKind.veepoo &&
                supplierRegistrationUsable(device.id)
        if (!isCompatibleBand && !isAccountLinkedBand) return null
        return source
    }

    val active = devices.firstOrNull {
        it.status == DeviceStatus.active.name
    }
    if (active != null) {
        eligibleSource(active)?.let { return it }
        // An unavailable account-linked row remains ownership authority and
        // must fail closed. An empty legacy seed row is not authority.
        if (active.sourceKind == SourceKind.veepoo.name) return null
    }

    return devices
        .asSequence()
        .filter { it.status == DeviceStatus.paired.name }
        .sortedWith(
            compareByDescending<PairedDeviceRow> { it.lastSeenAt }
                .thenByDescending { it.addedAt },
        )
        .mapNotNull(::eligibleSource)
        .firstOrNull()
}

internal fun onboardingNeedsDeviceSetupRead(
    page: OnboardingPage,
): Boolean = page == OnboardingPage.Connect ||
    page == OnboardingPage.Ownership ||
    page == OnboardingPage.Profile ||
    page == OnboardingPage.Plan ||
    page == OnboardingPage.Done

internal fun supplierBandOnboardingAvailable(
    adapterAvailable: Boolean,
    ownershipConfigured: Boolean,
): Boolean = adapterAvailable && ownershipConfigured
