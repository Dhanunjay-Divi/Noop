package com.noop.ble

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import com.noop.data.OuraStreamMapping
import com.noop.data.StreamBatch
import com.noop.data.StreamPersistence
import com.noop.oura.OuraAuth
import com.noop.oura.OuraCommand
import com.noop.oura.OuraDriver
import com.noop.oura.OuraDriverPhase
import com.noop.oura.OuraEvent
import com.noop.oura.OuraFraming
import com.noop.oura.OuraGatt
import com.noop.oura.OuraCommands
import com.noop.oura.OuraDecoders
import com.noop.oura.OuraHistoryDrain
import com.noop.oura.OuraHypnogramAssembler
import com.noop.oura.OuraHypnogramBurst
import com.noop.oura.OuraIbiHr
import com.noop.oura.OuraOuterFrame
import com.noop.oura.OuraReassembler
import com.noop.oura.OuraRingGen
import com.noop.oura.OuraSleepPhase
import com.noop.oura.OuraSleepSession
import com.noop.oura.OuraSleepSessionMapping
import com.noop.oura.OuraTransition
import com.noop.oura.OuraWearState
import com.noop.oura.OuraWearTracker
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean

/**
 * EXPERIMENTAL, ISOLATED live-BLE source for the Oura ring (gen3 / gen4 / gen5).
 *
 * Faithful Kotlin twin of Strand/BLE/OuraLiveSource.swift. This replaced an earlier honest dead-end
 * probe: where that probe only proved "there's no OPEN stream", this transport speaks the
 * ring's OWN documented protocol (clean-room, see docs/OURA_PROTOCOL.md) to authenticate with the
 * 16-byte application key, enable the daytime-HR feature, and decode the ring's RAW signals
 * (HR / IBI / RMSSD / SpO2 / skin-temp / sleep-phase tags). NOOP computes its OWN Charge/Rest from
 * those raw signals; the ring's encrypted readiness/sleep SCORES are never read or surfaced
 * (honest-data invariant).
 *
 * All BLE specifics live here; all protocol specifics live in the JVM-pure [OuraDriver] (which holds
 * NO BluetoothGatt). This class owns the transport and feeds the driver only bytes + transition events.
 *
 * WHOOP-FIRST ISOLATION (identical to [StandardHrSource] / [HuamiHrSource]): this class runs its OWN
 * scan + [BluetoothGatt] and never imports, calls, or shares state with the WHOOP BLE client. The
 * WHOOP path cannot regress because of anything here. The only shared surfaces are injected closures:
 *   - [liveSink]  pushes the ring's live HR (bpm) + R-R (ms) into whatever the UI observes (the
 *                 [SourceCoordinator] wires it to the same live state a WHOOP/strap reading uses).
 *   - [persist]   wired by the app to `repository.insert(StreamBatch, deviceId)` for the active ring.
 *   - [log]       the SAME exportable strap log (issue #421); every line is prefixed "Oura: ".
 *   - [onBattery] surfaces the ring's battery percent the same place a strap's does.
 *
 * HONEST FALLBACK (Huami precedent): when no install key is available ([authKey] returns null) or the
 * ring reports it is in factory reset, the ring needs a pairing/provisioning handshake the live flow
 * does not silently perform. This source then publishes an HONEST message via [needsPairing] and stays
 * disconnected from data - it NEVER fabricates a reading and never displays Oura's own scores.
 *
 * Android runtime-permission notes (same contract as the other sources): the caller must hold
 * BLUETOOTH_SCAN + BLUETOOTH_CONNECT before [scan]/[connect]. Every android.bluetooth call is
 * @SuppressLint("MissingPermission") - the caller owns the grant.
 */
