# NOOP — Android

A **local-first WHOOP companion** for Android. NOOP connects directly to a WHOOP 4.0
(and WHOOP 5.0) strap over Bluetooth Low Energy, reads heart rate, R-R intervals,
battery, and sensor data, and stores everything **locally** on the device. There is
no required account or cloud. Internet access exists only for explicit opt-ins such
as the bring-your-own-key Coach and upload to a server the user configures.

This is a Kotlin / Jetpack Compose port of the hardware-verified macOS reference app
(`/path/to/NOOP`, Swift). The protocol, framing, and BLE handshake are
translated from that verified implementation; they are not invented here.

---

## Status — read this first

The checked-in project is compiled and covered by the Android JVM suite in CI.
WHOOP 4.0 is the established hardware path; WHOOP 5.0/MG live heart rate works,
while deeper 5/MG history and biometric decoding remain experimental. A green
emulator/JVM build still cannot prove a real BLE bond or strap firmware behavior.

In particular, **the BLE layer must be validated on real hardware** — a phone with
Bluetooth and an actual WHOOP strap. The bond trick (one confirmed write to the command
characteristic), the realtime HR stream, the historical (type-47) offload, and the haptic
buzz cannot be exercised in an emulator. See the **Verification checklist** at the bottom.

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **JDK** | 17 | The build targets `jvmTarget = "17"`. Select JDK 17 under *Settings → Build Tools → Gradle → Gradle JDK*, or install Temurin 17. |
| **Android SDK** | API 36 (compileSdk/targetSdk), Build Tools 36.0.0 | Install the Android 16 platform, Build Tools 36.0.0, and Platform-Tools via the SDK Manager. `minSdk` remains 26 (Android 8.0). |
| **Android Studio** | Current stable | Must support syncing the pinned AGP 8.13.2 / Gradle 8.14.5 toolchain. |
| **A physical device** | Android 8.0+ with BLE | An emulator has no Bluetooth radio — you cannot test the strap link on it. |
| **A WHOOP strap** | WHOOP 4.0 (verified) or 5.0 | Required to exercise the protocol end-to-end. |

### Point Gradle at your SDK

Create `local.properties` in this `android/` directory (it is git-ignored):

```properties
sdk.dir=/Users/<you>/Library/Android/sdk
```

Android Studio writes this for you automatically when you open the project.

---

## Toolchain versions (pinned)

These are fixed in the build files; keep them in lockstep if you upgrade:

- **Android Gradle Plugin** 8.13.2 · **Gradle** 8.14.5 (wrapper)
- **Kotlin** 1.9.24 · **KSP** 1.9.24-1.0.20 (KSP must always match the Kotlin version)
- **Compose Compiler** extension 1.5.14 (matched to Kotlin 1.9.24)
- **Compose BOM** 2024.06.00 · **Material3** (from the BOM)
- **Room** 2.6.1 · **coroutines** 1.8.1
- **minSdk** 26 · **compile/targetSdk** 36 · **Build Tools** 36.0.0 · **JDK target** 17

### Updating dependencies safely

The resolved Android graph is committed in `app/gradle.lockfile`, and Gradle verifies downloaded
plugins, metadata, and artifacts against `gradle/verification-metadata.xml`. When changing a plugin,
library, BOM, or the Gradle wrapper:

1. Make the version change in the relevant build file.
2. Regenerate both security files with JDK 17:

   ```bash
   ./gradlew :app:dependencies --write-locks --write-verification-metadata sha256
   ```

3. Review the lockfile and verification-metadata diffs. Treat newly generated checksums as a
   trust-on-first-use prompt: confirm the coordinates and release from the publisher or repository;
   do not accept unexpected artifacts merely to make a build pass.
4. Exercise every shipped variant and the JVM tests before committing:

   ```bash
   ./gradlew assembleFullDebug assembleDemoDebug \
     testFullDebugUnitTest testDemoDebugUnitTest
   ./gradlew -PstagingRelease assembleFullRelease assembleDemoRelease
   ```

Never bypass verification or hand-edit the generated lockfile. For a wrapper upgrade, also obtain
the binary-distribution SHA-256 from Gradle's official checksum reference and regenerate the wrapper
JAR/scripts with the target Gradle version.

---

## Build & run

```bash
cd /path/to/NOOP/android

# If intentionally regenerating the checked-in wrapper, use the pinned version + official checksum.
./gradlew wrapper --gradle-version 8.14.5 \
  --gradle-distribution-sha256-sum 6f74b601422d6d6fc4e1f9a1ab6522f642c2fdcbc15ae33ebd30ba3d7198e854

# Compile the full debug APK:
./gradlew :app:assembleFullDebug

# Install the full debug flavour onto a connected, USB-debugging-enabled device:
./gradlew :app:installFullDebug

# Or simply open this folder in Android Studio and press Run.
```

