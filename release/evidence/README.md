# Release evidence

This directory defines NOOP's privacy-safe release evidence format. Generated
release artifacts belong in the release system, not in Git.

`manifest.schema.json` permits only:

- the canonical source repository, full commit, and full tree IDs;
- the release version;
- release-policy and schema basenames plus SHA-256 digests;
- artifact basenames, SHA-256 digests, byte sizes, and media types;
- fixed static-check names with a `passed` outcome.

It deliberately has no timestamps, local paths, usernames, device identifiers,
account identifiers, health values, logs, request data, credentials, signing
identities, or arbitrary failure text.

Generate and verify an evidence set from a clean release checkout:

```bash
VERSION=1.0.0
OUT="$(mktemp -d)"

python3 Tools/release-control-gate.py check \
  --report "$OUT/release-controls.json"
python3 Tools/release-evidence.py sbom \
  --source-ref HEAD \
  --version "$VERSION" \
  --output "$OUT/NOOP-source-v$VERSION.cdx.json"
python3 Tools/release-evidence.py manifest \
  --source-ref HEAD \
  --version "$VERSION" \
  --artifact "$OUT/NOOP-source-v$VERSION.cdx.json" \
  --artifact "$OUT/release-controls.json" \
  --checks "$OUT/release-controls.json" \
  --output "$OUT/NOOP-source-v$VERSION.manifest.json"
python3 Tools/release-evidence.py verify \
  --manifest "$OUT/NOOP-source-v$VERSION.manifest.json" \
  --artifact-directory "$OUT" \
  --expect-ref HEAD
```

The CycloneDX 1.5 SBOM is deterministic for the same source commit, tree,
version, and reviewed runtime inventory. It currently covers the complete
SwiftPM, Gradle/Maven, Python, and digest-pinned container inventory maintained
by `Tools/release-legal-gate.py`.