@SuppressLint("MissingPermission")
class OuraLiveSource(
    context: Context,
    /** Datastore device id every sample is stamped with (the active ring's registry id). */
    private val deviceId: String,
    /** The ring generation (selected by the user in the wizard, recovered from the row model). Drives
     *  the MTU clamp, discovered-characteristic set, and the live-HR enable command set. */
    private val ringGen: OuraRingGen,
    /** Push live HR (bpm) + R-R (ms) into whatever the UI observes. Called on the main looper. Mirrors
     *  [StandardHrSource.liveSink] so the [SourceCoordinator] wires both the same way. */
    private val liveSink: (hr: Int, rr: List<Int>) -> Unit,
    /** Returns the 16-byte application auth key (unsigned bytes 0..255) for this ring, or null when none
     *  has been provisioned. INJECTED, never hardcoded (the key lives in [OuraInstallKeyStore], backed by
     *  the Android Keystore). null drives the honest [needsPairing] path - no faked data. */
    private val authKey: () -> IntArray?,
    /**
     * Persist a batch under [deviceId], reporting the real Room result. History cursor movement waits for
     * this callback; discovery-only sources use the successful no-op default.
     */
    private val persist: (StreamBatch, String, (Boolean) -> Unit) -> Unit = { _, _, done -> done(true) },
    /**
     * Upsert the reconstructed hypnogram and report the real Room result. This is part of the same
     * durability obligation as its phase rows.
     */
    private val persistSleepSession:
        (OuraSleepSession, String, (Boolean) -> Unit) -> Unit = { _, _, done -> done(true) },
    /** Diagnostic sink for the connect/auth/stream lifecycle - the SAME exportable strap log (#421).
     *  Every line is prefixed "Oura: ". Statuses / UUIDs / counts only, NEVER a device address. Default
     *  no-op keeps existing call sites compiling and tests silent. */
    private val log: (String) -> Unit = {},
    /** Fired with the ring's battery percent (0-100) when decoded. */
    private val onBattery: (Int) -> Unit = {},
    /** Corrects a registry row when the hardware page resolves a different generation than the
     *  advertised-name/model guess used to start the session. */
    private val onModel: (String) -> Unit = {},
    /**
     * Source of cryptographically-random bytes for a freshly-generated install key (adopt flow step 1).
     * Injected so a test can pin a deterministic key; production defaults to [java.security.SecureRandom]
     * (the platform CSPRNG) so a forgotten injection is still secure, never a predictable key. Returns null
     * on RNG failure (then provisioning stays honest rather than installing a weak key).
     */
    private val randomKey: () -> IntArray? = { secureRandom16() },
) : LiveHrSource {

    /**
     * The live outcome of an in-flight adopt (the wizard observes this to leave its Adopting step). Kotlin
     * twin of Swift's `OuraLiveSource.AdoptPhase`. Reset to [Idle] on every connect/stop/disconnect so a
     * stale outcome never drives a transition.
     */
    enum class AdoptPhase {
        /** No adopt in flight (the default; a read-only connect never leaves this until streaming). */
        Idle,

        /** The dangerous 0x24 install was written; awaiting the 0x25 ack (an install IS running). */
        InstallingKey,

        /** Auth (re-auth on the adopt path) succeeded and HR/IBI is streaming: adoption complete. */
        Streaming,

        /** An honest dead-end (no ack / ack != OK / re-auth failed / no key): never a fake success. */
        Failed,
    }

    /** An Oura ring seen during a scan (UI affordance). [detectedGen] is a best-effort generation guess
     *  from the advertised name (null when the name carries no generation marker); the wizard confirms it
     *  via the model the user picks. Mirrors the Swift DiscoveredRing.detectedGen. */
    data class DiscoveredRing(
        val address: String,
        val name: String,
        val rssi: Int,
        val detectedGen: OuraRingGen? = null,
    )

    private val _discovered = MutableStateFlow<List<DiscoveredRing>>(emptyList())
    /** Rings discovered during the current scan, keyed by address (newest RSSI wins). */
    val discovered: StateFlow<List<DiscoveredRing>> = _discovered.asStateFlow()

    private val _scanning = MutableStateFlow(false)
    /** True while a scan is running. */
    val scanning: StateFlow<Boolean> = _scanning.asStateFlow()

    private val _batteryPct = MutableStateFlow<Int?>(null)
    /** The connected ring's battery percent, 0-100, once decoded; null until then or after disconnect
     *  (a stale value must not outlive the link). Surfaced on the device card like the WHOOP battery. */
    val batteryPct: StateFlow<Int?> = _batteryPct.asStateFlow()

    private val _needsPairing = MutableStateFlow<String?>(null)
    /** Set to an HONEST explanation when the ring needs a key install / pairing the live flow can't do
     *  (no app key, or the ring is in factory reset). null otherwise; cleared on scan/connect/stop. The
     *  source stays at "-" while this is set - never a fabricated value. */
    val needsPairing: StateFlow<String?> = _needsPairing.asStateFlow()

    private val _adoptPhase = MutableStateFlow(AdoptPhase.Idle)
    /** The live adopt outcome (see [AdoptPhase]). The wizard observes this to leave its Adopting step. Reset
     *  to [AdoptPhase.Idle] on every connect/stop/disconnect so a stale outcome never drives a transition. */
    val adoptPhase: StateFlow<AdoptPhase> = _adoptPhase.asStateFlow()

    // MARK: - Live wear/charge indicator (#628 twin) — On wrist / Off wrist / charging
    //
    // The ring emits no "worn" event, so wear is inferred: a LIVE-HR push (0x2F) means a finger; a silent
    // live stream past a grace window means it came off; the ring's "chg. detected"/"stopped" STATE strings
    // mean charging. All pure logic lives in [OuraWearTracker]; this source just feeds it the live signals.
    // Faithful twin of Strand/BLE/OuraLiveSource.swift's wear wiring.
    private val wearTracker = OuraWearTracker()
    /** The last published wear state, so each TRANSITION is logged once (steady state is not). */
    private var loggedWearState: OuraWearState? = null
    /** When the last LIVE-HR beat arrived (epoch ms). If the stream goes quiet for [wornPulseTimeoutMs]
     *  while we keep re-engaging it, the ring came off the finger -> NOT WORN. null until the first beat. */
    private var lastLivePulseAt: Long? = null
    /** Grace before a silent live-HR stream reads as "removed": the ring auto-reverts live HR ~20 s and we
     *  re-engage every [reengageIntervalMs] (15 s), so a worn ring resumes beats well within this window;
     *  exceeding it means no finger. Checked on the re-engage tick. Mirrors iOS `wornPulseTimeout` (40 s). */
    private val wornPulseTimeoutMs = 40_000L

    private val _ouraWearState = MutableStateFlow<OuraWearState?>(null)
    /** The ring's live wear/charge state (worn/charging/off), or null before any evidence this session and
     *  after disconnect (a stale badge must not outlive the link). Twin of iOS `LiveState.ouraWearState`. */
    val ouraWearState: StateFlow<OuraWearState?> = _ouraWearState.asStateFlow()

    // MARK: - Adopt consent (gates the DANGEROUS post-factory-reset key install, OURA_PROTOCOL.md s3.2)

    /**
     * EXPLICIT user-granted adopt consent for the NEXT connection. Default FALSE. The dangerous `0x24`
     * install opcode may be sent ONLY when this is true (it is wired straight to the per-connection driver's
     * `allowKeyInstall` gate). The Advanced-key path and every read-only connect leave it false, so they
     * NEVER provision a key (they stay honest via [announceNeedsPairing] when no valid key authenticates).
     */
    private var adoptIntent: Boolean = false

    /**
     * The freshly-generated install key, held in memory ONLY between writing the `0x24` install and the
     * `0x25` ack. It is persisted to the keystore ONLY once the ring acks OK (see [handleKeyInstallAck]), so
     * a failed/absent ack never leaves a wrongly-trusted key the next session would authenticate against.
     * The key is never logged. Mirrors Swift's `pendingInstallKey`.
     */
    private var pendingInstallKey: IntArray? = null

    /**
     * Grant (or revoke) adopt consent for the NEXT connection. The wizard's destructive adopt path calls
     * this with true AFTER its irreversible-consent gate AND its second "Take over" confirm, BEFORE
     * connecting, so the fresh per-connection driver is built with `allowKeyInstall == true` and the
     * dangerous install can run for exactly that session. It takes effect on the next connect (the driver
     * is re-created per connection); a connection already mid-flight is not retro-granted. Default-false
     * everywhere else keeps the dangerous opcode unreachable. Kotlin twin of Swift's `setAdoptIntent`.
     */
    fun setAdoptIntent(intent: Boolean) {
        adoptIntent = intent
    }

    // MARK: - Android Bluetooth handles (OWN scanner + GATT, separate from WHOOP)

    private val appContext = context.applicationContext
    private val bluetoothManager: BluetoothManager? =
        appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private val adapter: BluetoothAdapter? = bluetoothManager?.adapter

    /** Tier-B activity/MET research corpus writer (diagnostic JSONL sidecar; never scored, never a Streams
     *  row). Null when there is no device id. The Kotlin twin of the Swift `OuraActivityDump`. */
    private val activityDump: OuraActivityDump? =
        if (deviceId.isNotEmpty()) OuraActivityDump(appContext, deviceId, log) else null
    private val scanner: BluetoothLeScanner? get() = adapter?.bluetoothLeScanner

    private var gatt: BluetoothGatt? = null
    /** Peripherals seen in the current scan, retained by address so a chosen one survives to connect. */
    private val seen = ConcurrentHashMap<String, BluetoothDevice>()
    /** A device asked to connect before a scan result for it landed (connect-by-address path). */
    private var pendingConnectAddress: String? = null

    /** The device of the in-flight connection, remembered so a status-133 disconnect can retry it. */
    private var lastDevice: BluetoothDevice? = null
    /** Guards the single status-133 (Android GATT_ERROR) auto-retry; reset on a successful connect. */
    private var retried133 = false
    /** Logs the FIRST live-HR sample of a connection only; reset on stop/disconnect. */
    private var loggedFirstHr = false
    /**
     * True once the driver first reached Streaming this connection, so the one-shot streaming work
     * (adoptPhase, re-engage timer, history-fetch kick-off, battery request) runs exactly once and is NOT
     * re-run when the driver returns to Streaming after each history-fetch pass completes. Reset on
     * stop/disconnect. Kotlin twin of Swift's `reachedStreaming`.
     */
    private var reachedStreaming = false
    /** Logs the FIRST skin-temp sample DECODED THIS SESSION only (never every record); reset on
     *  stop/disconnect. These are last-night values from the history fetch, not live pushes, but we still
     *  only want one log line, not one per sample. Twin of [loggedFirstHr]. */
    private var loggedFirstTemp = false
    /** Logs the FIRST SpO2 sample decoded this session only. Twin of [loggedFirstTemp]. */
    private var loggedFirstSpo2 = false
    /** Logs the FIRST ring-time -> UTC anchor of this session only (s5.5); reset on stop/disconnect. */
    private var loggedAnchor = false
    /** Tier-B (UNVERIFIED) kinds ("activity" / "real_steps" / "sleep_summary" / "spo2_smoothed") already
     *  logged this session, so a repeated tag logs once per KIND, not once per record. INVESTIGATION
     *  ONLY (see the `allowTierB = true` comment at driver construction) - the log is how we collect raw
     *  captures to validate these layouts; nothing here ever persists or scores. Reset on stop/disconnect. */
    private val loggedTierBKinds = mutableSetOf<String>()
    /** Feature ids whose status we have already logged this session (SpO2 0x04 / real_steps 0x0b), so the
     *  read-only feature-status diagnostic prints once per feature, not on every reconnect. */
    private val loggedFeatureStatuses = mutableSetOf<Int>()
    /** Product-info strings handled this session. Serial and hardware pages can share one opcode. */
    private val handledProductInfo = mutableSetOf<String>()

    // MARK: - Auto-reconnect (#912)

    /**
     * The paired ring's address we should keep re-reaching. Set by [connect]/[connectToDevice], cleared by
     * [stop]. While it is non-null an INVOLUNTARY drop (or a failed connect) re-issues a connect on a capped
     * backoff, so the ring comes back on its own once it's in range again, exactly like the WHOOP strap's
     * auto-reconnect. WHOOP has this loop; the non-WHOOP sources never did, so a dropped Oura ring stayed
     * down until a manual reconnect. This never touches the WHOOP path or its client.
     *
     * @Volatile: written from [connect]/[stop] (main) and read in [scheduleReconnect]'s posted block and
     * the GATT-delivery-thread disconnect handler, so it needs cross-thread visibility - matching the WHOOP
     * client's reconnect state.
     */
    @Volatile
    private var reconnectAddress: String? = null
    /**
     * True while a teardown was USER/COORDINATOR-initiated ([stop]), so the disconnect handler suppresses
     * the auto-reconnect (twin of the Swift `intentionalDisconnect` / the WHOOP client's flag). Cleared on
     * every [connect].
     *
     * @Volatile: read on the GATT-delivery thread (onConnectionStateChange) and written on main
     * ([connect]/[stop]/[announceNeedsPairing]), so it needs cross-thread visibility - same as the WHOOP client.
     */
    @Volatile
    private var intentionalDisconnect = false
    /**
     * Consecutive involuntary reconnect attempts, feeding the capped-exponential [ReconnectBackoff] (3, 6,
     * 12, 24, 48, 60s). Reset to 0 on a successful connect and on an explicit [connect] so a ring genuinely
     * out of range doesn't hammer BLE. Twin of the WHOOP client's `failedReconnectAttempts` (which is
     * `@Volatile` for exactly this reason: it's read/reset on the GATT-delivery thread and written on main).
     */
    @Volatile
    private var failedReconnectAttempts = 0

    /**
     * The pending auto-reconnect, held as a NAMED field (not an anonymous lambda) so [stop] can remove it
     * from the main-looper handler via [handler.removeCallbacks] - exactly like [reengageRunnable] /
     * [cancelReengage]. An anonymous `postDelayed` lambda would otherwise be retained by the handler for the
     * full backoff (up to 60s) after a teardown. It reads the CURRENT [reconnectAddress]: a [stop] nulls
     * that (and sets [intentionalDisconnect]) so a firing runnable bails, and a fresh [connect] repoints it.
     */
    private val reconnectRunnable = Runnable {
        val address = reconnectAddress
        if (!intentionalDisconnect && address != null) connect(address)
    }

    /**
     * The one-shot status-133 retry, held as a NAMED field (like [reconnectRunnable]) so [stop] can remove
     * it from the handler rather than letting an anonymous lambda linger for its 1s window after a teardown.
     * Reads the CURRENT [lastDevice] at fire time (the newest connect target is the right one to retry).
     */
    private val retry133Runnable = Runnable {
        val device = lastDevice
        if (!intentionalDisconnect && device != null) connectToDevice(device)
    }

    /**
     * Schedule an auto-reconnect to the paired ring after a backoff delay, unless the teardown was
     * intentional or there is no known ring. Guarded again inside [reconnectRunnable]: a [stop] that lands
     * in the meantime removes the callback AND nulls the target/sets the flag, so a deliberate teardown
     * never races a stale reconnect. Re-posts the SAME named runnable (removing any prior one first) so at
     * most one reconnect is ever pending.
     */
    private fun scheduleReconnect() {
        if (intentionalDisconnect) return
        if (reconnectAddress == null) return
        failedReconnectAttempts += 1
        val delay = ReconnectBackoff.nextDelayMs(failedReconnectAttempts)
        log("Oura: reconnecting in ${delay / 1000}s (attempt $failedReconnectAttempts)")
        handler.removeCallbacks(reconnectRunnable)
        handler.postDelayed(reconnectRunnable, delay)
    }

    /** All BLE work hops onto the main looper, matching the other sources + CBCentralManager(queue:.main). */
    private val handler = Handler(Looper.getMainLooper())

    // MARK: - Protocol state (the pure driver + reassembler own all protocol logic)

    /**
     * The transport-agnostic protocol state machine. Recreated on each connect with a fresh snapshot of
     * the app key so a key provisioned mid-session is picked up on the next connect, and so a Stopped
     * driver never lingers. JVM-pure: holds NO BluetoothGatt.
     */
    private var driver: OuraDriver? = null

    /** Reassembles BLE notification fragments into complete TLV records (s2.4). Reset on disconnect so a
     *  half-record never bleeds into the next session. */
    private val reassembler = OuraReassembler()

    /** Groups burst-written SleepNet phase records and reconstructs their true 30-second time axis. */
    private val hypnogramAssembler = OuraHypnogramAssembler()
    private val hypnogramReceiptTracker = OuraHypnogramReceiptTracker()
    private data class PendingUnanchoredBurst(
        val burst: OuraHypnogramBurst,
        val historyGeneration: Long?,
    )
    /** Closed bursts waiting for the ring-time anchor. They are never assigned a guessed wall clock. */
    private val pendingUnanchoredBursts = ArrayList<PendingUnanchoredBurst>()

    /** Cached characteristics, resolved in onServicesDiscovered. */
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    /** Oura's command characteristic is write-without-response only. Android permits one GATT operation at
     *  a time, so commands are submitted once and paced instead of being fired back-to-back. */
    private val commandWrites = OuraCommandWriteQueue()
    private val commandWritePaceMs = 12L
    private val commandPaceRunnable: Runnable = Runnable {
        commandWrites.completeActive()
        if (teardownPending && commandWrites.isDrained) {
            finishTransportStop()
        } else {
            drainCommandWrites()
        }
    }
    /** Explicit stop waits for disable+unsubscribe to leave the local GATT queue, with a bounded fallback. */
    private var teardownPending = false
    private val teardownDeadlineMs = 1_000L
    private val teardownDeadlineRunnable = Runnable {
        if (teardownPending) {
            log("Oura: graceful command teardown timed out - closing the link")
            finishTransportStop()
        }
    }

    /** Periodic live-HR re-engage: daytime HR auto-reverts after ~20 s, so while streaming we re-send the
     *  enable+subscribe every ~15 s (OURA_PROTOCOL.md s5.7). The token lets stop() cancel it. */
    private var reengageScheduled = false
    private val reengageIntervalMs = 15_000L
    private val reengageRunnable = object : Runnable {
        override fun run() {
            val d = driver ?: return
            if (d.phase == OuraDriverPhase.Streaming) {
                for (cmd in d.reengageLiveHRCommands()) write(cmd)
            }
            // Removal watchdog (#628): if the live-HR stream has gone silent past the grace window while we
            // keep re-engaging it, the ring came off the finger (there is no "removed" event). Downgrades
            // WORN -> OFF; the tracker never overrides CHARGING. Mirrors the iOS re-engage-tick watchdog.
            lastLivePulseAt?.let { last ->
                if (System.currentTimeMillis() - last > wornPulseTimeoutMs) {
                    wearTracker.noteLivePulseTimeout()
                    publishWearState()
                }
            }
            // Reschedule only while a session is live; stop() clears reengageScheduled + removes callbacks.
            if (reengageScheduled) handler.postDelayed(this, reengageIntervalMs)
        }
    }

    // MARK: - History fetch (GetEvents, s5) - the ONLY path skin temp / SpO2 / HRV / sleep-phase ever
    // arrive by. Neither temp nor SpO2 is ever pushed live on this hardware; both are banked overnight and
    // retrievable only by asking the ring for its history. Kotlin twin of the Swift lane9 history wiring.

    /**
     * Client-managed GetEvents resume cursor, loaded from [OuraHistoryCursorStore] and committed only from
     * the newest stored + UTC-anchored history sample. A 0x11 summary contains `bytes_left`, not a cursor.
     */
    private var historyCursor: Long = 0

    /** Pure, unit-tested byte-progress, envelope-progress, and durable-cursor decisions. */
    private val historyDrain = OuraHistoryDrain()
    /** Cursor used to begin this drain, retained for genuine ring-clock reset detection. */
    private var resumeCursorAtFetchStart: Long = 0
    /** Wall-clock start for the hard drain deadline. */
    private var historyDrainStartedAtMs: Long? = null
    /** Cursor used by the most recent request; a continuation must move strictly beyond it. */
    private var lastHistoryRequestCursor: Long = 0

    private sealed class PendingHistoryDrainAction {
        object ContinueBatch : PendingHistoryDrainAction()
        data class Finish(val completed: Boolean) : PendingHistoryDrainAction()
    }

    /**
     * A 0x11 response may arrive before the last event notifications in its batch. Delay finalization or
     * continuation until no history event has arrived for this window, then use the true newest envelope.
     */
    private var pendingHistoryDrainAction: PendingHistoryDrainAction? = null
    private val historyBatchQuietIntervalMs = 1_500L
    private val historyBatchQuietRunnable = Runnable { continueHistoryDrainAfterQuiet() }
    private val historyPersistence = OuraHistoryPersistenceGate()
    /** Kept across the driver's Streaming transition because a terminal summary is not a packet boundary. */
    private var historyTransportGeneration: Long? = null
    /** A periodic fetch waits until the previous generation is sealed and durable. */
    private var historyRefetchPending = false
    private val historyPersistenceTimeoutMs = 45_000L
    private var historyPersistenceTimeoutRunnable: Runnable? = null

    /**
     * Periodic re-fetch while connected, so an overnight-connected session (or one left open after a nap)
     * picks up freshly-banked sleep data without needing a reconnect. Mirrors the WHOOP ~15 min periodic
     * history-offload floor. Held as a NAMED runnable so [stop]/disconnect can remove it from the handler,
     * matching [reengageRunnable] / [reconnectRunnable].
     */
    private var historyFetchScheduled = false
    private val historyFetchIntervalMs = 900_000L
    private val historyFetchRunnable = object : Runnable {
        override fun run() {
            fetchHistoryIfIdle()
            // Reschedule only while a session is live; stop()/disconnect clears the flag + removes callbacks.
            if (historyFetchScheduled) handler.postDelayed(this, historyFetchIntervalMs)
        }
    }

    /**
     * History-fetched events decoded BEFORE a ring-time -> UTC anchor exists this session, held here (with
     * their own ring timestamp) until the anchor lands ([drainPendingAnchorEvents]), so they get their real
     * historical time instead of a premature wall-clock guess. The ring's 0x42 time-sync can arrive
     * anywhere in a history-fetch stream, not necessarily first, so records that land before it are parked
     * here and re-stamped the moment an anchor lands. At teardown unresolved history is omitted so the
     * unchanged cursor retries it; only a real live push may retain its captured arrival timestamp.
     */
    private data class PendingAnchorEvent(
        val event: OuraEvent,
        val ringTimestamp: Long,
        /** The drain that delivered this record. null means a live push. */
        val historyGeneration: Long?,
        val historyEnvelope: Boolean,
        val liveArrivalTimestamp: Int?,
    )

    private val pendingAnchorEvents = ArrayList<PendingAnchorEvent>()

    /** Bounded 0x49 onset/end-offset windows used to refine a burst from write time to true sleep time. */
    private val recentSleepWindows049 = ArrayList<Triple<Long, Int, Int>>()

    /**
     * Kick a history-fetch pass at the current cursor, but ONLY when the driver is idle-streaming (never
     * overlaps a fetch already in flight - the driver's own phase is the guard, so this is safe to call
     * both right after reaching Streaming and from the periodic timer). Kotlin twin of Swift's
     * `fetchHistoryIfIdle`.
     */
    private fun fetchHistoryIfIdle(): Unit = guardedCallback("history-fetch") {
        val d = driver ?: return@guardedCallback
        if (d.phase != OuraDriverPhase.Streaming) return@guardedCallback
        val priorGeneration = historyTransportGeneration
        if (priorGeneration != null) {
            historyRefetchPending = true
            sealHistoryGenerationForRefetch(priorGeneration)
            return@guardedCallback
        }
        startHistoryFetch()
    }

    private fun startHistoryFetch() {
        val d = driver ?: return
        if (d.phase != OuraDriverPhase.Streaming) return
        resumeCursorAtFetchStart = historyCursor
        historyDrainStartedAtMs = System.currentTimeMillis()
        historyDrain.reset()
        lastHistoryRequestCursor = historyCursor
        pendingHistoryDrainAction = null
        cancelHistoryBatchQuietTimer()
        historyTransportGeneration = beginHistoryPersistenceBarrier()
        log("Oura: fetching history from cursor $historyCursor")
        advance(OuraTransition.StartHistoryFetch(cursor = historyCursor))
    }

    private fun scheduleHistoryFetch() {
        if (historyFetchScheduled) return
        historyFetchScheduled = true
        handler.postDelayed(historyFetchRunnable, historyFetchIntervalMs)
    }

    private fun cancelHistoryFetch() {
        historyFetchScheduled = false
        handler.removeCallbacks(historyFetchRunnable)
    }

    /** Fold a 0x11 byte-progress summary, then wait for the batch's trailing event notifications. */
    private fun handleHistorySummary(summary: com.noop.oura.GetEventsSummary): Unit = guardedCallback("history-summary") {
        val elapsedSeconds = historyDrainStartedAtMs?.let {
            (System.currentTimeMillis() - it).coerceAtLeast(0L) / 1_000.0
        } ?: 0.0
        val continueDrain = historyDrain.onSummary(
            bytesLeft = summary.bytesLeft,
            moreData = summary.moreData,
            elapsedSeconds = elapsedSeconds,
        )
        if (summary.moreData && !continueDrain) {
            val reason = if (elapsedSeconds > OuraHistoryDrain.MAX_DRAIN_SECONDS) {
                "deadline exceeded"
            } else {
                "bytes_left stalled"
            }
            log("Oura: history drain force-stopped - $reason (guard)")
        }
        pendingHistoryDrainAction = if (continueDrain) {
            PendingHistoryDrainAction.ContinueBatch
        } else {
            PendingHistoryDrainAction.Finish(completed = !summary.moreData)
        }
        restartHistoryBatchQuietTimer()
    }

    private fun continueHistoryDrainAfterQuiet(): Unit = guardedCallback("history-batch-quiet") {
        cancelHistoryBatchQuietTimer()
        val action = pendingHistoryDrainAction ?: return@guardedCallback
        pendingHistoryDrainAction = null
        val d = driver ?: return@guardedCallback
        if (d.phase != OuraDriverPhase.FetchingHistory) return@guardedCallback
        when (action) {
            is PendingHistoryDrainAction.Finish -> finishHistoryDrain(action.completed)
            PendingHistoryDrainAction.ContinueBatch -> {
                val next = historyDrain.continuationCursor(lastHistoryRequestCursor)
                if (next == null) {
                    log("Oura: history batch made no cursor progress - stopping drain")
                    finishHistoryDrain(completed = false)
                    return@guardedCallback
                }
                lastHistoryRequestCursor = next
                log("Oura: history batch quiet - continuing from the next record")
                advance(OuraTransition.HistoryCursorAdvanced(cursor = next, moreData = true))
            }
        }
    }

    private fun finishHistoryDrain(completed: Boolean) {
        pendingHistoryDrainAction = null
        cancelHistoryBatchQuietTimer()
        flushPendingHypnogramBurst()
        // Submit the final short batch, but leave this generation open after returning to Streaming. Delayed
        // TLVs remain part of this request until the next actual GetEvents request boundary.
        flush()
        val resolution = historyPersistence.requestFinish(drainCompleted = completed)
        if (resolution != null) {
            finalizeHistoryDrain(resolution, historyPersistence.generation)
        }
        historyDrainStartedAtMs = null
        advance(OuraTransition.HistoryCursorAdvanced(cursor = historyCursor, moreData = false))
    }

    private fun beginHistoryPersistenceBarrier(): Long {
        cancelHistoryPersistenceTimeout()
        return historyPersistence.begin()
    }

    private fun sealHistoryGenerationForRefetch(generation: Long) {
        if (generation != historyPersistence.generation) {
            historyTransportGeneration = null
            historyRefetchPending = false
            startHistoryFetch()
            return
        }
        flushPendingHypnogramBurst()
        flush()
        val resolution = historyPersistence.seal()
        if (resolution != null) {
            finalizeHistoryDrain(resolution, generation)
        } else {
            startHistoryPersistenceTimeout()
        }
    }

    private fun invalidateHistoryPersistenceBarrier() {
        cancelHistoryPersistenceTimeout()
        historyPersistence.invalidate()
        historyTransportGeneration = null
        historyRefetchPending = false
    }

    private fun registerHistoryWrite(
        generation: Long,
        ringTimestamps: List<Long>,
        start: ((Boolean) -> Unit) -> Unit,
    ) {
        val registered =
            ringTimestamps.isNotEmpty() && historyPersistence.register(generation)
        val delivered = AtomicBoolean(false)
        val completion: (Boolean) -> Unit = { succeeded ->
            if (delivered.compareAndSet(false, true)) {
                handler.post {
                    if (registered) {
                        historyWriteCompleted(
                            generation = generation,
                            ringTimestamps = ringTimestamps,
                            succeeded = succeeded,
                        )
                    } else if (!succeeded) {
                        log("Oura: stale-generation persistence failed; the record remains retryable")
                    }
                }
            }
        }
        runCatching { start(completion) }
            .onFailure { completion(false) }
        if (registered) startHistoryPersistenceTimeout()
    }

    private fun historyWriteCompleted(
        generation: Long,
        ringTimestamps: List<Long>,
        succeeded: Boolean,
    ) {
        val result = historyPersistence.completeWrite(generation, succeeded)
        if (!result.accepted) return
        if (succeeded) ringTimestamps.forEach(::noteStoredHistoryRingTime)
        result.resolution?.let { finalizeHistoryDrain(it, generation) }
    }

    private fun finalizeHistoryDrain(
        resolution: OuraHistoryPersistenceGate.Resolution,
        generation: Long,
    ) {
        cancelHistoryPersistenceTimeout()
        if (resolution.allWritesSucceeded) {
            commitHistoryResumeCursor(resolution.drainCompleted)
        } else {
            log("Oura: history persistence failed - keeping resume cursor $historyCursor for a safe retry")
        }
        historyDrainStartedAtMs = null
        if (historyTransportGeneration == generation) historyTransportGeneration = null
        if (historyRefetchPending) {
            historyRefetchPending = false
            startHistoryFetch()
        }
    }

    private fun startHistoryPersistenceTimeout() {
        if (!historyPersistence.shouldStartTimeout || historyPersistenceTimeoutRunnable != null) return
        val generation = historyPersistence.generation
        val runnable = Runnable {
            historyPersistenceTimeoutRunnable = null
            val outstanding = historyPersistence.pendingWriteCount
            if (historyPersistence.timeOut(generation)) {
                log(
                    "Oura: history persistence timed out with $outstanding write(s) pending - " +
                        "keeping resume cursor $historyCursor",
                )
                historyDrainStartedAtMs = null
                if (historyTransportGeneration == generation) historyTransportGeneration = null
                if (historyRefetchPending) {
                    historyRefetchPending = false
                    startHistoryFetch()
                }
            }
        }
        historyPersistenceTimeoutRunnable = runnable
        handler.postDelayed(runnable, historyPersistenceTimeoutMs)
    }

    private fun cancelHistoryPersistenceTimeout() {
        historyPersistenceTimeoutRunnable?.let(handler::removeCallbacks)
        historyPersistenceTimeoutRunnable = null
    }

    private fun commitHistoryResumeCursor(completed: Boolean) {
        val how = if (completed) "caught up" else "stopped early"
        val candidate = historyDrain.maxStoredRingTime
        val resolves = candidate > 0 && driver?.unixSeconds(forRingTimestamp = candidate) != null
        val newCursor = historyDrain.resumeCursorAtDrainEnd(
            currentCursor = historyCursor,
            resolvesUnderAnchor = resolves,
        )
        when {
            historyDrain.sawPreResumeData -> {
                historyCursor = 0
                OuraHistoryCursorStore.save(appContext, deviceId, 0)
                log("Oura: history $how but the ring served data older than the requested cursor; next connect does a full pull")
            }
            newCursor != historyCursor -> {
                historyCursor = newCursor
                OuraHistoryCursorStore.save(appContext, deviceId, newCursor)
                log("Oura: history $how - resume cursor advanced from stored samples")
            }
            candidate > historyCursor -> {
                log("Oura: history $how but the stored resume candidate has no current time anchor; cursor unchanged")
            }
            else -> log("Oura: history $how (resume cursor unchanged)")
        }
    }

    private fun restartHistoryBatchQuietTimer() {
        handler.removeCallbacks(historyBatchQuietRunnable)
        handler.postDelayed(historyBatchQuietRunnable, historyBatchQuietIntervalMs)
    }

    private fun cancelHistoryBatchQuietTimer() {
        handler.removeCallbacks(historyBatchQuietRunnable)
    }

    private fun resetHistoryDrainState() {
        cancelHistoryBatchQuietTimer()
        invalidateHistoryPersistenceBarrier()
        pendingHistoryDrainAction = null
        historyDrain.reset()
        resumeCursorAtFetchStart = 0
        historyDrainStartedAtMs = null
        lastHistoryRequestCursor = 0
    }

    private fun closestSleepWindow049(
        ringTimestamp: Long,
        tolerance: Long = 6_000L,
    ): Triple<Long, Int, Int>? {
        var closest: Triple<Long, Int, Int>? = null
        var closestGap = Long.MAX_VALUE
        for (window in recentSleepWindows049) {
            val gap = if (window.first >= ringTimestamp) {
                window.first - ringTimestamp
            } else {
                ringTimestamp - window.first
            }
            if (gap <= tolerance && gap < closestGap) {
                closest = window
                closestGap = gap
            }
        }
        return closest
    }

    /**
     * Persist a closed burst on its reconstructed time axis. All-FF pages are gaps, not Awake, and every
     * written phase receives a distinct event key. The same sequence is upserted as a ring-provided night
     * so normal sleep consumers can display its stage breakdown.
     */
    private fun persistHypnogramBurst(
        burst: OuraHypnogramBurst,
        historyGeneration: Long?,
    ) {
        val d = driver ?: return
        if (burst.totalCodes <= 0) return
        val writeEnd: Long = d.unixSeconds(forRingTimestamp = burst.lastRingTimestamp) ?: run {
            pendingUnanchoredBursts.add(PendingUnanchoredBurst(burst, historyGeneration))
            log("Oura: hypnogram burst held until the time anchor arrives")
            return
        }

        var end: Long = writeEnd
        var sleepStart: Long? = null
        closestSleepWindow049(burst.lastRingTimestamp)?.let { window ->
            d.unixSeconds(forRingTimestamp = window.first)?.let { eventUtc ->
                val candidateEnd = eventUtc - window.third * 60L
                if (candidateEnd <= writeEnd && writeEnd - candidateEnd < 6L * 3_600L) {
                    end = candidateEnd
                }
                val candidateStart = eventUtc - window.second * 60L
                if (candidateStart < end && end - candidateStart < 16L * 3_600L) {
                    sleepStart = candidateStart
                }
            }
        }

        if (burst.hasNonMonotonicRingTimes) {
            log("Oura: hypnogram burst has non-monotonic envelope times; preserving event-log arrival order")
        }
        val laid = burst.codesWithTimes(
            endUnixSeconds = end,
            sleepStartUnixSeconds = sleepStart,
        )
        if (laid.isEmpty()) {
            log("Oura: hypnogram burst entirely unwritten (0xFF); no awake stages or blank session persisted")
            return
        }

        val historyRingTimestamps = burst.records.map { it.ringTimestamp }
        val acknowledgedRingTimestamps =
            if (historyGeneration == null) emptyList() else historyRingTimestamps
        enqueueBatches(
            batches = laid.map {
                listOf<OuraEvent>(OuraEvent.SleepPhaseEvent(it.phase)) to it.ts.toInt()
            },
            historyRingTimestamps = acknowledgedRingTimestamps,
            historyGeneration = historyGeneration,
        )
        OuraSleepSessionMapping.session(laid.map { it.ts to it.phase.stage })?.let {
            if (historyGeneration != null) {
                registerHistoryWrite(
                    generation = historyGeneration,
                    ringTimestamps = historyRingTimestamps,
                ) { done ->
                    persistSleepSession(it, deviceId, done)
                }
            } else {
                runCatching {
                    persistSleepSession(it, deviceId) { succeeded ->
                        if (!succeeded) handler.post {
                            log("Oura: sleep-session persistence failed; the night will retry from history")
                        }
                    }
                }.onFailure {
                    log("Oura: sleep-session persistence failed (${it.javaClass.simpleName})")
                }
            }
        }
        val preservedGaps = laid.size < burst.totalCodes
        log(
            if (preservedGaps) {
                "Oura: hypnogram reconstructed with erased/pre-onset gaps preserved"
            } else {
                "Oura: hypnogram reconstructed"
            },
        )
    }

    private fun flushPendingHypnogramBurst() {
        val receipt = hypnogramReceiptTracker.takeForFlush()
        val burst = hypnogramAssembler.flush() ?: return
        persistHypnogramBurst(burst, receipt?.historyGeneration)
    }

    private fun ingestHypnogramRecord(
        ringTimestamp: Long,
        phases: List<OuraSleepPhase>,
        historyGeneration: Long?,
    ) {
        val priorReceipt = hypnogramReceiptTracker.rotate(historyGeneration)
        if (priorReceipt != null) {
            hypnogramAssembler.flush()?.let {
                persistHypnogramBurst(it, priorReceipt.historyGeneration)
            }
        }
        hypnogramAssembler.feed(ringTimestamp, phases)?.let {
            persistHypnogramBurst(it, historyGeneration)
        }
    }

    private fun drainPendingHypnogramBursts() {
        if (pendingUnanchoredBursts.isEmpty()) return
        val pending = pendingUnanchoredBursts.toList()
        pendingUnanchoredBursts.clear()
        pending.forEach { persistHypnogramBurst(it.burst, it.historyGeneration) }
    }

    private fun dropUnanchoredHypnogramBursts() {
        if (pendingUnanchoredBursts.isEmpty()) return
        // No stored-sample high-water mark was advanced for these bursts, so a future anchored fetch can
        // safely serve them again without mutating the durable cursor here.
        log("Oura: dropping unanchored hypnogram burst; cursor was not advanced")
        pendingUnanchoredBursts.clear()
    }

    /** Record a history sample only after it was placed on a real ring-time-derived UTC timestamp. */
    private fun noteStoredHistoryRingTime(ringTimestamp: Long) {
        historyDrain.noteStoredRingTime(ringTimestamp, resumeCursorAtFetchStart)
    }

    // MARK: - Sample buffer (flushed in batches off the per-notification hot loop)

    /**
     * One buffered batch of decoded events, stamped with its own [ts] (unix seconds): genuinely-live
     * pushes (HR, battery) are stamped at wall-clock arrival time; ring-time-carrying events (IBI, temp,
     * SpO2, HRV, sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) when an anchor is available,
     * so last night's data is never mis-recorded as happening right now. Mirrors the Swift buffer
     * `(events, ts)`. [flush] folds each batch through the unit-tested [OuraStreamMapping] so the SAME pure
     * mapping the tests pin is the production path.
     */
    private data class HistoryWriteReceipt(
        val generation: Long,
        val ringTimestamps: List<Long>,
    )

    private data class Batch(
        val events: List<OuraEvent>,
        val ts: Int,
        val historyReceipt: HistoryWriteReceipt?,
    )

    private val bufferLock = Any()
    private val buffer = ArrayList<Batch>()
    private var lastFlushMs = System.currentTimeMillis()
    private val flushCount = 30
    private val flushIntervalMs = 30_000L

    // MARK: - Scanning

    /** Begin scanning for Oura rings advertising the ring's base service. */
    override fun scan() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { scan() }
            return
        }
        seen.clear()
        _discovered.value = emptyList()
        _scanning.value = true
        _needsPairing.value = null
        log("Oura: scanning for an Oura ring (${ringGen.displayName})…")
        val sc = scanner ?: run {
            _scanning.value = false
            log("Oura: no BLE scanner available - Bluetooth may be off or unsupported")
            return
        }
        if (adapter?.isEnabled != true) {
            _scanning.value = false
            log("Oura: Bluetooth adapter is off - cannot scan")
            return
        }
        // Filter by the ring's base service so a broad scan does not surface unrelated peripherals; the
        // callback further confirms the advertised name reads as an Oura ring.
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        sc.startScan(listOf(filter), settings, scanCallback)
    }

    /** Stop an in-progress scan. Idempotent. */
    fun stopScan() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { stopScan() }
            return
        }
        _scanning.value = false
        if (adapter?.isEnabled == true) runCatching { scanner?.stopScan(scanCallback) }
    }

    // MARK: - Connecting

    /** Connect to the chosen discovered ring (by address) and start the auth → enable → stream flow. */
    override fun connect(address: String) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { connect(address) }
            return
        }
        stopScan()
        _needsPairing.value = null
        // Remember the paired ring so an involuntary drop auto-reconnects to it (#912). An explicit connect
        // is never the intentional-teardown case, so clear the suppression flag.
        reconnectAddress = address
        intentionalDisconnect = false
        val device = seen[address] ?: runCatching { adapter?.getRemoteDevice(address) }.getOrNull()
        if (device == null) { pendingConnectAddress = address; return }
        connectToDevice(device)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { connectToDevice(device) }
            return
        }
        lastDevice = device   // remembered so a status-133 disconnect can auto-retry the same ring
        log("Oura: connecting to ${device.address}")
        // Tear down any prior link first so we never run two GATTs for this source.
        val previousGatt = gatt
        gatt = null
        resetCommandTransport()
        previousGatt?.let { runCatching { it.disconnect(); it.close() } }
        // A fresh driver per connection: the app key is session-scoped (the proof handshake re-runs on
        // every connection), and a key provisioned since the last attempt is picked up here. allowKeyInstall
        // is wired straight from the connection's adoptIntent so the dangerous 0x24 write is reachable ONLY
        // under an explicit adopt consent (OURA_PROTOCOL.md s3.2).
        // allowTierB = true - INVESTIGATION ONLY (activity/real_steps/sleep-summary/smoothed-SpO2 tags,
        // OURA_PROTOCOL.md s7.3 Tier B, UNVERIFIED layouts; PR #960). This lets `emit` LOG what the ring
        // actually sends (raw bytes per kind, decoded MET for 0x50) so the layouts can be validated
        // against real captures. It can never leak a value into scoring: OuraStreamMapping drops
        // TierB/ActivityInfo unconditionally - the Tier-discipline gate that matters lives there, not here.
        driver = OuraDriver(ringGen = ringGen, authKey = authKey(), allowTierB = true,
                            allowKeyInstall = adoptIntent)
        reassembler.reset()
        pendingInstallKey = null       // a new connection starts with no install in flight
        _adoptPhase.value = AdoptPhase.Idle   // a stale outcome must never drive the wizard's transition
        resetWear()   // #628: fresh session — clear any stale worn/charging badge
        // A fresh session: reset the one-shot streaming/anchor state, and never replay a stale-anchor guess.
        reachedStreaming = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.clear()
        loggedFeatureStatuses.clear()
        handledProductInfo.clear()
        pendingAnchorEvents.clear()
        hypnogramAssembler.reset()
        hypnogramReceiptTracker.reset()
        pendingUnanchoredBursts.clear()
        recentSleepWindows049.clear()
        resetHistoryDrainState()
        // Resume the GetEvents cursor from where the LAST connection to this ring left off (s5.1/5.3), so a
        // routine reconnect doesn't re-fetch the ring's entire banked history every time. Values beyond
        // the plausible ring-time ceiling are pre-fix byte-count/misframe garbage and must not starve sync.
        val loadedHistoryCursor = OuraHistoryCursorStore.read(appContext, deviceId)
        historyCursor = OuraHistoryDrain.sanitizeLoadedCursor(loadedHistoryCursor)
        if (historyCursor != loadedHistoryCursor) {
            log("Oura: persisted resume cursor was implausible (pre-fix garbage) - full pull")
            OuraHistoryCursorStore.save(appContext, deviceId, 0)
        }
        // connectGatt can throw (SecurityException if BLUETOOTH_CONNECT was revoked mid-session,
        // IllegalArgumentException on a stale device) - never let that crash the app; a failed start
        // simply leaves the previous source in place (mirrors [StandardHrSource]).
        gatt = runCatching {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                device.connectGatt(appContext, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
            } else {
                @Suppress("DEPRECATION")
                device.connectGatt(appContext, false, gattCallback)
            }
        }.getOrElse {
            log("Oura: connectGatt failed (${it.javaClass.simpleName}: ${it.message})")
            null
        }
    }

    /** Tear down: cancel the connection and stop scanning, persisting anything still buffered. Idempotent. */
    override fun stop() {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { stop() }
            return
        }
        if (teardownPending) return
        // A deliberate teardown (device switch / removal) must NOT auto-reconnect: mark it intentional and
        // drop the reconnect target so any pending backoff bails and no fresh one is scheduled (#912). Remove
        // any already-posted reconnect from the main-looper handler too, so it isn't retained for the full
        // backoff (mirrors cancelReengage's removeCallbacks).
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        handler.removeCallbacks(reconnectRunnable)
        handler.removeCallbacks(retry133Runnable)
        stopScan()
        pendingConnectAddress = null
        cancelReengage()
        cancelHistoryFetch()
        cancelHistoryBatchQuietTimer()
        pendingHistoryDrainAction = null
        // Close the phase burst and drain parked samples before driver.stop() clears its time anchor.
        flushPendingHypnogramBurst()
        drainPendingAnchorEvents(dropUnresolvedHistory = true)
        dropUnanchoredHypnogramBursts()
        flush()
        // Teardown deliberately drops unresolved history above. Invalidate immediately so a Room callback
        // from the final flush cannot advance the cursor past those omitted records or start another fetch
        // while the live-HR shutdown commands are still draining.
        invalidateHistoryPersistenceBarrier()
        _batteryPct.value = null
        resetWear()

        if (OuraLivePublication.requiresLiveHrShutdown(reachedStreaming, driver?.phase) &&
            gatt != null && writeChar != null
        ) {
            beginCompletionAwareTeardown()
            return
        }
        finishTransportStop()
    }

    private fun beginCompletionAwareTeardown() {
        if (teardownPending) return
        teardownPending = true
        commandWrites.replacePendingForTeardown(
            listOf(OuraCommands.liveHRDisable(), OuraCommands.liveHRUnsubscribe()),
        )
        handler.removeCallbacks(teardownDeadlineRunnable)
        handler.postDelayed(teardownDeadlineRunnable, teardownDeadlineMs)
        drainCommandWrites()
    }

    /** Final transport close shared by the graceful drain and its bounded timeout fallback. */
    private fun finishTransportStop() {
        handler.removeCallbacks(teardownDeadlineRunnable)
        handler.removeCallbacks(commandPaceRunnable)
        commandWrites.reset()
        teardownPending = false
        driver?.stop()
        val closingGatt = gatt
        gatt = null
        closingGatt?.let { runCatching { it.disconnect(); it.close() } }
        writeChar = null
        notifyChar = null
        reassembler.reset()
        loggedFirstHr = false
        loggedFirstTemp = false
        loggedFirstSpo2 = false
        loggedAnchor = false
        loggedTierBKinds.clear()
        loggedFeatureStatuses.clear()
        handledProductInfo.clear()
        hypnogramAssembler.reset()
        hypnogramReceiptTracker.reset()
        recentSleepWindows049.clear()
        reachedStreaming = false
        resetHistoryDrainState()
        if (_adoptPhase.value == AdoptPhase.InstallingKey) _adoptPhase.value = AdoptPhase.Failed
        pendingInstallKey = null
        _batteryPct.value = null
        resetWear()
    }

    // MARK: - Buffer / persistence

    /** Buffer one batch of decoded events under the supplied [ts] (unix seconds: wall-clock for live
     *  pushes, ring-time-anchored for history-fetched records), flushing on count/interval. Mirrors the
     *  Swift `enqueue(_ events:ts:)`. */
    private fun enqueue(
        events: List<OuraEvent>,
        ts: Int,
        historyRingTimestamps: List<Long> = emptyList(),
        historyGeneration: Long? = null,
    ) {
        enqueueBatches(
            batches = listOf(events to ts),
            historyRingTimestamps = historyRingTimestamps,
            historyGeneration = historyGeneration,
        )
    }

    /**
     * Append a logically related set in one operation so a full hypnogram cannot hit [flushCount] every
     * 30 stages while its remaining rows are still being reconstructed.
     */
    private fun enqueueBatches(
        batches: List<Pair<List<OuraEvent>, Int>>,
        historyRingTimestamps: List<Long> = emptyList(),
        historyGeneration: Long? = null,
    ) {
        val nonEmpty = batches.filter { it.first.isNotEmpty() }
        if (nonEmpty.isEmpty()) return
        val receipt = if (historyRingTimestamps.isEmpty()) {
            null
        } else {
            HistoryWriteReceipt(
                generation = historyGeneration ?: historyPersistence.generation,
                ringTimestamps = historyRingTimestamps,
            )
        }
        val shouldFlush = synchronized(bufferLock) {
            nonEmpty.forEach { (events, ts) -> buffer.add(Batch(events, ts, receipt)) }
            buffer.size >= flushCount ||
                System.currentTimeMillis() - lastFlushMs >= flushIntervalMs ||
                (receipt != null && historyPersistence.requestedFinish != null)
        }
        if (shouldFlush) flush()
    }

    private fun flush() {
        val snapshot: List<Batch>
        synchronized(bufferLock) {
            lastFlushMs = System.currentTimeMillis()
            if (buffer.isEmpty()) return
            snapshot = ArrayList(buffer); buffer.clear()
        }
        data class GroupKey(val generation: Long?, val isHistory: Boolean)

        val grouped = LinkedHashMap<GroupKey, MutableList<Batch>>()
        for (batch in snapshot) {
            val key = GroupKey(
                generation = batch.historyReceipt?.generation,
                isHistory = batch.historyReceipt != null,
            )
            grouped.getOrPut(key) { ArrayList() }.add(batch)
        }
        // Map each entry with its own timestamp, then combine every persistence generation into one Room
        // transaction. This changes transaction count only; row values and event order remain identical.
        for ((key, batches) in grouped) {
            val streams = OuraStreamMapping.mergedStreams(
                batches.map { it.events to it.ts },
            )
            val out = StreamPersistence.toBatch(streams)
            if (out.hr.isNotEmpty() || out.rr.isNotEmpty() || out.spo2.isNotEmpty() ||
                out.skinTemp.isNotEmpty() || out.events.isNotEmpty() || out.battery.isNotEmpty()
            ) {
                if (key.isHistory && key.generation != null) {
                    val ringTimestamps = batches
                        .flatMap { it.historyReceipt?.ringTimestamps ?: emptyList() }
                        .distinct()
                    registerHistoryWrite(
                        generation = key.generation,
                        ringTimestamps = ringTimestamps,
                    ) { done ->
                        persist(out, deviceId, done)
                    }
                } else {
                    runCatching {
                        persist(out, deviceId) { succeeded ->
                            if (!succeeded) handler.post {
                                log("Oura: live persistence failed; the sample was not stored")
                            }
                        }
                    }.onFailure {
                        log("Oura: live persistence failed (${it.javaClass.simpleName})")
                    }
                }
            }
        }
    }

    /** Persist resolved entries. Unresolved history is omitted at teardown so the cursor retries it. */
    private fun drainPendingAnchorEvents(
        dropUnresolvedHistory: Boolean = false,
    ): Unit = guardedCallback("drain-pending") {
        if (pendingAnchorEvents.isEmpty()) return@guardedCallback
        val d = driver ?: return@guardedCallback

        data class PendingBatchKey(
            val ts: Int,
            val historyGeneration: Long?,
            val historyEnvelope: Boolean,
        )

        val grouped = LinkedHashMap<PendingBatchKey, MutableList<PendingAnchorEvent>>()
        val retained = ArrayList<PendingAnchorEvent>()
        var droppedHistoryCount = 0
        for (pending in pendingAnchorEvents) {
            val anchored = d.unixSeconds(forRingTimestamp = pending.ringTimestamp)
            val key = if (anchored != null) {
                PendingBatchKey(
                    anchored.toInt(),
                    pending.historyGeneration,
                    pending.historyEnvelope,
                )
            } else {
                val fallback = OuraPendingAnchorPolicy.fallbackTimestamp(
                    pending.historyEnvelope,
                    pending.liveArrivalTimestamp,
                )
                when {
                    fallback != null -> PendingBatchKey(fallback, null, false)
                    dropUnresolvedHistory -> {
                        droppedHistoryCount += 1
                        continue
                    }
                    else -> {
                        retained.add(pending)
                        continue
                    }
                }
            }
            grouped.getOrPut(key) { ArrayList() }.add(pending)
        }
        for ((key, pending) in grouped) {
            val queuedEvents = pending.map { it.event }
            val persistenceEvents = if (key.historyEnvelope) {
                OuraIbiHr.appendingDerivedHrToHistoryEvents(queuedEvents)
            } else {
                queuedEvents
            }
            enqueue(
                events = persistenceEvents,
                ts = key.ts,
                historyRingTimestamps = if (key.historyGeneration == null) {
                    emptyList()
                } else {
                    pending.map { it.ringTimestamp }
                },
                historyGeneration = key.historyGeneration,
            )
        }
        pendingAnchorEvents.clear()
        pendingAnchorEvents.addAll(retained)
        if (droppedHistoryCount > 0) {
            log("Oura: omitted $droppedHistoryCount unanchored history sample(s); the cursor remains behind for retry")
        }
    }

    // MARK: - Scan callback

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = onMainCallback("scan-result") {
            val device = result.device ?: return@onMainCallback
            val address = device.address ?: return@onMainCallback
            val name = result.scanRecord?.deviceName ?: runCatching { device.name }.getOrNull() ?: ""
            // Confirm the advertised name reads as an Oura ring (the service filter is the primary gate;
            // this rejects anything that slipped through advertising the same base service).
            if (ExperimentalBrand.recognise(name) != ExperimentalBrand.OURA) return@onMainCallback
            val firstSight = seen.put(address, device) == null   // null → not seen before this scan
            if (firstSight) log("Oura: found $name ($address) rssi ${result.rssi}")
            // Best-effort generation guess from the advertised name (confirmed by the model the user picks).
            val detectedGen = OuraRingGen.recognise(name)
            val ring = DiscoveredRing(
                address = address,
                name = name.ifBlank { "Oura" },
                rssi = result.rssi,
                detectedGen = detectedGen,
            )
            val list = _discovered.value.toMutableList()
            val i = list.indexOfFirst { it.address == address }
            if (i >= 0) list[i] = ring else list.add(ring)
            _discovered.value = list
            // Replay a connect intent that arrived before the ring was discovered.
            if (pendingConnectAddress == address) {
                pendingConnectAddress = null
                // onMainCallback already owns the main looper. Connect inline so stop() cannot clear the
                // intent between this check and a separately queued connect that would resurrect the source.
                connectToDevice(device)
            }
        }
    }

    // MARK: - GATT callback

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) =
            onMainCallback("connection-state") {
            if (!callbackBelongsToCurrentGatt(g, "connection-state")) return@onMainCallback
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (status != BluetoothGatt.GATT_SUCCESS) {
                        log("Oura: WARNING connected with non-success status=$status")
                    }
                    retried133 = false   // a real connection clears the one-shot 133 retry guard
                    failedReconnectAttempts = 0   // a real connection clears the reconnect backoff (#912)
                    log("Oura: connected (status=$status) - discovering services")
                    g.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    log("Oura: disconnected (status=$status)")
                    loggedFirstHr = false   // a reconnect should log its first sample again
                    _batteryPct.value = null
                    resetWear()             // #628: the wear badge must not survive the link dropping
                    cancelReengage()
                    cancelHistoryFetch()
                    cancelHistoryBatchQuietTimer()
                    pendingHistoryDrainAction = null
                    // Close the phase burst and drain parked samples while this session's anchor exists.
                    flushPendingHypnogramBurst()
                    drainPendingAnchorEvents(dropUnresolvedHistory = true)
                    dropUnanchoredHypnogramBursts()
                    flush()
                    reassembler.reset()
                    loggedFirstTemp = false
                    loggedFirstSpo2 = false
                    loggedAnchor = false
                    loggedTierBKinds.clear()
                    loggedFeatureStatuses.clear()
                    handledProductInfo.clear()
                    hypnogramAssembler.reset()
                    hypnogramReceiptTracker.reset()
                    recentSleepWindows049.clear()
                    reachedStreaming = false
                    resetHistoryDrainState()
                    // A disconnect MID-install is an honest failure (no 0x25 ack will arrive); a disconnect
                    // after streaming leaves the completed Streaming outcome intact. Drop any in-flight key
                    // WITHOUT persisting it (a failed install must never leave a wrongly-trusted key).
                    if (_adoptPhase.value == AdoptPhase.InstallingKey) _adoptPhase.value = AdoptPhase.Failed
                    pendingInstallKey = null
                    resetCommandTransport()
                    runCatching { g.close() }
                    gatt = null
                    // Hardening: status 133 is Android's infamous generic GATT_ERROR on connect - almost
                    // always transient. Auto-retry ONCE (immediately, 1s) before falling through to the
                    // general capped-backoff auto-reconnect below.
                    if (status == GATT_ERROR_133 && !retried133 && lastDevice != null && !intentionalDisconnect) {
                        retried133 = true
                        log("Oura: connect error 133 - retrying once in 1s")
                        handler.postDelayed(retry133Runnable, 1000)
                        return@onMainCallback   // the one-shot 133 retry owns the reconnect for this drop
                    }
                    if (status == GATT_ERROR_133 && retried133) {
                        log("Oura: still failing (133) - try forgetting the ring in Android " +
                            "Settings → Bluetooth, then re-pair.")
                        // Fall through to the capped-backoff reconnect so a transient 133 storm still recovers
                        // on its own once the ring settles, rather than giving up until a manual reconnect.
                    }
                    // Auto-reconnect on an INVOLUNTARY drop / failed connect (#912): the paired ring went out
                    // of range or the link dropped. Re-issue a connect on the capped backoff so it comes back
                    // on its own, exactly like the WHOOP strap. A deliberate stop() set intentionalDisconnect
                    // and cleared reconnectAddress, so this is a no-op there; a needs-pairing dead-end also
                    // suppressed it. This owns its OWN scan/GATT and never touches the WHOOP path.
                    scheduleReconnect()
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = onMainCallback("services-discovered") {
            if (!callbackBelongsToCurrentGatt(g, "services-discovered")) return@onMainCallback
            log("Oura: services discovered (status=$status)")
            if (status != BluetoothGatt.GATT_SUCCESS) {
                log("Oura: WARNING service discovery failed (status=$status) - giving up on this ring")
                return@onMainCallback
            }
            // Request the gen-appropriate MTU (gen3=203, gen4/5=247) so multi-record notifications and
            // the auth proof fit. The flow continues from onMtuChanged (or falls through if it fails).
            log("Oura: requesting MTU ${ringGen.mtu}")
            val requested = runCatching { g.requestMtu(ringGen.mtu) }.getOrDefault(false)
            if (!requested) {
                // Some stacks reject requestMtu; proceed at the default MTU rather than stall.
                log("Oura: MTU request not accepted - proceeding at default MTU")
                setUpNotifications(g)
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = onMainCallback("mtu-changed") {
            if (!callbackBelongsToCurrentGatt(g, "mtu-changed")) return@onMainCallback
            log("Oura: MTU negotiated = $mtu (status=$status)")
            setUpNotifications(g)
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) = onMainCallback("descriptor-write") {
            if (!callbackBelongsToCurrentGatt(g, "descriptor-write")) return@onMainCallback
            if (descriptor.uuid != CCCD) return@onMainCallback
            if (status == BluetoothGatt.GATT_SUCCESS) {
                log("Oura: notifications enabled (CCCD write status=$status) - beginning auth")
                // Notifications are live: tell the driver we are Ready. It returns the enable-notify +
                // get-nonce commands (or drives the honest needs-pairing path when there is no app key).
                advance(OuraTransition.Ready)
            } else {
                log("Oura: WARNING CCCD write FAILED (status=$status) - ring will send no data")
                announceNeedsPairing(KEY_INSTALL_MESSAGE)
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            ch: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            val copied = value.copyOf()
            onMainCallback("characteristic-changed") {
                if (!callbackBelongsToCurrentGatt(g, "characteristic-changed")) return@onMainCallback
                if (!teardownPending && ch.uuid == NOTIFY_UUID) handleNotification(copied)
            }
        }

        // Legacy (< API 33) characteristic-changed callback: read the value off the characteristic.
        @Deprecated("Deprecated in Java")
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            val copied = ch.value?.copyOf() ?: return
            onMainCallback("characteristic-changed") {
                if (!callbackBelongsToCurrentGatt(g, "characteristic-changed")) return@onMainCallback
                if (!teardownPending && ch.uuid == NOTIFY_UUID) handleNotification(copied)
            }
        }
    }

    /** Resolve the write/notify characteristics, enable notifications on ...0003, and write the CCCD.
     *  The auth flow begins from onDescriptorWrite once the CCCD write is acknowledged. */
    private fun setUpNotifications(g: BluetoothGatt) = guardedCallback("setup-notify") {
        val svc = g.getService(SERVICE_UUID)
        if (svc == null) {
            log("Oura: base service NOT FOUND - this peripheral is not a supported Oura ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        writeChar = svc.getCharacteristic(WRITE_UUID)
        notifyChar = svc.getCharacteristic(NOTIFY_UUID)
        val notify = notifyChar
        if (writeChar == null || notify == null) {
            log("Oura: write/notify characteristics NOT FOUND - cannot drive the ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        log("Oura: write + notify characteristics found - enabling notifications on the notify char")
        g.setCharacteristicNotification(notify, true)
        val cccd = notify.getDescriptor(CCCD)
        if (cccd == null) {
            log("Oura: WARNING notify char has no CCCD (0x2902) - cannot enable notifications")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val rc = g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
            log("Oura: CCCD write requested (rc=$rc)")
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                val ok = g.writeDescriptor(cccd)
                log("Oura: CCCD write requested (rc=$ok)")
            }
        }
    }

    // MARK: - Driver flow

    /** Feed a transport transition to the driver and write back the commands it returns. After the
     *  enable triplet completes the driver reports Streaming; we then begin the periodic re-engage. */
    private fun advance(transition: OuraTransition) = guardedCallback("advance") {
        val d = driver ?: return@guardedCallback
        val commands = d.nextStep(transition)
        for (cmd in commands) write(cmd)
        when (d.phase) {
            OuraDriverPhase.Streaming -> {
                // The driver returns to Streaming after EACH history-fetch pass completes, so gate all the
                // one-shot streaming work on reachedStreaming (twin of Swift's `if !reachedStreaming`) - it
                // must run exactly once per connection, not on every history summary.
                if (!reachedStreaming) {
                    reachedStreaming = true
                    // Re-auth after an install (or a normal auth) reached the stream: adoption is complete.
                    // The OK ack already persisted the key; nothing is left in flight.
                    _adoptPhase.value = AdoptPhase.Streaming
                    pendingInstallKey = null
                    log("Oura: live HR enabled - streaming")
                    scheduleReengage()
                    // Establish clock and hardware identity before the first history request. A short
                    // resume drain may contain no 0x42 anchor, and advertised names can contain serial
                    // digits that are not generation evidence.
                    write(OuraCommands.syncTime(System.currentTimeMillis() / 1000L))
                    write(OuraCommands.getProductSerial())
                    write(OuraCommands.getProductHardware())
                    // Pull last night's banked temp/SpO2/HRV/sleep-phase right away + keep a periodic pass
                    // running, and ask for battery once (the 0x0D reply routes to onBattery).
                    scheduleHistoryFetch()
                    fetchHistoryIfIdle()
                    write(OuraCommands.getBattery())
                    // Read-only diagnostic: ask the ring its SpO2 / real-steps feature status once, so a
                    // capture confirms (from the ring itself) that these server-flag features are
                    // subscription-gated OFF for an offline ring. NEVER an enable/set-mode write.
                    write(OuraCommands.spo2ReadStatus())
                    write(OuraCommands.realStepsReadStatus())
                }
            }
            OuraDriverPhase.NeedsKeyInstall -> {
                // Factory-reset ring (auth status 0x02) or no key. The dangerous key install is the ONLY
                // thing that recovers it, and ONLY with explicit adopt consent: provision when adoptIntent,
                // otherwise stay honest and never loop the dangerous command.
                if (adoptIntent) provisionKeyInstall(d) else announceNeedsPairing(KEY_INSTALL_MESSAGE)
            }
            is OuraDriverPhase.AuthFailed -> {
                log("Oura: auth failed - the stored install key does not match this ring")
                announceNeedsPairing(AUTH_FAILED_MESSAGE)
            }
            else -> Unit
        }
    }

    // MARK: - Adopt key-install handshake (s3.2) - ONLY ever reached with explicit adopt consent

    /**
     * PROVISION a fresh key into a factory-reset ring (OURA_PROTOCOL.md s3.2). Reached ONLY from [advance]
     * when the driver phase is NeedsKeyInstall AND [adoptIntent] is true. Steps:
     *   1. generate a fresh cryptographically-random 16-byte key;
     *   2. ask the driver for the dangerous `24 10 <key>` install command (the driver's own
     *      `allowKeyInstall`/phase gate is the second guard) and write it;
     *   3. hold the key in memory and mark [AdoptPhase.InstallingKey] (an install IS now running).
     * The key is NOT persisted yet: it is written to the keystore only once the ring acks OK
     * ([handleKeyInstallAck]), so a failed install never leaves a key the next session would wrongly trust.
     * On any RNG/build failure we stay honest (announceNeedsPairing) and never retry the dangerous command.
     * Kotlin twin of Swift's `provisionKeyInstall`.
     */
    private fun provisionKeyInstall(d: OuraDriver) = guardedCallback("provision-key") {
        if (!adoptIntent) return@guardedCallback             // belt-and-braces: never provision without consent
        if (pendingInstallKey != null) return@guardedCallback // an install is already in flight; don't double-send
        val key = runCatching { randomKey() }.getOrNull()
        if (key == null || key.size != OuraAuth.keyLength || key.any { it !in 0..255 }) {
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        val cmd = d.beginKeyInstall(key)
        if (cmd == null) {
            // The driver refused (wrong phase / not allowed / build failed): stay honest, never retry blind.
            log("Oura: the install command could not be prepared - staying honest")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
            return@guardedCallback
        }
        pendingInstallKey = key
        _adoptPhase.value = AdoptPhase.InstallingKey
        log("Oura: installing NOOP's key on the reset ring")
        write(cmd)
    }

    /**
     * Handle the ring's `0x25` SetAuthKey ack (OURA_PROTOCOL.md s3.2: `25 01 00`, status byte `0x00` = OK).
     * Acts ONLY when an install we initiated is in flight (a pending key is held AND driver phase is
     * InstallingKey); a stray 0x25 outside an adopt is ignored. On OK: PERSIST the freshly-provisioned key
     * under this deviceId (so every future session authenticates with it), then drive the driver's
     * keyInstallAcknowledged() to re-run the auth handshake (GetAuthNonce then Authenticate) with the NEW
     * key. On a non-OK status (or a failed store) announce an honest failure and do NOT retry the dangerous
     * command. Kotlin twin of Swift's `handleKeyInstallAck`.
     */
    private fun handleKeyInstallAck(d: OuraDriver, frame: OuraOuterFrame) = guardedCallback("key-install-ack") {
        val key = pendingInstallKey ?: return@guardedCallback              // no install in flight
        if (d.phase != OuraDriverPhase.InstallingKey) return@guardedCallback // not our install in flight
        val status = frame.body.firstOrNull()
        if (status == SET_AUTH_KEY_OK) {
            // Persist ONLY on OK, so a failed/absent ack never leaves a wrongly-trusted key behind.
            if (!OuraInstallKeyStore.save(appContext, deviceId, key)) {
                log("Oura: the installed key could not be stored - cannot adopt this ring")
                announceNeedsPairing(KEY_INSTALL_MESSAGE)
                return@guardedCallback
            }
            log("Oura: key installed and stored - re-authenticating with the new key")
            pendingInstallKey = null
            // Re-auth with the freshly-installed key. The driver returns enable-notify + get-nonce; the
            // nonce response then flows through the normal routeSecure -> advance path to streaming.
            for (cmd in d.keyInstallAcknowledged()) write(cmd)
        } else {
            log("Oura: the ring did not accept the key (status=${status ?: "none"}) - cannot adopt this ring")
            announceNeedsPairing(KEY_INSTALL_MESSAGE)
        }
    }

    /** Queue one command on the main looper. No-response submissions are never replayed after ambiguity. */
    private fun write(cmd: OuraCommand) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            handler.post { write(cmd) }
            return
        }
        guardedCallback("write") {
            if (teardownPending) return@guardedCallback
            commandWrites.enqueue(listOf(cmd))
            drainCommandWrites()
        }
    }

    /** Submit exactly one Oura command and hold the GATT slot through a short controller pacing window. */
    private fun drainCommandWrites(): Unit {
        guardedCallback("write-drain") {
            val g = gatt ?: run {
                if (teardownPending) finishTransportStop()
                return@guardedCallback
            }
            val ch = writeChar ?: run {
                if (teardownPending) finishTransportStop()
                return@guardedCallback
            }
            val cmd = commandWrites.beginNext() ?: run {
                if (teardownPending && commandWrites.isDrained) finishTransportStop()
                return@guardedCallback
            }
            val bytes = ByteArray(cmd.bytes.size) { cmd.bytes[it].toByte() }
            val accepted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(
                    ch,
                    bytes,
                    BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE,
                ) == BluetoothStatusCodes.SUCCESS
            } else {
                @Suppress("DEPRECATION")
                run {
                    ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
                    ch.value = bytes
                    g.writeCharacteristic(ch)
                }
            }
            if (!accepted) {
                commandWrites.completeActive()
                log(
                    "Oura: command ${cmd.label} was rejected by the GATT stack - " +
                        "closing this session without replay",
                )
                if (teardownPending) {
                    finishTransportStop()
                } else {
                    commandWrites.reset()
                    runCatching { g.disconnect() }
                }
                return@guardedCallback
            }
            log("Oura: -> ${cmd.label}")
            handler.removeCallbacks(commandPaceRunnable)
            handler.postDelayed(commandPaceRunnable, commandWritePaceMs)
        }
    }

    private fun resetCommandTransport() {
        handler.removeCallbacks(commandPaceRunnable)
        handler.removeCallbacks(teardownDeadlineRunnable)
        commandWrites.reset()
        teardownPending = false
    }

    /**
     * Handle one inbound notification value. Two framing layers ride the same notify char (s2):
     *   - 0x2F secure-session sub-frames carry the auth nonce/status, live-HR pushes, and enable ACKs.
     *   - everything else is one or more TLV event records (reassembled across notifications).
     * The pure driver owns every decode; we only route bytes and turn its results into transitions /
     * persisted rows. A throw anywhere here is contained by [guardedCallback] (degrade to "no data").
     */
    private fun handleNotification(data: ByteArray) = guardedCallback("notification") {
        val d = driver ?: return@guardedCallback
        val bytes = IntArray(data.size) { data[it].toInt() and 0xFF }
        // Split any packed outer frames; route 0x2F secure sub-frames through the driver's secure handler
        // and feed all other bytes to the TLV reassembler.
        val nonSecure = ArrayList<Int>()
        for (frame in OuraFraming.parseOuterFrames(bytes)) {
            if (frame.op in PRODUCT_INFO_RESPONSE_OPS) {
                handleProductInfo(frame.body)
            } else if (frame.op == OuraFraming.secureSessionOp) {
                val secure = OuraFraming.parseSecureFrame(frame) ?: continue
                routeSecure(d, secure)
            } else if (frame.op == SET_AUTH_KEY_RESP_OP) {
                // The post-factory-reset key-install acknowledgement (`25 01 00`, OURA_PROTOCOL.md s3.2):
                // an OUTER frame, not a 0x2F secure sub-frame and not a TLV record. Route it to the adopt
                // handler ONLY (it self-guards: it acts solely when an install we initiated is in flight).
                handleKeyInstallAck(d, frame)
            } else if (frame.op == OuraFraming.getEventsResponseOp) {
                // The `0x11` GetEvents summary drives the history-fetch cursor loop (OURA_PROTOCOL.md
                // s5.2/5.3): an OUTER frame, never a TLV record. Its op (0x11) is well below the event-tag
                // range (tags are >= 0x41), so had it fallen through to the reassembler it would decode as a
                // safe "unknown tag" no-op; we route it to the cursor loop instead (same convention as the
                // 0x25 ack above - handled, not re-serialised).
                val summary = OuraFraming.parseGetEventsResponse(frame.body)
                if (summary != null) handleHistorySummary(summary)
            } else if (frame.op == OuraFraming.syncTimeResponseOp) {
                val response = OuraFraming.parseSyncTimeResponse(frame.body)
                if (response != null) handleSyncTimeResponse(d, response)
            } else if (frame.op == OuraFraming.batteryResponseOp) {
                // The `0x0D` GetBattery response is ALSO an OUTER frame (never a TLV record, s6.10). Its op
                // is below the event-tag range too, so it is a safe no-op if it ever fell through; we route
                // it through the existing `.battery` ingest path (batteryPct/onBattery/log side effects).
                val battery = OuraDecoders.decodeBattery(frame.body)
                if (battery != null) emit(listOf(OuraEvent.Battery(battery)))
            } else {
                // Re-serialise the outer frame (op, len, body) so the reassembler sees the original wire
                // bytes; TLV records and outer frames share the op/len header shape.
                nonSecure.add(frame.op)
                nonSecure.add(frame.body.size)
                for (b in frame.body) nonSecure.add(b)
            }
        }
        if (nonSecure.isNotEmpty()) {
            val records = reassembler.feed(IntArray(nonSecure.size) { nonSecure[it] })
            for (rec in records) {
                val generation = historyTransportGeneration
                if (generation != null) {
                    // Continuation is a transport decision: count the RAW TLV envelope even when its tag
                    // is unknown, Tier-B-gated, padding-only, or otherwise decodes to no OuraEvent.
                    historyDrain.noteSeenRingTime(rec.ringTimestamp)
                    if (pendingHistoryDrainAction != null) restartHistoryBatchQuietTimer()
                }
                emit(
                    events = d.ingest(rec),
                    // TLV records are banked/event data. Live HR/IBI uses the secure-push path, so a delayed
                    // history callback can never become a live reading after the driver returns to Streaming.
                    historyEnvelope = true,
                    historyGeneration = generation,
                )
            }
        }
    }

    /** Adopt a successful SyncTime response only when its tick interpretation is unambiguous. */
    private fun handleSyncTimeResponse(d: OuraDriver, response: com.noop.oura.SyncTimeResponse) {
        if (response.status != 0) {
            log("Oura: SyncTime response rejected with status ${response.status}")
            return
        }
        val ringTimestamp = OuraDriver.syncTimeAnchorCandidate(response.deviceTimestamp, historyCursor)
        if (ringTimestamp == null ||
            !d.adoptSyncTimeAnchor(ringTimestamp, System.currentTimeMillis() / 1000L)
        ) {
            log("Oura: SyncTime response did not provide an unambiguous history anchor")
            return
        }
        if (!loggedAnchor) {
            loggedAnchor = true
            log("Oura: UTC anchor acquired from SyncTime response")
        }
        drainPendingAnchorEvents()
        drainPendingHypnogramBursts()
    }

    /** Decode hardware identity without logging or persisting the serial. */
    private fun handleProductInfo(body: IntArray) {
        val value = OuraDecoders.productInfoString(body) ?: return
        if (!handledProductInfo.add(value)) return
        val detected = OuraRingGen.fromHardwareId(value) ?: return
        if (detected == ringGen) return
        log("Oura: hardware reports ${detected.displayName}; correcting the stored model")
        onModel(detected.displayName)
    }

    /** Route a 0x2F secure sub-frame to the driver and turn its result into a transition or live events. */
    private fun routeSecure(d: OuraDriver, secure: com.noop.oura.OuraSecureFrame) = guardedCallback("secure-route") {
        when (val routing = d.handleSecureFrame(secure)) {
            is OuraDriver.SecureRouting.Nonce -> advance(OuraTransition.NonceReceived(routing.nonce))
            is OuraDriver.SecureRouting.AuthStatus -> {
                log("Oura: auth status = ${routing.status.name}")
                advance(OuraTransition.AuthCompleted(routing.status))
            }
            OuraDriver.SecureRouting.EnableAck -> advance(OuraTransition.EnableAckReceived)
            is OuraDriver.SecureRouting.FeatureStatus -> logFeatureStatus(routing.value)   // read-only; no advance
            is OuraDriver.SecureRouting.LiveHRPush -> emit(d.ingestLiveHRPush(routing.body))
            OuraDriver.SecureRouting.Unhandled -> Unit
        }
    }

    /**
     * Log a feature-status read reply once per feature (read-only diagnostic). Confirms, from the ring
     * itself, whether a server-flag feature (SpO2 0x04 / real_steps 0x0b) is subscribed/emitting — NOOP
     * cannot enable these offline (server ClientConfiguration gate), so a `subscription == 0` here is the
     * honest "not a bug, it's a gate" reading. Never scored, never stored.
     */
    private fun logFeatureStatus(st: com.noop.oura.OuraFeatureStatus) {
        if (!loggedFeatureStatuses.add(st.feature)) return
        val name = when (st.feature) {
            OuraCommands.featureSpO2 -> "SpO2 (0x04)"
            OuraCommands.featureRealSteps -> "real_steps (0x0b)"
            OuraCommands.featureDaytimeHR -> "daytime-HR (0x02)"
            else -> "0x${st.feature.toString(16)}"
        }
        // A gated/unavailable feature reports ALL-ZERO (mode/status/state); the streaming daytime-HR, by
        // contrast, reads mode=1 status=0x11 state=2. Flag the all-zero case as the honest "cloud never
        // enabled it" - NOT `subscription==0` alone, since daytime-HR is subscription=0 yet active.
        val off = st.mode == 0 && st.status == 0 && st.state == 0
        val gate = if (off) " - INACTIVE (server-gated off; the cloud never enabled it, not emitted offline)" else ""
        // Name the enum fields so the log reads plainly (OURA_PROTOCOL.md s7.1 [ring4-ble]) — e.g. a gated
        // feature prints `mode=0 (off) … subscription=0 (off)`, the active daytime-HR `mode=1 (automatic)`.
        log("Oura: feature status $name mode=${st.mode} (${featureModeName(st.mode)}) status=${st.status} " +
            "state=${st.state} subscription=${st.subscription} (${subscriptionName(st.subscription)})$gate")
    }

    /** The ring's feature-MODE enum (`2f 03 22` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble]. */
    private fun featureModeName(m: Int) = when (m) {
        0 -> "off"; 1 -> "automatic"; 2 -> "requested"; 3 -> "connected_live"; else -> "?"
    }
    /** The ring's SUBSCRIPTION enum (`2f 03 26` write byte), per OURA_PROTOCOL.md s7.1 [ring4-ble]. */
    private fun subscriptionName(s: Int) = when (s) {
        0 -> "off"; 1 -> "state"; 2 -> "latest"; 4 -> "feature_data"; else -> "?"
    }

    /**
     * Fold decoded driver events into live-UI updates + the persist buffer (the production path, parity
     * with Swift's `ingest`). Genuinely-live pushes (HR/battery) are stamped at wall-clock arrival time,
     * since they really are "now"; HR is range-gated for the LIVE display (off-finger / garbage never
     * shown) and battery surfaces immediately (a status, not a timestamped row). Ring-time-carrying events
     * (IBI, temp, SpO2, HRV, sleep-phase) are stamped with their REAL ring-time-anchored UTC (s5.5) so last
     * night's banked data is never mis-recorded as happening right now. IBI arrives both live and banked;
     * [historyEnvelope] keeps those paths distinct so only a stored banked beat may move the resume cursor.
     * When no anchor has arrived yet this session, the event is PARKED
     * ([pendingAnchorEvents]) until one does, rather than immediately guessing wall-clock. A 0x42
     * time-sync (the anchor) drains anything parked. Tier-B events (allowed for INVESTIGATION - see the
     * driver construction comment) are LOGGED only, never enqueued: OuraStreamMapping drops them anyway,
     * so an unverified layout can never feed a durable stream or scoring.
     */
    private fun emit(
        events: List<OuraEvent>,
        historyEnvelope: Boolean = false,
        historyGeneration: Long? = null,
    ) = guardedCallback("emit") {
        if (events.isEmpty()) return@guardedCallback
        val d = driver ?: return@guardedCallback
        val now = (System.currentTimeMillis() / 1000L).toInt()
        // A 0x4B/0x4E/0x5A record arrives as one event list. Preserve that record boundary while building
        // the finalization burst; the envelope timestamp is a write time, not an epoch time.
        val phases: List<OuraSleepPhase> = events.mapNotNull {
            (it as? OuraEvent.SleepPhaseEvent)?.value
        }
        phases.firstOrNull()?.let { first ->
            ingestHypnogramRecord(
                ringTimestamp = first.ringTimestamp,
                phases = phases,
                historyGeneration = historyGeneration,
            )
        }
        // A history record's beats and its IBI-derived HR must reach the store in one anchored batch.
        // Live pushes retain their existing path: only historyEnvelope permits HR materialization here.
        val persistenceEvents = if (historyEnvelope) {
            OuraIbiHr.appendingDerivedHrToHistoryEvents(events)
        } else {
            events
        }
        val anchoredSignals = persistenceEvents.mapNotNull { event ->
            val ringTimestamp = when (event) {
                is OuraEvent.Ibi -> event.value.ringTimestamp
                is OuraEvent.Hr -> if (historyEnvelope) event.value.ringTimestamp else return@mapNotNull null
                else -> return@mapNotNull null
            }
            d.unixSeconds(forRingTimestamp = ringTimestamp)?.let { event to it.toInt() }
        }
        for ((ts, batch) in OuraStreamMapping.batched(anchoredSignals)) {
            val ringTimestamps = if (historyGeneration != null) {
                batch.mapNotNull { (it as? OuraEvent.Ibi)?.value?.ringTimestamp }
            } else {
                emptyList()
            }
            enqueue(
                events = batch,
                ts = ts,
                historyRingTimestamps = ringTimestamps,
                historyGeneration = historyGeneration,
            )
        }
        for (e in events) when (e) {
            is OuraEvent.Hr -> {
                // Banked/derived history HR is persisted above; it must never become a live reading or
                // on-wrist pulse.
                if (!OuraLivePublication.permits(historyEnvelope)) continue
                val bpm = e.value.bpm
                if (bpm in 30..220) {   // physiological gate for the LIVE readout only
                    if (!loggedFirstHr) {
                        loggedFirstHr = true
                        log("Oura: receiving data - first sample $bpm bpm")
                    }
                    liveSink(bpm, emptyList())
                }
                // A LIVE HR push (0x2F) exists only while the ring is measuring on a finger, so it is the
                // sole safe "worn now" signal - fed unconditionally (even a gated-out bpm still proves the
                // ring is on a finger). NEVER fed from OuraEvent.Ibi below: the history path decodes IBI
                // tags to .Ibi only (never .Hr), so a past-night re-serve can't reach here and falsely
                // flip the badge to worn. Mirrors iOS OuraLiveSource `.hr` case. Posted to the main looper
                // (emit runs on the GATT binder thread) so ALL wear-tracker access — here + the re-engage
                // watchdog — is single-threaded, matching how liveSink is posted just above.
                lastLivePulseAt = System.currentTimeMillis()
                wearTracker.notePulse()
                publishWearState()
                enqueue(listOf(e), now)
            }
            is OuraEvent.StateEvent -> {
                // The ring's own lifecycle strings (0x45/0x53). Charger transitions drive the wear badge;
                // never a durable Streams row. Posted to the main looper (see the .Hr note) so wear-tracker
                // access stays single-threaded. Mirrors iOS OuraLiveSource `.state` case.
                if (OuraLivePublication.permitsCurrentState(
                        historyEnvelope = historyEnvelope,
                        eventUnixSeconds = d.unixSeconds(forRingTimestamp = e.value.ringTimestamp),
                        now = now.toLong(),
                    )
                ) {
                    wearTracker.note(e.value)
                    publishWearState()
                }
            }
            is OuraEvent.Ibi -> {
                val rr = e.value.ibiMs
                if (OuraLivePublication.permits(historyEnvelope) && rr in 250..3000) {
                    liveSink(0, listOf(rr))
                }
                // Anchored beats were enqueued above as one record batch. Only unanchored beats park here.
                if (d.unixSeconds(forRingTimestamp = e.value.ringTimestamp) == null) {
                    pendingAnchorEvents.add(
                        PendingAnchorEvent(
                            e,
                            e.value.ringTimestamp,
                            historyGeneration,
                            historyEnvelope,
                            if (historyEnvelope) null else now,
                        ),
                    )
                }
            }
            is OuraEvent.Battery -> {
                handleBattery(e.value.percent)
                enqueue(listOf(e), now)
            }
            is OuraEvent.Temp -> {
                // physiological gate (wrist skin temp); an out-of-range read is dropped, never shown.
                if (e.value.celsius in 20.0..45.0) {
                    if (!loggedFirstTemp) {
                        loggedFirstTemp = true
                        log("Oura: first skin temp decoded (last night) - %.2fC".format(e.value.celsius))
                    }
                    enqueueAnchoredOrPark(
                        e,
                        e.value.ringTimestamp,
                        d,
                        historyGeneration,
                        historyEnvelope,
                        now,
                    )
                }
            }
            is OuraEvent.Spo2 -> {
                if (!loggedFirstSpo2) {
                    loggedFirstSpo2 = true
                    log("Oura: first SpO2 decoded (last night) - value ${e.value.value} (${e.value.unit})")
                }
                enqueueAnchoredOrPark(
                    e,
                    e.value.ringTimestamp,
                    d,
                    historyGeneration,
                    historyEnvelope,
                    now,
                )
            }
            is OuraEvent.Hrv -> enqueueAnchoredOrPark(
                e,
                e.value.ringTimestamp,
                d,
                historyGeneration,
                historyEnvelope,
                now,
            )
            is OuraEvent.SleepPhaseEvent -> Unit // record/burst pipeline above owns persistence
            is OuraEvent.TimeSyncEvent -> {
                // #91: a 0x42 whose epoch is outside the 2020–2035 plausibility window is silently ignored,
                // so history samples stay unanchored (no sleep/daily). Log the rejection with the offending
                // epoch; only announce "acquired" when the sync ACTUALLY anchored (the old unconditional
                // "acquired" line fired even on a rejected sync). `epochMs` holds the raw wire value, which
                // is unix SECONDS despite the name (s6.11).
                if (d.isPlausibleAnchorEpoch(e.value.epochMs)) {
                    if (!loggedAnchor) {
                        loggedAnchor = true
                        log("Oura: UTC time anchor acquired - history-fetched samples now get their real time")
                    }
                } else {
                    log("Oura: 0x42 time-sync REJECTED - implausible epoch ${e.value.epochMs}s (outside the " +
                        "2020–2035 anchor window); history samples stay unanchored (#91)")
                }
                // The 0x42 time-sync can arrive ANYWHERE in a history-fetch stream, not necessarily first.
                // Anything parked while unanchored gets its real time retroactively the moment it lands.
                drainPendingAnchorEvents()
                drainPendingHypnogramBursts()
            }
            is OuraEvent.RtcBeaconEvent -> {
                // #91: the 0x85 beacon is the SECONDARY anchor (fills the gap only until a 0x42 arrives). A
                // beacon ignored because a primary anchor already exists is NORMAL and not logged; only an
                // IMPLAUSIBLE-epoch beacon is a real failure (it can never anchor), so log just that.
                if (d.isPlausibleAnchorEpoch(e.value.unixSeconds)) {
                    // The driver accepts this secondary anchor before emitting the event. Drain scalar
                    // samples and whole bursts here too, so an 0x85-only session cannot strand sleep stages.
                    drainPendingAnchorEvents()
                    drainPendingHypnogramBursts()
                } else {
                    log("Oura: 0x85 RTC beacon REJECTED - implausible epoch ${e.value.unixSeconds}s (outside " +
                        "the 2020–2035 anchor window) (#91)")
                }
            }
            is OuraEvent.TierB -> {
                // Validated ringverse 0x49 layout: two little-endian offsets in minutes before the event.
                // Keep a bounded list so each burst pairs with the nearest overnight/nap window.
                if (e.value.tag == 0x49 && e.value.rawPayload.size >= 4) {
                    val startOff = (e.value.rawPayload[0] and 0xFF) or
                        ((e.value.rawPayload[1] and 0xFF) shl 8)
                    val endOff = (e.value.rawPayload[2] and 0xFF) or
                        ((e.value.rawPayload[3] and 0xFF) shl 8)
                    recentSleepWindows049.add(Triple(e.value.ringTimestamp, startOff, endOff))
                    if (recentSleepWindows049.size > RECENT_SLEEP_WINDOWS_049_CAP) {
                        recentSleepWindows049.subList(
                            0,
                            recentSleepWindows049.size - RECENT_SLEEP_WINDOWS_049_CAP,
                        ).clear()
                    }
                }
                // INVESTIGATION ONLY (real_steps / activity-summary / sleep-summary / smoothed-SpO2,
                // OURA_PROTOCOL.md s7.3 Tier B; PR #960). Logged ONCE PER KIND with the raw bytes so we
                // can see whether the ring sends these tags at all and collect capture material - e.g.
                // real_steps 0x7E/0x7F is server-flag-gated OFF by default ([open_oura-feat]), so its
                // continued absence here is the ring's doing, not a decode gap. Never persisted, never
                // scored (OuraStreamMapping drops TierB unconditionally regardless of this log).
                if (loggedTierBKinds.add(e.value.kind)) {
                    val hex = e.value.rawPayload.joinToString(" ") { "%02x".format(it) }
                    log("Oura: Tier-B ${e.value.kind} seen (tag 0x${e.value.tag.toString(16)}) - raw: $hex")
                }
            }
            is OuraEvent.ActivityInfo -> {
                // INVESTIGATION ONLY (0x50 activity/MET, Tier B - a plausible third-party formula, NOT
                // ground-truth-validated; see OuraActivityInfo). Logged with the DECODED state/MET values
                // every time (not once-per-kind): this is the tag under active plausibility evaluation, so
                // every real capture is evidence. Never persisted, never scored, and NEVER converted into
                // steps (MET is not a step count; OuraStreamMapping drops ActivityInfo unconditionally).
                log("Oura: activity (Tier-B) state=${e.value.state} met=${e.value.met}")
                // Append the raw record to the Tier-B research corpus (anchored records only; deduped by
                // ring-time in the writer). Diagnostic sidecar - never persisted to the DB, never scored.
                d.unixSeconds(forRingTimestamp = e.value.ringTimestamp)?.let { utc ->
                    activityDump?.record(
                        ringTs = e.value.ringTimestamp, utc = utc, state = e.value.state,
                        secPerSample = 60, met = e.value.met, // 60 s = assumed MET cadence (s6.13)
                    )
                }
            }
            // Motion / debugText / etc: not a durable Streams row (see OuraStreamMapping). StateEvent is
            // handled above (wear badge only, also not a Streams row).
            else -> Unit
        }
    }

    /** Mirror the tracker's current wear/charge state to [ouraWearState], logging each TRANSITION once (a
     *  charger on/off or first pulse is worth a strap-log line; steady state is not). Twin of iOS
     *  `publishWearState`. */
    private fun publishWearState() {
        val s = wearTracker.current
        _ouraWearState.value = s
        if (s != loggedWearState) {
            loggedWearState = s
            when (s) {
                OuraWearState.WORN -> log("Oura: ring WORN - live HR streaming")
                OuraWearState.CHARGING -> log("Oura: ring NOT WORN - on charger (HR/IBI paused until removed)")
                OuraWearState.OFF -> log("Oura: ring NOT WORN - no live HR (removed / off charger)")
                OuraWearState.UNKNOWN -> Unit
            }
        }
    }

    /** Reset synchronously on the main owner so a stopped session cannot publish afterward. */
    private fun resetWear() {
        wearTracker.reset()
        loggedWearState = null
        lastLivePulseAt = null
        _ouraWearState.value = null
    }

    /**
     * Stamp a history-fetched event with its ring-time-anchored UTC (s5.5) and enqueue it, or - when no
     * anchor has arrived yet this session - park it in [pendingAnchorEvents] to be re-stamped the moment
     * one lands (drained by a 0x42 time-sync, or with an honest wall-clock fallback at teardown). Kotlin
     * twin of the Swift `if let ts = driver.unixSeconds(...) { enqueue } else { pendingAnchorEvents.append }`
     * pattern repeated per history signal.
     */
    private fun enqueueAnchoredOrPark(
        event: OuraEvent,
        ringTimestamp: Long,
        d: OuraDriver,
        historyGeneration: Long?,
        historyEnvelope: Boolean,
        liveArrivalTimestamp: Int,
    ) {
        val ts = d.unixSeconds(forRingTimestamp = ringTimestamp)
        if (ts != null) {
            enqueue(
                events = listOf(event),
                ts = ts.toInt(),
                historyRingTimestamps =
                    if (historyGeneration == null) emptyList() else listOf(ringTimestamp),
                historyGeneration = historyGeneration,
            )
        } else {
            pendingAnchorEvents.add(
                PendingAnchorEvent(
                    event,
                    ringTimestamp,
                    historyGeneration,
                    historyEnvelope,
                    if (historyEnvelope) null else liveArrivalTimestamp,
                ),
            )
        }
    }

    private fun handleBattery(pct: Int) = guardedCallback("battery") {
        if (pct !in 0..100) return@guardedCallback
        log("Oura: battery $pct%")
        _batteryPct.value = pct
        // Battery is NOT persisted as a stream row here: it carries no ring timestamp, and OuraStreamMapping
        // intentionally drops it (honest: no faked ts). It flows only via the live onBattery path, exactly
        // like the Swift twin.
        onBattery(pct)
    }

    // MARK: - Live-HR re-engage scheduling

    private fun scheduleReengage() {
        if (reengageScheduled) return
        reengageScheduled = true
        handler.postDelayed(reengageRunnable, reengageIntervalMs)
    }

    private fun cancelReengage() {
        reengageScheduled = false
        handler.removeCallbacks(reengageRunnable)
    }

    // MARK: - Honest fallback

    /**
     * Record the honest "this ring needs a pairing handshake NOOP can't complete" outcome (the message is
     * already RECOVERY-HONEST: a factory-reset ring is NOT bricked, re-pairing in the Oura app brings it
     * back, and adopt is Beta). Also marks [AdoptPhase.Failed] so an in-flight adopt's Adopting step lands
     * on a REACHABLE honest Failed state, and clears any in-flight install key WITHOUT persisting it (a
     * failed install must never leave a wrongly-trusted key). We never claim a key was installed here.
     * Mirrors the Swift `announceNeedsPairing`.
     */
    private fun announceNeedsPairing(message: String) {
        // A failed install must drop its pending key whether or not this is the first announce.
        pendingInstallKey = null
        _adoptPhase.value = AdoptPhase.Failed
        // This is an honest dead-end (no key / auth rejected / install failed), NOT a transient drop, so a
        // later disconnect must NOT auto-reconnect (that would loop the same auth failure and drain the
        // ring). Suppress it the same way a deliberate teardown does (#912); a user reconnect re-arms it.
        intentionalDisconnect = true
        reconnectAddress = null
        failedReconnectAttempts = 0
        cancelHistoryFetch()
        resetHistoryDrainState()
        if (_needsPairing.value != null) return
        _needsPairing.value = message
        log("Oura: $message")
    }

    /**
     * Run a GATT-callback body so a throw on the binder thread (or a posted main-thread block) can never
     * crash the app. BLE callbacks run outside any try/catch and outside the SourceCoordinator reconcile
     * guard, so an exception in a decode / live sink would otherwise crash the process - and because the
     * ring is the persisted active source, it would crash-LOOP on every launch (#421 regression). A
     * misbehaving ring must degrade to "no data", never take the app down. The message lands in the
     * exportable strap log. Mirrors [StandardHrSource.guardedCallback].
     */
    private fun guardedCallback(label: String, block: () -> Unit) {
        runCatching(block).onFailure {
            log("Oura: $label error (${it.javaClass.simpleName}: ${it.message})")
        }
    }

    /** Marshal every BLE callback onto one owner thread before touching driver, persistence, or queue state. */
    private fun onMainCallback(label: String, block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            guardedCallback(label, block)
        } else {
            handler.post { guardedCallback(label, block) }
        }
    }

    /**
     * A callback from the GATT closed during replacement must not reset the new session. Identity is checked
     * before any state mutation; the stale object is closed without touching current transport state.
     */
    private fun callbackBelongsToCurrentGatt(callbackGatt: BluetoothGatt, callback: String): Boolean {
        if (gatt === callbackGatt) return true
        log("Oura: ignoring stale $callback callback from a replaced GATT")
        runCatching { callbackGatt.close() }
        return false
    }

    companion object {
        /** The ring's base service + write/notify characteristics (OURA_PROTOCOL.md s1.1). Built from the
         *  protocol package's UUID strings so the facts live in exactly one place. */
        val SERVICE_UUID: UUID = UUID.fromString(OuraGatt.serviceUUID)
        val WRITE_UUID: UUID = UUID.fromString(OuraGatt.writeCharacteristicUUID)
        val NOTIFY_UUID: UUID = UUID.fromString(OuraGatt.notifyCharacteristicUUID)

        /** The standard client-characteristic-configuration descriptor (0x2902). */
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        /** Android's infamous generic GATT connect failure (`BluetoothGatt.GATT_ERROR`, not a public
         *  constant). We auto-retry it once. */
        private const val GATT_ERROR_133 = 133

        private const val RECENT_SLEEP_WINDOWS_049_CAP = 16

        /** The SetAuthKey-response OUTER opcode (`0x25`) and its OK status byte (`0x00`). The ring replies
         *  `25 01 00` to a successful `0x24` key install (OURA_PROTOCOL.md s3.2). */
        private const val SET_AUTH_KEY_RESP_OP = 0x25
        private val PRODUCT_INFO_RESPONSE_OPS = setOf(0x18, 0x19)
        private const val SET_AUTH_KEY_OK = 0x00

        /** Generate a fresh cryptographically-random 16-byte install key as unsigned bytes 0..255
         *  (OURA_PROTOCOL.md s3.2 step 1). [java.security.SecureRandom] is the platform CSPRNG. */
        private fun secureRandom16(): IntArray {
            val bytes = ByteArray(OuraAuth.keyLength)
            SecureRandom().nextBytes(bytes)
            return IntArray(OuraAuth.keyLength) { bytes[it].toInt() and 0xFF }
        }

        /**
         * Honest fallback copy: live data is not available, AND the ring is RECOVERABLE. A factory-reset
         * ring is not bricked: re-pairing it in the Oura app sets it up again. NOOP adopt is Beta and may
         * not succeed on every ring or firmware yet. No "installing key" wording (no install ran here).
         */
        private const val KEY_INSTALL_MESSAGE =
            "NOOP couldn't pair with this Oura ring. Live data isn't available. The ring is not damaged: " +
                "re-pair it in the Oura app to set it up again. NOOP adopt is Beta and may not work on " +
                "every ring or firmware yet. You can also export from the Oura app and use file import."

        /** Honest fallback copy: a key IS installed but it does not match this ring. Same recovery note. */
        private const val AUTH_FAILED_MESSAGE =
            "This Oura ring rejected the stored pairing key. Live data isn't available. The ring is not " +
                "damaged: re-pair it in the Oura app to set it up again, or export from the Oura app and " +
                "use file import."
    }
}

// MARK: - Oura GetEvents cursor persistence

/**
 * Persists the Oura `GetEvents` cursor (OURA_PROTOCOL.md s5.1/5.3) per ring, so a later connection
 * resumes from where the last session left off instead of re-fetching the ring's entire banked history on
 * every single connect. Kotlin twin of Swift's `OuraHistoryCursorStore` (which uses `UserDefaults`).
 *
 * Unlike [OuraInstallKeyStore] this is NOT sensitive - it's an opaque ring-clock tick counter, not a
 * credential - so plain [SharedPreferences] is the right (and simplest) store (no EncryptedSharedPreferences
 * / keystore round-trip). The cursor is the unsigned 32-bit ring timestamp; it is stored as a Long (the JVM
 * has no unsigned int) so the full 0..0xFFFFFFFF range survives a round-trip.
 */
object OuraHistoryCursorStore {
    private const val FILE_NAME = "noop_oura_history_cursor"
    private const val KEY_PREFIX = "history_cursor_"

    private fun prefs(ctx: Context): SharedPreferences =
        ctx.applicationContext.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    private fun prefKey(deviceId: String) = "$KEY_PREFIX$deviceId"

    /** The persisted cursor for [deviceId], or 0 (fetch everything) if none is stored yet. Clamped to the
     *  unsigned-32 range so a corrupt/negative stored value can never drive a malformed GetEvents request. */
    fun read(ctx: Context, deviceId: String): Long {
        val raw = runCatching { prefs(ctx).getLong(prefKey(deviceId), 0L) }.getOrDefault(0L)
        return raw.coerceIn(0L, 0xFFFF_FFFFL)
    }

    /** Store the advanced cursor for [deviceId]. */
    fun save(ctx: Context, deviceId: String, cursor: Long) {
        runCatching { prefs(ctx).edit().putLong(prefKey(deviceId), cursor and 0xFFFF_FFFFL).apply() }
    }
}