The full debug APK lands at `app/build/outputs/apk/full/debug/app-full-debug.apk`. The demo
counterpart is `app/build/outputs/apk/demo/debug/app-demo-debug.apk` after
`./gradlew :app:assembleDemoDebug`.

> **About the wrapper:** `gradle-wrapper.jar`, both wrapper scripts, and the wrapper properties are
> checked in. The properties pin the Gradle distribution checksum, while CI validates the wrapper
> JAR. Do not regenerate only one part of the wrapper or substitute an unreviewed binary.

### Release and staging signing

A normal release build refuses to run without a gitignored
`android/keystore.properties` pointing at a private signing key you control.

`-PstagingRelease` gives a release the separate
`com.noop.whoop.staging` application ID, but it does **not** weaken the signing
gate. Both staging and non-staging release builds require either the gitignored
`keystore.properties` values or all four `NOOP_RELEASE_*` environment variables.
Repository workflows obtain a private staging identity from Actions secrets.

The pinned AGP 8.13.2 / Gradle 8.14.5 toolchain compiles and targets API 36. A Play-labelled build
must use `-PplayRelease`; `./gradlew :app:verifyPlayTargetSdk` exposes the same API-floor gate
directly. Meeting that build-time target is not by itself a publication: Play policy, console, and
review requirements still apply. Every release path, including `-PplayRelease`, remains fail-closed
unless the private signing configuration above is present.

Ordinary local debug builds still work without release secrets and use Gradle's
per-machine debug identity. The tracked `fork-debug.keystore` is retained only as
a historical artifact and is no longer referenced by Gradle or release workflows:
its credentials are public, so any APK bearing that signature is forgeable and
must be treated as disposable. It cannot be a trusted update or production
identity.

Changing away from the historical public signature means a privately signed
`com.noop.whoop.staging` APK cannot update an older public-key staging install.
Export and verify an in-app backup before uninstalling the old app, then restore
after installing the new build. Preserve and back up the private staging key;
rotating or losing it prevents future in-place updates.

Android `.noopbak` exports use the authenticated `NOOPBAK` v1 envelope: PBKDF2-
HMAC-SHA256 (310,000 iterations) plus chunked AES-256-GCM. Manual exports ask for
the passphrase each time. Opt-in folder backups store their user-chosen recovery
passphrase only in Keystore-backed encrypted preferences and fail closed if it is
missing; losing it makes those backups unrecoverable. Restore decrypts into private
staging and applies the candidate on a cold database open with an atomic swap and
automatic rollback if Room cannot open or migrate it. Legacy plaintext backups are
import-only. The envelope is shared with Apple, but embedded Room/GRDB databases are
platform-specific; WHOOP-format CSV is the portable transfer format.

---

## Project layout

```
android/
├── settings.gradle.kts          # rootProject "NOOP", includes :app
├── build.gradle.kts             # root — plugin versions (apply false)
├── gradle.properties            # AndroidX on, JVM args
├── gradlew / gradlew.bat        # checked-in wrapper launchers
├── gradle/verification-metadata.xml # SHA-256 allowlist for plugins + dependencies
├── gradle/wrapper/…             # checked-in Gradle 8.14.5 wrapper + distribution checksum
└── app/
    ├── build.gradle.kts         # android{} config + dependencies + locking policy
    ├── gradle.lockfile          # exact resolved versions for every Android variant
    ├── proguard-rules.pro
    └── src/main/
        ├── AndroidManifest.xml  # BLE permissions, MainActivity launcher
        ├── res/                 # theme, colors, strings, adaptive launcher icon
        └── java/com/noop/
            ├── NoopApplication.kt
            ├── protocol/        # enums, Crc, Framing, Reassembler, DeviceFamily
            ├── ble/             # WhoopBleClient (BluetoothGatt + scanner)
            ├── data/            # Room entities, DAO, database, repository
            ├── analytics/       # Hrv, Zones, IllnessWatch
            └── ui/              # NoopTheme, MainActivity, AppViewModel, screens, NavHost
```

Root package: `com.noop` · application id: `com.noop.whoop` (debug builds append `.debug`).

---

## Permissions & why

NOOP requests the platform capabilities used by its visible features:

- **`INTERNET`** — enables only user-initiated/opt-in network features, including
  the bring-your-own-key Coach and Self-hosted Sync. Strap collection, local
  analysis, and file import do not require a network.

