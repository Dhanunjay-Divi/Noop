import SwiftUI
import StrandDesign
import StrandAnalytics   // ConnectionReadout - the #987 clock-latch / RTC-epoch readout parsers
import WhoopStore
import OuraProtocol
import WhoopProtocol

// MARK: - Devices
//
// Pair and manage the bands NOOP reads from. WHOOP-FIRST: the WHOOP is the primary, fully-supported
// device; generic heart-rate straps (Polar / Wahoo / Coospo / Garmin HRM …) are an early, in-development
// addition. The screen is a thin UI over `DeviceRegistry` (the Phase 1A/1B data layer): every mutation
// goes through a registry op, and the `SourceCoordinator` (already wired in AppModel) reacts to the
// active-device change — so this view never touches BLEManager or the WHOOP path directly.
struct DevicesView: View {
    @EnvironmentObject var model: AppModel
    // PERF: this OUTER view does NOT observe `LiveState`. It only branches on `model.deviceRegistry`
    // becoming non-nil and hands off to `DevicesContent`, which owns its own `@EnvironmentObject live`
    // (the live battery / "Active · Live" badge live there). Observing `live` here would re-render the
    // whole screen on every ~1 Hz strap tick for no visible change — `live` is still in the environment
    // for `DevicesContent` and the Add-device wizard, so nothing downstream loses its live readout.

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "Pair and manage the bands NOOP reads from.",
                       // The day-of-sky liquid backdrop, matching Today / Health / Sleep / Trends: a fixed,
                       // full-bleed time-of-day sky behind the scroll content (it does not scroll).
                       topBackground: liquidScaffoldSky()) {
            if let registry = model.deviceRegistry {
                DevicesContent(registry: registry)
            } else {
                // The registry is built once the on-device store opens (a beat after launch). Show a
                // calm pending note rather than an empty screen in that brief window.
                DataPendingNote(
                    title: "Getting your devices ready",
                    message: "NOOP is opening your on-device data. Your paired bands will appear here in a moment.",
                    symbol: "badge.plus.radiowaves.right")
            }
        }
    }
}

// MARK: - Content (registry resolved)

/// The screen body once `DeviceRegistry` exists. Split out so it can observe the registry's
/// `@Published devices` / `activeDeviceId` directly — the parent only observes `model.deviceRegistry`
/// becoming non-nil.
private struct DevicesContent: View {
    @ObservedObject var registry: DeviceRegistry
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true

    // Sheets / alerts
    @State private var showAddWizard = false
    @State private var switchTarget: PairedDevice?
    @State private var renameTarget: PairedDevice?
    @State private var renameDraft = ""
    @State private var removeTarget: PairedDevice?
    @State private var deleteDataTarget: PairedDevice?
    @State private var rebootTarget: PairedDevice?
    /// WHOOP 4.0 reboot probe (Test Centre → Connection, 4.0 only) — the device whose probe sheet is open.
    @State private var probeTarget: PairedDevice?
    /// #592 extended-battery probe (Test Centre → Connection) — the device whose confirm dialog is open.
    @State private var batteryProbeTarget: PairedDevice?
    /// #690 body-location probe (Test Centre → Connection) — the device whose confirm dialog is open.
    @State private var bodyLocationProbeTarget: PairedDevice?
    @State private var ecgProbeTarget: PairedDevice?
    @State private var ecgWristTarget: PairedDevice?
    @AppStorage(PuffinExperiment.ecgKey) private var ecgEnabled = false
    /// After removing the ACTIVE device with other devices still paired, prompt to pick a new active one.
    @State private var pickNewActive = false

    private var activeDevices: [PairedDevice] { registry.devices.filter { $0.status != .archived } }
    private var removedDevices: [PairedDevice] { registry.devices.filter { $0.status == .archived } }
    /// I-1: `activeDevices` minus import sources (cloud/file) — the candidates actually eligible for
    /// "make active". An import source is a data partition, not a live device; offering it here would let
    /// activating it demote the live WHOOP driving BLE routing + day-owner priority 0.
    private var activatableDevices: [PairedDevice] { activeDevices.filter { !$0.isImportSource } }

