from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class VeepooIOSAppSliceTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROOT / relative).read_text(encoding="utf-8")

    def test_vendor_import_is_device_only_default_off(self) -> None:
        adapter = self.read("Strand/BLE/VeepooBandAdapter.swift")
        self.assertEqual(adapter.count("import VeepooBleSDK"), 1)
        self.assertIn(
            "#if os(iOS) && NOOP_SUPPLIER_VEEPOO && canImport(VeepooBleSDK)",
            adapter,
        )
        self.assertIn("static let productionEnabled = true", adapter)
        self.assertIn("static let productionEnabled = false", adapter)
        for relative in (
            "Strand/BLE/VeepooBandAdapterCore.swift",
            "Strand/BLE/VeepooBandSource.swift",
            "Strand/Screens/AddDeviceWizard.swift",
        ):
            self.assertNotIn("import VeepooBleSDK", self.read(relative))

    def test_pairing_uses_trusted_id_when_available_and_physical_confirmation_otherwise(
        self,
    ) -> None:
        core = self.read("Strand/BLE/VeepooBandAdapterCore.swift")
        source = self.read("Strand/BLE/VeepooBandSource.swift")
        wizard = self.read("Strand/Screens/AddDeviceWizard.swift")
        connect = core.index("func connect(")
        optional_mapping = core.index(
            "if let printedIdentifier = candidate.printedIdentifier",
            connect,
        )
        printed_match = core.index("Self.printedIdentifiersMatch", connect)
        begin_connection = core.index(
            "beginConnection(candidateHandle, requiresUserConfirmation: true)",
            connect,
        )
        self.assertLess(optional_mapping, printed_match)
        self.assertLess(printed_match, begin_connection)
        self.assertIn("if candidate.printedIdentifier == nil", source)
        self.assertIn("confirmedPrintedIdentifier: \"\"", source)
        self.assertIn("session.select(candidate)", wizard)
        self.assertIn(
            "session.confirmPrintedIdentifier(printedIdentifier)",
            wizard,
        )
        self.assertIn("session.submitPassword(value)", wizard)
        self.assertLess(
            wizard.index("session.confirmPrintedIdentifier(printedIdentifier)"),
            wizard.index("session.submitPassword(value)"),
        )

    def test_battery_is_automatic_and_precedes_live(self) -> None:
        core = self.read("Strand/BLE/VeepooBandAdapterCore.swift")
        verified = core.index("case .verified(let identity):")
        battery_state = core.index("transition(to: .readingBattery)", verified)
        battery_read = core.index("client.readBattery", battery_state)
        self.assertLess(battery_state, battery_read)
        self.assertIn("guard state == .ready else", core)
        self.assertIn(
            "case .battery(let reading):\n"
            "            battery = reading\n"
            "            phase = .ready\n"
            "            adapter.startLiveHeartRate()",
            self.read("Strand/BLE/VeepooBandSource.swift"),
        )
        self.assertIn(
            "if stage == .live,\n"
            "               battery != nil,\n"
            "               failure == .notWorn || failure == .busy {\n"
            "                lastFailure = nil\n"
            "                phase = .ready",
            self.read("Strand/BLE/VeepooBandSource.swift"),
        )

    def test_live_hr_is_display_only_and_not_persisted(self) -> None:
        source = self.read("Strand/BLE/VeepooBandSource.swift")
        source_class = source[source.index("final class VeepooBandSource") :]
        self.assertIn("live.setDisplayOnlyHeartRate(", source_class)
        self.assertNotIn("live.setHeartRate(", source_class)
        live_state = self.read("Strand/BLE/LiveState.swift")
        display_setter = live_state[
            live_state.index("public func setDisplayOnlyHeartRate") :
            live_state.index("public func clearBiometrics")
        ]
        self.assertNotIn("heartRateSampleSequence", display_setter)
        self.assertNotIn("heartRateSampleSubject", display_setter)
        for forbidden in (
            "WhoopStore",
            "insert(",
            "Streams(",
            "StandardHRMapping",
            "upsert",
        ):
            self.assertNotIn(forbidden, source_class)

    def test_diagnostics_are_fixed_categorical_fields(self) -> None:
        core = self.read("Strand/BLE/VeepooBandAdapterCore.swift")
        diagnostic = core[
            core.index("final class VeepooBandAppDiagnostics") :
            core.index("/// App-owned state machine")
        ]
        self.assertEqual(
            {
                '"stage"',
                '"outcome"',
                '"failure_kind"',
                '"count_bucket"',
            },
            {
                token
                for token in (
                    '"stage"',
                    '"outcome"',
                    '"failure_kind"',
                    '"count_bucket"',
                )
                if token in diagnostic
            },
        )
        for forbidden in (
            "identifier",
            "address",
            "name",
            "rssi",
            "password",
            "heart",
            "battery",
            "error.localizedDescription",
        ):
            self.assertNotIn(forbidden, diagnostic.lower())

        source = self.read("Strand/BLE/VeepooBandSource.swift")
        lifecycle = source[
            source.index("enum VeepooSupplierLifecycleDiagnostics") :
            source.index("@MainActor\nenum VeepooSupplierRemoval")
        ]
        self.assertEqual(
            {'"stage"', '"outcome"', '"trigger"', '"failure_kind"'},
            {
                token
                for token in (
                    '"stage"',
                    '"outcome"',
                    '"trigger"',
                    '"failure_kind"',
                )
                if token in lifecycle
            },
        )
        for forbidden in (
            "deviceid",
            "identifier",
            "password",
            "heartrate",
            "bpm",
            "localizeddescription",
        ):
            self.assertNotIn(forbidden, lifecycle.lower())

    def test_source_factory_is_veepoo_specific_and_fail_closed(self) -> None:
        coordinator = self.read("Strand/BLE/SourceCoordinator.swift")
        preflight = coordinator.index(
            "let preflightedSupplierSource: (any LiveHRSource)?"
        )
        stop = coordinator.index("if !onStrap { stopWhoop() }", preflight)
        unavailable = coordinator[preflight:stop]
        self.assertIn("if sourceKind == .veepoo", unavailable)
        self.assertIn(
            "preflightedSupplierSource = noopBandSourceFactory?(id)",
            unavailable,
        )
        self.assertIn("registry.reconcileUnavailableSupplier(", unavailable)
        self.assertIn(
            "preferredTransportDeviceID: actualTransportDeviceID",
            unavailable,
        )
        build = coordinator.index(
            "guard let source = preflightedSupplierSource ?? makeSource(for: id)",
            stop,
        )
        self.assertLess(stop, build)

        registry = self.read("Strand/Data/DeviceRegistry.swift")
        reconcile = registry[
            registry.index("func reconcileUnavailableSupplier(") :
            registry.index("/// Make `id` the single active device")
        ]
        self.assertIn('$0.id == "my-whoop"', reconcile)
        self.assertIn("Self.isWhoop($0)", reconcile)
        self.assertIn("$0.status != .archived", reconcile)

        source = self.read("Strand/BLE/VeepooBandSource.swift")
        rejected = source[
            source.index("let reconcileAuthenticationRejection = {") :
            source.index(
                "let reconcileBatteryFailure = {",
                source.index("let reconcileAuthenticationRejection = {"),
            )
        ]
        self.assertIn("VeepooRejectedCredentialCleanup.begin(", rejected)
        self.assertIn("persistFailClosedRejection:", rejected)
        self.assertIn("registry.persistRejectedSupplier(", rejected)
        self.assertIn("registry.reconcileUnavailableSupplier(", rejected)
        self.assertLess(
            rejected.index("VeepooRejectedCredentialCleanup.begin("),
            rejected.index("registry.reconcileUnavailableSupplier("),
        )
        cleanup = source[
            source.index("enum VeepooRejectedCredentialCleanup") :
            source.index(
                "final class VeepooPendingCredentialCleanupReconciler"
            )
        ]
        mark = cleanup.index(
            "cleanup.markRejectedPending(deviceID: deviceID)"
        )
        clear = cleanup.index(
            "credentials.clear(deviceID: deviceID)"
        )
        clear_marker = cleanup.index(
            "cleanup.clearRejectedPending(deviceID: deviceID)"
        )
        self.assertLess(mark, clear)
        self.assertLess(clear, clear_marker)
        factory_switch = source[
            source.index("switch credentials.load(deviceID: deviceID)") :
            source.index("private static func credentialAvailability(")
        ]
        self.assertEqual(
            2,
            factory_switch.count(
                "onCredentialRejected:\n"
                "                        reconcileAuthenticationRejection"
            ),
        )

    def test_registration_is_verified_and_atomic(self) -> None:
        source = self.read("Strand/BLE/VeepooBandSource.swift")
        commit = source[
            source.index("func commitPairedDevice(") :
            source.index("func cancel()", source.index("func commitPairedDevice("))
        ]
        save = commit.index("credentials.save(")
        register = commit.index("guard register(device) else")
        clear = commit.index("credentials.clear(", register)
        self.assertLess(save, register)
        self.assertLess(register, clear)
        self.assertIn("failRegistration(.registryPersistence)", commit)

        registry = self.read("Strand/Data/DeviceRegistry.swift")
        registration = registry[
            registry.index("func addAndSetActive(") :
            registry.index("func reconcileUnavailableSupplier(")
        ]
        self.assertIn("publish(try store.addAndSetActive(device))", registration)
        self.assertIn("catch", registration)
        self.assertIn("return false", registration)
        self.assertNotIn("try store.add(device)", registration)
        self.assertNotIn("try store.setActive(device.id)", registration)
        self.assertNotIn("compensateFailedRegistration(", registration)

        store = self.read(
            "Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift"
        )
        atomic = store[
            store.index("public func addAndSetActive(") :
            store.index("public func setActive(", store.index("public func addAndSetActive("))
        ]
        self.assertIn("try dbQueue.write", atomic)
        self.assertIn("Self.upsert(db, activeDevice)", atomic)
        self.assertIn("rows.filter({ $0.status == .active }).count == 1", atomic)
        self.assertIn("MutationFailure.registrationVerificationFailed", atomic)

        wizard = self.read("Strand/Screens/AddDeviceWizard.swift")
        finish = wizard[
            wizard.index("private func finishVeepooAdd()") :
            wizard.index("private func ouraCapabilities")
        ]
        self.assertIn("session.commitPairedDevice(", finish)
        self.assertIn("model.deviceRegistry?.addAndSetActive(device)", finish)
        self.assertLess(
            finish.index("guard committed, let addedDevice else"),
            finish.index("onClose()"),
        )
        self.assertNotIn("model.registerDevice", finish)

    def test_only_proven_registry_capability_is_exposed(self) -> None:
        source = self.read("Strand/BLE/VeepooBandSource.swift")
        device = source[source.index("let device = PairedDevice(") :]
        self.assertIn("capabilities: [.hr]", device)
        profile = self.read("Strand/Screens/DevicesView.swift")
        veepoo_profile = profile[
            profile.index("if d.sourceKind == .veepoo") :
            profile.index("if d.sourceKind == .oura")
        ]
        self.assertIn(
            'localized: "appwide.devices.supplier_captures"',
            veepoo_profile,
        )
        self.assertIn(
            'localized: "appwide.devices.supplier_powers"',
            veepoo_profile,
        )
        localized = self.read("Tools/AppWideLocalization/appwide_strings.json")
        self.assertIn("Heart rate (live display only) · Battery", localized)
        self.assertIn(
            "Live display only. No history or scores are stored from this source.",
            localized,
        )
        for unsupported in (
            ".hrv",
            ".spo2",
            ".skinTemp",
            ".steps",
            ".sleep",
            ".strainLoad",
        ):
            self.assertNotIn(unsupported, device)
        for unsupported_copy in (
            "Powers Effort",
            "Powers Recovery",
            "Powers Sleep",
        ):
            self.assertNotIn(unsupported_copy, veepoo_profile)


if __name__ == "__main__":
    unittest.main()