- **`BLUETOOTH_SCAN`** (`neverForLocation`) + **`BLUETOOTH_CONNECT`** — Android 12+ (API 31+)
  runtime permissions. `neverForLocation` lets us skip the location grant on modern Android
  because we never derive physical location from scan results.
- **`BLUETOOTH` / `BLUETOOTH_ADMIN`** (`maxSdkVersion=30`) — the legacy install-time perms for
  Android 8–11.
- **`ACCESS_FINE_LOCATION`** — required for BLE scanning on Android 8–11 and for
  an explicitly started GPS-tracked workout on newer Android versions.
- **`FOREGROUND_SERVICE`** (+ `FOREGROUND_SERVICE_CONNECTED_DEVICE` on API 34) — to keep the
  link alive while collecting/offloading in the background.

On Android 12+ the app must **request the BLUETOOTH_SCAN / BLUETOOTH_CONNECT runtime
permissions at first launch** before scanning — handle this in the UI permission flow.

---

## BLE contract (must match the strap)

These come from the hardware-verified reference (`Strand/Strand/BLE/BLEManager.swift`)
and are the source of truth for the BLE layer:

| Item | Value |
|---|---|
| WHOOP 4 custom service | `61080001-8d6d-82b8-614a-1c8cb0f8dcc6` |
| → command write char | `61080002-…` (CMD → strap) |
| → command notify char | `61080003-…` (responses) |
| → event notify char | `61080004-…` (events) |
| → data notify char | `61080005-…` (fragmented data) |
| WHOOP 5 custom service | `fd4b0001-cce1-4033-93ce-002d5875f58a` |
| Standard HR service / char | `0x180D` / `0x2A37` (HR + R-R, works **unbonded**) |
| Battery service / char | `0x180F` / `0x2A19` (percent) |
| **Bond** | exactly **one confirmed (`writeWithResponse`) write** to the command characteristic — the reference uses `GET_BATTERY_LEVEL`. Its completion callback = bonded. |

The framing envelope (verified): `0xAA`, u16 LE length, CRC8(length bytes),
`[type=35][seq][cmd][payload]`, CRC32 LE. Fragments arriving on the notify
characteristics are reassembled before routing.

---

## Verification checklist

Work top-to-bottom. Items above the line need only a phone; items below the line need a
phone **and** a WHOOP strap.

**Build (phone or emulator):**

- [ ] `./gradlew :app:assembleFullDebug` compiles with no errors.
- [ ] App installs and launches to the main screen without crashing.
- [ ] Dark NOOP theme renders (surfaceBase `#060A08`, accent `#18C98B`); no white flash on launch.
- [ ] Navigation between screens works (Live / History / Support, etc.).
- [ ] Runtime BLE permission prompt appears on first launch (Android 12+) and is handled.

**On real hardware (phone + WHOOP strap):**

- [ ] Scan discovers the strap by the WHOOP 4 service UUID and connects.
- [ ] **Bond succeeds** — one confirmed write to the command characteristic completes without error.
- [ ] Standard HR (`0x2A37`) streams a plausible heart rate (30–220 bpm) and R-R intervals.
- [ ] Battery (`0x2A19`) reports a sane percentage.
- [ ] Realtime HR toggle starts/stops the custom REALTIME stream.
- [ ] Historical (type-47) offload runs after connect and persists rows to Room.
- [ ] Wrist-on / wrist-off and charging events update `LiveState`.
- [ ] `buzz()` (RUN_HAPTICS_PATTERN, patternId 2) makes the strap vibrate.
- [ ] Reconnect after walking out of range / toggling Bluetooth resumes streaming.
- [ ] After a session, HRV (RMSSD), zones, and any daily metrics compute from stored data.

**Privacy sanity check:**

- [ ] Confirm Self-hosted Sync is disabled on a fresh install and no request is
      sent until a user saves an endpoint/token and opts in.
- [ ] Confirm public sync endpoints require HTTPS, while literal private,
      loopback, and link-local addresses may use HTTP for a user's own LAN.
- [ ] Confirm failed or partially acknowledged uploads remain pending.

---

## Notes for porters

- The BLE layer is the highest-risk part. Android's `BluetoothGatt` is callback-based and
  serializes GATT operations differently from CoreBluetooth — queue writes/reads and wait
  for each callback before issuing the next, or operations will be silently dropped.
- "Bond" here means the app-level confirmed-write handshake described above, **not**
  necessarily Android OS pairing (`createBond()`); follow the reference's just-works flow.
- Keep all timestamps and CRC math byte-exact against the Swift reference — protocol bugs
  surface as "the strap won't serve data", not as crashes.
