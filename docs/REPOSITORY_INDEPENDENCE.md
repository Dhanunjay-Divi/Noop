# Repository independence

**Status:** standalone canonical repository; owner-controlled source rights
recorded.

The canonical repository is
[`Dhanunjay-Divi/Noop`](https://github.com/Dhanunjay-Divi/Noop). Its only
configured Git remote is that repository. Authenticated GitHub inspection on
2026-08-24 reported `isFork=false`, no parent, and `main` as the default branch.

On 2026-08-25 the repository owner represented that they own or control the
source and contribution rights required for the code consolidated into NOOP and
authorized its distribution under NOOP's PolyForm Noncommercial License 1.0.0.
The signed-in-session engineering record is
[`provenance/OWNER-RIGHTS-DECLARATION.md`](provenance/OWNER-RIGHTS-DECLARATION.md);
the machine-readable state is
[`provenance/rights-status.json`](provenance/rights-status.json).

## Preserved boundaries

- NOOP's `LICENSE`, copyright, and Required Notice remain unchanged.
- Independent runtime dependencies retain their own licenses and required
  notices in `NOTICE` and `ThirdPartyNotices/`.
- Supported wearable trademarks, firmware, vendor applications, and platform
  SDKs are not claimed as NOOP property.
- Existing commit history was not rewritten. The cleanup changes the current
  source tree, release documents, and checks only.

## Release checks

Run both commands before publishing an artifact:

```bash
python3 Tools/release-legal-gate.py check
python3 Tools/release-legal-gate.py distribution
```

The gate fails on a missing or altered owner declaration, changed NOOP license,
stale project-license copies, unresolved runtime dependency drift, missing
third-party license text, stale generated notices, or mismatched Terms versions.

Passing this source-rights and dependency gate does not prove signing, App Store
or Play readiness, physical-device behavior, carrier delivery, infrastructure
capacity, clinical accuracy, or regulatory clearance. Those remain separate
release gates in [`handoff/RELEASE-BLOCKERS.md`](handoff/RELEASE-BLOCKERS.md).