    /// #987: the active+connected strap's clock state, from the SAME pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds (one source of truth). nil (no row at all) until the WHOOP path
    /// has produced any clock signal - a routed frame, a clock correlation, or a data-range reply - so a
    /// generic HR strap or an idle card never shows a fabricated "waiting" state. One computation for
    /// both the line and the warning (the log scan is the cost worth paying once, not twice).
    private var strapClockState: (line: String, warning: String?)? {
        guard live.connected else { return nil }
        let deviceClock = ConnectionReadout.clockCorrelatedDevice(logLines: live.log)
        guard deviceClock != nil || live.strapRange != nil || live.lastFrameAtUnix != nil else { return nil }
        let latched = ConnectionReadout.clockLatchedLabel(deviceClockUnix: deviceClock,
                                                          strapNewestUnix: live.strapRange?.newestUnix)
        let frame = ConnectionReadout.lastFrameLabel(lastFrameUnix: live.lastFrameAtUnix,
                                                     nowUnix: Int(Date().timeIntervalSince1970))
        let warning = ConnectionReadout.rtcWarning(deviceClockUnix: deviceClock,
                                                   strapNewestUnix: live.strapRange?.newestUnix)
        return (String(localized: "Clock latched: \(latched) · last frame \(frame)"), warning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            if activeDevices.isEmpty {
                emptyDevicesHero
            } else {
                // UPPERCASE overline section header, matching the liquid Today. Counts the paired bands so
                // the multi-device reality reads at a glance without pretending an import is a live band.
                sectionHead("YOUR DEVICES", trailing: activeDevices.count == 1
                            ? String(localized: "1 paired")
                            : String(localized: "\(activeDevices.count) paired"))
            }
            ForEach(Array(activeDevices.enumerated()), id: \.element.id) { idx, device in
                // Shared read-only probe gate (Test Centre → Connection + a live WHOOP), hoisted so the two
                // probe closures below don't each re-inline a 4-term && chain — which tips the iOS Swift
                // type-checker over its budget ("unable to type-check this expression in reasonable time").
                let probeGate = device.status == .active && live.connected
                    && SourceCoordinator.isWhoop(device) && TestCentre.active(.connection)
                let ecgGate = probeGate && (ecgEnabled || model.ecgMayBeRunning) && model.isWhoop5MG
                DeviceCard(
                    device: device,
                    isActive: device.status == .active,
                    isLiveConnected: device.status == .active && live.connected,
                    // #221: a WHOOP 5/MG can be BLE-connected yet have its ENCRYPTED bond refused (the
                    // WHOOP app, or a stale iOS pairing, holds the single-app bond) — no HR/biometric data
                    // flows even though the link is up, so "Active · Live" overstates it. pairingHint is
                    // set only once that refusal is genuinely detected (#78), never during a normal
                    // connect, so this can't false-alarm a working 4.0 (its pairingHint stays nil) or a
                    // fresh 5/MG connect.
                    bondRefused: device.status == .active && live.connected && live.pairingHint != nil,
                    // The full #78 how-to-fix guidance, surfaced on the card itself when bondRefused so
                    // the fix is self-service instead of buried in the strap log.
                    pairingHint: device.status == .active ? live.pairingHint : nil,
                    // Reboot in flight + link currently down → "Reconnecting…" (#166).
                    isReconnecting: device.status == .active && live.rebootInProgress && !live.connected,
                    // The live battery belongs to whichever device is ACTIVE + connected (the WHOOP, a
                    // generic strap, or an FTMS machine all funnel into live.batteryPct). nil otherwise.
                    liveBatteryPct: (device.status == .active && live.connected) ? live.batteryPct.map { Int($0.rounded()) } : nil,
                    liveBatteryMv: (device.status == .active && live.connected) ? live.batteryMv : nil,
                    // Firmware version belongs to the active + connected strap only; nil otherwise (and
                    // for a non-WHOOP source that never reports one).
                    liveFirmware: (device.status == .active && live.connected) ? live.strapFirmware : nil,
                    // Historical record layout (v24/v25 on WHOOP 4.0) observed from this connection's
                    // backfill. Distinct from the strap firmware build shown as FW.
                    liveHistoryLayout: (device.status == .active && live.connected) ? live.strapRange?.firmwareLayout : nil,
                    // #987: clock latch + frame freshness + the 1970/71 RTC warning, active card only.
                    liveClockLine: device.status == .active ? strapClockState?.line : nil,
                    liveClockWarning: device.status == .active ? strapClockState?.warning : nil,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: { removeTarget = device },
                    // Restart is offered only for a live-connected WHOOP that is NOT a 4.0: the strap-log
                    // analysis on #275 showed no safe frame reboots a 4.0 (empty bodies are ignored; any
                    // non-empty body just wedges the BLE link for ~7s, sensor stays on), so a 4.0 Restart
                    // button could never work. 5.0/MG reboot on the production frame. nil otherwise.
                    onReboot: (device.status == .active && live.connected
                               && SourceCoordinator.isWhoop(device)
                               && !model.ble.isWhoop4) ? { rebootTarget = device } : nil,
                    // 4.0 reboot probe: only offered when Test Centre → Connection is on AND the live
                    // strap is a WHOOP 4.0 (a 5.0 already reboots on the production frame). nil otherwise.
                    onRebootProbe: (device.status == .active && live.connected
                                    && SourceCoordinator.isWhoop(device)
                                    && model.ble.isWhoop4
                                    && TestCentre.active(.connection)) ? { probeTarget = device } : nil,
                    // #592 extended-battery probe: read-only, BOTH families (the 4.0 is discriminating).
                    // Same Test Centre → Connection gate as the reboot probe, minus the 4.0-only clause.
                    onExtendedBatteryProbe: probeGate ? { batteryProbeTarget = device } : nil,
                    // #690 body-location probe: read-only, both families. Same Test Centre → Connection gate.
                    onBodyLocationProbe: probeGate ? { bodyLocationProbeTarget = device } : nil,
                    onEcgProbe: ecgGate ? { ecgProbeTarget = device } : nil)
                    .staggeredAppear(index: idx)
            }

            if !activeDevices.isEmpty {
                addButton
                    .staggeredAppear(index: activeDevices.count)
            }

            if !removedDevices.isEmpty { removedSection }

            whoopFirstFooter
        }
        // Add a device — guided, branching wizard (asks the device TYPE first, then runs the right
        // scan/register path: WHOOP present-scan for WHOOP families, StandardHRSource for HR straps).
        .sheet(isPresented: $showAddWizard) {
            AddDeviceWizard(live: live) { showAddWizard = false }
                .environmentObject(model)
                .environmentObject(live)
        }
        // Switch confirm
        .alert("Make this your active wearable?",
               isPresented: Binding(get: { switchTarget != nil },
                                    set: { if !$0 { switchTarget = nil } }),
               presenting: switchTarget) { device in
            Button("Cancel", role: .cancel) { switchTarget = nil }
            Button("Make active") {
                registry.setActive(device.id)
                switchTarget = nil
            }
        } message: { device in
            Text("Make \(device.displayName) your active wearable? From now on it provides your live data. \(currentActiveName)'s history stays exactly as it is. Only new days come from \(device.displayName).")
        }
        // Rename
        .alert("Rename device",
               isPresented: Binding(get: { renameTarget != nil },
                                    set: { if !$0 { renameTarget = nil } }),
               presenting: renameTarget) { device in
            TextField("Name", text: $renameDraft)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                registry.rename(device.id, to: renameDraft)
                renameTarget = nil
            }
        } message: { device in
            Text("Give \(device.brand) \(device.model) a name you'll recognise.")
        }
        // Remove confirm
        .alert("Remove this device?",
               isPresented: Binding(get: { removeTarget != nil },
                                    set: { if !$0 { removeTarget = nil } }),
               presenting: removeTarget) { device in
            Button("Cancel", role: .cancel) { removeTarget = nil }
            Button("Remove", role: .destructive) { confirmRemove(device) }
        } message: { device in
            Text("Remove \(device.displayName)? NOOP will stop connecting to it. Its recorded data is kept and you can re-add it any time.")
        }
        // Restart strap confirm (#166)
        .alert("Restart Noop Band?",
               isPresented: Binding(get: { rebootTarget != nil },
                                    set: { if !$0 { rebootTarget = nil } }),
               presenting: rebootTarget) { _ in
            Button("Cancel", role: .cancel) { rebootTarget = nil }
            Button("Restart") { model.rebootStrap(); rebootTarget = nil }
        } message: { device in
            Text("Restart \(device.displayName)? It disconnects for about 30 seconds while it reboots, then reconnects on its own. Your recorded data is kept.")
        }
        // WHOOP 4.0 reboot probe (#235): only reachable with Test Centre → Connection on and a 4.0 connected.
        // Tries each candidate frame one at a time so the strap log shows which one actually reboots.
        .confirmationDialog("WHOOP 4.0 reboot probe",
                            isPresented: Binding(get: { probeTarget != nil },
                                                 set: { if !$0 { probeTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: probeTarget) { _ in
            ForEach(RebootProbeVariant.allCases, id: \.self) { variant in
                Button(variant.menuLabel) { model.rebootProbe(variant); probeTarget = nil }
            }
            Button("Cancel", role: .cancel) { probeTarget = nil }
        } message: { _ in
            Text("The WHOOP 4.0 reboot frame isn't confirmed - a normal Restart is ignored (#235). Send each candidate and watch BOTH the strap log and the strap itself. “no disconnect within 12s” means the strap ignored the frame. A “link dropped” line means the frame reached the strap - but a dropped link alone isn't a reboot: a real reboot also switches the strap's sensor light off for a few seconds, so if the light stayed on it was just a dropped connection, not a reboot. Non-destructive - your data is kept. Please share the log so we can pin the real frame.")
        }
        // #592 extended-battery opcode probe: read-only, dumps the strap's full raw reply so a capture
        // settles the disputed GET_EXTENDED_BATTERY_INFO number (98 vs an APK decompile's 87).
        .confirmationDialog("Battery-info probe (#592 RE)",
                            isPresented: Binding(get: { batteryProbeTarget != nil },
                                                 set: { if !$0 { batteryProbeTarget = nil } }),
                            titleVisibility: .visible,
                            presenting: batteryProbeTarget) { _ in
            Button("Send probe (read-only)") { model.probeExtendedBatteryInfo(); batteryProbeTarget = nil }
            Button("Cancel", role: .cancel) { batteryProbeTarget = nil }
        } message: { _ in
            Text("Two independent protocol tables disagree on the extended-battery opcode (98 vs 87). This sends the curated read-only 98 and shows the strap's full raw reply. A battery-style payload confirms 98 on your firmware; a short stub means it stays ambiguous. Nothing is written to the strap.")
        }
        // #592 probe result: the strap's reply (or a "waiting…" state), readable + copyable in place.
        .sheet(isPresented: Binding(get: { live.extendedBatteryProbe != nil },
                                    set: { if !$0 { model.clearExtendedBatteryProbe() } })) {
            ExtendedBatteryProbeResultView(
                text: live.extendedBatteryProbe ?? "",
                onClose: { model.clearExtendedBatteryProbe() })
        }
        // #690 body-location probe (confirm + result), isolated into a ViewModifier so its two heavy
        // dialog modifiers type-check in their OWN scope — the DevicesView dialog chain is already near the
        // iOS Swift type-checker's budget, and inlining a 6th/7th modifier here tips it over ("unable to
        // type-check in reasonable time"). macOS tolerates the inline form; iOS's type-inference is stricter.
        .modifier(BodyLocationProbeSheets(target: $bodyLocationProbeTarget))
        .modifier(EcgProbeSheets(target: $ecgProbeTarget, wristTarget: $ecgWristTarget))
        // Second, strongly-worded delete-data confirm (reached from the Remove card's secondary control)
        .alert("Delete all of this device's data?",
               isPresented: Binding(get: { deleteDataTarget != nil },
                                    set: { if !$0 { deleteDataTarget = nil } }),
               presenting: deleteDataTarget) { device in
            Button("Cancel", role: .cancel) { deleteDataTarget = nil }
            Button("Delete data", role: .destructive) {
                // Route the heavy 16+-table delete through the WhoopStore actor (off the main thread) so a
                // large device dataset can't freeze the UI. Resolve the store handle inside the Task, then
                // await the delete; the registry reloads the (now-emptied) list on completion.
                let deviceId = device.id
                Task {
                    guard let store = await model.repo.storeHandle() else { return }
                    guard await registry.deleteDeviceData(deviceId, store: store) else { return }
                    model.repo.noteWorkoutsChanged()
                    await model.repo.refresh()
                    model.repo.noteAgeMetricsChanged()
                }
                deleteDataTarget = nil
            }
        } message: { device in
            Text("This permanently deletes all data recorded from \(device.displayName). This can't be undone.")
        }
        // After removing the active device, offer to pick a new active one (if any remain).
        .confirmationDialog("Pick a new active wearable",
                            isPresented: $pickNewActive,
                            titleVisibility: .visible) {
            // I-1: import sources (Oura cloud import, file imports) are excluded — they're data
            // partitions, not live devices, and must never be offered as an active-strap candidate.
            ForEach(activatableDevices) { device in
                Button(device.displayName) { registry.setActive(device.id) }
            }
            Button("Leave none active", role: .cancel) { }
        } message: {
            Text("You removed your active wearable. Choose which paired device provides your live data, or leave none active and pair one later.")
        }
    }

    // MARK: Pieces

    private var addButton: some View {
        NoopButton("Add a device", systemImage: "plus", kind: .primary, fullWidth: true) {
            showAddWizard = true
        }
        .accessibilityLabel("Add a device")
    }

    /// A real zero-device state. A blank section plus a detached Add button looked like the registry had
    /// failed to load; this card states the state, the benefit, and the next action in one accessible hero.
    private var emptyDevicesHero: some View {
        StrandCard(padding: 22, tint: StrandPalette.accent) {
            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .fill(StrandPalette.accent.opacity(0.13))
                        .frame(width: 78, height: 78)
                    Image(systemName: "wave.3.right.circle.fill")
                        .font(.system(size: 36, weight: .regular))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                }

                VStack(spacing: 6) {
                    Text("Add your first device")
                        .font(StrandFont.title2)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Connect a Noop Band, Apple Watch, heart-rate strap, ring, or supported gym machine. NOOP will show only the signals that device actually provides.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 430)
                }

                NoopButton("Add a device", systemImage: "plus", kind: .primary, fullWidth: true) {
                    showAddWizard = true
                }
                .accessibilityHint("Opens the guided device setup")
            }
            .frame(maxWidth: .infinity)
        }
        .staggeredAppear(index: 0)
    }

    private var removedSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
            sectionHead("REMOVED", trailing: String(localized: "Data kept"))
            ForEach(removedDevices) { device in
                DeviceCard(
                    device: device,
                    isActive: false,
                    isLiveConnected: false,
                    dimmed: true,
                    onMakeActive: { switchTarget = device },
                    onRename: { renameDraft = device.nickname ?? device.displayName; renameTarget = device },
                    onRemove: nil,
                    onReAdd: { registry.setActive(device.id) },
                    onDeleteData: { deleteDataTarget = device })
            }
        }
    }

    private var whoopFirstFooter: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            Text("Noop Band is NOOP's fully supported band. Other heart-rate straps can stream live heart rate and HRV, but they do not provide the deeper nightly signals available from Noop Band.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("noop.devices.footer")
    }

    /// UPPERCASE overline section header with tracking + a muted trailing note, matching the liquid Today's
    /// `sectionHead`. Keeps every page's section chrome identical.
    private func sectionHead(_ title: LocalizedStringKey, trailing: String,
                             onDark: Bool = false) -> some View {
        let color = onDark ? StrandPalette.onDarkSecondary : StrandPalette.textTertiary
        return HStack(alignment: .firstTextBaseline) {
            Text(title).font(StrandFont.overline).tracking(0).foregroundStyle(color)
            Spacer()
            Text(trailing).font(StrandFont.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 2)
    }

    // MARK: Logic

    private var currentActiveName: String {
        registry.devices.first(where: { $0.status == .active })?.displayName ?? String(localized: "Your current wearable")
    }

    /// Archive the device, then — if it was the active one and other non-archived devices remain —
    /// prompt for a new active device. The active row is demoted to `.paired` by the registry's reload,
    /// so the dialog's choices come from the still-paired devices.
    private func confirmRemove(_ device: PairedDevice) {
        let wasActive = device.status == .active
        // #78: release only the LIVE owner represented by this exact row. AppModel still has the row's
        // source/status context here, so a nil Apple Watch/import/inactive-WHOOP identifier can never be
        // misread as "release whichever WHOOP happens to be connected."
        model.prepareForDeviceRemoval(device)
        registry.archive(device.id)
        removeTarget = nil
        if wasActive {
            // Other ACTIVATABLE devices left → ask which becomes active; otherwise (none left, or only
            // import sources remain) no active device remains and there's nothing to offer (I-1).
            if !activatableDevices.isEmpty {
                pickNewActive = true
            }
        }
    }
}

