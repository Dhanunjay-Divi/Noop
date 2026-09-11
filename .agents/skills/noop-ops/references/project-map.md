# NOOP Project Map

Use this map to reduce broad searches. Verify current ownership in code before
editing because paths and contracts can evolve.

## Applications And Shared Logic

- `Strand/`: shared Apple app logic, analytics integration, stores, screens,
  notification policy, and macOS shell.
- `StrandiOS/`: iOS-specific shell, tabs, background integration, permissions,
  and lifecycle wiring.
- `StrandTests/`: Apple app integration and contract tests. Run through the
  `Strand` scheme on macOS.
- `android/app/src/main/java/com/noop/`: Android UI, data, BLE, Health Connect,
  notifications, alarms, background work, and app lifecycle.
- `android/app/src/test/`: Android JVM policy and source-contract tests.
- `Packages/StrandAnalytics/`: shared/pure Apple analytics policies. Match
  equivalent Kotlin policy behavior where the feature is cross-platform.
- `Packages/WhoopProtocol`, `Packages/WhoopStore`, `Packages/OuraProtocol`:
  existing protocol/storage integrations. Do not perform broad terminology or
  hardware migration without the replacement band SDK/specification.
- `server/`: managed account, sync, Safety, paging, and lifecycle services.
- `Tools/`: policy gates, localization generation/audits, simulator QA, release
  controls, and operations validation.

## High-Risk Ownership

- Daily/review/workout notification arbitration:
  `Strand/System/DailyReviewNotifications.swift`,
  `Strand/System/ContextualInterventions.swift`,
  `Strand/App/AppModel.swift`,
  `android/.../notif/`, `android/.../ble/WhoopBleClient.kt`, and
  `android/.../ingest/HealthConnectAutoSync.kt`.
- Wind-down and sleep-state suppression:
  `Strand/System/WindDownNudge.swift` and `android/.../alarm/`.
- Today information hierarchy:
  `Strand/Liquid/LiquidTodayView.swift`,
  `Strand/Screens/TodayView.swift`, and `android/.../ui/TodayScreen.kt`.
- Hydration transactional state and accessibility:
  `Strand/Data/HydrationStore.swift`,
  `Strand/Screens/HydrationView.swift`,
  `android/.../analytics/HydrationStore.kt`, and
  `android/.../ui/HydrationScreen.kt`.
- Body metrics and Fitness Age:
  `Strand/Data/IntelligenceEngine.swift`,
  `Strand/Screens/HealthView.swift`,
  `android/.../analytics/FitnessAgeEngine.kt`,
  `android/.../analytics/IntelligenceEngine.kt`, and profile stores.
- Safety precise-location lifecycle:
  `server/app/safety_repository.py`, Safety API/service code, and direct
  PostgreSQL lifecycle tests.
- Diagnostics and user reports:
  platform `AppDiagnosticsRecorder` implementations, debug export/report
  surfaces, server request observability, and `docs/OBSERVABILITY.md`.

## Durable Documentation

Read in this order:

1. Checked-in code, tests, migrations, and generated configuration.
2. `CLAUDE.md`.
3. `docs/ops/ACTIVE.md`.
4. Newest relevant file under `docs/ops/rounds/`.
5. `docs/ops/DECISIONS.md`.
6. Task-specific architecture, privacy, Safety, production, and physical-device
   runbooks.
7. Historical handoffs and changelogs only when current evidence is absent.

Do not let a chat transcript or old round override current source. Resolve the
contradiction and record it.
