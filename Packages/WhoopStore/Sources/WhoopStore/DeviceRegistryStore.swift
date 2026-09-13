import Foundation
import GRDB
import WhoopProtocol

/// Synchronous GRDB access to the device registry + day-ownership tables. Kept synchronous (its own
/// queue) to mirror the existing store helpers; the app wraps it behind the WhoopStore actor / a
/// @MainActor cache. Enforces invariant I1 (at most one .active) inside setActive's transaction.
///
/// `Sendable`: the only stored property is a GRDB `DatabaseWriter` (a `DatabasePool` in production;
/// the protocol refines `Sendable` and manages its own concurrency), so this thin synchronous wrapper
/// is safe to hand across actor boundaries, e.g. the off-main `IntelligenceEngine.analyzeRecent` scan
/// loop (FIX 1). A cross-module `public` struct doesn't auto-infer `Sendable`, so it's declared here.
///
/// Takes `any DatabaseWriter` (not the concrete `DatabaseQueue`) so it works with the store's
/// `DatabasePool` (#755) AND a plain `DatabaseQueue` (in-memory tests) unchanged: both expose the
/// same synchronous `.read`/`.write` API used below.
public struct DeviceRegistryStore: Sendable {
    let dbQueue: any DatabaseWriter
    public init(dbQueue: any DatabaseWriter) { self.dbQueue = dbQueue }

