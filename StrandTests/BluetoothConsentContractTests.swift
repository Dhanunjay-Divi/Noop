import XCTest
@testable import Strand

/// CoreBluetooth can show its permission sheet when a central is constructed. These source contracts keep
/// the iOS composition root inert until either an explicit Connect/Scan gesture or a prior paired-device
/// restoration path proves user intent. The pure lifecycle policies are covered in their package tests;
/// this protects the iOS-only wiring that the macOS test host cannot exercise directly.
final class BluetoothConsentContractTests: XCTestCase {
    func testWhoopCentralIsLazyForFreshInstalls() throws {
        let source = try text("Strand/BLE/BLEManager.swift")
        let initializer = try slice(source, from: "public init(state: LiveState", to: "/// Build the WhoopStore")
        let iosInitializer = try slice(initializer, from: "#if os(iOS)", to: "#else")

        XCTAssertTrue(initializer.contains("Self.shouldResumeBluetoothRuntime"))
        XCTAssertTrue(initializer.contains("activateCentralIfNeeded(recordUserIntent: false)"))
        XCTAssertFalse(iosInitializer.contains("central = CBCentralManager"),
                       "A fresh AppModel must not directly construct CoreBluetooth before rationale.")
        XCTAssertTrue(source.contains("activateCentralIfNeeded(recordUserIntent: true)"),
                      "Explicit Connect/Scan entry points must prime the lazy runtime.")
        XCTAssertTrue(source.contains("noop.bluetooth.explicitlyReleased"),
                      "Removing the active strap must override legacy auto-resume evidence.")
    }

    func testWeightScaleCentralRequiresPairingOrExplicitAction() throws {
        let source = try text("Strand/BLE/WeightScaleSource.swift")
        let initializer = try slice(source, from: "init(defaults: UserDefaults", to: "var isScanning")
        let iosInitializer = try slice(initializer, from: "#if os(iOS)", to: "#else")

        XCTAssertTrue(initializer.contains("if restoredPeripheralID != nil { activateCentralIfNeeded() }"))
        XCTAssertFalse(iosInitializer.contains("central = CBCentralManager"),
                       "An unpaired scale source must not directly construct CoreBluetooth at launch.")
        XCTAssertTrue(source.contains("func scan() {\n        activateCentralIfNeeded()"))
        XCTAssertTrue(source.contains("func connect(_ id: UUID) {\n        activateCentralIfNeeded()"))
    }

    func testAddDeviceWizardConstructsOnlyTheSelectedScannerAfterScan() throws {
        let source = try text("Strand/Screens/AddDeviceWizard.swift")
        let initializer = try slice(source, from: "init(live: LiveState", to: "var body: some View")
        let startScan = try slice(source, from: "private func startScan(for type: DeviceType)",
                                  to: "/// These are the only construction points")

        // Presenting Add Device may render type/prep guidance but must not instantiate any discovery source:
        // each source constructs a CBCentralManager in its initializer, which can trigger iOS permission UI.
        for constructor in ["StandardHRSource(", "FTMSSource(", "HuamiHRSource(", "OuraLiveSource("] {
            XCTAssertFalse(initializer.contains(constructor),
                           "Opening Add Device must not construct \(constructor) before a Scan gesture.")
        }
        XCTAssertTrue(source.contains("@State private var hrScanner: StandardHRSource?"))
        XCTAssertTrue(source.contains("@State private var ftmsScanner: FTMSSource?"))
        XCTAssertTrue(source.contains("@State private var huamiScanner: HuamiHRSource?"))
        XCTAssertTrue(source.contains("@State private var ouraScanner: OuraLiveSource?"))

        // The explicit Scan dispatcher activates exactly the scanner for the selected family. Its ensure
        // helper is the sole constructor location and retains that source for rescan/stop.
        XCTAssertTrue(startScan.contains("ensureHRScanner().scan()"))
        XCTAssertTrue(startScan.contains("ensureFTMSScanner().scan()"))
        XCTAssertTrue(startScan.contains("ensureHuamiScanner().scan()"))
        XCTAssertTrue(startScan.contains("ensureOuraScanner().scan()"))
        XCTAssertEqual(occurrences(of: "let scanner = StandardHRSource(", in: source), 1)
        XCTAssertEqual(occurrences(of: "let scanner = FTMSSource(", in: source), 1)
        XCTAssertEqual(occurrences(of: "let scanner = HuamiHRSource(", in: source), 1)
        XCTAssertEqual(occurrences(of: "let scanner = OuraLiveSource(", in: source), 1)
    }

    private func text(_ relativePath: String) throws -> String {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func slice(_ source: String, from start: String, to end: String) throws -> String {
        let lower = try XCTUnwrap(source.range(of: start)).lowerBound
        let upper = try XCTUnwrap(source.range(of: end, range: lower..<source.endIndex)).lowerBound
        return String(source[lower..<upper])
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }
}
