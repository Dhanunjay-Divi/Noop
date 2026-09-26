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
    /// All paired devices (any status), oldest-added first — the store's `all()` ordering.
    @Published private(set) var devices: [PairedDevice] = []
    /// The active device's id. The seeded source is used before the first successful read, while `nil`
    /// explicitly represents a readable registry with no active row.
    @Published private(set) var activeDeviceId: String? = "my-whoop"

    private let store: DeviceRegistryStore

    init(store: DeviceRegistryStore) {
        self.store = store
    }

    /// Load the device list and active id from the store. Best-effort: on any error the published
    /// values are left untouched, never crashing.
    func reload() {
        guard let rows = try? store.all() else { return }
        publish(rows)
    }

    /// Authoritative supplier registrations for secure-cleanup reconciliation.
    /// `nil` means the registry could not be read and callers must fail closed.
    /// Archived compensation rows do not own a live credential.
    func registeredSupplierCredentialDeviceIDs() -> Set<String>? {
        do {
            return Set(
                try store.all()
                    .filter {
                        $0.sourceKind == .veepoo
                            && $0.status != .archived
                    }
                    .map(\.id)
            )
        } catch {
            return nil
        }
    }

    /// Archived supplier rows are a durable fail-closed cleanup ledger. A
    /// rejected credential whose Keychain and fallback markers were both
    /// unavailable cannot become active again, and a later process can retry
    /// deleting its credential from this inventory.
    func archivedSupplierCredentialDeviceIDs() -> Set<String>? {
        do {
            return Set(
                try store.all()
                    .filter {
                        $0.sourceKind == .veepoo
                            && $0.status == .archived
                    }
                    .map(\.id)
            )
        } catch {
            return nil
        }
    }

    // MARK: - UI mutations (Devices screen)
    //
    // Each op delegates to the synchronous store, then `reload()`s so the published `devices` /
    // `activeDeviceId` reflect the change and the UI updates. Best-effort: a store failure leaves the
    // published state untouched (we never crash the UI on a write error).

    /// Add or upsert a paired device (the Add wizard's chosen strap), then verify the authoritative
    /// read-back before publishing success. A swallowed store failure must never let onboarding claim
    /// that a band was saved when it will disappear on relaunch.
    @discardableResult
    func add(_ device: PairedDevice) -> Bool {
        do {
            try store.add(device)
            let rows = try store.all()
            guard let saved = rows.first(where: { $0.id == device.id }),
                  saved.brand == device.brand,
                  saved.model == device.model,
                  saved.nickname == device.nickname,
                  saved.peripheralId == device.peripheralId,
                  saved.sourceKind == device.sourceKind,
                  saved.capabilities
                    == (Self.isWhoop(device)
                        ? WhoopLiveCapabilities.withoutUnvalidatedLiveMetrics(
                            device.capabilities
                        )
                        : device.capabilities),
                  saved.status == device.status,
                  saved.lastSeenAt == device.lastSeenAt else {
                return false
            }
            publish(rows)
            return true
        } catch {
            return false
        }
    }

    /// Register a newly authenticated source and make it active as one verified database transaction.
    /// The store returns the authoritative rows only after the complete selected device and the
    /// single-active invariant are verified, so onboarding cannot publish a partial adoption.
    @discardableResult
    func addAndSetActive(_ device: PairedDevice) -> Bool {
        do {
            publish(try store.addAndSetActive(device))
            return true
        } catch {
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

            publish(try store.setActiveVerified(fallback.id))
            return true
        } catch {
            return false
        }
    }

    /// Persist an authentication rejection when neither secure cleanup marker
    /// can be written. Archiving happens before fallback selection, so a crash
    /// cannot leave the rejected supplier eligible for activation. A fallback
    /// activation failure does not undo that fail-closed state.
    @discardableResult
    func persistRejectedSupplier(_ rejectedDeviceID: String) -> Bool {
        do {
            let rows = try store.all()
            guard let rejected = rows.first(
                where: { $0.id == rejectedDeviceID }
            ), rejected.sourceKind == .veepoo else {
                return false
            }
            let existingActive = rows.first {
                $0.id != rejectedDeviceID
                    && $0.status == .active
                    && $0.status != .archived
            }
            let defaultWhoop = rows.first {
                $0.id != rejectedDeviceID
                    && $0.id == "my-whoop"
                    && $0.status != .archived
            } ?? rows.first {
                $0.id != rejectedDeviceID
                    && Self.isWhoop($0)
                    && $0.status != .archived
            }

            guard try store.archiveVerified(rejectedDeviceID) else {
                return false
            }
            if let fallback = existingActive ?? defaultWhoop,
               let activated = try? store.setActiveVerified(fallback.id) {
                publish(activated)
            } else {
                reload()
            }
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
    /// publication emits `nil` until the caller selects a verified replacement.
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

    private func publish(_ rows: [PairedDevice]) {
        devices = rows
        activeDeviceId = rows.first(where: { $0.status == .active })?.id
    }

    private static func isWhoop(_ device: PairedDevice) -> Bool {
        device.id == "my-whoop"
            || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }
}
