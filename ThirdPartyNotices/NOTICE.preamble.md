NOOP — third-party notices and redistribution status
====================================================

NOOP's original source code and documentation are offered under the PolyForm
Noncommercial License 1.0.0 (see LICENSE). Third-party code, inherited work,
package-manager dependencies, container images, and protocol facts are not
relicensed by that file.

Release status (fail closed)
----------------------------

The dependency inventory and license texts below are generated from the exact
checked-in Apple SwiftPM, Android Gradle, and server Python runtime graphs.
`python3 Tools/release-legal-gate.py check` rejects unresolved dependency drift.

That mechanical dependency work does **not** cure NOOP's inherited
`johnmiddleton12/my-whoop` (now `johnmiddleton12/wearable`) provenance. The
active base says that WHOOP 4 protocol/store and collection expression was
adapted from that repository, but the pinned reference has no explicit software
license. Attribution is not permission. External binary/source redistribution
therefore remains blocked until the affected expression is independently
reimplemented with documented clean-room provenance or the rights holder grants
an explicit license. The repository owner's permission cannot grant rights held
by that third party. The `distribution` mode of the release gate enforces this.

Container boundary
------------------

The API and encrypted-backup images are built on digest-pinned official base
images. Their operating-system package notices remain inside `/usr/share/doc` in
the resulting image. The TimescaleDB image in Compose is pulled by the operator,
not copied into NOOP. Anyone who republishes a composed or flattened image must
also preserve and audit all notices supplied by those base images.

Project lineage and interoperability research
---------------------------------------------

ryanbr/noop — https://github.com/ryanbr/noop
  This repository forks that active PolyForm Noncommercial codebase. Its Git
  history, license, Required Notice (`Copyright 2026 NoopApp`), and contributor
  attribution are preserved.

johnmiddleton12/my-whoop (now johnmiddleton12/wearable)
  The active base describes the WHOOP 4 Swift protocol/store packages and
  collection layers as adapted from this work. The pinned repository declares
  no software license. This notice is attribution only and grants no rights.

b-nnett/goose — https://github.com/b-nnett/goose
  Consulted for observed WHOOP 5 / MG wire-protocol facts. Its repository has no
  explicit software license, so NOOP copies no source or assets from it.

tigercraft4/goose — https://github.com/tigercraft4/goose
  Self-hosting inspiration only. NOOP's server and sync clients are independently
  implemented; no source or assets are copied from it.

Additional research credits, clean-room boundaries, trademark disclaimers, and
component-specific links are maintained in ATTRIBUTION.md and DISCLAIMER.md.