    public func all() throws -> [PairedDevice] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM pairedDevice ORDER BY addedAt ASC").map(Self.decode)
        }
    }

    public func activeDeviceId() throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1")
        }
    }

    public func add(_ d: PairedDevice) throws {
        try dbQueue.write { db in try Self.upsert(db, d) }
    }

    /// I1: promoting one device demotes whatever was active, atomically (single write transaction).
    public func setActive(_ id: String) throws {
        try dbQueue.write { db in
            let previous = try String.fetchOne(
                db,
                sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1"
            )
            if previous == id {
                try db.execute(
                    sql: "UPDATE pairedDevice SET lastSeenAt = ? WHERE id = ?",
                    arguments: [Int(Date().timeIntervalSince1970), id]
                )
                return
            }
            try db.execute(sql: "UPDATE pairedDevice SET status = 'paired' WHERE status = 'active'")
            try db.execute(sql: "UPDATE pairedDevice SET status = 'active', lastSeenAt = ? WHERE id = ?",
                           arguments: [Int(Date().timeIntervalSince1970), id])
            try AnalysisOwnershipInvalidation.mark(db)
        }
    }

    /// Refresh connection recency without changing device status or identity. Call this only on a real
    /// connect/disconnect transition; live samples can arrive many times per second and must not turn the
    /// registry into a write-amplification path.
    public func touch(_ id: String, at unix: Int = Int(Date().timeIntervalSince1970)) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET lastSeenAt = ? WHERE id = ?",
                           arguments: [unix, id])
        }
    }

    public func archive(_ id: String) throws {
        try dbQueue.write { db in
            guard let status = try String.fetchOne(
                db,
                sql: "SELECT status FROM pairedDevice WHERE id = ?",
                arguments: [id]
            ),
            status != DeviceStatus.archived.rawValue else {
                return
            }
            try db.execute(sql: "UPDATE pairedDevice SET status = 'archived' WHERE id = ?", arguments: [id])
            try db.execute(
                sql: "DELETE FROM dayOwnership WHERE deviceId = ?",
                arguments: [id]
            )
            try AnalysisOwnershipInvalidation.mark(db)
        }
    }

    public func rename(_ id: String, nickname: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET nickname = ? WHERE id = ?", arguments: [nickname, id])
        }
    }

    /// Update the model label for an existing device (e.g. seeded "WHOOP" → "WHOOP 4.0" once the
    /// strap's service family is known from a live BLE connect).
    public func setModel(_ id: String, model: String) throws {
        try dbQueue.write { db in try Self.updateModel(db, id: id, model: model) }
    }

    /// Reconcile the active WHOOP row with identity evidence from the connection that is actually live.
    ///
    /// `attestedVariant == nil` means only the GATT family is known. That evidence repairs stale labels,
    /// but preserves an existing exact label from the same family (an ordinary reconnect must not turn
    /// "WHOOP MG" back into "WHOOP 5.0 / MG"). Passing `.unknown` means DIS evidence was absent or
    /// contradictory and is deliberately a no-op. A positive DIS variant stores the exact model label.
    /// Non-WHOOP active rows are never touched.
    @discardableResult
    public func reconcileActiveWhoopModel(
        observedFamily: DeviceFamily,
        attestedVariant: Whoop5Variant? = nil
    ) throws -> Bool {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM pairedDevice WHERE status = 'active' LIMIT 1"
            ) else { return false }

            let active = Self.decode(row)
            guard Self.isWhoop(active) else { return false }

            let target: String
            if let attestedVariant {
                // DIS is only meaningful on the 5-generation transport. Refuse a cross-family or
                // unknown/contradictory result instead of choosing a convenient label.
                guard observedFamily == .whoop5,
                      let exact = attestedVariant.registryModelLabel else { return false }
                target = exact
            } else {
                // The existing label is already exact/vague for the observed family: preserve it.
                // This is what prevents a later GATT reconnect from downgrading WHOOP MG to 5.0 / MG.
                target = DeviceFamily.identifiedRegistryModel(active.model) == observedFamily
                    ? active.model : observedFamily.registryModelLabel
            }

            var changed = false
            if active.model != target {
                try Self.updateModel(db, id: active.id, model: target)
                changed = true
            }
            // `device` is the legacy stream-owner table used by older reads/exports. Keep the row for
            // THIS attested WHOOP in lockstep with the canonical registry inside the same transaction;
            // otherwise a real MG can remain labelled 4.0 there forever. The active-row `isWhoop` guard
            // above is load-bearing: no non-WHOOP brand or different device id is eligible.
            try db.execute(sql: """
                UPDATE device SET name = ?
                WHERE id = ? AND (name IS NULL OR name <> ?)
                """, arguments: [target, active.id, target])
            changed = changed || db.changesCount > 0
            return changed
        }
    }

    /// Adopt (or clear) the stable BLE identity for a registry row. `peripheralId` is the
    /// CBPeripheral.identifier.uuidString on iOS/Mac; passing nil un-adopts it.
    public func setPeripheralId(_ id: String, peripheralId: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE pairedDevice SET peripheralId = ? WHERE id = ?",
                           arguments: [peripheralId, id])
        }
    }

    /// Find the registry row that has adopted a given BLE peripheral, if any. Used to map a
    /// connected CBPeripheral back to its `PairedDevice` so multiple straps stay distinct.
    public func device(forPeripheralId peripheralId: String) throws -> PairedDevice? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM pairedDevice WHERE peripheralId = ? LIMIT 1",
                             arguments: [peripheralId]).map(Self.decode)
        }
    }

    /// Every table whose rows are keyed by `deviceId` (the per-device sample/derived tables). This is
    /// the authoritative list `deleteAllData` clears — kept in sync with the `deviceId`-keyed tables in
    /// `Database.swift`. The `pairedDevice` registry row itself is NOT here (a delete-data operation
    /// empties the device's recordings; archiving/removing the registry entry is a separate op).
    static let deviceScopedTables = [
        "hrSample", "rrInterval", "spo2Sample", "skinTempSample", "respSample", "gravitySample",
        "stepSample", "ppgHrSample", "event", "battery", "dailyMetric", "sleepSession",
        "journal", "workout", "appleDaily", "metricSeries", "dayOwnership",
        // Added: device-keyed tables introduced by later migrations that the list previously missed, so a
        // "delete all of this device's data" left raw captures (rawBatch), user-entered lab/blood markers
        // (labMarker), banked band sleep-state (sleepStateSample) and live coaching sessions
        // (liveSession) behind — a privacy defect for a delete-means-gone app. `DeviceRegistryStoreTests`
        // asserts this list covers every deviceId-keyed table in Database.swift so future migrations
        // can't reintroduce the gap.
        "rawBatch", "labMarker", "sleepStateSample", "liveSession",
        // v25-oura-raw: the opt-in Oura cloud-import raw archive is deviceId-keyed too, so "delete this
        // device's data" must clear it - else an imported Oura source's payloads would survive deletion.
        "ouraRaw",
        // v27-ppg-waveform (issue #156 follow-up): the durable raw v26 optical PPG waveform is
        // deviceId-keyed exactly like every other per-second stream above — must be cleared too, or a
        // "delete all of this device's data" leaves the raw waveform behind (the same privacy defect
        // this list exists to close).
        "ppgWaveformSample",
        // v28-raw-imu (#423): the opt-in 5/MG raw-IMU offload capture is deviceId-keyed too - "delete all
        // of this device's data" must clear it, or the raw inertial samples survive deletion (same defect).
        "rawImuSample",
        // v34: timestamped external body-weight readings are device-scoped canonical health data too.
        "bodyMeasurement",
        // v39: editable manual/imported nutrition rows are user-owned and device-scoped under the
        // dedicated `nutrition-log` id, so an explicit source deletion must remove both entries and
        // their metricSeries projections.
        "nutritionEntry",
        // v55: editable hydration rows are canonical, device-scoped health data. They must not
        // survive an explicit source deletion while their scalar metric projection is removed.
        "hydrationEntry",
        // v57: analysis generation/acknowledgement state is keyed by source and must be removed with that
        // source. Leaving it behind would retain an identifier and trigger a meaningless future rescore.
        "analysisDirtySource",
    ]

    /// Permanently delete every recorded sample/derived row belonging to one device, across all
    /// `deviceId`-keyed tables, in a single transaction (all-or-nothing). The `pairedDevice` registry
    /// row is left intact — the caller archives/removes that separately. Tables are deleted defensively
    /// with `DELETE FROM <table> WHERE deviceId = ?`; a missing table would throw, but every table here
    /// is created unconditionally by the migrator, so the set is stable.
    public func deleteAllData(deviceId: String) throws {
        try dbQueue.write { db in
            for table in Self.deviceScopedTables {
                try db.execute(sql: "DELETE FROM \(table) WHERE deviceId = ?", arguments: [deviceId])
            }
        }
    }

    // MARK: day ownership
    public struct DayOwner: Equatable { public let deviceId: String; public let locked: Bool }

    public func setDayOwner(day: String, deviceId: String, locked: Bool) throws {
        try dbQueue.write { db in
            let previous = try Row.fetchOne(
                db,
                sql: "SELECT deviceId, locked FROM dayOwnership WHERE day = ?",
                arguments: [day]
            )
            if let previous,
               (previous["deviceId"] as String) == deviceId,
               (previous["locked"] as Int) == (locked ? 1 : 0) {
                return
            }
            try db.execute(sql: """
                INSERT INTO dayOwnership (day, deviceId, locked) VALUES (?, ?, ?)
                ON CONFLICT(day) DO UPDATE SET deviceId = excluded.deviceId, locked = excluded.locked
            """, arguments: [day, deviceId, locked ? 1 : 0])
            try AnalysisOwnershipInvalidation.mark(
                db,
                affectedRange: AnalysisOwnershipInvalidation.dayRange(day)
            )
        }
    }

    public func dayOwner(_ day: String) throws -> DayOwner? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT deviceId, locked FROM dayOwnership WHERE day = ?", arguments: [day])
            else { return nil }
            return DayOwner(deviceId: row["deviceId"], locked: (row["locked"] as Int) == 1)
        }
    }

    // MARK: mapping
    private static func isWhoop(_ device: PairedDevice) -> Bool {
        device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
            || device.id == "my-whoop"
            || device.id.lowercased().hasPrefix("whoop-")
    }

    private static func updateModel(_ db: Database, id: String, model: String) throws {
        // A model attestation also repairs the seeded WHOOP's capability truth. This is important
        // for a 5/MG: only after generation is known can the live `steps` capability be advertised.
        let capabilities = WhoopLiveCapabilities.encoded(forModel: model)
        try db.execute(sql: """
            UPDATE pairedDevice SET model = ?,
                capabilities = CASE
                    WHEN brand = 'WHOOP' OR id = 'my-whoop' OR id LIKE 'whoop-%' THEN ?
                    ELSE capabilities
                END
            WHERE id = ?
            """, arguments: [model, capabilities, id])
    }

    private static func upsert(_ db: Database, _ d: PairedDevice) throws {
        try db.execute(sql: """
            INSERT INTO pairedDevice (id, brand, model, nickname, peripheralId, sourceKind, capabilities, status, addedAt, lastSeenAt)
            VALUES (?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET brand=excluded.brand, model=excluded.model, nickname=excluded.nickname,
                peripheralId=excluded.peripheralId, sourceKind=excluded.sourceKind, capabilities=excluded.capabilities,
                status=excluded.status, lastSeenAt=excluded.lastSeenAt
        """, arguments: [d.id, d.brand, d.model, d.nickname, d.peripheralId, d.sourceKind.rawValue,
                         d.capabilities.map(\.rawValue).sorted().joined(separator: ","),
                         d.status.rawValue, d.addedAt, d.lastSeenAt])
    }

    private static func decode(_ row: Row) -> PairedDevice {
        var caps = Set((row["capabilities"] as String).split(separator: ",")
            .compactMap { Metric(rawValue: String($0)) })
        let id = row["id"] as String
        let brand = row["brand"] as String
        if brand.caseInsensitiveCompare("WHOOP") == .orderedSame || id == "my-whoop" || id.hasPrefix("whoop-") {
            caps = WhoopLiveCapabilities.withoutCalibratedSpo2(caps)
        }
        return PairedDevice(id: id, brand: brand, model: row["model"], nickname: row["nickname"],
                            peripheralId: row["peripheralId"],
                            sourceKind: SourceKind(rawValue: row["sourceKind"]) ?? .liveBLE,
                            capabilities: caps, status: DeviceStatus(rawValue: row["status"]) ?? .paired,
                            addedAt: row["addedAt"], lastSeenAt: row["lastSeenAt"])
    }
}
