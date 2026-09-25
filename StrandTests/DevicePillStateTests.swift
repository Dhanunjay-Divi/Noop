import XCTest
@testable import Strand
import WhoopStore

/// Pins the Devices card's state-pill priority (#221): "Connected · not paired" must beat "Active · Live"
/// but yield to a reboot's "Reconnecting…". Mirrors the Kotlin `DevicePillStateTest` exactly — a silent
/// reorder on either platform would otherwise only be caught by eyeballing a screenshot.
final class DevicePillStateTests: XCTestCase {

    func testBondRefused_beatsActiveLive_butYieldsToReconnecting() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: true, isLiveConnected: true).label,
            "Connected · not paired")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: true,
                                     bondRefused: true, isLiveConnected: true).label,
            "Reconnecting…")
    }

    func testNormalConnect_isUnaffected() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: true).label,
            "Active · Live")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: true, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Active")
    }

    func testNonActiveAndArchived() {
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: false, isActive: false, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Paired")
        XCTAssertEqual(
            DevicePillState.resolve(isArchived: true, isActive: false, isReconnecting: false,
                                     bondRefused: false, isLiveConnected: false).label,
            "Removed")
    }

    func testUnknownBandModelUsesProductName() {
        let device = PairedDevice(id: "my-whoop", brand: "WHOOP", model: "WHOOP",
                                  nickname: nil, peripheralId: nil, sourceKind: .liveBLE,
                                  capabilities: [.hr, .hrv], status: .active,
                                  addedAt: 0, lastSeenAt: 0)
        XCTAssertEqual(DeviceCapabilityProfile.make(for: device).displayModel, "Compatible band")
    }

    func testBandCustomerNameAndVisibleDiagnosticsHideVendorBrand() {
        XCTAssertEqual(WhoopModel.whoop4.displayName, "Compatible band")
        XCTAssertEqual(WhoopModel.whoop5mg.displayName, "Compatible band")
        XCTAssertEqual(WhoopModel.whoop4.transportName, "legacy band")
        XCTAssertEqual(WhoopModel.whoop5mg.transportName, "newer band")
    }

    func testCompatibleBandSelectionPreservesDistinctVisibleAndRegistryModels() {
        let older = AddDeviceWizard.compatibleBandIdentity(for: .whoop4)
        let newer = AddDeviceWizard.compatibleBandIdentity(for: .whoop5mg)

        XCTAssertEqual(
            older.displayName,
            String(
                localized:
                    "appwide.onboarding.device_wizard.compatible_4_title"
            )
        )
        XCTAssertEqual(older.registryModel, "4.0")
        XCTAssertEqual(
            newer.displayName,
            String(
                localized:
                    "appwide.onboarding.device_wizard.compatible_5_title"
            )
        )
        XCTAssertEqual(newer.registryModel, "5.0 MG")
        XCTAssertNotEqual(older, newer)

        let olderDevice = PairedDevice(
            id: "whoop-older",
            brand: "WHOOP",
            model: older.registryModel,
            nickname: older.displayName,
            peripheralId: UUID().uuidString,
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .paired,
            addedAt: 0,
            lastSeenAt: 0
        )
        let newerDevice = PairedDevice(
            id: "whoop-newer",
            brand: "WHOOP",
            model: newer.registryModel,
            nickname: newer.displayName,
            peripheralId: UUID().uuidString,
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .paired,
            addedAt: 0,
            lastSeenAt: 0
        )

        XCTAssertEqual(olderDevice.displayName, older.displayName)
        XCTAssertEqual(newerDevice.displayName, newer.displayName)
        XCTAssertNotEqual(olderDevice.displayName, newerDevice.displayName)
        XCTAssertNotEqual(olderDevice.model, newerDevice.model)
    }

    func testDeviceModelIsHiddenOnlyWhenItDuplicatesTheDisplayName() {
        XCTAssertFalse(
            DeviceCapabilityProfile.shouldShowModel(
                displayName: " Compatible band ",
                displayModel: "compatible BAND"
            )
        )
        XCTAssertTrue(
            DeviceCapabilityProfile.shouldShowModel(
                displayName: "Morning Band",
                displayModel: "Compatible band"
            )
        )
    }

    func testDevicesDefaultHierarchyKeepsDiagnosticsBehindDisclosure() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Screens/DevicesView.swift"))
        XCTAssertTrue(source.contains("private var emptyDevicesHero"))
        XCTAssertTrue(source.contains("Text(\"appwide.devices.empty_title\")"))
        XCTAssertTrue(source.contains("\"appwide.devices.connect_action\""))
        XCTAssertTrue(source.contains("selectionScope: .launchBands"))
        XCTAssertTrue(source.contains("DisclosureGroup(isExpanded: $showTechnicalDetails)"))
        XCTAssertTrue(source.contains("Text(\"Technical details\")"))
        XCTAssertFalse(source.contains("Button(action: action) { cardContent }"),
                       "A disclosure cannot be nested in the whole-card activation button.")
    }

    func testLaunchBandPickerOmitsUnavailableAndExperimentalRows() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Strand/Screens/AddDeviceWizard.swift"))
        let typeStep = source
            .components(separatedBy: "@ViewBuilder private var typeStep: some View {")[1]
            .components(separatedBy: "private func typeRow")[0]

        XCTAssertFalse(typeStep.contains("unavailableTypeRow"))
        XCTAssertLessThan(
            try XCTUnwrap(typeStep.range(of: ".whoop5mg")?.lowerBound),
            try XCTUnwrap(typeStep.range(of: ".whoop4")?.lowerBound)
        )
        XCTAssertTrue(source.contains("if selectionScope == .allDevices"))
        XCTAssertTrue(source.contains("type.isWhoop || type == .veepoo"))
    }

    func testArchivedSupplierAffordanceUsesAddDeviceInsteadOfMakeActive() {
        let supplier = PairedDevice(
            id: "supplier-removed",
            brand: "Veepoo-compatible",
            model: "Compatible supplier band",
            peripheralId: UUID().uuidString,
            sourceKind: .veepoo,
            capabilities: [.hr],
            status: .archived,
            addedAt: 0,
            lastSeenAt: 0
        )

        XCTAssertEqual(
            DeviceActivationAffordance.resolve(
                device: supplier,
                isActive: false,
                hasReAddAction: true,
                supplierPairingAvailable: true
            ),
            .addDevice
        )
        XCTAssertNil(
            DeviceActivationAffordance.resolve(
                device: supplier,
                isActive: false,
                hasReAddAction: false,
                supplierPairingAvailable: true
            )
        )
        XCTAssertNil(
            DeviceActivationAffordance.resolve(
                device: supplier,
                isActive: false,
                hasReAddAction: true,
                supplierPairingAvailable: false
            )
        )
    }

    func testArchivedWhoopAndOuraAffordancesRemainMakeActive() {
        let devices = [
            PairedDevice(
                id: "whoop-removed",
                brand: "WHOOP",
                model: "5.0 MG",
                peripheralId: UUID().uuidString,
                sourceKind: .liveBLE,
                capabilities: [.hr],
                status: .archived,
                addedAt: 0,
                lastSeenAt: 0
            ),
            PairedDevice(
                id: "oura-removed",
                brand: "Oura",
                model: "Oura Ring 4",
                peripheralId: UUID().uuidString,
                sourceKind: .oura,
                capabilities: [.hr, .sleep],
                status: .archived,
                addedAt: 0,
                lastSeenAt: 0
            ),
        ]

        for device in devices {
            XCTAssertEqual(
                DeviceActivationAffordance.resolve(
                    device: device,
                    isActive: false,
                    hasReAddAction: true,
                    supplierPairingAvailable: false
                ),
                .makeActive
            )
        }
    }

    func testRemovedSupplierUIReentersPairingInsteadOfSettingRegistryActive()
        throws
    {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "Strand/Screens/DevicesView.swift"
            )
        )

        XCTAssertTrue(
            source.contains(
                "presentAddWizard(startAt: (.veepoo, .prep))"
            )
        )
        XCTAssertFalse(
            source.contains(
                "onReAdd: { registry.setActive(device.id) }"
            )
        )
    }
}