// MARK: - Device card pill state (pure, testable)

/// The device card's state-pill label/tone/pulsing, as a priority-ordered pure decision (#221): archived
/// beats everything; on the active card, reconnecting > bond-refused > live > plain active; a non-active
/// card is "Paired". Mirrors the Kotlin `devicePillState` in DevicesScreen.kt exactly (see
/// `DevicePillStateTests` / the Kotlin `DevicePillStateTest`), so a future edit to either side can't
/// silently reorder "Connected · not paired" vs "Active · Live" without a test catching it.
struct DevicePillState: Equatable {
    let label: String
    let tone: StrandTone
    var pulsing: Bool = false
    var showsDot: Bool = true

    static func resolve(isArchived: Bool, isActive: Bool, isReconnecting: Bool,
                         bondRefused: Bool, isLiveConnected: Bool) -> DevicePillState {
        if isArchived { return DevicePillState(label: "Removed", tone: .neutral, showsDot: false) }
        guard isActive else { return DevicePillState(label: "Paired", tone: .neutral) }
        if isReconnecting { return DevicePillState(label: "Reconnecting…", tone: .warning, pulsing: true) }
        if bondRefused { return DevicePillState(label: "Connected · not paired", tone: .warning) }
        if isLiveConnected { return DevicePillState(label: "Active · Live", tone: .positive, pulsing: true) }
        return DevicePillState(label: "Active", tone: .positive)
    }
}

