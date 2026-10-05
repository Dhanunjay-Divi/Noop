package com.noop.ui

import org.junit.Assert.assertEquals
import org.junit.Test

class AddDeviceWizardNavigationTest {
    @Test
    fun supplierPrepBackTargetPreservesItsEntryPath() {
        assertEquals(
            SupplierPrepBackTarget.UnifiedScan,
            supplierPrepBackTarget(SupplierPrepOrigin.UnifiedScan),
        )
        listOf(
            null,
            SupplierPrepOrigin.DirectStart,
            SupplierPrepOrigin.DevicePicker,
        ).forEach { origin ->
            assertEquals(
                SupplierPrepBackTarget.DevicePicker,
                supplierPrepBackTarget(origin),
            )
        }
    }
}
