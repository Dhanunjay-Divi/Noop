# Android supplier SDK local wiring

**Status:** local engineering path only; disabled by default and blocked from
release packaging

## Boundary

The public repository contains the supplier-neutral NOOP Band contract and the
NOOP-owned adapter source only. Supplier AARs, JARs, native libraries, APKs,
firmware, credentials, demo code, and private captures remain outside Git.

Android enables the supplier source set and local AAR dependencies only when
the gitignored file `android/noop-supplier-sdk.properties` exists with
`enabled=true`. There is no Gradle property or environment-variable fallback.
Without that file, Full and Demo retain their ordinary dependency graphs,
supplier imports are excluded, `VEEPOO_ADAPTER_AVAILABLE` is false, and WHOOP
remains the active production transport.

The local file uses strict, unescaped `key=value` entries:

```properties
enabled=true
sdk.root=<absolute path outside this repository>
artifact.count=<positive count>
artifact.0.path=<relative path below sdk.root ending in .aar>
artifact.0.sha256=<lowercase SHA-256>
artifact.0.requiredClasses=<comma-separated fully qualified classes>
artifact.0.nativeAbis=<comma-separated exact ABI set, or empty>
artifact.0.nativeLibraries=<comma-separated exact .so basenames, or empty>
```

Repeat the `artifact.N.*` keys with contiguous zero-based indexes. All local
artifact paths, filenames, hashes, required classes, native ABIs, and native
library names belong in this untracked file, not Gradle or tracked source.

## Verification

Run lightweight checks from the repository root:

```bash
python3 Tools/local/verify-android-supplier-sdk.py \
  --repo-root . \
  --config android/noop-supplier-sdk.properties
cd android && ./gradlew -q :app:noopSupplierSdkStatus
cd android && ./gradlew -q :app:verifyNoopSupplierSdk
```

The verifier fails closed on malformed or duplicate config, missing or linked
files, digest drift, missing required classes, duplicate or unsafe archive
paths, unexpected nested archives/binaries, native ABI/library drift, supplier
roots inside the repository, tracked local config/staging files, and tracked
AAR/JAR/SO/APK/AAB payloads. The Gradle wrapper JAR is the only tracked binary
exception.

Supplier-enabled Full compile, test, lint, assemble, bundle, merge, package,
KSP, and connected-test tasks depend on the verifier. Demo never receives the
supplier source set or AARs. Supplier-enabled Full release packaging is
deliberately rejected.

## Remaining gates

- Written supplier and transitive-component redistribution authority.
- Complete SBOM, notices, license compatibility, vulnerability review, update
  ownership, and support/security-response terms.
- Review of every transitive runtime dependency. The supplier's bundled legacy
  JSON library is not a configured local artifact; compatibility with the
  app-owned locked runtime must be proven by the parent dependency/compile run.
- Signed debug/internal packaging review and actual egress inspection.
- Exact model/firmware capability report and adapter conformance.
- Physical Android scan, connect, confirmation, reconnect, history,
  background/OEM, process-death, battery, haptic, clock, and source-switch
  evidence.
- Production signing, store, privacy, certification, and launch approval.

A successful verifier or Gradle configuration proves only local artifact
identity and build selection. It does not prove BLE behavior, hardware
capability, data accuracy, background execution, safety behavior, legal
redistribution, or release readiness.
