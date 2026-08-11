package com.noop.analytics

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** Mirror of StrandAnalytics WearableCapabilityCatalogTests. */
class WearableCapabilityCatalogTest {
    @Test fun catalogContainsEverySourceExactlyOnce() {
        assertEquals(listOf(WearableSource.WHOOP4, WearableSource.WHOOP5, WearableSource.WHOOP_MG,
            WearableSource.OURA_RING4, WearableSource.RINGCONN_GEN3, WearableSource.HUME_BAND2,
            WearableSource.APPLE_WATCH), WearableCapabilityCatalog.all.map { it.source })
        assertEquals(WearableSource.values().toSet(), WearableCapabilityCatalog.all.map { it.source }.toSet())
    }

    @Test fun everyContractDeclaresEveryAcquisitionLane() = WearableCapabilityCatalog.all.forEach {
        assertEquals(WearableAcquisitionLane.values().toSet(), it.acquisition.keys)
    }

    @Test fun missingValuesFailClosed() {
        val incomplete = WearableCapabilityContract(WearableSource.WHOOP4, emptyMap(), emptyMap())
        assertEquals(AcquisitionAvailability.UNAVAILABLE,
            incomplete.availability(WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.UNSUPPORTED,
            incomplete.state(WearableMetric.HEART_RATE, WearableAcquisitionLane.DIRECT_BLE))
        assertFalse(incomplete.hasProjectSupportedPath(WearableMetric.HEART_RATE))
        WearableCapabilityCatalog.all.forEach { contract ->
            WearableMetric.values().forEach { metric ->
                WearableAcquisitionLane.values().forEach { lane ->
                    if (contract.metricCapabilities[metric]?.get(lane) == null) {
                        assertEquals(MetricCapabilityState.UNSUPPORTED, contract.state(metric, lane))
                    }
                }
            }
        }
    }

    @Test fun vendorDocumentedLaneDoesNotBecomeProjectSupport() {
        val ring = requireNotNull(WearableCapabilityCatalog.contract(WearableSource.RINGCONN_GEN3))
        assertEquals(AcquisitionAvailability.VENDOR_DOCUMENTED,
            ring.availability(WearableAcquisitionLane.HEALTH_KIT_BRIDGE))
        assertEquals(MetricCapabilityState.BRIDGE_IMPORTED,
            ring.state(WearableMetric.HEART_RATE, WearableAcquisitionLane.HEALTH_KIT_BRIDGE))
        assertFalse(ring.hasProjectSupportedPath(WearableMetric.HEART_RATE))
    }

    @Test fun ringConnAndHumeHaveNoDirectBle() {
        listOf(WearableSource.RINGCONN_GEN3, WearableSource.HUME_BAND2).forEach { source ->
            val contract = requireNotNull(WearableCapabilityCatalog.contract(source))
            assertEquals(AcquisitionAvailability.UNAVAILABLE,
                contract.availability(WearableAcquisitionLane.DIRECT_BLE))
            assertTrue(contract.constraints.contains(WearableCapabilityConstraint.NO_PUBLIC_BLE_PROTOCOL))
            WearableMetric.values().forEach { metric ->
                assertFalse(contract.state(metric, WearableAcquisitionLane.DIRECT_BLE).isExposed)
            }
        }
    }

    @Test fun humeHealthKitCategoriesStayUnverified() {
        val hume = requireNotNull(WearableCapabilityCatalog.contract(WearableSource.HUME_BAND2))
        assertTrue(hume.constraints.contains(
            WearableCapabilityConstraint.BRIDGE_CATEGORIES_REQUIRE_DEVICE_VALIDATION))
        listOf(WearableMetric.HEART_RATE, WearableMetric.HEART_RATE_VARIABILITY,
            WearableMetric.BLOOD_OXYGEN, WearableMetric.SKIN_TEMPERATURE,
            WearableMetric.STEPS, WearableMetric.SLEEP_STAGES).forEach { metric ->
            assertEquals(MetricCapabilityState.NOT_EXPOSED,
                hume.state(metric, WearableAcquisitionLane.HEALTH_KIT_BRIDGE))
            assertFalse(hume.hasProjectSupportedPath(metric))
        }
    }

    @Test fun whoop5DirectRowsDescribeBleAndRemainExperimental() {
        val whoop = requireNotNull(WearableCapabilityCatalog.contract(WearableSource.WHOOP5))
        assertEquals(AcquisitionAvailability.EXPERIMENTAL,
            whoop.availability(WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.DEVICE_DERIVED,
            whoop.state(WearableMetric.HEART_RATE, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.DEVICE_DERIVED,
            whoop.state(WearableMetric.RR_INTERVALS, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.MEASURED_SIGNAL,
            whoop.state(WearableMetric.SKIN_TEMPERATURE, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.MEASURED_SIGNAL,
            whoop.state(WearableMetric.MOTION, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.MEASURED_SIGNAL,
            whoop.state(WearableMetric.OPTICAL_WAVEFORM, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.NOT_EXPOSED,
            whoop.state(WearableMetric.BLOOD_OXYGEN, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.DEVICE_DERIVED,
            whoop.state(WearableMetric.STEPS, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.DEVICE_DERIVED,
            whoop.state(WearableMetric.SLEEP_STAGES, WearableAcquisitionLane.DIRECT_BLE))
        assertFalse(whoop.hasProjectSupportedPath(WearableMetric.RR_INTERVALS))
        assertFalse(whoop.hasProjectSupportedPath(WearableMetric.OPTICAL_WAVEFORM))
        assertTrue(whoop.hasProjectSupportedPath(WearableMetric.HEART_RATE))
    }

    @Test fun ouraCloudDocumentedAndBleExperimental() {
        val oura = requireNotNull(WearableCapabilityCatalog.contract(WearableSource.OURA_RING4))
        assertEquals(AcquisitionAvailability.VENDOR_DOCUMENTED,
            oura.availability(WearableAcquisitionLane.VENDOR_CLOUD))
        assertEquals(AcquisitionAvailability.EXPERIMENTAL,
            oura.availability(WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(MetricCapabilityState.BRIDGE_IMPORTED,
            oura.state(WearableMetric.READINESS_SCORE, WearableAcquisitionLane.VENDOR_CLOUD))
        assertFalse(oura.hasProjectSupportedPath(WearableMetric.RR_INTERVALS))
    }

    @Test fun whoopMgEcgAcquisitionExperimentalAndInterpretationUnsupported() {
        val mg = requireNotNull(WearableCapabilityCatalog.contract(WearableSource.WHOOP_MG))
        assertEquals(MetricCapabilityState.MEASURED_SIGNAL,
            mg.state(WearableMetric.ECG_PACKETS, WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(AcquisitionAvailability.EXPERIMENTAL,
            mg.availability(WearableAcquisitionLane.DIRECT_BLE))
        assertFalse(mg.hasProjectSupportedPath(WearableMetric.ECG_PACKETS))
        WearableAcquisitionLane.values().forEach { lane ->
            assertEquals(MetricCapabilityState.UNSUPPORTED,
                mg.state(WearableMetric.ECG_INTERPRETATION, lane))
        }
    }

    @Test fun appleWatchIsConditionalHealthKitOnly() {
        val watch = requireNotNull(WearableCapabilityCatalog.contract(WearableSource.APPLE_WATCH))
        assertEquals(AcquisitionAvailability.UNAVAILABLE,
            watch.availability(WearableAcquisitionLane.DIRECT_BLE))
        assertEquals(AcquisitionAvailability.UNAVAILABLE,
            watch.availability(WearableAcquisitionLane.HEALTH_CONNECT_BRIDGE))
        assertEquals(AcquisitionAvailability.PROJECT_SUPPORTED,
            watch.availability(WearableAcquisitionLane.HEALTH_KIT_BRIDGE))
        listOf(WearableMetric.HEART_RATE, WearableMetric.HEART_RATE_VARIABILITY,
            WearableMetric.BLOOD_OXYGEN, WearableMetric.RESPIRATORY_RATE,
            WearableMetric.WRIST_TEMPERATURE, WearableMetric.STEPS, WearableMetric.SLEEP_STAGES,
            WearableMetric.WORKOUTS, WearableMetric.VO2_MAX).forEach { metric ->
            assertEquals(MetricCapabilityState.BRIDGE_IMPORTED,
                watch.state(metric, WearableAcquisitionLane.HEALTH_KIT_BRIDGE))
            assertTrue(watch.hasProjectSupportedPath(metric))
        }
        assertEquals(MetricCapabilityState.NOT_EXPOSED,
            watch.state(WearableMetric.RR_INTERVALS, WearableAcquisitionLane.DIRECT_BLE))
        assertTrue(watch.constraints.containsAll(setOf(
            WearableCapabilityConstraint.HEALTH_KIT_ENTITLEMENT_REQUIRED,
            WearableCapabilityConstraint.HEALTH_KIT_PER_TYPE_CONSENT_REQUIRED,
            WearableCapabilityConstraint.METRIC_REQUIRES_COMPATIBLE_DEVICE,
            WearableCapabilityConstraint.BACKGROUND_DELIVERY_NOT_GUARANTEED,
        )))
    }

    @Test fun bloodPressureUnsupportedEverywhere() = WearableCapabilityCatalog.all.forEach { contract ->
        WearableAcquisitionLane.values().forEach { lane ->
            assertEquals(MetricCapabilityState.UNSUPPORTED,
                contract.state(WearableMetric.BLOOD_PRESSURE, lane))
        }
        assertFalse(contract.hasProjectSupportedPath(WearableMetric.BLOOD_PRESSURE))
        assertTrue(contract.constraints.contains(WearableCapabilityConstraint.BLOOD_PRESSURE_UNSUPPORTED))
    }
}