// MARK: - Device card

/// One paired device as a card: name, brand/model, capabilities line, a state pill, last-seen, and a
/// per-device actions menu. The active device is tinted with the accent (WHOOP blue) and carries an "Active" pill.
private struct DeviceCard: View {
    let device: PairedDevice
    let isActive: Bool
    let isLiveConnected: Bool
    /// #221: the active+connected strap is BLE-linked but its encrypted bond was refused (#78 state) —
    /// no HR/biometric data flows despite the link being up. Drives the "Connected · not paired" pill
    /// (which takes priority over "Active · Live") and the honest subtitle/footnote. False for every
    /// non-WHOOP source and for a normal connect.
    var bondRefused: Bool = false
    /// #221: the full #78 pairing-refusal guidance (bonded-elsewhere / pairing-mode / Forget This Device
    /// steps), shown on the card when `bondRefused` so the fix is self-service. nil otherwise.
    var pairingHint: String? = nil
    /// The active strap's link dropped for a user-initiated reboot and NOOP is auto-reconnecting (#166).
    /// Drives the transient "Reconnecting…" pill; false for every non-reboot state.
    var isReconnecting: Bool = false
    /// The active+connected device's live battery percent (0–100), surfaced on the card the same way
    /// for WHOOP, a generic strap, or an FTMS machine. nil when not the active/connected device or
    /// the source hasn't reported a battery (e.g. a strap/machine without the 0x180F service).
    var liveBatteryPct: Int? = nil
    /// #592: strap pack voltage (mV) for the active+connected strap; nil otherwise. Shown beside the percent.
    var liveBatteryMv: Int? = nil
    /// The active+connected strap's firmware version (from the connect handshake). nil when not the
    /// active/connected device, or for a source that reports no firmware (e.g. a non-WHOOP strap).
    var liveFirmware: String? = nil
    /// The active+connected strap's observed banked-history record layout (`hist_version`).
    var liveHistoryLayout: Int? = nil
    /// #987: the active+connected strap's clock-state line ("Clock latched: yes · last frame 12s ago"),
    /// nil for every other card. Built by the parent off the same pure ConnectionReadout parsers the
    /// Test Centre Connection panel binds, so the two readouts can never disagree.
    var liveClockLine: String? = nil
    /// #987: the plain-words warning when the strap RTC reads ~1970/71 (never set, so it banks no
    /// history) - the single most common "no history" root cause, surfaced where the user looks first.
    var liveClockWarning: String? = nil
    var dimmed: Bool = false
    var onMakeActive: () -> Void
    var onRename: () -> Void
    var onRemove: (() -> Void)?
    /// Restart the strap (WHOOP-only, connected-only; confirmation-gated by the parent). nil for a
    /// non-WHOOP source or a device that isn't the live-connected one. (#166)
    var onReboot: (() -> Void)? = nil
    /// WHOOP 4.0 reboot probe (Test Centre → Connection, 4.0 only). Non-nil only when the parent has
    /// decided the probe applies (live-connected WHOOP 4.0 + Connection test mode on); nil otherwise. (#235)
    var onRebootProbe: (() -> Void)? = nil
    /// #592 extended-battery opcode probe (Test Centre → Connection, both WHOOP families). Read-only.
    var onExtendedBatteryProbe: (() -> Void)? = nil
    var onBodyLocationProbe: (() -> Void)? = nil
    /// WHOOP MG ECG protocol probe. Non-nil only after opt-in and positive MG identification.
    var onEcgProbe: (() -> Void)? = nil
    /// Removed-section affordances (re-add as active / delete its data).
    var onReAdd: (() -> Void)? = nil
    var onDeleteData: (() -> Void)? = nil
    @State private var showTechnicalDetails = false

