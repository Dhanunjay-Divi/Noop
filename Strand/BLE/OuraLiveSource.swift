import Foundation
import Combine
import CoreBluetooth
import Security
import WhoopProtocol
import WhoopStore
import OuraProtocol

/// Pure state machine that keeps an Oura history resume cursor behind every asynchronous store write.
/// The BLE transport owns the tasks and ring timestamps; this type owns only ordering, failure and stale-
/// generation decisions so reconnect/timeout behavior is deterministic and unit-testable.
struct OuraHistoryPersistenceGate: Equatable {
    struct Resolution: Equatable {
        let drainCompleted: Bool
        let allWritesSucceeded: Bool
    }

    struct WriteResult: Equatable {
        let accepted: Bool
        let resolution: Resolution?
    }

    private(set) var generation: UInt64 = 0
    private(set) var isActive = false
    private(set) var pendingWriteCount = 0
    private(set) var sawWriteFailure = false
    private(set) var requestedFinish: Bool?
    private(set) var isSealed = false

    @discardableResult
    mutating func begin() -> UInt64 {
        generation &+= 1
        isActive = true
        pendingWriteCount = 0
        sawWriteFailure = false
        requestedFinish = nil
        isSealed = false
        return generation
    }

    mutating func invalidate() {
        generation &+= 1
        isActive = false
        pendingWriteCount = 0
        sawWriteFailure = false
        requestedFinish = nil
        isSealed = false
    }

    mutating func register(generation candidate: UInt64) -> Bool {
        guard isActive, candidate == generation else { return false }
        pendingWriteCount += 1
        return true
    }

    mutating func completeWrite(generation candidate: UInt64, succeeded: Bool) -> WriteResult {
        guard isActive, candidate == generation, pendingWriteCount > 0 else {
            return WriteResult(accepted: false, resolution: nil)
        }
        pendingWriteCount -= 1
        if !succeeded { sawWriteFailure = true }
        return WriteResult(accepted: true, resolution: resolveIfReady())
    }

    mutating func requestFinish(drainCompleted: Bool) -> Resolution? {
        guard isActive else { return nil }
        requestedFinish = drainCompleted
        return resolveIfReady()
    }

    /// Close registration at a real request boundary. Until then, delayed notifications from the current
    /// GetEvents request may still register writes after its terminal summary and quiet window.
    mutating func seal() -> Resolution? {
        guard isActive, requestedFinish != nil else { return nil }
        isSealed = true
        return resolveIfReady()
    }

    var shouldStartTimeout: Bool {
        isActive && isSealed && requestedFinish != nil && pendingWriteCount > 0
    }

    /// Invalidating instead of cancelling preserves an idempotent write that may already have committed.
    mutating func timeOut(generation candidate: UInt64) -> Bool {
        guard isActive, isSealed, candidate == generation, requestedFinish != nil else { return false }
        invalidate()
        return true
    }

    private mutating func resolveIfReady() -> Resolution? {
        guard isActive, isSealed,
              let drainCompleted = requestedFinish,
              pendingWriteCount == 0 else { return nil }
        let resolution = Resolution(
            drainCompleted: drainCompleted,
            allWritesSucceeded: !sawWriteFailure
        )
        isActive = false
        requestedFinish = nil
        return resolution
    }
}

/// Associates the records currently buffered by `OuraHypnogramAssembler` with the history drain that
/// actually delivered them. The wrapper is deliberately optional inside an optional: a pending live
/// burst has a nil history generation, while a nil `pendingReceipt` means there is no buffered burst.
/// This prevents an old partial burst from inheriting a newer drain generation when it closes later.
struct OuraHypnogramReceiptTracker: Equatable {
    struct Receipt: Equatable {
        let historyGeneration: UInt64?
    }

    private(set) var pendingReceipt: Receipt?

    /// Starts tracking `generation`, or rotates to it and returns the receipt that must be flushed first.
    mutating func rotate(to generation: UInt64?) -> Receipt? {
        let incoming = Receipt(historyGeneration: generation)
        guard let pendingReceipt else {
            self.pendingReceipt = incoming
            return nil
        }
        guard pendingReceipt != incoming else { return nil }
        self.pendingReceipt = incoming
        return pendingReceipt
    }

    /// Takes the receipt for an explicit assembler flush and clears the pending association.
    mutating func takeForFlush() -> Receipt? {
        defer { pendingReceipt = nil }
        return pendingReceipt
    }

    mutating func reset() {
        pendingReceipt = nil
    }
}

/// Serializes Oura's write-without-response commands. CoreBluetooth exposes flow-control readiness but
/// no per-write acknowledgement for this characteristic, so the transport admits one command, observes
/// a short pacing interval, then admits the next. Teardown replaces queued background work with the
/// disable/unsubscribe pair while preserving a command already submitted to the controller.
struct OuraCommandWriteQueue: Equatable {
    private(set) var pending: [OuraCommand] = []
    private(set) var active: OuraCommand?

    mutating func enqueue(_ commands: [OuraCommand]) {
        pending.append(contentsOf: commands)
    }

    mutating func beginNext() -> OuraCommand? {
        guard active == nil, !pending.isEmpty else { return nil }
        let command = pending.removeFirst()
        active = command
        return command
    }

    @discardableResult
    mutating func completeActive() -> OuraCommand? {
        defer { active = nil }
        return active
    }

    /// Keep the already-submitted command, but discard work that should not outrank shutdown.
    mutating func replacePendingForTeardown(with commands: [OuraCommand]) {
        pending = commands
    }

    mutating func reset() {
        pending.removeAll(keepingCapacity: true)
        active = nil
    }

    var isDrained: Bool { active == nil && pending.isEmpty }
}

/// History records may be persisted and scored, but must never mutate the "now" HR/R-R/wear surface.
enum OuraLivePublication {
    static func permits(historyEnvelope: Bool) -> Bool { !historyEnvelope }

    static func requiresLiveHRShutdown(
        reachedStreaming: Bool,
        driverPhase: OuraDriverPhase?
    ) -> Bool {
        reachedStreaming || driverPhase == .enablingLiveHR
    }

    /// State TLVs can be unsolicited while streaming. Only a timestamp near "now" may update the wear
    /// surface; an older history re-serve remains persistence-only.
    static func permitsCurrentState(
        historyEnvelope: Bool,
        eventUnixSeconds: Int?,
        now: Int,
        toleranceSeconds: Int = 120
    ) -> Bool {
        guard historyEnvelope else { return true }
        guard let eventUnixSeconds else { return false }
        return abs(eventUnixSeconds - now) <= toleranceSeconds
    }
}

/// An unresolved history timestamp is omitted so the durable cursor can retry it. A genuinely live push
/// may retain the wall-clock arrival captured when it was received.
enum OuraPendingAnchorPolicy {
    static func fallbackTimestamp(historyEnvelope: Bool, liveArrivalTimestamp: Int?) -> Int? {
        historyEnvelope ? nil : liveArrivalTimestamp
    }
}

/// EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen 3/4/5), driven by the clean-room
/// `OuraProtocol.OuraDriver`.
///
/// This is a real transport (it replaced an earlier honest dead-end probe): it decodes the ring's OWN
/// raw signals + open event tags (HR / IBI / HRV / SpO2 / temp / sleep-phase / battery), persists them
/// under the ring's `deviceId`, and lets NOOP compute its own Charge/Rest from those streams exactly like
/// a WHOOP day. It NEVER reads or surfaces Oura's encrypted readiness/sleep scores (honest-data
/// invariant), and when a signal can't be read it stays at "-", never a fabricated value (Huami precedent).
///
/// WHOOP-FIRST ISOLATION (identical to `StandardHRSource` / `HuamiHRSource`): this class runs its OWN
/// `CBCentralManager` and never imports, calls, or shares state with `BLEManager` / `WhoopBleClient`. The
/// WHOOP path cannot regress. The only shared surfaces are `LiveState` and the injected closures
/// (`persist`, `log`, `onBattery`). All BLE specifics live here; all protocol specifics live in the pure,
/// headless-testable `OuraDriver` (no CoreBluetooth in that package).
///
/// Honest about the handshake, step by step:
///   1. Scan for the Oura GATT service and filter discoveries by `OuraRingGen.recognise`.
///   2. Connect, discover the write/notify characteristics, enable notifications on ...0003.
///   3. Run the application auth challenge through `OuraDriver` (GetAuthNonce -> compute proof ->
///      Authenticate). The 16-byte install key is injected via `authKey`; when it is nil (or auth fails
///      because the ring is in factory reset / wrong key) we surface an HONEST `needsPairing` message and
///      stream NO data rather than faking one.
///   3a. ADOPT (factory-reset ring + explicit consent only): when the ring is in factory reset (auth status
///      `inFactoryReset` / no key) AND `adoptIntent == true`, the transport PROVISIONS a fresh 16-byte key:
///      it writes the dangerous `0x24` install, awaits the `0x25` OK ack, persists the key to `OuraKeyStore`,
///      then re-runs auth with the new key (s3.2). Without `adoptIntent` the dangerous opcode is NEVER sent;
///      we announce needs-pairing instead. A failed install is honest (Failed), never a fake success.
///   4. On auth success, run the gen-appropriate live-HR enable triplet; HR/IBI then streams as 0x2F
///      sub-op 0x28 pushes which the driver decodes.
///   5. Once streaming, also run a `GetEvents` HISTORY FETCH (s5) from the last-persisted cursor, and
///      periodically thereafter. Skin temp and SpO2 are SLEEP-ONLY on this hardware (neither ever arrives
///      as a live push, only as banked history), so the fetch is the only way last night's readings ever
///      reach the app. Fetched records are stamped with their real ring-time-anchored UTC (s5.5, from the
///      ring's own 0x42 time-sync event), NOT the wall-clock arrival time, so "last night" data is never
///      mis-timestamped as "now".
///   6. Decoded events map onto `Streams` via `OuraStreamMapping` and persist in batches; live HR also
///      feeds `LiveState`. Temp/SpO2/HRV/sleep-phase persist ONLY (no live surface - they are last-night
///      values, not a live readout). Battery is requested once streaming starts (`GetBattery`, 0x0C ->
///      0x0D) and feeds `onBattery`/`batteryPct`.
@MainActor
public final class OuraLiveSource: NSObject, ObservableObject {

    // MARK: - Public model

    /// An Oura ring seen during a scan.
    public struct DiscoveredRing: Identifiable, Equatable {
        public let id: UUID
        public let name: String
        public let rssi: Int
        /// Best-effort generation guess from the advertised name (confirmed by the model the user picks).
        public let detectedGen: OuraRingGen?
    }

    /// The coarse adopt outcome the wizard observes while it is in its "Taking over your ring" state, so it
    /// can drive Adopting -> success (on `.streaming`/connected) and Adopting -> an honest Failed (on
    /// `.failed`). It is ONLY meaningful for an adopt-intent connection; a read-only connect stays `.idle`
    /// until it streams (or surfaces `needsPairing`). PARITY: the Android twin exposes the same coarse
    /// adopt outcome the Compose wizard observes to leave its Adopting step.
    public enum AdoptPhase: Equatable, Sendable {
        case idle            // no adopt in flight (the default; a read-only connect never leaves this until streaming)
        case installingKey   // the dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running)
        case streaming       // auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete
        case failed          // an honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success
    }

    @Published public private(set) var discovered: [DiscoveredRing] = []
    @Published public private(set) var scanning: Bool = false
    @Published public private(set) var batteryPct: Int? = nil
    /// Set to an HONEST explanation string when the ring needs a pairing/key handshake NOOP can't complete
    /// (no install key, or the ring is in factory reset, or the key was rejected). nil otherwise. The UI
    /// surfaces this instead of a fake reading. Cleared on stop/disconnect.
    @Published public private(set) var needsPairing: String? = nil
    /// The live adopt outcome (see `AdoptPhase`). The wizard observes this to leave its Adopting step. Reset
    /// to `.idle` on every connect/stop/disconnect so a stale outcome never drives a transition.
    @Published public private(set) var adoptPhase: AdoptPhase = .idle

    // MARK: - BLE UUIDs (from the platform-pure OuraGatt facts)

    /// The Oura base service (gen3/4/5). `OuraGatt` keeps the raw strings so the package stays
    /// CoreBluetooth-free; the app turns them into `CBUUID` here.
    private static let service = CBUUID(string: OuraGatt.serviceUUID)
    private static let writeChar = CBUUID(string: OuraGatt.writeCharacteristicUUID)
    private static let notifyChar = CBUUID(string: OuraGatt.notifyCharacteristicUUID)

    /// The `0x25` SetAuthKey-response outer opcode (`25 01 <status>`, status `0x00` = OK). Per
    /// OURA_PROTOCOL.md s3.2. This is the install-ack the adopt key-install awaits.
    private static let setAuthKeyRespOp: UInt8 = 0x25

    /// GetProductInfo replies have been observed under both the request opcode and the conventional
    /// request+1 response opcode. Both are below the event-tag range, so they are transport responses.
    private static let productInfoResponseOps: Set<UInt8> = [0x18, 0x19]

    /// Local-time formatter for logging a decoded date/time next to a raw ring-tick cursor value, so a
    /// number like "1178203" reads as an actual date instead of an opaque tick count. Logging only.
    private static let cursorDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Decode a ring-tick cursor value to a human-readable local date/time via the driver's current
    /// session anchor (s5.5), or "no anchor yet" when none has arrived yet this session (honest: never
    /// guesses a time). Investigation/logging only.
    private func describeCursor(_ cursor: UInt32) -> String {
        guard let driver, let seconds = driver.unixSeconds(forRingTimestamp: cursor) else {
            return "no anchor yet"
        }
        return Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }

