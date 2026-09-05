## What this PR does

<!-- A short description of the change and why it's needed. -->

## Type of change

- [ ] Bug fix
- [ ] New feature
- [ ] Refactor / cleanup
- [ ] Documentation
- [ ] CI / tooling

## How it was tested

<!--
For anything on the BLE path, say what you tested on real hardware and which
strap (4.0 / 5.0 / MG). For protocol or analytics changes, point to the test
that covers it. "Builds and unit tests pass" alone is not enough for BLE work.
-->

## Observability

<!--
What exact evidence diagnoses success, stall/rejection, and failure at each
material boundary? How is it bounded, and what prevents health data, user
content, credentials, dynamic identifiers, or payloads from entering it?
-->

## Checklist

- [ ] Swift package tests pass for any package I touched (`swift test` in `Packages/<name>`)
- [ ] Android unit tests pass if I touched `android/` (`./gradlew testFullDebugUnitTest`)
- [ ] No new build warnings introduced
- [ ] UI changes use only `StrandDesign` tokens — no hardcoded colors, fonts, or spacing
- [ ] No hardcoded hex frame bytes; protocol facts live in the schema / decoders
- [ ] I reviewed observability for each material path; new events are bounded, categorical, privacy-safe, tested, and paired across Apple/Android where applicable
- [ ] Follows the conventions in [`docs/CONTRIBUTING.md`](../docs/CONTRIBUTING.md)
- [ ] I did not commit generated output (`Strand.xcodeproj/`) or any secrets/keystores
- [ ] I did not commit personal health exports, raw captures, databases, backups, routes, journal notes, or other participant data; any fixture is minimized synthetic data
- [ ] I created or updated the material-round record under [`docs/ops/rounds/`](../docs/ops/rounds/) and indexed it

## Related issues

<!-- Closes #N -->