    /// The card's visible content. Every action is laid out in-flow so disclosure and action chevrons
    /// never compete with an overlaid menu on compact devices or at larger Dynamic Type sizes.
    private var cardContent: some View {
        StrandCard(padding: 18, tint: isActive ? StrandPalette.accent : nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                adaptiveHeader

                // What this device CAPTURES — honest, per-model (not the generic stored set, which would
                // mislabel e.g. a "Blood oxygen" chip when no SpO₂ % ever comes off the strap).
                capabilityRow(symbol: "waveform.path.ecg", text: profile.captures,
                              tint: StrandPalette.textSecondary)
                // What NOOP USES it for — the scores/screens this device drives.
                capabilityRow(symbol: "bolt.fill", text: profile.powers,
                              tint: StrandPalette.textSecondary)
                // #221: the full #78 pairing-refusal guidance, self-service right on the card instead of
                // buried in the strap log — only when the bond was genuinely refused.
                if bondRefused, let hint = pairingHint {
                    Text(CustomerFacingBrand.text(hint))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(CustomerFacingBrand.text(hint))
                }

                // Live battery for the active+connected device, shown as a liquid tube that fills to the
                // charge — same surface for WHOOP / strap / FTMS. The tube reads the charge band's colour.
                if let pct = liveBatteryPct {
                    batteryTube(pct)
                }

                HStack(spacing: 6) {
                    Text(lastSeenLine)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer()
                }

                technicalDisclosure

                if let action = primaryAction, let hint = primaryActionHint {
                    Button(action: action) {
                        HStack(spacing: 7) {
                            Text(hint)
                                .font(StrandFont.subhead)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .accessibilityHidden(true)
                        }
                        .foregroundStyle(StrandPalette.accent)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .opacity(dimmed ? 0.6 : 1)
        .accessibilityElement(children: .contain)
    }

    /// Keep identity and connection state in one row while there is genuinely room. Compact widths,
    /// larger text, and long user-assigned names move the pills below the identity instead of squeezing
    /// or overlapping either side.
    private var adaptiveHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                deviceIdentity(multiline: false)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: NoopMetrics.space2)
                stateBadges
                    .fixedSize(horizontal: true, vertical: false)
                actionsMenu
            }

            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .top, spacing: NoopMetrics.space2) {
                    deviceIdentity(multiline: true)
                    Spacer(minLength: NoopMetrics.space1)
                    actionsMenu
                }
                stateBadges
                    .padding(.leading, 28 + NoopMetrics.space3)
            }
        }
    }

    private func deviceIdentity(multiline: Bool) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: icon)
                .font(StrandFont.title2)
                .foregroundStyle(isActive ? StrandPalette.accent : StrandPalette.textSecondary)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.displayName)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(multiline ? 2 : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("noop.device.\(device.id).name")
                Text(profile.displayModel)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var stateBadges: some View {
        HStack(spacing: NoopMetrics.space2) {
            // Locally-adopted Oura is Beta: a non-dot Beta chip sits beside the usual state pill.
            if device.sourceKind == .oura {
                StatePill("Beta", tone: .warning, showsDot: false)
            }
            statePill
        }
    }

    /// Firmware, voltage, clock correlation, record layout and model caveats are valuable when debugging,
    /// but they should not compete with connection state on every visit. Keep them one explicit tap away.
    private var technicalDisclosure: some View {
        DisclosureGroup(isExpanded: $showTechnicalDetails) {
            VStack(alignment: .leading, spacing: 9) {
                if device.sourceKind == .oura && !isLiveConnected && device.status == .paired {
                    ouraLocalStateNote
                }
                if !profile.footnote.isEmpty {
                    technicalLine(symbol: "info.circle", text: profile.footnote)
                }
                if let fw = liveFirmware {
                    technicalLine(symbol: "cpu", text: String(localized: "Firmware \(fw)"))
                }
                if let mv = liveBatteryMv {
                    technicalLine(symbol: "bolt", text: String(localized: "Battery voltage \(Double(mv) / 1000.0, specifier: "%.2f") V"))
                }
                if let layout = liveHistoryLayout {
                    technicalLine(symbol: "externaldrive", text: String(localized: "History record layout v\(layout)"))
                }
                if let clockLine = liveClockLine {
                    technicalLine(symbol: "clock.arrow.2.circlepath", text: clockLine)
                }
                if let warning = liveClockWarning {
                    technicalLine(symbol: "exclamationmark.triangle", text: warning,
                                  tint: StrandPalette.statusWarning)
                }
            }
            .padding(.top, 10)
        } label: {
            Text("Technical details")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .tint(StrandPalette.textSecondary)
        .accessibilityHint(showTechnicalDetails
                           ? "Hides firmware, protocol and sensor caveats"
                           : "Shows firmware, protocol and sensor caveats")
    }

    private func technicalLine(symbol: String, text: String,
                               tint: Color = StrandPalette.textTertiary) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .frame(width: 15)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// Actions stay as peer controls inside the card. Wrapping the entire card in a Button would
    /// nest the Technical details disclosure inside that Button, causing disclosure taps to activate the
    /// device instead of opening diagnostics.
    var body: some View {
        cardContent
    }

    /// The card's primary tap action, or nil when there isn't one. A paired-but-not-active band → make it
    /// active; a removed band → re-add it as active. The active band and any card without those callbacks
    /// have no whole-card tap (their controls live entirely in the ⋮ menu). I-1: an import source (Oura
    /// cloud import, file imports) never offers activation — it's a data partition, not a live device;
    /// making it "active" would demote whatever live device drives BLE routing + day-owner priority 0.
    private var primaryAction: (() -> Void)? {
        if device.isImportSource { return nil }
        if device.status == .archived { return onReAdd }
        if !isActive { return onMakeActive }
        return nil
    }

    /// Short accent label for the explicit primary action. nil when the card has no primary action.
    private var primaryActionHint: String? {
        if device.isImportSource { return nil }
        if device.status == .archived { return onReAdd == nil ? nil : String(localized: "Make active") }
        if !isActive { return String(localized: "Make active") }
        return nil
    }

    /// The live battery as a liquid tube (fills to the charge, coloured by band) with a trailing percent.
    /// Static-posed so it costs nothing per frame — one of many small liquid elements on the screen.
    private func batteryTube(_ pct: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: batterySymbol(pct))
                .font(StrandFont.caption)
                .foregroundStyle(batteryTint(pct))
                .frame(width: 18)
                .accessibilityHidden(true)
            LiquidTube(frac: Double(pct) / 100, tint: batteryTint(pct), height: 8, animated: false)
            Text("\(pct)%")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(pct) percent")
    }

    /// The charge-band colour for the battery tube/icon (mirrors the menu-bar battery buckets).
    private func batteryTint(_ pct: Int) -> Color {
        pct < 15 ? StrandPalette.statusCritical : pct < 35 ? StrandPalette.statusWarning : StrandPalette.chargeColor
    }

    /// The pure `DevicePillState.resolve` priority (#221): reboot's "Reconnecting…" beats a bond refusal's
    /// "Connected · not paired", which beats "Active · Live" - pinned by `DevicePillStateTests` instead of
    /// only verified visually.
    private var pillState: DevicePillState {
        DevicePillState.resolve(isArchived: device.status == .archived, isActive: isActive,
                                 isReconnecting: isReconnecting, bondRefused: bondRefused,
                                 isLiveConnected: isLiveConnected)
    }

    private var statePill: some View {
        let state = pillState
        return StatePill(LocalizedStringKey(state.label), tone: state.tone,
                          showsDot: state.showsDot, pulsing: state.pulsing)
    }

    private var actionsMenu: some View {
        Menu {
            if device.status == .archived {
                // I-1: a removed import source (e.g. Oura cloud import, archived on Disconnect) never
                // offers "Make active" reactivation - it's a data partition, not a live device.
                if let onReAdd, !device.isImportSource {
                    Button { onReAdd() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                if let onDeleteData {
                    Divider()
                    Button(role: .destructive) { onDeleteData() } label: {
                        Label("Delete this device's data…", systemImage: "trash")
                    }
                }
            } else {
                if !isActive && !device.isImportSource {
                    Button { onMakeActive() } label: { Label("Make active", systemImage: "bolt.fill") }
                }
                Button { onRename() } label: { Label("Rename", systemImage: "pencil") }
                // Restart the strap — only for the live-connected WHOOP (the reboot travels over the active
                // BLE link). Confirmation-gated by the parent. (#166)
                if isLiveConnected, SourceCoordinator.isWhoop(device), let onReboot {
                    Button { onReboot() } label: { Label("Restart Noop Band…", systemImage: "arrow.clockwise") }
                }
                // 4.0 reboot probe (RE): only present when the parent passed a closure (Test Centre →
                // Connection on + a live WHOOP 4.0). Finds the real reboot frame the 4.0 accepts (#235).
                if let onRebootProbe {
                    Button { onRebootProbe() } label: { Label("Reboot probe (4.0 RE)…", systemImage: "ladybug") }
                }
                // #592 extended-battery opcode probe (RE): read-only, both families. Test Centre → Connection.
                if let onExtendedBatteryProbe {
                    Button { onExtendedBatteryProbe() } label: { Label("Battery-info probe (#592 RE)…", systemImage: "ladybug") }
                }
                // #690 body-location opcode probe (RE): read-only, both families. Test Centre → Connection.
                if let onBodyLocationProbe {
                    Button { onBodyLocationProbe() } label: { Label("Body-location probe (#690 RE)…", systemImage: "ladybug") }
                }
                if let onEcgProbe {
                    Button { onEcgProbe() } label: {
                        Label("ECG spot recording (experimental)…", systemImage: "waveform.path.ecg")
                    }
                }
                if let onRemove {
                    Divider()
                    Button(role: .destructive) { onRemove() } label: {
                        Label("Remove", systemImage: "minus.circle")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Device actions for \(device.displayName)")
        .accessibilityIdentifier("noop.device.actions")
    }

    /// SF Symbol for the device: WHOOP keeps the band glyph; an FTMS machine reads as gym equipment;
    /// an Apple Watch reads as a watch; generic straps read as a heart-rate strap.
    private var icon: String {
        if device.sourceKind == .ftms { return "figure.run.treadmill" }
        if device.sourceKind == .huami { return "waveform.path.ecg.rectangle" }
        if device.sourceKind == .liveAppleWatch { return "applewatch" }
        if device.sourceKind == .oura { return "circle.circle" }
        return SourceCoordinator.isWhoop(device) ? "applewatch.side.right" : "heart.circle"
    }

    /// The honest, per-model capability + function summary for this device's card.
    private var profile: DeviceCapabilityProfile { .make(for: device) }

    /// One icon-prefixed info row (captures / powers), matching the card's caption style.
    private func capabilityRow(symbol: String, text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.caption)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var lastSeenLine: String {
        if device.status == .archived { return String(localized: "Removed · data kept") }
        // No "tap ⋯" pointer here (#221 review) - the full how-to-fix guidance is already inline on the
        // card just below, so pointing at the menu would send the user looking for help that's already
        // on screen.
        if bondRefused { return String(localized: "Connected, but not paired") }
        if isLiveConnected { return String(localized: "Connected now") }
        return String(localized: "Last seen \(relativeAgo(TimeInterval(device.lastSeenAt)))")
    }

    /// Honest paired-but-not-connected note for a locally-adopted Oura ring. Amber heads-up, no fabricated
    /// reading: re-states the single-owner reality so the user understands why a re-reset / Oura re-claim
    /// would break NOOP's ownership.
    private var ouraLocalStateNote: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text("Paired locally. NOOP owns this ring while it holds the key. If you reset it again or set it up in the Oura app, NOOP no longer owns it and you would re-add it to take it over.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A battery SF Symbol matching the charge band (mirrors the menu-bar battery glyph buckets).
    private func batterySymbol(_ pct: Int) -> String {
        switch pct {
        case ..<13:  return "battery.0"
        case ..<38:  return "battery.25"
        case ..<63:  return "battery.50"
        case ..<88:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

// MARK: - Capability profile

/// Honest, per-model summary of what a device captures and what NOOP uses it for — shown on its card.
///
/// Derived from brand/model/sourceKind, NOT from the stored capability `Set`. The stored set is generic
/// across WHOOP models (it would render an identical "Heart rate · HRV · Blood oxygen · Skin temp · …"
/// line for a 4.0 and a 5/MG alike) and it mislabels: no SpO₂ **percentage** ever comes off any WHOOP
/// strap (raw red/IR only — a real % exists only from a WHOOP CSV / Apple Health import), skin temp is a
/// nightly ±°C sleep deviation rather than a live reading, steps are 5/MG-only and a raw motion count,
/// and Charge/Effort/Rest are NOOP-derived scores. Verdicts are source-verified against the decode +
/// scoring paths (the device-capability audit). `*` in a label = an on-device estimate, not a raw sensor.
struct DeviceCapabilityProfile {
    let displayModel: String   // clean card subtitle (replaces the redundant "WHOOP · WHOOP")
    let captures: String       // "·"-joined honest capture labels for THIS model
    let powers: String         // the NOOP scores / screens this device drives
    let footnote: String       // one short honest caveat line ("*" estimates + the SpO₂/steps notes)

    static func make(for d: PairedDevice) -> DeviceCapabilityProfile {
        // FTMS gym machine: a live machine + (when reported) HR session, recorded via the existing
        // live-workout path. Honest — we surface the machine's metrics + HR live; the session is
        // Effort-scored only when the machine actually reports heart rate.
        if d.sourceKind == .ftms {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Gym equipment (FTMS)"),
                captures: String(localized: "Speed · Cadence · Power · Distance · Energy · Heart rate (if the machine sends it)"),
                powers: String(localized: "Records a live machine workout, Effort-scored from HR when the machine reports it"),
                footnote: String(localized: "Live machine data over Bluetooth FTMS. No sleep, recovery, skin temp or SpO₂. Effort needs the machine's heart rate; without it the session logs the machine metrics only."))
        }
        // EXPERIMENTAL Huami device (Amazfit / Zepp / Mi Band): best-effort live HR only, honest about it.
        if d.sourceKind == .huami {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "\(d.brand) (experimental)"),
                captures: String(localized: "Heart rate (live, best-effort)"),
                powers: String(localized: "Powers the live console + Effort. No Recovery or Sleep Score"),
                footnote: String(localized: "Experimental: live heart rate where the band exposes it. Some bands need a pairing we can't do yet. NOOP will say so honestly and never show a made-up number. No sleep, recovery, skin temp, SpO₂ or steps."))
        }
        // EXPERIMENTAL locally-adopted Oura ring (gen 3/4/5). The gen is carried on `model` ("Oura Ring
        // 3/4/5") and recovered with OuraRingGen.from(model:). NOOP reads the ring's OWN raw signals + open
        // HRV/sleep-phase tags and computes its own Charge/Effort/Rest; it NEVER reads Oura's encrypted
        // Readiness/Sleep scores, and claims NO absolute SpO₂ %. Estimates carry "*"; a signal it can't read
        // stays "-". Per-gen copy and the canonical Beta caveat (spec
        // docs/superpowers/specs/2026-06-29-oura-onboarding-ux.md s3/s4).
        if d.sourceKind == .oura {
            let gen = OuraRingGen.from(model: d.model)
            // gen3/4 are verified-shape; gen5 ("newer") carries the least-proven caveat.
            let newer = (gen == .gen5)
            let captures = newer
                ? String(localized: "Heart rate* · HRV* · Sleep* · Resting HR* · Skin temp* · Battery*")
                : String(localized: "Heart rate · HRV* · Sleep · Resting HR · Skin temp* · Battery")
            let powers = newer
                ? String(localized: "Powers Effort now; Recovery and Sleep once enough nights and decode are confirmed")
                : String(localized: "Powers Recovery, Effort, Sleep Score and sleep details")
            return DeviceCapabilityProfile(
                displayModel: String(localized: "\(gen.displayName) (Beta)"),
                captures: captures,
                powers: powers,
                footnote: String(localized: "Beta. * is an on-device estimate. Skin temp is a trend versus your own baseline, and HRV needs you to be still. No Oura Readiness or SpO₂ percentage comes off the ring (import an Oura file for those)."))
        }
        // Apple Watch (live HealthKit source). UNLIKE the WHOOP/strap branches, the watch's stored
        // capability `Set` is already the honest per-model trim (AppleWatchDevice only adds a metric
        // once real data for it arrives), so we read the labels straight off it. An older watch with
        // no SpO₂/wrist-temp samples simply won't list them. Recovery is the calibrating-by-design
        // score (~a week of nights), so the footnote sets that expectation rather than over-promising.
        if d.sourceKind == .liveAppleWatch {
            let labels: [(Metric, String)] = [
                (.hr, String(localized: "Heart rate")), (.hrv, "HRV"), (.sleep, String(localized: "Sleep")),
                (.steps, String(localized: "Steps")), (.spo2, String(localized: "Blood oxygen")), (.skinTemp, String(localized: "Wrist temp")),
            ]
            let captures = labels.filter { d.capabilities.contains($0.0) }.map { $0.1 }.joined(separator: " · ")
            return DeviceCapabilityProfile(
                displayModel: "Apple Watch",
                captures: captures.isEmpty ? String(localized: "Calibrating, no data yet") : captures,
                powers: String(localized: "Powers Sleep, Effort, Fitness Age and steps, plus Recovery once its baseline calibrates"),
                footnote: String(localized: "Computed live from your Apple Watch via Health. Recovery needs about a week of nights to calibrate, and every watch-derived score is labelled with its confidence. Only the metrics your watch actually records are listed above."))
        }
        // Generic heart-rate strap: live HR + R-R only; drives the live console + Effort, nothing nightly.
        // (Same WHOOP test as SourceCoordinator.isWhoop, inlined so this stays nonisolated.)
        let isWhoop = d.id == "my-whoop" || d.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
        guard isWhoop else {
            return DeviceCapabilityProfile(
                displayModel: String(localized: "Heart-rate strap"),
                captures: String(localized: "Heart rate · HRV (live)* · Strain"),
                powers: String(localized: "Powers the live console + Effort. No Recovery or Sleep Score"),
                footnote: String(localized: "Live HR + R-R only · no sleep, recovery, skin temp, SpO₂, steps or battery (those require Noop Band or another compatible source)."))
        }
        let whoopPowers = String(localized: "Powers Recovery, Effort, Sleep Score, sleep details + Health Monitor")
        let model = d.model.lowercased()
        // Newer transport family adds a raw motion count that can support an estimated step series.
        if model.contains("5") || model.contains("mg") {
            return DeviceCapabilityProfile(
                displayModel: "Noop Band",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Steps* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation, steps are a raw motion count. No SpO₂ percentage comes directly from Noop Band; use Apple Health or a supported file import for that."))
        }
        // Older transport family does not expose a usable step stream.
        if model.contains("4") {
            return DeviceCapabilityProfile(
                displayModel: "Noop Band",
                captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
                powers: whoopPowers,
                footnote: String(localized: "* on-device estimate: skin temp is a nightly ±°C deviation (firmware-dependent); steps are unavailable on this firmware. No SpO₂ percentage comes directly from Noop Band; use Apple Health or a supported file import for that."))
        }
        // Unknown family: show only the capability set common to supported Noop Band transports.
        return DeviceCapabilityProfile(
            displayModel: "Noop Band",
            captures: String(localized: "Heart rate · HRV · Skin temp* · Resp rate* · Sleep · Strain · Battery"),
            powers: whoopPowers,
            footnote: String(localized: "Hardware details are still being identified, so this shows only common signals. * indicates an on-device estimate. SpO₂ percentage requires another compatible source."))
    }
}

// MARK: - Signal indicator

/// A four-bar Wi-Fi-style signal indicator derived from RSSI. RSSI is negative dBm: closer to 0 is
/// stronger. Buckets are coarse on purpose — a precise dBm readout would be noise to the user.
/// Internal (not private) so the Add-a-device wizard reuses the same indicator.
struct SignalBars: View {
    let rssi: Int

    static func level(for rssi: Int) -> Int {
        switch rssi {
        case (-55)...:    return 4   // very strong
        case (-67)...:    return 3
        case (-80)...:    return 2
        case (-90)...:    return 1
        default:          return 0
        }
    }

    var body: some View {
        let level = Self.level(for: rssi)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(i < level ? StrandPalette.accent : StrandPalette.hairlineStrong)
                    .frame(width: 3, height: 6 + CGFloat(i) * 3)
            }
        }
        .frame(width: 22, height: 18, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

// MARK: - #592 extended-battery probe result

/// The #592 probe reply (raw hex + payload triage + capture diff), or a "waiting…" state while in flight.
/// Read-only; the text is selectable and a Copy button puts it on the clipboard so a capture pastes into
/// the issue without a full strap-log export. Twin of the Android BatteryInfoProbeResultDialog.
private struct ExtendedBatteryProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.extendedBatteryProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Battery-info probe result (#592)")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if waiting {
                Text("Waiting for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(StrandPalette.surfaceOverlay)
    }
}

/// #690: the body-location probe's confirm + result dialogs as one ViewModifier, so they're type-checked
/// in isolation instead of extending the DevicesView `.confirmationDialog`/`.sheet` chain (which is already
/// near the iOS Swift type-checker's budget). `model`/`live` auto-inject from the parent's environment.
private struct BodyLocationProbeSheets: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var target: PairedDevice?

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Body-location probe (#690 RE)",
                                isPresented: Binding(get: { target != nil },
                                                     set: { if !$0 { target = nil } }),
                                titleVisibility: .visible,
                                presenting: target) { _ in
                Button("Send probe (read-only)") { model.probeBodyLocationAndStatus(); target = nil }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { _ in
                Text("Sends the read-only GET_BODY_LOCATION_AND_STATUS (0x54) and shows the strap's full raw reply, decoding the body-location record (revision / location / confidence / status) on WHOOP 4.0. Nothing is written to the strap, and it never changes wear detection or scoring.")
            }
            .sheet(isPresented: Binding(get: { live.bodyLocationProbe != nil },
                                        set: { if !$0 { model.clearBodyLocationProbe() } })) {
                BodyLocationProbeResultView(
                    text: live.bodyLocationProbe ?? "",
                    onClose: { model.clearBodyLocationProbe() })
            }
    }
}

/// The #690 body-location probe reply (raw hex + decoded record + capture diff), or a "waiting…" state
/// while in flight. Read-only; selectable text + a Copy button. Twin of the Android BodyLocationProbe
/// result dialog and structurally identical to ExtendedBatteryProbeResultView.
private struct BodyLocationProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.bodyLocationProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Body-location probe result (#690)")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            if waiting {
                Text("Waiting for the strap's reply…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting {
                    Button("Copy") { PlatformPasteboard.copy(text) }
                }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(StrandPalette.surfaceOverlay)
    }
}

// MARK: - ECG spot-recording research probe

/// Keeps the multi-step, explicitly user-started MG protocol probe isolated from the already-heavy
/// Devices view modifier chain. The BLE layer repeats every gate before it writes a byte.
private struct EcgProbeSheets: ViewModifier {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveState
    @Binding var target: PairedDevice?
    @Binding var wristTarget: PairedDevice?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Noop Band ECG spot recording (experimental)",
                isPresented: Binding(get: { target != nil }, set: { if !$0 { target = nil } }),
                titleVisibility: .visible,
                presenting: target
            ) { device in
                Button("Start 30-second spot recording") {
                    model.ecgStartCapture()
                    target = nil
                }
                Button("Stop spot recording") {
                    model.ecgStopCapture()
                    target = nil
                }
                Button("Set wrist…") {
                    target = nil
                    wristTarget = device
                }
                Button("Cancel", role: .cancel) { target = nil }
            } message: { _ in
                Text("Research instrumentation only, not a diagnostic ECG or continuous monitor. Keep the opposite hand touching both clasp electrodes for the full 30 seconds. Signal units, scale, and any band-provided rhythm classification are unvalidated and are not shown as health results. The commands may do nothing; Stop reverses the stream controls.")
            }
            .sheet(isPresented: Binding(get: { wristTarget != nil },
                                        set: { if !$0 { wristTarget = nil } })) {
                EcgWristSheet(
                    onPick: { wrist in
                        model.ecgSelectWrist(wrist)
                        wristTarget = nil
                    },
                    onCancel: { wristTarget = nil })
            }
            .sheet(isPresented: Binding(get: { live.ecgProbe != nil },
                                        set: { if !$0 { model.clearEcgProbe() } })) {
                EcgProbeResultView(
                    text: live.ecgProbe ?? "",
                    onClose: { model.clearEcgProbe() })
            }
    }
}

/// Wrist selection is a persistent strap setting, so it gets a separate, deliberate confirmation.
private struct EcgWristSheet: View {
    let onPick: (Whoop5Ecg.WristSelection) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Which wrist do you wear it on?")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("This choice is written to the strap and persists after disconnecting. The left/right wire mapping is inferred, not yet hardware-validated; selecting the other wrist reverses it.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: NoopMetrics.space3) {
                Button("Left wrist") { onPick(.left) }
                Button("Right wrist") { onPick(.right) }
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 220)
        .background(StrandPalette.surfaceOverlay)
    }
}

private struct EcgProbeResultView: View {
    let text: String
    let onClose: () -> Void
    private var waiting: Bool { text == BLEManager.ecgProbeWaiting }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ECG spot-recording probe")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Unvalidated research instrumentation - not a medical measurement or diagnosis.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
            if waiting {
                ProgressView("Listening for the strap for 30 seconds…")
            } else {
                ScrollView {
                    Text(text)
                        .font(StrandFont.mono)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if !waiting { Button("Copy") { PlatformPasteboard.copy(text) } }
                Spacer()
                Button("Close") { onClose() }
            }
        }
        .padding(20)
        .frame(minWidth: 340, minHeight: 260)
        .background(StrandPalette.surfaceOverlay)
    }
}

// MARK: - Capability catalog (DEBUG render harness)

#if DEBUG
/// DEBUG-only: one DeviceCard per capability-profile kind so the honest per-model display can be
/// screenshotted deterministically (`--demo-screen devicescatalog`). Same file as `DeviceCard` /
/// `DeviceCapabilityProfile` so it can reach them. Stripped from Release.
struct DeviceCardCatalog: View {
    private static let whoopCaps: Set<Metric> = [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad]

    private static func dev(_ id: String, _ brand: String, _ model: String,
                            _ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: id, brand: brand, model: model, nickname: nil, peripheralId: nil,
                     sourceKind: .liveBLE, capabilities: caps, status: .paired,
                     addedAt: 0, lastSeenAt: 0)
    }

    private static func watch(_ caps: Set<Metric>) -> PairedDevice {
        PairedDevice(id: "apple-health", brand: "Apple", model: "Apple Watch", nickname: nil,
                     peripheralId: nil, sourceKind: .liveAppleWatch, capabilities: caps,
                     status: .paired, addedAt: 0, lastSeenAt: 0)
    }

    /// A locally-adopted Oura ring (sourceKind `.oura`), built with mock data so the honest per-gen Beta
    /// card renders deterministically WITHOUT a ring. `model` carries the gen ("Oura Ring 3/4/5").
    static func oura(_ model: String, status: DeviceStatus = .paired) -> PairedDevice {
        PairedDevice(id: "oura-demo-\(model)", brand: "Oura", model: model, nickname: nil,
                     peripheralId: "00000000-0000-0000-0000-0000000000aa", sourceKind: .oura,
                     capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep],
                     status: status, addedAt: 0, lastSeenAt: 0)
    }

    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "What each band captures (and what NOOP uses it for).",
                       topBackground: liquidScaffoldSky()) {
            VStack(spacing: NoopMetrics.gap) {
                DeviceCard(device: Self.dev("whoop-4d", "WHOOP", "4.0", Self.whoopCaps),
                           isActive: true, isLiveConnected: true,
                           onMakeActive: {}, onRename: {}, onRemove: nil)
                DeviceCard(device: Self.dev("whoop-5d", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // #221: a WHOOP 5/MG that's BLE-connected but whose encrypted bond was refused (#78) — no
                // data flows despite the link being up. Renders the "Connected · not paired" pill + the
                // self-service pairing guidance so this can be verified WITHOUT reproducing the bond
                // refusal on real hardware.
                DeviceCard(device: Self.dev("whoop-5-refused", "WHOOP", "5.0 MG",
                                            Self.whoopCaps.union([.steps])),
                           isActive: true, isLiveConnected: true, bondRefused: true,
                           pairingHint: "Noop Band will not pair because another app or an old phone pairing still holds its secure connection. Close other band apps, put Noop Band in pairing mode, then open Settings → Bluetooth and choose Forget This Device if the band is listed. Return to NOOP and reconnect.",
                           onMakeActive: {}, onRename: {}, onRemove: {})
                DeviceCard(device: Self.dev("strap-d", "Polar", "H10", [.hr, .hrv]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Apple Watch, with an older-model trimmed set (no SpO₂ / wrist temp) so the honest
                // capability read renders deterministically alongside the straps.
                DeviceCard(device: Self.watch([.hr, .hrv, .sleep, .steps]),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // Locally-adopted Oura ring (Beta): per-gen honest capability copy + the Beta chip + the
                // paired-but-not-connected local-state note, all without a ring on-wrist.
                DeviceCard(device: Self.oura("Oura Ring 3"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}

/// DEBUG-only: just the locally-adopted Oura device card, active + connected, so `--demo-screen ouradevice`
/// can screenshot the Beta Oura card (battery + "Active · Live") WITHOUT a ring. Same file as `DeviceCard`
/// so it can reach it. Stripped from Release.
struct OuraDeviceDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "A locally-adopted Oura ring, in beta.",
                       topBackground: liquidScaffoldSky()) {
            VStack(spacing: NoopMetrics.gap) {
                // Active + connected so the card shows "Active · Live" + a live battery readout.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 3"),
                           isActive: true, isLiveConnected: true, liveBatteryPct: 71,
                           onMakeActive: {}, onRename: {}, onRemove: {})
                // A second, paired-but-not-connected gen-4 ring so the honest local-state note + per-gen
                // copy render in the same shot.
                DeviceCard(device: DeviceCardCatalog.oura("Oura Ring 4"),
                           isActive: false, isLiveConnected: false,
                           onMakeActive: {}, onRename: {}, onRemove: {})
            }
        }
    }
}

/// DEBUG-only: just the WHOOP 5/MG bond-refused card, so `--demo-screen bondrefused` can screenshot the
/// "Connected · not paired" pill + the self-service #78 pairing guidance (#221) WITHOUT reproducing the
/// bond refusal on real hardware. Same file as `DeviceCard` so it can reach it. Stripped from Release.
struct BondRefusedDemoScreen: View {
    var body: some View {
        ScreenScaffold(title: "Devices",
                       subtitle: "A Noop Band whose secure connection was refused.",
                       topBackground: liquidScaffoldSky()) {
            DeviceCard(device: PairedDevice(id: "whoop-5-refused-solo", brand: "WHOOP", model: "5.0 MG",
                                            nickname: nil, peripheralId: nil, sourceKind: .liveBLE,
                                            capabilities: [.hr, .hrv, .spo2, .skinTemp, .sleep, .strainLoad, .steps],
                                            status: .active, addedAt: 0, lastSeenAt: 0),
                       isActive: true, isLiveConnected: true, bondRefused: true,
                       pairingHint: "Noop Band will not pair because another app or an old phone pairing still holds its secure connection. Close other band apps, put Noop Band in pairing mode, then open Settings → Bluetooth and choose Forget This Device if the band is listed. Return to NOOP and reconnect.",
                       onMakeActive: {}, onRename: {}, onRemove: {})
        }
    }
}
#endif

// MARK: - Preview

#if DEBUG
#Preview("Devices") {
    let model = AppModel()
    return DevicesView()
        .environmentObject(model)
        .environmentObject(model.live)
        .frame(width: 480, height: 760)
        .background(StrandPalette.surfaceBase)
        .preferredColorScheme(.dark)
}
#endif