    // MARK: - Dependencies (injected - no BLEManager / WhoopBleClient reference)

    private let live: LiveState
    private let deviceId: String
    /// Starts an asynchronous store write and returns an acknowledgement task. History cursors never move
    /// until that task succeeds; live writes still run immediately and ignore the result as before.
    private let persist: (Streams) -> Task<Bool, Never>
    /// Upserts the ring-provided, reconstructed hypnogram as a stage-rich sleep session under the ring's
    /// own device id, so the normal imported-vs-computed sleep arbitration can consume it.
    private let persistSleepSession: (CachedSleepSession) -> Task<Bool, Never>
    private let log: (String) -> Void
    private let onBattery: (Int) -> Void
    /// Corrects a registry row when GetProductInfo reports a different hardware generation than the
    /// best-effort advertised-name/model guess used to start this session.
    private let onModel: (String) -> Void
    /// The ring generation (carried on `PairedDevice.model`, recovered via `OuraRingGen.from(model:)`).
    /// Selects the MTU clamp, which characteristics to discover, and the live-HR command set.
    private let ringGen: OuraRingGen
    /// Supplies the 16-byte application install key (from the Keychain) for this ring, or nil. A nil key
    /// drives the honest `needsPairing` path: the driver answers `.needsKeyInstall` and we never fake data.
    private let authKey: () -> Data?
    /// When false (the wizard's discovery-only scanner) this source never writes `LiveState` or persists.
    private let feedsLive: Bool
    /// A delayed callback from a replaced source must not clear or repopulate the shared live surface.
    private let isLiveOwner: () -> Bool
    private var mayPublishLive: Bool { feedsLive && isLiveOwner() }
    /// EXPLICIT, USER-GRANTED adopt consent for THIS connection. Default FALSE. The dangerous installKey
    /// opcode (`0x24`) may be sent ONLY when this is true: it is what gates the post-factory-reset key
    /// provisioning (s3.2). It is set true by the adopt flow AFTER the wizard's irreversible-consent gate
    /// (the consent tick AND the "Take over this ring?" confirm), and it gates the driver's `allowKeyInstall`
    /// so a read-only / Advanced-key connection can NEVER install a key. Set once at construction (the
    /// coordinator builds a fresh source per connection, so a new value just means a new source).
    private let adoptIntent: Bool

    // MARK: - Protocol state machine (pure - holds NO BLE handle)

    /// The transport-agnostic driver. Re-created on each connect so a fresh session re-runs auth (the
    /// app key is session-scoped). nil until a connection begins.
    private var driver: OuraDriver?
    /// Reassembles notification fragments into complete TLV inner records across feeds.
    private let reassembler = OuraReassembler()
    /// Oura writes a whole night's SleepNet phases in a compact post-wake burst whose envelope timestamps
    /// are write times. Accumulate the records and reconstruct one 30-second time axis before persistence.
    private let hypnogramAssembler = OuraHypnogramAssembler()
    /// Keeps a partial phase burst attached to its originating history generation. A later drain may close
    /// that burst, but can never claim its writes toward the newer cursor.
    private var hypnogramReceiptTracker = OuraHypnogramReceiptTracker()
    /// Bursts closed before the ring-time anchor arrives. These are retried when time sync lands and never
    /// stamped with a guessed wall clock because the anchor defines the entire night.
    private struct PendingUnanchoredBurst {
        let burst: OuraHypnogramBurst
        let historyGeneration: UInt64?
    }
    private var pendingUnanchoredBursts: [PendingUnanchoredBurst] = []

    /// Live wear/charge indicator: a LIVE-HR push (.hr) means the ring is on a finger; the ring's own "chg.
    /// detected"/"stopped" STATE strings bracket a charging period. Fed ONLY from the live push and STATE
    /// (never a banked .ibi, which can be a past-night re-serve) and only while `feedsLive`. Mirrored to
    /// `live.ouraWearState` for the On-wrist / Off-wrist UI.
    private let wearTracker = OuraWearTracker()
    private var loggedWearState: OuraWearState?
    /// When the last LIVE-HR beat arrived. If the stream goes quiet for `wornPulseTimeout` while we are
    /// still re-engaging it, the ring came off the finger (there is no "removed" event) -> NOT WORN.
    private var lastLivePulseAt: Date?
    /// Grace before a silent live-HR stream means "removed": the ring auto-reverts DHR ~20 s and we
    /// re-engage every `reengageInterval` (15 s), so a worn ring resumes beats well within this; exceeding
    /// it means no finger. Checked on the re-engage tick, so worst-case detection is this + one interval.
    private let wornPulseTimeout: TimeInterval = 40

    /// Logs the FIRST live HR sample of a connection only (never every push); reset on stop/disconnect.
    private var loggedFirstHR = false
    /// The ring's optical HR needs a beat or two to settle after (re)subscribe, so the very first live-HR
    /// sample of a session is often an artifact (observed on-device). Drop exactly one, then stream
    /// normally. Reset on stop/disconnect alongside `loggedFirstHR`.
    private var droppedFirstLiveHR = false
    /// Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
    /// stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
    /// only want one log line, not one per sample. Twin of `loggedFirstHR`.
    private var loggedFirstTemp = false
    /// Logs the FIRST SpO2 sample decoded this session only. Twin of `loggedFirstTemp`.
    private var loggedFirstSpo2 = false
    /// Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect.
    private var loggedAnchor = false
    /// Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
    /// logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
    /// ONLY (see the `allowTierB: true` comment at driver construction) - the log is how we collect raw
    /// captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect.
    private var loggedTierBKinds: Set<String> = []
    /// Feature ids whose status we have already logged this session (SpO2 0x04 / real_steps 0x0b), so the
    /// read-only feature-status diagnostic prints once per feature, not on every reconnect.
    private var loggedFeatureStatuses: Set<Int> = []
    /// Product-info bodies already handled this session. Serial and hardware pages can share one opcode,
    /// so dedupe by decoded content rather than opcode.
    private var handledProductInfo: Set<String> = []

