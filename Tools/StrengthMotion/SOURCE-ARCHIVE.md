# Strength source archive

## Purpose

The complete user-supplied workout-media and openGym reference set is preserved
under `LocalAssets/StrengthMotion`. That directory is stable across normal build
cleaning but is ignored by Git because the exercise-media redistribution rights
are not established.

The archive includes:

- The four original ZIP files without modification.
- The complete extracted Vital Animations and exercise-GIF working trees.
- Both extracted openGym reference trees.
- The openGym visual-comparison screenshots.
- A SHA-256 digest for every archived file.
- A compact tracked inventory at `source-asset-inventory.json`.

On macOS, the archive command requests APFS copy-on-write clones. They use
separate filesystem entries, so deleting or later editing the Downloads copy
does not change the archived snapshot, while unchanged data blocks remain
space-efficient. It falls back to a normal independent copy when cloning is not
available.

## Create

From the repository root:

```sh
python3 Tools/StrengthMotion/archive-source-assets.py \
  --acknowledge-local-only
```

The acknowledgment is required because preservation for private QA does not
grant permission to distribute the files.

## Verify

```sh
python3 Tools/StrengthMotion/archive-source-assets.py --verify-only
```

Verification hashes every archived source and compares it with
`LocalAssets/StrengthMotion/SHA256SUMS`.

## Use

`import-media.py` automatically prefers the archived Vital and GIF working
trees. It falls back to the original Downloads locations only when the local
archive does not exist.

The archive is a preservation source, not an app asset directory. Production
media must come from a separately licensed HTTPS source. Debug/demo imports
remain excluded from release artifacts.

## Catalog expansion

NOOP currently has 56 first-party exercise records. The source CSV has 1,324
records and 1,323 matching GIF files; media ID `0609` is absent. The preserved
Vital set has 50 metadata records and 60 MP4 files, including character samples.

Do not expose all source rows directly. Expansion requires, for every exercise:

1. A stable NOOP identifier and canonical name.
2. Primary and secondary muscles, equipment, and movement pattern.
3. Exact media matching with no substituted movement.
4. Setup, movement, breathing, tempo, and safety guidance.
5. Rep-versus-duration behavior and progression compatibility.
6. Search aliases, substitutions, regressions, and accessibility labels.
7. iOS/Android localization and contract parity.
8. Documented redistribution rights for any shipped visual.

A practical progression is a curated 120-exercise core, then roughly 250
high-value variations. The remaining long tail should follow only after
deduplication, product demand, and licensing review.
