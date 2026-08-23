# Runtime dependency notices

NOOP keeps one checked-in, exact inventory for the dependencies that enter its
Apple app, Android release runtime, and self-hosted server image. The current
reviewed graph contains:

- 5 SwiftPM components from the app workspace `Package.resolved`;
- 127 Maven components selected by `fullReleaseRuntimeClasspath` in the Gradle
  lockfile;
- 20 hash-locked Python runtime distributions; and
- 3 digest-pinned OCI inputs (two build bases and the pulled TimescaleDB image).

The generated `NOTICE`, `server/NOTICE`, and `server/backup/NOTICE` files contain
the exact component/version inventory and the reviewed license/NOTICE texts.
Apple bundles the root `NOTICE`; Android's generated legal assets bundle it; the
server Dockerfiles copy the generated server notices and exact project license
into `/usr/share/doc/noop`.

## Maintainer workflow

1. Update and resolve the package-manager lockfiles intentionally.
2. Collect license texts from those exact resolved artifacts with
   `Tools/collect-third-party-licenses.py`.
3. For a Python update, refresh `server/requirements.lock` with
   `Tools/refresh-server-runtime-lock.py`; the server image installs it with
   pip's `--require-hashes` enforcement.
4. Review every new license and notice, then run
   `python3 Tools/release-legal-gate.py write`.
5. Run `python3 Tools/release-legal-gate.py check` and the legal inventory unit
   tests. CI repeats both checks and rejects unreviewed graph drift.

`write` is not a license-approval shortcut. The collector only makes exact
license text review reproducible; the maintainer remains responsible for the
terms and attribution of each new component.

## Distribution gate

`python3 Tools/release-legal-gate.py distribution` is stricter and currently
fails intentionally. The active base describes WHOOP 4 protocol/store and
collection expression as inherited from `johnmiddleton12/my-whoop` (now
`johnmiddleton12/wearable`), whose pinned repository has no explicit software
license. Attribution cannot create redistribution permission, and permission
from this codebase's owner cannot grant a third party's rights.

Both artifact-publishing workflows run this fail-closed gate before they create
or replace a release. To remove the gate legitimately, obtain an explicit
rights-holder license or independently replace the affected expression and
record a clean-room provenance audit. Do not simply delete the check.

The OCI base images preserve their operating-system notices under
`/usr/share/doc`. A party republishing a composed or flattened image must also
audit and preserve all notices from those bases; the TimescaleDB image referenced
by Compose is pulled by the operator rather than redistributed in this repo.