    // MARK: - Activity (0x50 MET) estimate accumulation — INVESTIGATION ONLY
    // Aggregate the decoded 0x50 MET stream into an honest, clearly-labeled per-day estimate
    // (OuraActivityEstimator) logged at drain-end, for eyeballing against WHOOP active minutes / Apple
    // exercise minutes. Tier-B: never persisted, never scored, never a step count. Reset per connection.
    /// MET samples bucketed by LOCAL calendar day (key `yyyy-MM-dd`, so a bucket matches the WHOOP / Apple
    /// daily figure being compared), accumulated across the history drain.
    private var activityMETByDay: [String: [Double]] = [:]
    /// Cadence self-check state: the previous 0x50 record's UTC and sample count, plus the per-sample
    /// seconds observed between consecutive records — `(curr.utc - prev.utc) / prev.sampleCount`. The
    /// median pins the ring's MET epoch directly from the stream, validating `activityEpochSeconds`.
    private var lastActivityUtc: Int?
    private var lastActivitySampleCount = 0
    private var activityCadenceObs: [Double] = []
    /// Assumed per-sample epoch for the estimate log (the ONE calibration knob; the cadence self-check
    /// above measures the real value). 60 s = Oura's common 1-minute MET resolution.
    private let activityEpochSeconds: Double = 60
    /// Append-only JSONL research corpus for the raw 0x50 MET series (Tier-B, never scored/persisted to
    /// SQLite). Created only on a live/persisting source (nil for the discovery-only scanner). Deduped by
    /// ring-time so re-served records don't duplicate; logs its file path once when the first record lands.
    private let activityDump: OuraActivityDump?
    /// Cached local-day formatter (the 0x50 stream is high-volume; avoid building one per record).
    private static let activityDayFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f   // local time zone by default
    }()

    /// Recent Tier-B 0x49 window candidates (minutes before the finalization event). The nearest window
    /// refines a phase burst from analysis-write time to the ring's tracked onset/end. Bounded per session.
    private var recentSleepWindows049: [(ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)] = []
    private static let recentSleepWindows049Cap = 16

    /// History-fetched events decoded BEFORE a ring-time -> UTC anchor exists this session, held here
    /// (with their own ring timestamp) until the anchor lands (`drainPendingAnchorEvents`), so they get
    /// their real historical time instead of a premature wall-clock guess. The ring's 0x42 time-sync can
    /// arrive anywhere in a history-fetch stream, not necessarily first, so records that land before it
    /// are parked here and re-stamped the moment an anchor lands. Unresolved history is omitted at teardown
    /// so the unchanged cursor retries it; only a live push may retain its captured arrival time.
    private struct PendingAnchorEvent {
        let event: OuraEvent
        let ringTimestamp: UInt32
        /// The history-drain generation that delivered this record. nil means a live push. Retaining the
        /// original generation prevents a late time anchor from crediting an old record to a new drain.
        let historyGeneration: UInt64?
        let historyEnvelope: Bool
        let liveArrivalTimestamp: Int?
    }
    private var pendingAnchorEvents: [PendingAnchorEvent] = []
    /// True once the live-HR stream has been requested, so the disconnect handler can tell "we never got
    /// authenticated/streaming" (-> honest note) from "the link just dropped".
    private var reachedStreaming = false
    /// The freshly-generated 16-byte key written to the ring during an adopt key install. Held in memory
    /// ONLY between writing the `0x24` install and receiving the `0x25` ack: it is persisted to the keystore
    /// ONLY on an OK ack (so a failed/absent ack never leaves a key the next session would wrongly trust).
    /// Cleared on stop/disconnect/failure.
    private var pendingInstallKey: Data?

    // MARK: - CoreBluetooth state (OWN central, separate from WHOOP)

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    /// Oura's command characteristic is write-without-response only. Serialize and pace commands rather
    /// than relying on CoreBluetooth/controller queue depth, which can drop a startup burst under load.
    private var commandWrites = OuraCommandWriteQueue()
    private var commandPaceWorkItem: DispatchWorkItem?
    private let commandPaceInterval: TimeInterval = 0.012
    /// An explicit stop waits for the live-HR disable/unsubscribe pair to drain before cancelling the link.
    private var teardownPending = false
    private var teardownDeadlineWorkItem: DispatchWorkItem?
    private let teardownDeadline: TimeInterval = 1
    /// A peripheral asked to connect before `centralManagerDidUpdateState` reported `.poweredOn`.
    private var pendingConnectID: UUID?
    /// Peripherals retained by identifier so a chosen one survives until connection (exact
    /// StandardHRSource seenPeripherals/pendingConnectID/retrievePeripherals pattern).
    private var seenPeripherals: [UUID: CBPeripheral] = [:]

    // MARK: - Auto-reconnect (#912)

    /// The paired ring we should keep re-reaching. Set by `connect(_:)`, cleared by `stop()`. While it is
    /// non-nil an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped backoff, so the
    /// ring comes back on its own once it's in range again, exactly like the WHOOP strap's auto-reconnect
    /// (BLEManager). WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
    /// down until a manual reconnect. This never touches the WHOOP path or the shared central queue.
    private var reconnectID: UUID?
    /// True while a teardown was USER/COORDINATOR-initiated (`stop()`), so the disconnect handler suppresses
    /// the auto-reconnect (mirrors BLEManager's `intentionalDisconnect`). Cleared on every `connect(_:)`.
    private var intentionalDisconnect = false
    /// Consecutive involuntary reconnect attempts, driving the capped-exponential backoff (3, 6, 12, 24,
    /// 48, 60s). Reset to 0 on a successful connect and on an explicit `connect(_:)`. Matches BLEManager
    /// (#414) and the Android `ReconnectBackoff` so a ring genuinely out of range doesn't hammer BLE.
    private var failedReconnectAttempts = 0

    /// Next backoff delay, capped at 60s, matching BLEManager's `min(60, 3 * 2^(n-1))` and the Android twin.
    private func nextReconnectDelay() -> TimeInterval {
        min(60.0, 3.0 * pow(2.0, Double(max(0, failedReconnectAttempts - 1))))
    }

    /// Schedule an auto-reconnect to the paired ring after a backoff delay, unless the teardown was
    /// intentional or there is no known ring. Guarded again inside the deferred block: a `stop()` that
    /// lands in the meantime cancels the pending reconnect (it re-checks `intentionalDisconnect` and that
    /// the target is unchanged), so a deliberate teardown never races a stale reconnect.
    private func scheduleReconnect() {
        guard !intentionalDisconnect, let id = reconnectID else { return }
        failedReconnectAttempts += 1
        let delay = nextReconnectDelay()
        log("Oura: reconnecting in \(Int(delay))s (attempt \(failedReconnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.intentionalDisconnect, self.reconnectID == id else { return }
            self.connect(id)
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history.

    /// The GetEvents resume cursor — a CLIENT-managed event-envelope ring-time (open_oura
    /// `nextEventToSync`), loaded from `OuraHistoryCursorStore` on connect and COMMITTED only when a
    /// drain completes (from `maxStoredRingTime`). 0 = fetch everything the ring has banked.
    ///
    /// #91: the `0x11` response carries NO cursor — only `bytes_left` (a remaining-byte count). NOOP
    /// previously persisted that byte-count as a "cursor" and compared it across sessions as a clock,
    /// minting a phantom "ring-time regression" → reset-to-0 → full re-dump on every connect.
    private var historyCursor: UInt32 = 0
    /// The pure, unit-tested drain + resume-cursor decision core (#291): the stall/deadline guards, the
    /// stored-ring-time high-water mark, the reboot flag, the cursor-commit and loaded-cursor-sanitize
    /// decisions, and the plausibility ceiling. OuraLiveSource keeps only the I/O — anchor resolution,
    /// persistence, logging, and the `historyCursorAdvanced` emit — and delegates every decision here so
    /// they can't silently regress in a refactor again (they did once: #91 → #291). See OuraHistoryDrainTests.
    private var drain = OuraHistoryDrain()
    /// The cursor we resumed FROM at the start of the current fetch — passed into `drain.noteStoredRingTime`
    /// so a real stored sample OLDER than it flags a genuine ring reboot (clock reset / seek ignored).
    private var resumeCursorAtFetchStart: UInt32 = 0
    /// Wall-clock start of the current drain; `drain`'s deadline guard force-stops one running too long.
    private var drainStartedAt: Date?
    /// Cursor used by the most recent GetEvents request. Continuations must move strictly beyond it.
    private var lastRequestCursor: UInt32 = 0
    private enum PendingDrainAction {
        case continueBatch
        case finish(completed: Bool)
    }
    /// A 0x11 summary is an early summary, not an end-of-notification delimiter. Finalize or continue only
    /// after 1.5 seconds without another history record so tail events cannot be skipped by a cursor commit.
    private var pendingDrainAction: PendingDrainAction?
    private var batchQuietTimer: Timer?
    private let batchQuietInterval: TimeInterval = 1.5
    /// Async persistence barrier for the current history drain. A generation token prevents a late callback
    /// from a disconnected session mutating a later fetch. Any failed write keeps the durable cursor behind.
    private var historyPersistence = OuraHistoryPersistenceGate()
    /// Attached to TLVs until the next GetEvents request boundary. It intentionally outlives the driver's
    /// `.fetchingHistory` phase because a terminal summary is not a packet boundary.
    private var historyTransportGeneration: UInt64?
    /// A periodic fetch waits here while the prior generation seals and its store writes finish.
    private var historyRefetchPending = false
    private var historyPersistenceTimer: Timer?
    private let historyPersistenceTimeout: TimeInterval = 45
    /// Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
    /// picks up freshly-banked sleep data without needing a reconnect. Mirrors BLEManager's ~15 min
    /// periodic WHOOP history-offload floor.
    private var historyFetchTimer: Timer?
    private let historyFetchInterval: TimeInterval = 900

    /// Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
    /// overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
    /// both right after reaching `.streaming` and from the periodic timer).
    private func fetchHistoryIfIdle() {
        guard let driver, driver.phase == .streaming else { return }
        if let generation = historyTransportGeneration {
            // Seal only when the next real request is ready to begin. Until this boundary, delayed TLVs from
            // the prior request keep their original generation and can still join its persistence barrier.
            historyRefetchPending = true
            sealHistoryGenerationForRefetch(generation)
            return
        }
        startHistoryFetch()
    }

    private func startHistoryFetch() {
        guard let driver, driver.phase == .streaming else { return }
        // Arm the per-drain state: where we sought from (reboot detection), the stored-sample high-water
        // mark the cursor will commit from, and the stall/deadline guards.
        resumeCursorAtFetchStart = historyCursor
        drainStartedAt = Date()
        drain.reset()
        lastRequestCursor = historyCursor
        pendingDrainAction = nil
        stopBatchQuietTimer()
        historyTransportGeneration = beginHistoryPersistenceBarrier()
        log("Oura: fetching history from cursor \(historyCursor) (\(describeCursor(historyCursor))) [cursor-fix]")
        advance(.startHistoryFetch(cursor: historyCursor))
    }

    private func startHistoryFetchTimer() {
        stopHistoryFetchTimer()
        let t = Timer.scheduledTimer(withTimeInterval: historyFetchInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fetchHistoryIfIdle() }
        }
        historyFetchTimer = t
    }

    private func stopHistoryFetchTimer() {
        historyFetchTimer?.invalidate()
        historyFetchTimer = nil
    }

    /// Handle a `0x11` GetEvents summary (open_oura `EventBatchSummary`): the drain continues while
    /// `bytes_left > 0` and is complete at `bytes_left == 0`. The response's byte-count is NEVER persisted
    /// — persisting it and comparing byte-counts across sessions as clocks was the #91 re-dump loop.
    ///
    /// The durable resume point (open_oura `nextEventToSync`) is the newest STORED history sample's
    /// ring-time (`maxStoredRingTime`), committed here when the drain completes. A genuine ring reboot is
    /// caught by `sawPreResumeData` — a stored sample OLDER than where we sought means the ring's clock
    /// reset (or it ignored the seek), so next connect does a full pull rather than resume from a
    /// now-stale ring-time. Stall/deadline guards are backstops only; they force-stop the drain but keep
    /// whatever forward progress was banked (never reset to 0 — that re-arms the loop).
    private func handleHistorySummary(_ summary: (eventsReceived: UInt8, bytesLeft: UInt32, moreData: Bool)) {
        // Stall + deadline backstops (a healthy drain ends at bytes_left 0, where moreData is false).
        let elapsed = drainStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let continueDrain = drain.onSummary(bytesLeft: summary.bytesLeft, moreData: summary.moreData,
                                            elapsedSeconds: elapsed)
        if summary.moreData, !continueDrain {
            let reason = elapsed > OuraHistoryDrain.maxDrainSeconds
                ? "exceeded \(Int(OuraHistoryDrain.maxDrainSeconds))s deadline"
                : "bytes_left stalled"
            log("Oura: history drain force-stopped - \(reason) at bytes_left \(summary.bytesLeft) (guard)")
        }
        pendingDrainAction = continueDrain
            ? .continueBatch
            : .finish(completed: !summary.moreData)
        restartBatchQuietTimer()
    }

    private func finishHistoryDrain(completed: Bool) {
        pendingDrainAction = nil
        stopBatchQuietTimer()
        flushPendingHypnogramBurst()
        // The final batch is frequently smaller than the normal buffer threshold. Force it to disk, but keep
        // the generation open after returning the driver to streaming: the summary/quiet window is not a
        // packet boundary, so delayed TLVs must still join this barrier.
        flush()
        if let resolution = historyPersistence.requestFinish(drainCompleted: completed) {
            finalizeHistoryDrain(resolution, generation: historyPersistence.generation)
        }
        drainStartedAt = nil
        advance(.historyCursorAdvanced(cursor: historyCursor, moreData: false))
    }

    /// Start a new per-drain persistence generation. Store tasks from an older connection may still finish,
    /// but their generation can no longer mutate this drain or its durable cursor.
    private func beginHistoryPersistenceBarrier() -> UInt64 {
        stopHistoryPersistenceTimer()
        return historyPersistence.begin()
    }

    private func sealHistoryGenerationForRefetch(_ generation: UInt64) {
        guard generation == historyPersistence.generation else {
            historyTransportGeneration = nil
            historyRefetchPending = false
            startHistoryFetch()
            return
        }
        flushPendingHypnogramBurst()
        flush()
        if let resolution = historyPersistence.seal() {
            finalizeHistoryDrain(resolution, generation: generation)
        } else {
            startHistoryPersistenceTimerIfNeeded()
        }
    }

    /// Close the current barrier without treating cancellation as success. In-flight SQLite tasks are left
    /// alone (they may already have committed); their late acknowledgements are simply ignored.
    private func invalidateHistoryPersistenceBarrier() {
        stopHistoryPersistenceTimer()
        historyPersistence.invalidate()
        historyTransportGeneration = nil
        historyRefetchPending = false
    }

    private func registerHistoryWrite(
        _ task: Task<Bool, Never>,
        ringTimestamps: [UInt32],
        generation: UInt64
    ) {
        guard !ringTimestamps.isEmpty,
              historyPersistence.register(generation: generation) else { return }
        Task { @MainActor [weak self] in
            let succeeded = await task.value
            self?.historyWriteCompleted(
                succeeded: succeeded,
                ringTimestamps: ringTimestamps,
                generation: generation
            )
        }
        startHistoryPersistenceTimerIfNeeded()
    }

    private func historyWriteCompleted(
        succeeded: Bool,
        ringTimestamps: [UInt32],
        generation: UInt64
    ) {
        let result = historyPersistence.completeWrite(
            generation: generation,
            succeeded: succeeded
        )
        guard result.accepted else { return }
        if succeeded {
            for ringTimestamp in ringTimestamps {
                noteStoredHistoryRingTime(ringTimestamp)
            }
        }
        if let resolution = result.resolution {
            finalizeHistoryDrain(resolution, generation: generation)
        }
    }

    private func finalizeHistoryDrain(
        _ resolution: OuraHistoryPersistenceGate.Resolution,
        generation: UInt64
    ) {
        stopHistoryPersistenceTimer()
        if !resolution.allWritesSucceeded {
            // Do not advance even to a later successful row: history can arrive out of order, so doing so
            // could place the failed record permanently behind the next resume cursor.
            log("Oura: history persistence failed - keeping resume cursor \(historyCursor) for a safe retry")
        } else {
            commitResumeCursor(drainCompleted: resolution.drainCompleted)
        }
        logActivityEstimateSummary()
        if historyTransportGeneration == generation {
            historyTransportGeneration = nil
        }
        if historyRefetchPending {
            historyRefetchPending = false
            startHistoryFetch()
        }
    }

    private func startHistoryPersistenceTimerIfNeeded() {
        guard historyPersistence.shouldStartTimeout,
              historyPersistenceTimer == nil else { return }
        let generation = historyPersistence.generation
        let timer = Timer.scheduledTimer(withTimeInterval: historyPersistenceTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.historyPersistenceTimedOut(generation: generation) }
        }
        historyPersistenceTimer = timer
    }

    private func stopHistoryPersistenceTimer() {
        historyPersistenceTimer?.invalidate()
        historyPersistenceTimer = nil
    }

    private func historyPersistenceTimedOut(generation: UInt64) {
        let outstanding = historyPersistence.pendingWriteCount
        guard historyPersistence.timeOut(generation: generation) else { return }
        // Invalidate before returning the driver to streaming. A task that commits after this timeout is
        // safe/idempotent, but its late acknowledgement must never move the cursor.
        stopHistoryPersistenceTimer()
        log("Oura: history persistence timed out with \(outstanding) write(s) pending - keeping resume cursor \(historyCursor)")
        logActivityEstimateSummary()
        if historyTransportGeneration == generation {
            historyTransportGeneration = nil
        }
        if historyRefetchPending {
            historyRefetchPending = false
            startHistoryFetch()
        }
    }

    private func continueHistoryDrainAfterQuiet() {
        stopBatchQuietTimer()
        guard let action = pendingDrainAction else { return }
        pendingDrainAction = nil
        guard let driver, driver.phase == .fetchingHistory else { return }
        switch action {
        case .finish(let completed):
            finishHistoryDrain(completed: completed)
        case .continueBatch:
            guard let next = drain.continuationCursor(lastRequestCursor: lastRequestCursor) else {
                log("Oura: history batch made no cursor progress - stopping drain")
                finishHistoryDrain(completed: false)
                return
            }
            lastRequestCursor = next
            log("Oura: history batch quiet - continuing from the next record")
            advance(.historyCursorAdvanced(cursor: next, moreData: true))
        }
    }

    private func restartBatchQuietTimer() {
        stopBatchQuietTimer()
        let timer = Timer.scheduledTimer(withTimeInterval: batchQuietInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.continueHistoryDrainAfterQuiet() }
        }
        batchQuietTimer = timer
    }

    private func stopBatchQuietTimer() {
        batchQuietTimer?.invalidate()
        batchQuietTimer = nil
    }

    /// Commit the durable resume cursor at drain end. Only a cursor that (a) moved forward, (b) is below
    /// the plausibility ceiling, and (c) resolves to a real time under the CURRENT anchor is persisted;
    /// a reboot (`sawPreResumeData`) resets to 0 so next connect does an honest full pull.
    private func commitResumeCursor(drainCompleted: Bool) {
        let how = drainCompleted ? "caught up (bytes_left 0)" : "stopped early"
        let resolves = drain.maxStoredRingTime > 0
            && (driver?.unixSeconds(forRingTimestamp: drain.maxStoredRingTime) != nil)
        let newCursor = drain.resumeCursorAtDrainEnd(currentCursor: historyCursor, resolvesUnderAnchor: resolves)
        if drain.sawPreResumeData {
            log("Oura: history \(how) but the ring served data older than cursor \(resumeCursorAtFetchStart) - clock reset/seek ignored; next connect does a full pull")
            historyCursor = 0
            OuraHistoryCursorStore.save(0, deviceId: deviceId)
        } else if newCursor != historyCursor {
            historyCursor = newCursor
            OuraHistoryCursorStore.save(newCursor, deviceId: deviceId)
            log("Oura: history \(how) - resume cursor advanced to \(historyCursor) [\(describeCursor(historyCursor))]")
        } else if drain.maxStoredRingTime > historyCursor {
            log("Oura: history \(how) but resume candidate \(drain.maxStoredRingTime) does not resolve under the current anchor - keeping cursor \(historyCursor)")
        } else {
            log("Oura: history \(how) (resume cursor unchanged \(historyCursor) [\(describeCursor(historyCursor))])")
        }
    }

    /// Pick the 0x49 sleep window nearest a phase burst's final envelope time. A drain may contain an
    /// overnight and a nap, so "most recent" is not a safe pairing rule.
    nonisolated static func closestSleepWindow049(
        in windows: [(ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)],
        toRingTimestamp ringTimestamp: UInt32,
        within tolerance: UInt32
    ) -> (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)? {
        var closest: (ringTimestamp: UInt32, startOffMin: Int, endOffMin: Int)?
        var closestGap = UInt32.max
        for window in windows {
            let gap = window.ringTimestamp >= ringTimestamp
                ? window.ringTimestamp - ringTimestamp
                : ringTimestamp - window.ringTimestamp
            if gap <= tolerance, gap < closestGap {
                closestGap = gap
                closest = window
            }
        }
        return closest
    }

    /// Reconstruct and persist one phase burst. Every written code gets its own 30-second timestamp,
    /// preventing `event(deviceId, ts, kind)` collisions; erased 0xFF pages remain gaps. The same sequence
    /// is also upserted as a stage-rich session so the Sleep UI consumes the ring-provided hypnogram.
    private func persistHypnogramBurst(
        _ burst: OuraHypnogramBurst,
        historyGeneration: UInt64?
    ) {
        guard let driver, burst.totalCodes > 0 else { return }
        guard let writeEnd = driver.unixSeconds(forRingTimestamp: burst.lastRingTimestamp) else {
            pendingUnanchoredBursts.append(PendingUnanchoredBurst(
                burst: burst,
                historyGeneration: historyGeneration
            ))
            log("Oura: hypnogram burst held until the time anchor arrives")
            return
        }

        var end = writeEnd
        var sleepStart: Int?
        if let window = Self.closestSleepWindow049(
            in: recentSleepWindows049,
            toRingTimestamp: burst.lastRingTimestamp,
            within: 6_000
        ), let eventUtc = driver.unixSeconds(forRingTimestamp: window.ringTimestamp) {
            let candidateEnd = eventUtc - window.endOffMin * 60
            if candidateEnd <= writeEnd, writeEnd - candidateEnd < 6 * 3_600 {
                end = candidateEnd
            }
            let candidateStart = eventUtc - window.startOffMin * 60
            if candidateStart < end, end - candidateStart < 16 * 3_600 {
                sleepStart = candidateStart
            }
        }

        if burst.hasNonMonotonicRingTimes {
            log("Oura: hypnogram burst has non-monotonic envelope times; preserving event-log arrival order")
        }

        let laid = burst.codesWithTimes(
            endUnixSeconds: end,
            sleepStartUnixSeconds: sleepStart
        )
        guard !laid.isEmpty else {
            log("Oura: hypnogram burst entirely unwritten (0xFF); no awake stages or blank session persisted")
            return
        }

        let historyRingTimestamps = burst.records.map(\.ringTimestamp)
        let acknowledgedRingTimestamps = historyGeneration == nil ? [] : historyRingTimestamps
        enqueueBatches(
            laid.map { (events: [.sleepPhase($0.phase)], ts: $0.ts) },
            historyRingTimestamps: acknowledgedRingTimestamps,
            historyGeneration: historyGeneration
        )

        if let session = OuraSleepSessionMapping.session(
            fromCodes: laid.map { (ts: $0.ts, stage: $0.phase.stage) }
        ) {
            let task = persistSleepSession(session)
            if let historyGeneration {
                registerHistoryWrite(
                    task,
                    ringTimestamps: historyRingTimestamps,
                    generation: historyGeneration
                )
            }
        }
        let preservedGaps = laid.count < burst.totalCodes
        log(preservedGaps
            ? "Oura: hypnogram reconstructed with erased/pre-onset gaps preserved"
            : "Oura: hypnogram reconstructed")
    }

    /// Close the currently assembled phase burst with the receipt captured when its first record arrived.
    /// Clearing both sides together keeps assembler contents and generation ownership in lockstep.
    private func flushPendingHypnogramBurst() {
        let receipt = hypnogramReceiptTracker.takeForFlush()
        guard let burst = hypnogramAssembler.flush() else { return }
        persistHypnogramBurst(burst, historyGeneration: receipt?.historyGeneration)
    }

    /// Feed one phase record without ever allowing a partial burst to cross a history-generation boundary.
    private func ingestHypnogramRecord(
        ringTimestamp: UInt32,
        phases: [OuraSleepPhase],
        historyGeneration: UInt64?
    ) {
        if let priorReceipt = hypnogramReceiptTracker.rotate(to: historyGeneration),
           let priorBurst = hypnogramAssembler.flush() {
            persistHypnogramBurst(
                priorBurst,
                historyGeneration: priorReceipt.historyGeneration
            )
        }
        if let closed = hypnogramAssembler.feed(
            ringTimestamp: ringTimestamp,
            phases: phases
        ) {
            // A timestamp gap closes the preceding burst and starts a new one from this same record. Both
            // belong to the same already-captured receipt because generation changes were flushed above.
            persistHypnogramBurst(closed, historyGeneration: historyGeneration)
        }
    }

    private func drainPendingHypnogramBursts() {
        guard !pendingUnanchoredBursts.isEmpty else { return }
        let pending = pendingUnanchoredBursts
        pendingUnanchoredBursts.removeAll(keepingCapacity: true)
        for item in pending {
            persistHypnogramBurst(item.burst, historyGeneration: item.historyGeneration)
        }
    }

    /// Never fabricate a night's axis at teardown. Because no burst cursor was advanced, the ring can
    /// serve these records again after a future connection obtains a valid anchor.
    private func dropUnanchoredHypnogramBursts() {
        guard !pendingUnanchoredBursts.isEmpty else { return }
        log("Oura: dropping unanchored hypnogram burst; cursor was not advanced")
        pendingUnanchoredBursts.removeAll(keepingCapacity: true)
    }

    /// Record a STORED history sample's ring-time toward the resume cursor (open_oura `nextEventToSync`).
    /// Called only where a sample resolved a REAL anchored time and was enqueued — never for a no-anchor
    /// wall-clock fallback. Also flags a reboot: a real sample older than where we sought this fetch.
    private func noteStoredHistoryRingTime(_ rt: UInt32) {
        // A ring-time above the plausibility ceiling is corrupt; letting it set the resume cursor would
        // seek the next session into nonsense. Bounds the cursor at the source.
        drain.noteStoredRingTime(rt, resumeCursorAtFetchStart: resumeCursorAtFetchStart)
    }

    /// Log the per-day MET-derived activity estimate + the empirical cadence cross-check at drain-end.
    /// INVESTIGATION ONLY (OuraActivityEstimator; weight-free, so no kcal): a clearly-labeled Tier-B
    /// estimate for eyeballing against WHOOP active minutes / Apple exercise minutes. The cadence line
    /// reports the ring's real per-sample spacing so `activityEpochSeconds` can be pinned. Never
    /// persisted, never scored, never a step count.
    private func logActivityEstimateSummary() {
        guard !activityMETByDay.isEmpty else { return }
        if !activityCadenceObs.isEmpty {
            let sorted = activityCadenceObs.sorted()
            let median = sorted[sorted.count / 2]
            log(String(format: "Oura: activity cadence self-check - median %.1fs/sample over %d gaps (assumed %.0fs)",
                       median, activityCadenceObs.count, activityEpochSeconds))
        }
        for day in activityMETByDay.keys.sorted() {
            let est = OuraActivityEstimator.estimate(metSamples: activityMETByDay[day] ?? [],
                                                     epochSeconds: activityEpochSeconds)
            log(String(format: "Oura: activity estimate day=%@ samples=%d meanMET=%.2f maxMET=%.1f metMin=%.1f activeMin=%.1f [assumed %.0fs/sample, Tier-B est]",
                       day, est.sampleCount, est.meanMET, est.maxMET, est.metMinutes, est.activeMinutes, activityEpochSeconds))
        }
    }

    // MARK: - Sample buffer

    /// Buffered decoded events, flushed to `persist` in batches to keep the write path off the
    /// per-notification hot loop. Each entry carries its own `ts` (unix seconds): live-push events (HR,
    /// IBI, battery) are stamped at wall-clock arrival time; history-fetched events (temp, SpO2, HRV,
    /// sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
    /// so last night's data is never mis-recorded as happening right now.
    private struct HistoryWriteReceipt {
        let generation: UInt64
        /// One insert can contain several beats collapsed onto the same unix second. Preserve every
        /// represented ring-time so reboot detection and the durable high-water mark remain exact.
        let ringTimestamps: [UInt32]
    }

    private struct BufferedEntry {
        let events: [OuraEvent]
        let ts: Int
        let historyReceipt: HistoryWriteReceipt?
    }

    private var buffer: [BufferedEntry] = []
    private var lastFlush: Date = .init()
    private let flushCount = 30
    private let flushInterval: TimeInterval = 30

    // MARK: - Live-HR re-engagement

    /// Daytime-HR auto-reverts after ~20 s (OURA_PROTOCOL.md s5.7), so while a live session is open we
    /// re-send the enable+subscribe every ~15 s. nil when no session is streaming.
    private var reengageTimer: Timer?
    private let reengageInterval: TimeInterval = 15

    // MARK: - Init

    /// - Parameters:
    ///   - live: the shared `LiveState` the Live UI observes.
    ///   - deviceId: the datastore device id these samples are attributed to.
    ///   - ringGen: the ring generation (selects MTU clamp + command set).
    ///   - authKey: supplies the 16-byte install key from the Keychain, or nil to drive `needsPairing`.
    ///   - persist: wired by the app to `store.insert(_, deviceId:)`. Called on the main actor.
    ///   - persistSleepSession: wired to `store.upsertSleepSessions` for the ring-provided hypnogram night.
    ///   - log: connect-lifecycle diagnostics sink, wired at the composition root to the same strap log
    ///     `BLEManager` writes to (issue #421). Every line is prefixed "Oura: ". Defaults to a no-op.
    ///   - onBattery: fired with the ring's battery percent (0-100). Default no-op.
    ///   - onModel: fired when the ring's hardware page corrects the stored generation. Default no-op.
    ///   - feedsLive: when false (the discovery-only wizard scanner) this source never touches LiveState
    ///     or persists. Default true.
    ///   - isLiveOwner: false after the coordinator replaces this source, blocking delayed shared-state writes.
    ///   - adoptIntent: EXPLICIT user-granted adopt consent for this connection. Default FALSE. Only when
    ///     true may the dangerous `0x24` installKey opcode ever be sent (the post-factory-reset provisioning,
    ///     s3.2). The standard live path leaves it false (read-only / Advanced-key), so a key is NEVER
    ///     installed outside the wizard's irreversible-consent adopt flow.
    public init(live: LiveState,
                deviceId: String,
                ringGen: OuraRingGen,
                authKey: @escaping () -> Data?,
                persist: @escaping (Streams) -> Task<Bool, Never> = { _ in Task { true } },
                persistSleepSession: @escaping (CachedSleepSession) -> Task<Bool, Never> = { _ in Task { true } },
                log: @escaping (String) -> Void = { _ in },
                onBattery: @escaping (Int) -> Void = { _ in },
                onModel: @escaping (String) -> Void = { _ in },
                feedsLive: Bool = true,
                isLiveOwner: @escaping () -> Bool = { true },
                adoptIntent: Bool = false) {
        self.live = live
        self.deviceId = deviceId
        self.ringGen = ringGen
        self.authKey = authKey
        self.persist = persist
        self.persistSleepSession = persistSleepSession
        self.log = log
        self.onBattery = onBattery
        self.onModel = onModel
        self.feedsLive = feedsLive
        self.isLiveOwner = isLiveOwner
        self.adoptIntent = adoptIntent
        // Tier-B MET research corpus: only on a live/persisting source, never the discovery-only scanner.
        self.activityDump = feedsLive && !deviceId.isEmpty ? OuraActivityDump(deviceId: deviceId, log: log) : nil
        super.init()
        // Dedicated queue-less central -> callbacks arrive on the main queue, matching @MainActor.
        self.central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Scanning

    /// Scan for Oura rings advertising the Oura GATT service, keeping only ones the ring-gen recogniser
    /// accepts as an Oura ring.
    public func scan() {
        discovered.removeAll()
        seenPeripherals.removeAll()
        scanning = true
        needsPairing = nil
        log("Oura: scanning for an Oura ring (service \(OuraGatt.serviceUUID))")
        guard central.state == .poweredOn else {
            log("Oura: Bluetooth not powered on (state=\(central.state.rawValue)) - scan deferred until ready")
            return
        }
        central.scanForPeripherals(withServices: [Self.service],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        scanning = false
        if central.state == .poweredOn { central.stopScan() }
    }

    // MARK: - Connecting

    /// Connect to the chosen ring and start the auth -> enable -> stream flow. Mirrors the
    /// StandardHRSource cached-by-identifier-first, else scan-then-connect pattern.
    public func connect(_ id: UUID) {
        if teardownPending {
            // A new explicit connection supersedes the short graceful-stop window.
            finishTransportStop()
        }
        stopScan()
        needsPairing = nil
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectID = id
        intentionalDisconnect = false
        let p = seenPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first
        guard let p else {
            // Never seen by this Mac/iPhone yet -> remember it and scan; didDiscover connects on sight.
            pendingConnectID = id
            log("Oura: ring \(id) not cached yet - scanning to find it")
            scan()
            return
        }
        seenPeripherals[id] = p
        peripheral = p
        p.delegate = self
        guard central.state == .poweredOn else {
            pendingConnectID = id
            log("Oura: Bluetooth not powered on - connect to \(id) deferred until ready")
            return
        }
        log("Oura: connecting to \(id)")
        central.connect(p, options: nil)
    }

    /// Tear down: cancel the connection, stop scanning, flush, clear all transient state. Idempotent.
    public func stop() {
        guard !teardownPending else { return }
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        stopScan()
        pendingConnectID = nil
        stopReengageTimer()
        stopHistoryFetchTimer()
        stopBatchQuietTimer()
        pendingDrainAction = nil
        // Close the phase burst and drain parked samples BEFORE driver.stop() clears its anchor.
        flushPendingHypnogramBurst()
        drainPendingAnchorEvents(dropUnresolvedHistory: true)
        dropUnanchoredHypnogramBursts()
        // Dispatch best-effort writes while every history entry still carries its original generation,
        // then invalidate the barrier before clearing the drain. Late acknowledgements cannot move a cursor.
        flush()
        invalidateHistoryPersistenceBarrier()
        if mayPublishLive { live.connected = false; live.streamingLiveHR = false }

        // A streaming ring must receive both shutdown commands before the link is cancelled. There is no
        // per-write acknowledgement on this characteristic, so "complete" means CoreBluetooth accepted each
        // command under flow control and its pacing window elapsed. A one-second deadline prevents teardown
        // from hanging if the controller never becomes writable.
        if OuraLivePublication.requiresLiveHRShutdown(
            reachedStreaming: reachedStreaming,
            driverPhase: driver?.phase
        ),
           peripheral?.state == .connected,
           writeCharacteristic != nil {
            beginCompletionAwareTeardown()
            return
        }
        finishTransportStop()
    }

    private func beginCompletionAwareTeardown() {
        guard !teardownPending else { return }
        teardownPending = true
        commandWrites.replacePendingForTeardown(with: [
            OuraCommands.liveHRDisable(),
            OuraCommands.liveHRUnsubscribe(),
        ])
        let deadline = DispatchWorkItem { [self] in
            guard teardownPending else { return }
            log("Oura: graceful command teardown timed out - closing the link")
            finishTransportStop()
        }
        teardownDeadlineWorkItem = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + teardownDeadline, execute: deadline)
        pumpCommandWrites()
    }

    /// Final transport close shared by the normal graceful drain and its bounded timeout fallback.
    private func finishTransportStop() {
        teardownDeadlineWorkItem?.cancel()
        teardownDeadlineWorkItem = nil
        commandPaceWorkItem?.cancel()
        commandPaceWorkItem = nil
        commandWrites.reset()
        teardownPending = false
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        writeCharacteristic = nil
        driver?.stop()
        driver = nil
        reassembler.reset()
        wearTracker.reset(); loggedWearState = nil; lastLivePulseAt = nil
        loggedFirstHR = false
        droppedFirstLiveHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        loggedFeatureStatuses.removeAll()
        handledProductInfo.removeAll()
        recentSleepWindows049.removeAll()
        hypnogramAssembler.reset()
        hypnogramReceiptTracker.reset()
        activityMETByDay.removeAll()
        activityCadenceObs.removeAll()
        lastActivityUtc = nil
        lastActivitySampleCount = 0
        drain.reset()
        resumeCursorAtFetchStart = 0
        drainStartedAt = nil
        lastRequestCursor = 0
        reachedStreaming = false
        pendingInstallKey = nil
        adoptPhase = .idle
        batteryPct = nil
        needsPairing = nil
        if mayPublishLive { live.connected = false; live.streamingLiveHR = false }
    }

    // MARK: - Driver wiring

    /// Enqueue commands for single-delivery, flow-controlled write-without-response transport.
    private func write(_ commands: [OuraCommand]) {
        let mtuPayload = ringGen.maxWritePayload   // gen-appropriate clamp (gen3=200, gen4/5=244)
        var accepted: [OuraCommand] = []
        for cmd in commands {
            guard cmd.bytes.count <= mtuPayload else {
                log("Oura: skipping \(cmd.label) - \(cmd.bytes.count)B exceeds the \(mtuPayload)B write window")
                continue
            }
            accepted.append(cmd)
        }
        guard !accepted.isEmpty, !teardownPending else { return }
        commandWrites.enqueue(accepted)
        pumpCommandWrites()
    }

    private func pumpCommandWrites() {
        guard let peripheral, let writeCharacteristic,
              peripheral.state == .connected else {
            if teardownPending { finishTransportStop() }
            return
        }
        guard peripheral.canSendWriteWithoutResponse,
              let command = commandWrites.beginNext() else {
            if teardownPending, commandWrites.isDrained { finishTransportStop() }
            return
        }
        log("Oura: -> \(command.label)")
        peripheral.writeValue(Data(command.bytes), for: writeCharacteristic, type: .withoutResponse)

        let pace = DispatchWorkItem { [self] in
            commandPaceWorkItem = nil
            _ = commandWrites.completeActive()
            if teardownPending, commandWrites.isDrained {
                finishTransportStop()
            } else {
                pumpCommandWrites()
            }
        }
        commandPaceWorkItem = pace
        DispatchQueue.main.asyncAfter(deadline: .now() + commandPaceInterval, execute: pace)
    }

    /// Advance the driver with a transition and write whatever it asks for next.
    private func advance(_ transition: OuraTransition) {
        guard let driver else { return }
        let commands = driver.nextStep(after: transition)
        write(commands)
        // Surface the driver's coarse phase honestly into the UI state.
        switch driver.phase {
        case .needsKeyInstall:
            // A factory-reset ring (auth status inFactoryReset) or no key available. The dangerous key
            // install is the ONLY thing that recovers it, and ONLY with explicit adopt consent: provision
            // when `adoptIntent`, otherwise stay honest (never loop the dangerous command).
            if adoptIntent {
                provisionKeyInstall()
            } else {
                announceNeedsPairing(reason: .factoryResetOrNoKey)
            }
        case .authFailed(let status):
            announceNeedsPairing(reason: .authFailed(status))
        case .streaming:
            if !reachedStreaming {
                reachedStreaming = true
                adoptPhase = .streaming   // re-auth after an install (or a normal auth) reached the stream: adoption complete
                pendingInstallKey = nil   // an OK ack already persisted the key; nothing left in flight
                if mayPublishLive { live.streamingLiveHR = true }
                log("Oura: live-HR enabled - streaming HR / IBI")
                startReengageTimer()
                // Establish clock and hardware identity before asking for banked history. The 0x13 clock
                // reply can anchor a short drain that contains no 0x42 event, while the hardware page
                // corrects a generation guessed from an unreliable advertised name.
                write([
                    OuraCommands.syncTime(unixSeconds: Int(Date().timeIntervalSince1970)),
                    OuraCommands.getProductSerial(),
                    OuraCommands.getProductHardware(),
                ])
                startHistoryFetchTimer()
                fetchHistoryIfIdle()   // pull last night's banked temp/SpO2/HRV/sleep-phase right away
                write([OuraCommands.getBattery()])   // ask once HR streams; the 0x0D reply routes to onBattery
                // Read-only diagnostic: ask the ring its SpO2 / real-steps feature status once, so a capture
                // confirms (from the ring itself) that these server-flag features are subscription-gated OFF
                // for an offline ring. NEVER an enable/set-mode write - purely the 0x20 read verb.
                write([OuraCommands.spo2ReadStatus(), OuraCommands.realStepsReadStatus()])
            }
        default:
            break
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /// PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from `advance`
    /// when `driver.phase == .needsKeyInstall` AND `adoptIntent == true`. Steps: (1) generate a fresh
    /// cryptographically-random 16-byte key; (2) ask the driver for the dangerous `24 10 <key>` install
    /// command (the driver's own `allowKeyInstall`/phase gate is the second guard) and write it; (3) hold the
    /// key in memory and mark `.installingKey` (an install IS now running). The key is NOT persisted yet: it
    /// is written to the keystore only once the ring acks OK (`handleKeyInstallAck`), so a failed install
    /// never leaves a key the next session would wrongly trust. On any build/RNG failure we stay honest.
    private func provisionKeyInstall() {
        guard adoptIntent else { return }                 // belt-and-braces: never provision without consent
        guard pendingInstallKey == nil else { return }    // an install is already in flight; don't double-send
        guard let driver else { return }
        guard let key = Self.randomInstallKey() else {
            announceNeedsPairing(reason: .installFailed("could not generate a key"))
            return
        }
        guard let cmd = driver.beginKeyInstall(key: [UInt8](key)) else {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            announceNeedsPairing(reason: .installFailed("the install command could not be prepared"))
            return
        }
        pendingInstallKey = key
        adoptPhase = .installingKey
        log("Oura: installing NOOP's key on the reset ring")
        write([cmd])
    }

    /// Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
    /// On OK: persist the freshly-provisioned key under this `deviceId` (so every future session authenticates
    /// with it), then drive the driver's `keyInstallAcknowledged()` to re-run the auth handshake (GetAuthNonce
    /// then Authenticate) with the NEW key. On a non-OK status (or a missing pending key) announce an honest
    /// failure and do NOT retry the dangerous command.
    private func handleKeyInstallAck(status: UInt8) {
        guard let driver, let key = pendingInstallKey else { return }
        guard status == 0x00 else {
            announceNeedsPairing(reason: .installFailed("the ring did not accept the key (status \(status))"))
            return
        }
        // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
        guard OuraKeyStore.save(key, deviceId: deviceId) else {
            announceNeedsPairing(reason: .installFailed("the installed key could not be stored"))
            return
        }
        log("Oura: key installed and stored - re-running auth with the new key")
        pendingInstallKey = nil
        // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the nonce
        // response then flows through the normal handleSecure -> advance path to streaming.
        write(driver.keyInstallAcknowledged())
    }

    /// A fresh 16-byte application key for the adopt install, from the system CSPRNG. Per OURA_PROTOCOL.md
    /// s3 the key is exactly 16 bytes; `SecRandomCopyBytes` is the same CSPRNG the rest of the app relies on.
    /// Returns nil if the RNG fails (then the caller stays honest rather than installing a weak key).
    private static func randomInstallKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: OuraKeyStore.keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    // MARK: - Buffer / persistence

    private func enqueue(
        _ events: [OuraEvent],
        ts: Int,
        historyRingTimestamps: [UInt32] = [],
        historyGeneration: UInt64? = nil
    ) {
        enqueueBatches(
            [(events: events, ts: ts)],
            historyRingTimestamps: historyRingTimestamps,
            historyGeneration: historyGeneration
        )
    }

    /// Append a logically related set in one shot so the count threshold cannot flush a 960-stage night
    /// every 30 rows while it is still being assembled.
    private func enqueueBatches(
        _ batches: [(events: [OuraEvent], ts: Int)],
        historyRingTimestamps: [UInt32] = [],
        historyGeneration: UInt64? = nil
    ) {
        let batches = batches.filter { !$0.events.isEmpty }
        guard !batches.isEmpty else { return }
        let receipt: HistoryWriteReceipt?
        if historyRingTimestamps.isEmpty {
            receipt = nil
        } else {
            receipt = HistoryWriteReceipt(
                generation: historyGeneration ?? historyPersistence.generation,
                ringTimestamps: historyRingTimestamps
            )
        }
        buffer.append(contentsOf: batches.map {
            BufferedEntry(events: $0.events, ts: $0.ts, historyReceipt: receipt)
        })
        if buffer.count >= flushCount
            || Date().timeIntervalSince(lastFlush) >= flushInterval
            || (receipt != nil && historyPersistence.requestedFinish != nil) {
            flush()
        }
    }

    private func flush() {
        guard feedsLive, !buffer.isEmpty else { lastFlush = Date(); return }
        struct GroupKey: Hashable {
            let generation: UInt64?
            let isHistory: Bool
        }
        var order: [GroupKey] = []
        var grouped: [GroupKey: [BufferedEntry]] = [:]
        for entry in buffer {
            let key = GroupKey(
                generation: entry.historyReceipt?.generation,
                isHistory: entry.historyReceipt != nil
            )
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append(entry)
        }
        for key in order {
            let entries = grouped[key] ?? []
            // Pure, unit-tested mapping keyed by each entry's own timestamp. Combining entries changes only
            // transaction count, not row values or ordering.
            let streams = OuraStreamMapping.mergedStreams(
                from: entries.map { (events: $0.events, ts: $0.ts) }
            )
            guard !streams.isEmpty else { continue }
            let task = persist(streams)
            if key.isHistory, let generation = key.generation {
                let ringTimestamps = entries
                    .flatMap { $0.historyReceipt?.ringTimestamps ?? [] }
                    .reduce(into: [UInt32]()) { result, value in
                        if !result.contains(value) { result.append(value) }
                    }
                registerHistoryWrite(
                    task,
                    ringTimestamps: ringTimestamps,
                    generation: generation
                )
            }
        }
        buffer.removeAll()
        lastFlush = Date()
    }

    /// Persist entries whose ring time now resolves. At teardown only genuinely live pushes may use their
    /// captured arrival time; unresolved history is omitted and remains behind the durable cursor for retry.
    private func drainPendingAnchorEvents(dropUnresolvedHistory: Bool = false) {
        guard !pendingAnchorEvents.isEmpty, let driver else { return }

        struct GroupKey: Hashable {
            let ts: Int
            let historyGeneration: UInt64?
            let historyEnvelope: Bool
        }
        var order: [GroupKey] = []
        var grouped: [GroupKey: [(event: OuraEvent, ringTimestamp: UInt32?)]] = [:]
        var retained: [PendingAnchorEvent] = []
        var droppedHistoryCount = 0
        for pending in pendingAnchorEvents {
            let resolvedTs = driver.unixSeconds(forRingTimestamp: pending.ringTimestamp)
            let key: GroupKey
            let durableRingTimestamp: UInt32?
            if let ts = resolvedTs {
                key = GroupKey(
                    ts: ts,
                    historyGeneration: pending.historyGeneration,
                    historyEnvelope: pending.historyEnvelope
                )
                durableRingTimestamp = pending.historyGeneration == nil ? nil : pending.ringTimestamp
            } else if let fallback = OuraPendingAnchorPolicy.fallbackTimestamp(
                historyEnvelope: pending.historyEnvelope,
                liveArrivalTimestamp: pending.liveArrivalTimestamp
            ) {
                key = GroupKey(ts: fallback, historyGeneration: nil, historyEnvelope: false)
                durableRingTimestamp = nil
            } else if dropUnresolvedHistory {
                droppedHistoryCount += 1
                continue
            } else {
                retained.append(pending)
                continue
            }
            if grouped[key] == nil {
                order.append(key)
                grouped[key] = []
            }
            grouped[key]?.append((event: pending.event, ringTimestamp: durableRingTimestamp))
        }
        for key in order {
            let values = grouped[key] ?? []
            let queuedEvents = values.map(\.event)
            let persistenceEvents = key.historyEnvelope
                ? OuraIbiHr.appendingDerivedHR(toHistoryEvents: queuedEvents)
                : queuedEvents
            enqueue(
                persistenceEvents,
                ts: key.ts,
                historyRingTimestamps: values.compactMap(\.ringTimestamp),
                historyGeneration: key.historyGeneration
            )
        }
        pendingAnchorEvents = retained
        if droppedHistoryCount > 0 {
            log("Oura: omitted \(droppedHistoryCount) unanchored history sample(s); the cursor remains behind for retry")
        }
    }

    // MARK: - Live ingest

    /// Fold decoded events into live state (HR / R-R only - skin temp and SpO2 are SLEEP-ONLY on this
    /// hardware, never a live readout) + the persist buffer. Genuinely-live pushes (HR/battery) are stamped
    /// at wall-clock arrival time, since they really are "now". Ring-time-carrying events (IBI, temp, SpO2,
    /// HRV, sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) so last night's banked
    /// data is never mis-recorded as happening right now; when no anchor has arrived yet this session, we
    /// park the event until one does (`pendingAnchorEvents`), rather than immediately guessing wall-clock.
    /// IBI is special because it arrives both live and banked: `historyEnvelope` lets only an anchored,
    /// stored GetEvents beat advance the durable cursor; a secure live push never can. Out-of-range HR/temp
    /// is dropped, never shown.
    private func ingest(
        _ events: [OuraEvent],
        historyEnvelope: Bool = false,
        historyGeneration: UInt64? = nil
    ) {
        guard !events.isEmpty, let driver else { return }
        let now = Int(Date().timeIntervalSince1970)
        // A decoded 0x4B/0x4E/0x5A record arrives as one events array. Feed all of its phase codes to the
        // burst assembler as one unit; individual envelope timestamps are analysis-write times and must
        // never be used directly as stage timestamps.
        let phases = events.compactMap { event -> OuraSleepPhase? in
            if case .sleepPhase(let phase) = event { return phase }
            return nil
        }
        if let first = phases.first {
            ingestHypnogramRecord(
                ringTimestamp: first.ringTimestamp,
                phases: phases,
                historyGeneration: historyGeneration
            )
        }
        // A history record's beats and its IBI-derived HR must reach StreamStore in one anchored batch.
        // Live pushes retain their existing path: only historyEnvelope permits HR materialization here.
        let persistenceEvents = historyEnvelope
            ? OuraIbiHr.appendingDerivedHR(toHistoryEvents: events)
            : events
        let anchoredSignals: [(event: OuraEvent, ts: Int)] = persistenceEvents.compactMap { event in
            let ringTimestamp: UInt32
            switch event {
            case .ibi(let ibi):
                ringTimestamp = ibi.ringTimestamp
            case .hr(let hr) where historyEnvelope:
                ringTimestamp = hr.ringTimestamp
            default:
                return nil
            }
            guard let ts = driver.unixSeconds(forRingTimestamp: ringTimestamp) else { return nil }
            return (event: event, ts: ts)
        }
        for batch in OuraStreamMapping.batched(anchoredSignals) {
            let ringTimestamps: [UInt32] = historyGeneration != nil
                ? batch.events.compactMap { event in
                    if case .ibi(let ibi) = event { return ibi.ringTimestamp }
                    return nil
                }
                : []
            enqueue(
                batch.events,
                ts: batch.ts,
                historyRingTimestamps: ringTimestamps,
                historyGeneration: historyGeneration
            )
        }
        for e in events {
            switch e {
            case .hr(let hr):
                // A banked/derived history HR belongs in the dated store batch above, never in the live
                // readout or wear detector.
                guard OuraLivePublication.permits(historyEnvelope: historyEnvelope) else { continue }
                guard hr.bpm >= 30, hr.bpm <= 220 else { continue }   // physiological gate
                // Drop the first (settling) live-HR sample of the session — it is frequently an artifact.
                // The value is never shown or persisted; the NEXT sample becomes the first real reading.
                if !droppedFirstLiveHR {
                    droppedFirstLiveHR = true
                    log("Oura: dropping first live HR \(hr.bpm) bpm (settling sample)")
                    continue
                }
                if !loggedFirstHR {
                    loggedFirstHR = true
                    log("Oura: receiving live data - first HR \(hr.bpm) bpm")
                }
                if mayPublishLive {
                    live.setHeartRate(hr.bpm)
                    live.connected = true
                    // A LIVE HR push (0x2F) exists only while the ring is measuring on a finger, so it is
                    // the sole safe "worn now" signal. A banked IBI (.ibi below) can be a history re-serve
                    // from a past night, so it must NOT flip the badge to worn.
                    lastLivePulseAt = Date()
                    wearTracker.notePulse()
                    publishWearState()
                }
                enqueue([e], ts: now)

            case .ibi(let ibi):
                if mayPublishLive, OuraLivePublication.permits(historyEnvelope: historyEnvelope) {
                    live.setRRIntervals([ibi.ibiMs])
                }
                // A banked IBI is history data: anchor it to its REAL ring-time, exactly like the sibling
                // banked streams (.hrv/.temp/.spo2/.sleepPhase) below — never the drain-arrival `now`.
                // Stamping it at `now` (52b6e88d) misfiled every overnight beat to the daytime sync moment,
                // so the sleep window ended up with zero R-R -> no restingHr/avgHrv for the night.
                // Anchored beats were already enqueued above as one record-sized batch. Only unanchored
                // beats remain for this arm to park until the time anchor arrives.
                if driver.unixSeconds(forRingTimestamp: ibi.ringTimestamp) == nil {
                    pendingAnchorEvents.append(PendingAnchorEvent(
                        event: e,
                        ringTimestamp: ibi.ringTimestamp,
                        historyGeneration: historyGeneration,
                        historyEnvelope: historyEnvelope,
                        liveArrivalTimestamp: historyEnvelope ? nil : now
                    ))
                }

            case .battery(let bat):
                batteryPct = bat.percent
                if mayPublishLive { onBattery(bat.percent) }
                log("Oura: battery \(bat.percent)%")
                enqueue([e], ts: now)

            case .temp(let t):
                guard t.celsius >= 20, t.celsius <= 45 else { continue }   // physiological gate (wrist skin temp)
                if !loggedFirstTemp {
                    loggedFirstTemp = true
                    log("Oura: first skin temp decoded (last night) - \(String(format: "%.2f", t.celsius))C")
                }
                if let ts = driver.unixSeconds(forRingTimestamp: t.ringTimestamp) {
                    enqueue(
                        [e],
                        ts: ts,
                        historyRingTimestamps: historyGeneration == nil ? [] : [t.ringTimestamp],
                        historyGeneration: historyGeneration
                    )
                } else {
                    pendingAnchorEvents.append(PendingAnchorEvent(
                        event: e,
                        ringTimestamp: t.ringTimestamp,
                        historyGeneration: historyGeneration,
                        historyEnvelope: historyEnvelope,
                        liveArrivalTimestamp: historyEnvelope ? nil : now
                    ))
                }

            case .spo2(let s):
                if !loggedFirstSpo2 {
                    loggedFirstSpo2 = true
                    log("Oura: first SpO2 decoded (last night) - value \(s.value) (\(s.unit))")
                }
                if let ts = driver.unixSeconds(forRingTimestamp: s.ringTimestamp) {
                    enqueue(
                        [e],
                        ts: ts,
                        historyRingTimestamps: historyGeneration == nil ? [] : [s.ringTimestamp],
                        historyGeneration: historyGeneration
                    )
                } else {
                    pendingAnchorEvents.append(PendingAnchorEvent(
                        event: e,
                        ringTimestamp: s.ringTimestamp,
                        historyGeneration: historyGeneration,
                        historyEnvelope: historyEnvelope,
                        liveArrivalTimestamp: historyEnvelope ? nil : now
                    ))
                }

            case .hrv(let v):
                if let ts = driver.unixSeconds(forRingTimestamp: v.ringTimestamp) {
                    enqueue(
                        [e],
                        ts: ts,
                        historyRingTimestamps: historyGeneration == nil ? [] : [v.ringTimestamp],
                        historyGeneration: historyGeneration
                    )
                } else {
                    pendingAnchorEvents.append(PendingAnchorEvent(
                        event: e,
                        ringTimestamp: v.ringTimestamp,
                        historyGeneration: historyGeneration,
                        historyEnvelope: historyEnvelope,
                        liveArrivalTimestamp: historyEnvelope ? nil : now
                    ))
                }

            case .sleepPhase:
                // Persisted at the record/burst level above after reconstructing the real 30-second axis.
                break

            case .timeSync(let ts):
                // #91: a 0x42 whose epoch is outside the 2020–2035 plausibility window is silently ignored,
                // so history samples stay unanchored (no sleep/daily). Log the rejection with the offending
                // epoch; only announce "acquired" when the sync ACTUALLY anchored (the old unconditional
                // "acquired" line fired even on a rejected sync). `epochMs` holds the raw wire value, which
                // is unix SECONDS despite the name (s6.11).
                if OuraDriver.isPlausibleAnchorEpoch(ts.epochMs) {
                    if !loggedAnchor {
                        loggedAnchor = true
                        log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                    }
                } else {
                    log("Oura: 0x42 time-sync REJECTED - implausible epoch \(ts.epochMs)s (outside the 2020–2035 anchor window); history samples stay unanchored (#91)")
                }
                // The 0x42 time-sync can arrive ANYWHERE in a history-fetch stream, not necessarily first.
                // Anything parked while unanchored gets its real time retroactively the moment an anchor lands.
                drainPendingAnchorEvents()
                drainPendingHypnogramBursts()

            case .rtcBeacon(let r):
                // #91: the 0x85 beacon is the SECONDARY anchor (fills the gap only until a 0x42 arrives). A
                // beacon ignored because a primary anchor already exists is NORMAL and not logged; only an
                // IMPLAUSIBLE-epoch beacon is a real failure (it can never anchor), so log just that.
                if OuraDriver.isPlausibleAnchorEpoch(Int64(r.unixSeconds)) {
                    // OuraDriver has accepted the secondary anchor before emitting this event. Drain both
                    // parked scalar samples and whole hypnogram bursts just as the primary 0x42 path does;
                    // otherwise a session that receives only 0x85 can lose its ring-provided sleep stages.
                    drainPendingAnchorEvents()
                    drainPendingHypnogramBursts()
                } else {
                    log("Oura: 0x85 RTC beacon REJECTED - implausible epoch \(r.unixSeconds)s (outside the 2020–2035 anchor window) (#91)")
                }

            case .tierB(let summary):
                // The validated 0x49 fields are offsets in minutes before the finalization event. Retain a
                // bounded set so the nearest phase burst can anchor to the true sleep window, not the later
                // analysis-write time. Still Tier-B: this raw summary is never itself persisted or scored.
                if summary.tag == 0x49, summary.rawPayload.count >= 4 {
                    let startOff = Int(summary.rawPayload[0]) | (Int(summary.rawPayload[1]) << 8)
                    let endOff = Int(summary.rawPayload[2]) | (Int(summary.rawPayload[3]) << 8)
                    recentSleepWindows049.append((summary.ringTimestamp, startOff, endOff))
                    if recentSleepWindows049.count > Self.recentSleepWindows049Cap {
                        recentSleepWindows049.removeFirst(
                            recentSleepWindows049.count - Self.recentSleepWindows049Cap
                        )
                    }
                }
                // INVESTIGATION ONLY (real_steps / activity-summary / sleep-summary / smoothed-SpO2,
                // OURA_PROTOCOL.md s7.3 Tier B; PR #960). Logged ONCE PER KIND with the raw bytes so we
                // can see whether the ring sends these tags at all and collect capture material - e.g.
                // real_steps 0x7E/0x7F is server-flag-gated OFF by default ([open_oura-feat]), so its
                // continued absence here is the ring's doing, not a decode gap. Never persisted, never
                // scored (OuraStreamMapping drops .tierB unconditionally regardless of this log).
                if !loggedTierBKinds.contains(summary.kind) {
                    loggedTierBKinds.insert(summary.kind)
                    let hex = summary.rawPayload.map { String(format: "%02x", $0) }.joined(separator: " ")
                    log("Oura: Tier-B \(summary.kind) seen (tag 0x\(String(summary.tag, radix: 16))) - raw: \(hex)")
                }

            case .activityInfo(let info):
                // INVESTIGATION ONLY (0x50 activity/MET, Tier B - a plausible third-party formula, NOT
                // ground-truth-validated; see OuraActivityInfo). Logged with the DECODED state/MET values
                // every time (not once-per-kind): this is the tag under active plausibility evaluation, so
                // every real capture is evidence. Never persisted, never scored, and NEVER converted into
                // steps (MET is not a step count; OuraStreamMapping drops .activityInfo unconditionally).
                // Include the record's anchored timestamp so an individual MET burst can be correlated
                // with what the wearer was doing (walk / swim / …); before the UTC anchor lands it reads
                // "no anchor yet".
                let utc = driver.unixSeconds(forRingTimestamp: info.ringTimestamp)
                let when = utc.map { Self.cursorDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) } ?? "no anchor yet"
                log("Oura: activity (Tier-B) [\(when)] state=\(info.state) met=\(info.met)")
                // Append the raw record to the Tier-B research corpus (anchored records only; deduped by
                // ring-time inside the writer). Diagnostic sidecar — never persisted to SQLite, never scored.
                if let utc = utc {
                    activityDump?.record(ringTs: info.ringTimestamp, utc: utc, state: info.state,
                                         secPerSample: Int(activityEpochSeconds), met: info.met)
                }
                // Accumulate the MET series by local day for the drain-end estimate, and observe the
                // per-sample cadence from consecutive record times (both investigation-only, never scored).
                if let utc = utc {
                    let dayKey = Self.activityDayFormatter.string(from: Date(timeIntervalSince1970: Double(utc)))
                    activityMETByDay[dayKey, default: []].append(contentsOf: info.met)
                    if let prev = lastActivityUtc, lastActivitySampleCount > 0 {
                        let perSample = Double(utc - prev) / Double(lastActivitySampleCount)
                        // Reject off-wrist gaps / out-of-order re-dumps; keep only plausible epoch spacings.
                        if perSample >= 5, perSample <= 600 { activityCadenceObs.append(perSample) }
                    }
                    lastActivityUtc = utc
                    lastActivitySampleCount = info.met.count
                }

            case .state(let s):
                // The ring's own lifecycle strings (0x45/0x53). Charger transitions drive the wear badge;
                // never a durable Streams row. Only the LIVE stream updates the indicator (a history
                // re-serve is out of order and would flap it).
                if mayPublishLive,
                   OuraLivePublication.permitsCurrentState(
                    historyEnvelope: historyEnvelope,
                    eventUnixSeconds: driver.unixSeconds(forRingTimestamp: s.ringTimestamp),
                    now: now
                   ) {
                    wearTracker.note(state: s)
                    publishWearState()
                }

            default:
                break   // motion / debugText / etc: not a durable Streams row (see OuraStreamMapping)
            }
        }
    }

    /// Mirror the tracker's current wear/charge state to the observable, and log each TRANSITION once (a
    /// charger on/off or first pulse is worth a strap-log line; steady state is not).
    private func publishWearState() {
        let s = wearTracker.current
        if mayPublishLive { live.ouraWearState = s }
        if s != loggedWearState {
            loggedWearState = s
            switch s {
            case .worn:     log("Oura: ring WORN - live HR streaming")
            case .charging: log("Oura: ring NOT WORN - on charger (HR/IBI paused until removed)")
            case .off:      log("Oura: ring NOT WORN - no live HR (removed / off charger)")
            case .unknown:  break
            }
        }
    }

    /// Log a feature-status read reply once per feature (read-only diagnostic). Confirms, from the ring
    /// itself, whether a server-flag feature (SpO2 0x04 / real_steps 0x0b) is subscribed/emitting — NOOP
    /// cannot enable these offline (server ClientConfiguration gate), so a `subscription == 0` here is the
    /// honest "not a bug, it's a gate" reading. Never scored, never stored.
    private func logFeatureStatus(_ st: OuraFeatureStatus) {
        guard loggedFeatureStatuses.insert(st.feature).inserted else { return }
        let name: String
        switch UInt8(truncatingIfNeeded: st.feature) {
        case OuraCommands.featureSpO2:      name = "SpO2 (0x04)"
        case OuraCommands.featureRealSteps: name = "real_steps (0x0b)"
        case OuraCommands.featureDaytimeHR: name = "daytime-HR (0x02)"
        default:                            name = "0x\(String(st.feature, radix: 16))"
        }
        // A gated/unavailable feature reports ALL-ZERO (mode/status/state); the streaming daytime-HR, by
        // contrast, reads mode=1 status=0x11 state=2. Flag the all-zero case as the honest "cloud never
        // enabled it" - NOT `subscription==0` alone, since daytime-HR is subscription=0 yet active.
        let off = st.mode == 0 && st.status == 0 && st.state == 0
        let gate = off ? " - INACTIVE (server-gated off; the cloud never enabled it, not emitted offline)" : ""
        // Name the enum fields so the log reads plainly (OURA_PROTOCOL.md s7.1 [ring4-ble]) — e.g. a gated
        // feature prints `mode=0 (off) … subscription=0 (off)`, the active daytime-HR `mode=1 (automatic)`.
        log("Oura: feature status \(name) mode=\(st.mode) (\(Self.featureModeName(st.mode))) status=\(st.status) state=\(st.state) subscription=\(st.subscription) (\(Self.subscriptionName(st.subscription)))\(gate)")
    }

    /// The ring's feature-MODE enum (`2f 03 22` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble].
    private static func featureModeName(_ m: Int) -> String {
        switch m {
        case 0: return "off"; case 1: return "automatic"; case 2: return "requested"; case 3: return "connected_live"
        default: return "?"
        }
    }
    /// The ring's SUBSCRIPTION enum (`2f 03 26` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble].
    private static func subscriptionName(_ s: Int) -> String {
        switch s {
        case 0: return "off"; case 1: return "state"; case 2: return "latest"; case 4: return "feature_data"
        default: return "?"
        }
    }

    // MARK: - Re-engagement timer (daytime-HR auto-reverts ~20s)

    private func startReengageTimer() {
        stopReengageTimer()
        let t = Timer.scheduledTimer(withTimeInterval: reengageInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.reengageLiveHR() }
        }
        reengageTimer = t
    }

    private func stopReengageTimer() {
        reengageTimer?.invalidate()
        reengageTimer = nil
    }

    /// Re-send the live-HR enable+subscribe so the ~20 s auto-revert never silently stops the stream.
    private func reengageLiveHR() {
        guard let driver, reachedStreaming else { return }
        write(driver.reengageLiveHRCommands())
        // Live-HR watchdog: if the stream has gone silent past the grace window while we were WORN, the
        // ring came off the finger (no "removed" event exists) -> NOT WORN. Only meaningful once we have
        // seen at least one live beat this session.
        if mayPublishLive, let last = lastLivePulseAt, Date().timeIntervalSince(last) > wornPulseTimeout {
            wearTracker.noteLivePulseTimeout()
            publishWearState()
        }
    }

    // MARK: - Honest needs-pairing fallback (Huami precedent)

    private enum NeedsPairingReason {
        case factoryResetOrNoKey
        case authFailed(OuraAuthStatus)
        case installFailed(String)
    }

    /// Record + log the honest "this ring needs a pairing handshake NOOP can't complete" outcome (once),
    /// and drop the link so no half-authenticated session lingers. We never fabricate a reading. Also marks
    /// `adoptPhase = .failed` so an in-flight adopt's Adopting step lands on a REACHABLE honest Failed state
    /// (file-import + Advanced-key fallbacks), and clears any in-flight install key WITHOUT persisting it (a
    /// failed install must never leave a wrongly-trusted key). RECOVERY-HONEST: a factory-reset ring is NOT
    /// bricked; re-pairing it in the Oura app brings it back. We never claim a key was installed here.
    private func announceNeedsPairing(reason: NeedsPairingReason) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = nil
        adoptPhase = .failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so the
        // ensuing disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912): a later user reconnect re-arms.
        // Run this UNCONDITIONALLY, before the first-announce guard, so a SECOND announce in the same session
        // (needsPairing already set) still cancels the lingering peripheral and re-suppresses the reconnect,
        // mirroring the Android twin (OuraLiveSource.kt announceNeedsPairing).
        intentionalDisconnect = true
        reconnectID = nil
        failedReconnectAttempts = 0
        commandPaceWorkItem?.cancel()
        commandPaceWorkItem = nil
        commandWrites.reset()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        guard needsPairing == nil else { return }
        let detail: String
        switch reason {
        case .factoryResetOrNoKey:
            detail = "NOOP needs the ring's install key to read it live, and that pairing handshake isn't set up yet."
        case .authFailed(let status):
            detail = "The ring rejected the pairing handshake (status \(status.rawValue))."
        case .installFailed(let why):
            detail = "NOOP couldn't take over this ring (\(why))."
        }
        let recovery = " The ring isn't bricked: re-pair it in the Oura app to recover it."
        let msg = detail + " Live data isn't available - export from the Oura app and import the file instead." + recovery
        needsPairing = msg
        log("Oura: \(msg)")
        stopReengageTimer()
        stopHistoryFetchTimer()
        stopBatchQuietTimer()
        pendingDrainAction = nil
        flush()
        invalidateHistoryPersistenceBarrier()
        if mayPublishLive { live.connected = false; live.streamingLiveHR = false }
    }

    // CB delegate callbacks live in the @preconcurrency extensions below. The queue-less central delivers
    // them on the main thread, so MainActor isolation is sound; @preconcurrency lets this @MainActor type
    // satisfy the nonisolated CoreBluetooth requirements (same pattern as StandardHRSource / BLEManager).
}

