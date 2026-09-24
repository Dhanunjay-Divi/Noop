import Foundation
import Combine
import WhoopStore

// MARK: - DeviceRegistry
//
// Observable @MainActor cache over the synchronous `DeviceRegistryStore` (device-foundation
// Task 5). The UI observes this for the paired-device list + the currently active device; the
// app's `deviceId` is sourced from `activeDeviceId` so it's "the active device's id" rather than
// the hardcoded "my-whoop" literal. Behaviour is unchanged today - migration v15 seeds a single
// 'my-whoop' row as `.active`, so the active id is still "my-whoop".
//
// `DeviceRegistryStore` is synchronous (its own GRDB queue, internally serialized), so the reads
// here are plain synchronous calls; we keep failures non-fatal and fall back to the seeded defaults.
@MainActor
final class DeviceRegistry: ObservableObject {
    private enum MutationFailure: Error {
        case verificationFailed
    }

    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. Defaults to "my-whoop" so callers have a safe value before the
    /// first `reload()` and if the registry can't be read.
    @Published private(set) var activeDeviceId: String = "my-whoop"

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. Best-effort: on any error the published
    /// values are left untouched (keeping the safe "my-whoop" fallback), never crashing.
    func reload() {
        guard let rows = try? store.all() else { return }
        publish(rows)
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s so the published `devices` /
    // `activeDeviceId` reflect the change and the UI updates. Best-effort: a store failure leaves the
    // published state untouched (we never crash the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap). Refreshes the published list.
    func add(_ device: PairedDevice) {
        try? store.add(device)
        reload()
    }

    /// Register a newly authenticated source and make it active as one verified operation from the
    /// app's perspective. The underlying store keeps each database write transactional; this wrapper
    /// withholds publication until both writes and the authoritative read-back succeed. On failure it
    /// restores the prior rows and archives a newly inserted candidate so a partial adoption cannot be
    /// mistaken for an active source.
    @discardableResult
    func addAndSetActive(_ device: PairedDevice) -> Bool {
        let originalRows: [PairedDevice]
        do {
            originalRows = try store.all()
        } catch {
            return false
        }

        do {
            try store.add(device)
            try store.setActive(device.id)
            let rows = try store.all()
            guard rows.first(where: { $0.status == .active })?.id == device.id else {
                throw MutationFailure.verificationFailed
            }
            publish(rows)
            return true
        } catch {
            compensateFailedRegistration(
                attemptedDeviceID: device.id,
                originalRows: originalRows
            )
            return false
        }
    }

    /// Reconcile a supplier row that cannot own transport with the source that is actually still
    /// running. A known prior transport wins; otherwise the seeded/non-archived WHOOP path is restored.
    /// Publication happens only after the durable active row is verified.
    @discardableResult
    func reconcileUnavailableSupplier(
        _ unavailableDeviceID: String,
        preferredTransportDeviceID: String? = nil
    ) -> Bool {
        do {
            let rows = try store.all()
            guard let active = rows.first(where: { $0.status == .active }) else {
                return false
            }
            guard active.id == unavailableDeviceID else {
                publish(rows)
                return true
            }
            guard active.sourceKind == .veepoo else { return false }

            let preferred = preferredTransportDeviceID.flatMap { preferredID in
                rows.first {
                    $0.id == preferredID
                        && $0.id != unavailableDeviceID
                        && $0.status != .archived
                }
            }
            let defaultWhoop = rows.first {
                $0.id == "my-whoop" && $0.status != .archived
            } ?? rows.first {
                Self.isWhoop($0) && $0.status != .archived
            }
            guard let fallback = preferred ?? defaultWhoop else { return false }

            try store.setActive(fallback.id)
            let updatedRows = try store.all()
            guard updatedRows.first(where: { $0.status == .active })?.id == fallback.id else {
                throw MutationFailure.verificationFailed
            }
            publish(updatedRows)
            return true
        } catch {
            return false
        }
    }

    /// Make `id` the single active device. The store demotes whatever was active in the same
    /// transaction (invariant I1); changing `activeDeviceId` drives the `SourceCoordinator` to run the
    /// right live source.
    func setActive(_ id: String) {
        try? store.setActive(id)
        reload()
    }

    /// Archive (remove) a device: NOOP stops connecting to it, but its recorded data is kept. The store
    /// verifies the status change and clears day ownership in one transaction, so a failed archive leaves
    /// both the registry row and every ownership override unchanged. If the archived device was active,
    /// `activeDeviceId` is left as-is here; the caller decides the next active device.
    @discardableResult
    func archive(_ id: String) -> Bool {
        do {
            guard try store.archiveVerified(id) else { return false }
            reload()
            return true
        } catch {
            return false
        }
    }

    /// Rename a device. `name` nil/empty clears the nickname so it falls back to brand+model.
    func rename(_ id: String, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        try? store.rename(id, nickname: (trimmed?.isEmpty == false) ? trimmed : nil)
        reload()
    }

    /// Permanently delete every recorded sample/derived row for a device across all `deviceId`-keyed
    /// tables. Does NOT remove the registry row (that's `archive`); this only empties its recordings.
    ///
    /// Routed through the `WhoopStore` actor's `deleteAllData(deviceId:)`, so the heavy 16+-table delete
    /// runs on the actor's OWN (off-main) executor instead of blocking the main thread (this is a
    /// `@MainActor` cache). Calling the synchronous `DeviceRegistryStore` write directly here would run
    /// the whole transaction on the main actor and freeze the UI on a large device/Apple-Health dataset.
    /// Best-effort: a store failure leaves the recordings and published state untouched. Awaits the delete
    /// BEFORE `reload()` so the refreshed device list reflects the emptied recordings.
    @discardableResult
    func deleteDeviceData(_ id: String, store: WhoopStore) async -> Bool {
        do {
            try await store.deleteAllData(deviceId: id)
        } catch {
            return false
        }
        reload()
        return true
    }

    /// Adopt (or clear, when nil) the stable BLE identity for a device — the
    /// CBPeripheral.identifier.uuidString on iOS/Mac. Lets NOOP tell physical straps apart and map a
    /// connected peripheral back to its registry row. Refreshes the published list. Best-effort.
    func setPeripheralId(_ id: String, peripheralId: String?) {
        try? store.setPeripheralId(id, peripheralId: peripheralId)
        reload()
    }

    /// Find the paired device that has adopted a given BLE peripheral, if any. A plain read of the
    /// store (no reload) — returns nil on any error or when no row has adopted that peripheral yet.
    func device(forPeripheralId peripheralId: String) -> PairedDevice? {
        (try? store.device(forPeripheralId: peripheralId)) ?? nil
    }

    /// Update the model label for a device and refresh the published list. Best-effort.
    func setModel(_ id: String, model: String) {
        try? store.setModel(id, model: model)
        reload()
    }

    /// Refresh the device's last-seen timestamp on a real connection edge. Kept separate from sample
    /// ingestion so a high-rate heart-rate stream never writes the registry for every packet.
    func touch(_ id: String, at unix: Int = Int(Date().timeIntervalSince1970)) {
        try? store.touch(id, at: unix)
        reload()
    }

    private func compensateFailedRegistration(
        attemptedDeviceID: String,
        originalRows: [PairedDevice]
    ) {
        do {
            if !originalRows.contains(where: { $0.id == attemptedDeviceID }) {
                try store.archive(attemptedDeviceID)
            }
            for row in originalRows {
                try store.add(row)
            }
            if let originalActive = originalRows.first(where: { $0.status == .active }) {
                try store.setActive(originalActive.id)
            }
            publish(try store.all())
        } catch {
            reload()
        }
    }

    private func publish(_ rows: [PairedDevice]) {
        devices = rows
        if let active = rows.first(where: { $0.status == .active })?.id {
            activeDeviceId = active
        }
    }

    private static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop"
            || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
