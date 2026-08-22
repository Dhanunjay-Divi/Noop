# Durable NOOP Decisions

These decisions span multiple work rounds. A later round may replace one only
by documenting the reason, migration, evidence, and compatibility impact.

| ID | Decision | Status | Evidence / authority |
|---|---|---|---|
| D-001 | NOOP is local-first and account-free by default. Network features are explicit opt-ins to a destination the user chooses. | Active | `README.md`, `docs/PRIVACY_SECURITY.md` |
| D-002 | Measured, device-derived, imported/vendor, and NOOP-derived values retain distinct provenance. Missing input is not zero and an estimate is not a measurement. | Active | `docs/COMPETITIVE_CAPABILITY_AUDIT.md`, `docs/DATA_MODEL.md` |
| D-003 | Charge, Effort, Rest, autonomic load, readiness, Fitness Age, Vitality, and Wellness Age are independent transparent wellness estimates, not recovered proprietary formulas or clinical outputs. | Active | `docs/ANALYTICS.md`, `docs/FEATURE_PARITY.md`, `DISCLAIMER.md` |
| D-004 | Background collection and upload are described as best effort. Foreground catch-up, restoration, freshness, and completeness are implemented without promising an OS-controlled cadence. | Active | `docs/IOS.md`, `docs/ANDROID.md`, `docs/FEATURE_PARITY.md` |
| D-005 | App upgrades preserve the existing local container. Install in place with the same bundle identity; an uninstall or destructive reset requires explicit authorization and a verified backup. | Active | `docs/IOS.md`, round records |
| D-006 | Automatic activity and stress interruptions fail conservatively. Weak evidence stays in-app; interruptive alerts require opt-in and corroborating inputs. | Active | `docs/DETECTION_VALIDATION_PLAN.md`, `docs/releases/v9.2.0.md` |
| D-007 | BLE, overnight history, sleep, background, haptic, battery, and detector claims require representative physical-device evidence. Simulator/build success is not a substitute. | Active | `docs/CONTRIBUTING.md`, `docs/FEATURE_PARITY.md` |
| D-008 | Private development may continue while public distribution remains blocked by unresolved inherited-license scope. Passing the inventory check is not the same as passing the distribution gate. | Active | `Tools/release-legal-gate.py`, `docs/REFERENCE_REPOSITORY_AUDIT.md` |
| D-009 | A metric detail starts with the selected/latest day and then shows personal comparison, history, related signals, provenance, confidence, and education. | Active | `docs/releases/v9.2.0.md`, Today/Metric Explorer implementation |
| D-010 | A temporary App Store preview gate stores no plaintext shared code in Git or app storage. Release archives fail closed without an ignored one-way verifier; App Review receives the code only through private Review Information. The gate is a preview deterrent, not biometric encryption or strong authentication. | Active | `Strand/App/LaunchAccess.swift`, `StrandiOS/App/LaunchAccessGateView.swift`, `docs/APP_STORE_RELEASE.md` |