// MARK: - CBCentralManagerDelegate

extension OuraLiveSource: @preconcurrency CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // Replay any intent that arrived before the radio was ready.
            if let id = pendingConnectID, let p = seenPeripherals[id] {
                pendingConnectID = nil
                central.connect(p, options: nil)
            } else if scanning {
                central.scanForPeripherals(withServices: [Self.service],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            }
        default:
            // Radio off / unauthorized / resetting -> the link is not live.
            if mayPublishLive { live.connected = false; live.streamingLiveHR = false }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advName ?? peripheral.name ?? ""
        // The scan already filters on the Oura service, but re-check the name through the gen recogniser
        // so a coincidental service match without an Oura-shaped name is dropped (best-effort).
        let detectedGen = OuraRingGen.recognise(advertisedName: name)
        let id = peripheral.identifier
        let firstSight = seenPeripherals[id] == nil
        seenPeripherals[id] = peripheral
        if firstSight { log("Oura: found \(name.isEmpty ? "Oura ring" : name) (\(id)) rssi \(RSSI.intValue)") }
        let ring = DiscoveredRing(id: id,
                                  name: name.isEmpty ? "Oura" : name,
                                  rssi: RSSI.intValue,
                                  detectedGen: detectedGen)
        if let idx = discovered.firstIndex(where: { $0.id == id }) {
            discovered[idx] = ring
        } else {
            discovered.append(ring)
        }
        // If we were scanning specifically to reach this ring (a not-yet-cached active ring), connect now.
        if pendingConnectID == id {
            pendingConnectID = nil
            connect(id)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else {
            log("Oura: ignoring connect callback from a replaced peripheral")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        log("Oura: connected - discovering services")
        failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
        peripheral.delegate = self
        teardownDeadlineWorkItem?.cancel()
        teardownDeadlineWorkItem = nil
        commandPaceWorkItem?.cancel()
        commandPaceWorkItem = nil
        commandWrites.reset()
        teardownPending = false
        // A reconnect starts a wholly new persistence generation. Dispatch any straggling buffered data,
        // then make every old completion incapable of touching the new drain.
        flush()
        invalidateHistoryPersistenceBarrier()
        // Fresh driver per connection so a new session re-runs auth (the app key is session-scoped). The
        // driver's `allowKeyInstall` is gated on this connection's adopt consent ONLY: with no consent the
        // dangerous `0x24` installKey can never be sequenced, so a read-only / Advanced-key connect stays
        // honest (it announces needs-pairing instead of provisioning). Per OURA_PROTOCOL.md s3.2.
        // allowTierB: true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `ingest` LOG what the
        // ring actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // .tierB/.activityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        driver = OuraDriver(ringGen: ringGen,
                            authKey: authKey().map { [UInt8]($0) },
                            allowTierB: true,
                            allowKeyInstall: adoptIntent)
        reachedStreaming = false
        loggedFirstHR = false
        droppedFirstLiveHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        loggedFeatureStatuses.removeAll()
        handledProductInfo.removeAll()
        pendingAnchorEvents.removeAll()   // a fresh session must never replay a stale-anchor guess
        hypnogramAssembler.reset()
        hypnogramReceiptTracker.reset()
        pendingUnanchoredBursts.removeAll()
        recentSleepWindows049.removeAll()
        pendingInstallKey = nil
        adoptPhase = .idle
        reassembler.reset()
        wearTracker.reset(); loggedWearState = nil; lastLivePulseAt = nil
        // Per-drain cursor state starts clean each session (fetchHistoryIfIdle re-arms it per drain).
        drain.reset()
        resumeCursorAtFetchStart = 0
        drainStartedAt = nil
        lastRequestCursor = 0
        // Resume the GetEvents cursor from where the LAST connection to this ring left off (s5.1/5.3), so
        // a routine reconnect doesn't re-fetch the ring's entire banked history every time. A persisted
        // value above the plausibility ceiling is garbage banked by a pre-fix build (a bytes_left count or
        // a misframe-era ring-time) - seeking to it would starve the fetch; reset to a full pull instead.
        let loadedCursor = OuraHistoryCursorStore.read(deviceId: deviceId)
        historyCursor = OuraHistoryDrain.sanitizeLoadedCursor(loadedCursor)
        if historyCursor != loadedCursor {
            log("Oura: persisted resume cursor \(loadedCursor) exceeds the plausibility ceiling (pre-fix garbage) - full pull")
            OuraHistoryCursorStore.save(0, deviceId: deviceId)
        }
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else {
            log("Oura: ignoring failed-connect callback from a replaced peripheral")
            return
        }
        log("Oura: WARNING failed to connect - \(error?.localizedDescription ?? "unknown error")")
        commandPaceWorkItem?.cancel()
        commandPaceWorkItem = nil
        commandWrites.reset()
        flush()
        invalidateHistoryPersistenceBarrier()
        if mayPublishLive { live.connected = false; live.streamingLiveHR = false }
        // The ring wiped its bond (re-paired in the Oura app, or a firmware reset). CoreBluetooth surfaces
        // this as a stable CBError, and re-issuing connect just loops the same stale-pairing failure and
        // drains the ring, so DON'T auto-reconnect: route to the honest needs-pairing path instead, exactly
        // like BLEManager returns early on this error without rescheduling (#912/#414).
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            announceNeedsPairing(reason: .factoryResetOrNoKey)
            return
        }
        // A failed connect to the paired ring (e.g. out of range at launch) retries on the backoff so the
        // ring comes back on its own, mirroring BLEManager's failed-connect reschedule (#912/#414).
        scheduleReconnect()
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard self.peripheral === peripheral else {
            log("Oura: ignoring disconnect callback from a replaced peripheral")
            return
        }
        if let error = error {
            log("Oura: disconnected - \(error.localizedDescription)")
        } else {
            log("Oura: disconnected (clean)")
        }
        stopReengageTimer()
        stopHistoryFetchTimer()
        stopBatchQuietTimer()
        pendingDrainAction = nil
        teardownDeadlineWorkItem?.cancel()
        teardownDeadlineWorkItem = nil
        commandPaceWorkItem?.cancel()
        commandPaceWorkItem = nil
        commandWrites.reset()
        teardownPending = false
        // Close the phase burst and drain parked samples before the driver's time anchor is cleared.
        flushPendingHypnogramBurst()
        drainPendingAnchorEvents(dropUnresolvedHistory: true)
        dropUnanchoredHypnogramBursts()
        flush()
        invalidateHistoryPersistenceBarrier()
        driver?.stop()
        driver = nil
        reassembler.reset()
        wearTracker.reset(); loggedWearState = nil; lastLivePulseAt = nil
        writeCharacteristic = nil
        loggedFirstHR = false
        droppedFirstLiveHR = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.removeAll()
        loggedFeatureStatuses.removeAll()
        handledProductInfo.removeAll()
        recentSleepWindows049.removeAll()
        hypnogramAssembler.reset()
        hypnogramReceiptTracker.reset()
        activityMETByDay.removeAll()
        activityCadenceObs.removeAll()
        lastActivityUtc = nil
        lastActivitySampleCount = 0
        reachedStreaming = false
        pendingInstallKey = nil
        // A disconnect MID-install is an honest failure (no ack came); a disconnect after streaming leaves
        // the completed `.streaming` outcome intact so the wizard's success transition isn't undone.
        if adoptPhase == .installingKey { adoptPhase = .failed }
        batteryPct = nil
        if mayPublishLive { live.connected = false; live.streamingLiveHR = false }
        if self.peripheral?.identifier == peripheral.identifier { self.peripheral = nil }
        // Auto-reconnect on an INVOLUNTARY drop (#912): the paired ring went out of range or the link timed
        // out. Re-issue a connect on the backoff so it comes back on its own, exactly like the WHOOP strap.
        // A deliberate `stop()` set `intentionalDisconnect`/cleared `reconnectID`, so this is a no-op there.
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension OuraLiveSource: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error = error {
            log("Oura: WARNING service discovery failed - \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else {
            log("Oura: services discovered but the list was empty")
            return
        }
        guard let svc = services.first(where: { $0.uuid == Self.service }) else {
            log("Oura: Oura service NOT FOUND - this ring may not expose the expected GATT layout")
            return
        }
        log("Oura: Oura service found - discovering characteristics")
        // Discover the write + notify chars (gen5 also advertises ...0004/5/6, which v1 discovers but
        // never writes to). RingGen drives which to discover.
        let charUUIDs = OuraGatt.characteristicUUIDs(for: ringGen).map { CBUUID(string: $0) }
        peripheral.discoverCharacteristics(charUUIDs, for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral else { return }
        if let error = error {
            log("Oura: WARNING characteristic discovery failed - \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else {
            log("Oura: characteristics discovered but the list was empty")
            return
        }
        if let wc = chars.first(where: { $0.uuid == Self.writeChar }) {
            writeCharacteristic = wc
            log("Oura: write characteristic found")
        } else {
            log("Oura: write characteristic NOT FOUND - cannot drive the ring")
        }
        if let nc = chars.first(where: { $0.uuid == Self.notifyChar }) {
            log("Oura: notify characteristic found - enabling notifications")
            peripheral.setNotifyValue(true, for: nc)
        } else {
            log("Oura: notify characteristic NOT FOUND - cannot read the ring")
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard self.peripheral === peripheral else { return }
        guard characteristic.uuid == Self.notifyChar else { return }
        if let error = error {
            log("Oura: WARNING enabling notifications FAILED - \(error.localizedDescription) - ring will send no data")
            return
        }
        log("Oura: notifications enabled (isNotifying=\(characteristic.isNotifying)) - beginning auth")
        // Notifications are live: tell the driver we're ready. It returns the auth-nonce request (or, with
        // no key, drives the honest needs-pairing path).
        advance(.ready)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, !teardownPending else { return }
        guard error == nil, let value = characteristic.value, characteristic.uuid == Self.notifyChar else { return }
        let bytes = [UInt8](value)
        // The notify char carries TWO framings on the same channel (OURA_PROTOCOL.md s2):
        //   - 0x2F secure-session sub-frames (auth nonce/status, enable ACKs, live-HR pushes)
        //   - inner TLV event records (IBI / HRV / SpO2 / temp / sleep-phase / battery)
        // Event tags are >= 0x41. Parse those notifications directly through the one-packet, lenient TLV
        // path; command/response opcodes are below that range and use outer framing. This prevents a 0x11
        // summary from being misread as an unknown event and overwriting the driver's last ring timestamp.
        guard let driver else { return }
        if let op = bytes.first, op >= 0x41 {
            ingestTLVNotification(bytes, driver: driver)
            return
        }

        let frames = OuraFraming.parseOuterFrames(bytes)
        for frame in frames {
            switch frame.op {
            case Self.setAuthKeyRespOp where pendingInstallKey != nil:
                // `25 01 <status>` is an outer SetAuthKey acknowledgement, never an event record.
                handleKeyInstallAck(status: frame.body.first ?? 0xFF)

            case OuraFraming.getEventsResponseOp:
                // A 0x11 summary is an early byte-progress report. It is consumed here and never allowed
                // to mutate the event-envelope cursor or driver's last real ring timestamp.
                if let summary = OuraFraming.parseGetEventsResponse(frame.body) {
                    handleHistorySummary(summary)
                }

            case OuraFraming.syncTimeResponseOp:
                if let response = OuraFraming.parseSyncTimeResponse(frame.body) {
                    handleSyncTimeResponse(response)
                }

            case OuraFraming.batteryResponseOp:
                if let battery = OuraDecoders.decodeBattery(frame.body) {
                    ingest([.battery(battery)])
                }

            case let op where Self.productInfoResponseOps.contains(op):
                handleProductInfo(frame.body)

            case OuraFraming.secureSessionOp:
                guard let secure = OuraFraming.parseSecureFrame(frame) else { continue }
                handleSecure(driver.handleSecureFrame(secure))

            default:
                // A secure notification may pack a normal event frame beside the secure frame. Rebuild
                // that one record exactly and feed it through the same raw-envelope path.
                if frame.op >= 0x41 {
                    ingestTLVNotification(
                        [frame.op, UInt8(frame.body.count)] + frame.body,
                        driver: driver
                    )
                }
            }
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard self.peripheral === peripheral else { return }
        pumpCommandWrites()
    }

    /// Adopt the ring clock returned by SyncTime only when its raw-vs-seconds interpretation is
    /// unambiguous near the durable history cursor. A failed status or cold-start ambiguity stays missing.
    private func handleSyncTimeResponse(
        _ response: (deviceTimestamp: UInt32, status: UInt8)
    ) {
        guard response.status == 0 else {
            log("Oura: SyncTime response rejected with status \(response.status)")
            return
        }
        guard let driver,
              let ringTimestamp = OuraDriver.syncTimeAnchorCandidate(
                responseValue: response.deviceTimestamp,
                historyCursor: historyCursor
              ),
              driver.adoptSyncTimeAnchor(
                ringTimestamp: ringTimestamp,
                unixSeconds: Int64(Date().timeIntervalSince1970)
              ) else {
            log("Oura: SyncTime response did not provide an unambiguous history anchor")
            return
        }
        if !loggedAnchor {
            loggedAnchor = true
            log("Oura: UTC anchor acquired from SyncTime response")
        }
        drainPendingAnchorEvents()
        drainPendingHypnogramBursts()
    }

    /// Decode serial/hardware pages without persisting or logging the serial. Only a known hardware id
    /// may correct the registry model; unknown strings remain inert.
    private func handleProductInfo(_ body: [UInt8]) {
        guard let value = OuraDecoders.productInfoString(body),
              handledProductInfo.insert(value).inserted,
              let detected = OuraRingGen.from(hardwareId: value) else { return }
        guard detected != ringGen else { return }
        log("Oura: hardware reports \(detected.displayName); correcting the stored model")
        onModel(detected.displayName)
    }

    /// Observe the RAW record envelope before decoding it. Unknown or malformed payloads still move the
    /// in-session continuation position, while only successfully stored, anchored samples may move the
    /// durable resume cursor. A trailing record after an early summary also extends the quiet window.
    private func ingestTLVNotification(_ bytes: [UInt8], driver: OuraDriver) {
        for record in reassembler.feed(bytes) {
            let generation = historyTransportGeneration
            if generation != nil {
                drain.noteSeenRingTime(record.ringTimestamp)
                if pendingDrainAction != nil { restartBatchQuietTimer() }
            }
            // TLV records are banked/event data even if their callback arrives after the driver returned to
            // streaming. Live HR/IBI uses the separately framed secure push path.
            ingest(
                driver.ingest(record: record),
                historyEnvelope: true,
                historyGeneration: generation
            )
        }
    }

    /// Act on what the driver resolved a 0x2F secure sub-frame to.
    private func handleSecure(_ routing: OuraDriver.SecureRouting) {
        switch routing {
        case .nonce(let nonce):
            log("Oura: auth nonce received - submitting proof")
            advance(.nonceReceived(nonce))
        case .authStatus(let status):
            if status.isSuccess {
                log("Oura: auth OK - enabling live HR")
            } else {
                log("Oura: WARNING auth status \(status.rawValue)")
            }
            advance(.authCompleted(status))
        case .enableAck:
            advance(.enableAckReceived)
        case .featureStatus(let st):
            logFeatureStatus(st)   // read-only diagnostic; never advances the state machine
        case .liveHRPush(let body):
            guard let driver else { return }
            ingest(driver.ingestLiveHRPush(body: body))
        case .unhandled:
            break
        }
    }
}

// MARK: - Oura install-key Keychain accessor

/// Keychain Services wrapper for the per-ring 16-byte Oura application install key. Mirrors the
/// `AIKeyStore` generic-password pattern (`Strand/AI/AICoach.swift`) so the key never lands in
/// UserDefaults, a plist, or on disk in the clear. The key is scoped per `deviceId` (the `account`), so
/// each registered ring has its own item. The install key is written here from exactly two places: the
/// adopt key-install handshake (on an OK `0x25` ack, `OuraLiveSource.handleKeyInstallAck`) and the wizard's
/// Advanced "I already have my ring's key" path. This accessor only stores/reads/clears it.
public enum OuraKeyStore {
    private static let service = "com.noop.oura.installkey"
    /// The fixed key length per OURA_PROTOCOL.md s3 (16-byte application auth key).
    public static let keyLength = 16

    private static func baseQuery(deviceId: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: deviceId,
        ]
    }

    /// Store (or replace) the 16-byte install key for `deviceId`. A wrong-length key is rejected (no
    /// partial key is ever stored, so a later read can't return a malformed key).
    @discardableResult
    public static func save(_ key: Data, deviceId: String) -> Bool {
        guard key.count == keyLength else { return false }
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
        var attrs = baseQuery(deviceId: deviceId)
        attrs[kSecValueData as String] = key
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    /// Read the stored 16-byte install key for `deviceId`, or nil if none is set (or the stored item is
    /// the wrong length, which is treated as absent so the honest needs-pairing path runs).
    public static func read(deviceId: String) -> Data? {
        var query = baseQuery(deviceId: deviceId)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == keyLength else { return nil }
        return data
    }

    /// Remove the stored install key for `deviceId`.
    public static func clear(deviceId: String) {
        SecItemDelete(baseQuery(deviceId: deviceId) as CFDictionary)
    }
}

// MARK: - Oura GetEvents cursor persistence

/// Persists the Oura `GetEvents` cursor (OURA_PROTOCOL.md s5.1/5.3) per ring, so a later connection
/// resumes from where the last session left off instead of re-fetching the ring's entire banked history
/// on every single connect. Unlike `OuraKeyStore` this is NOT sensitive - it's an opaque ring-clock tick
/// counter, not a credential - so plain `UserDefaults` is the right (and simplest) store.
enum OuraHistoryCursorStore {
    private static func key(deviceId: String) -> String { "com.noop.oura.historyCursor.\(deviceId)" }

    /// The persisted cursor for `deviceId`, or 0 (fetch everything) if none is stored yet.
    static func read(deviceId: String) -> UInt32 {
        let raw = UserDefaults.standard.object(forKey: key(deviceId: deviceId)) as? Int ?? 0
        return UInt32(clamping: raw)
    }

    /// Store the advanced cursor for `deviceId`.
    static func save(_ cursor: UInt32, deviceId: String) {
        UserDefaults.standard.set(Int(cursor), forKey: key(deviceId: deviceId))
    }
}
