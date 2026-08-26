NOOP - third-party notices
==========================

NOOP-controlled source code and documentation are offered under the PolyForm
Noncommercial License 1.0.0 (see LICENSE). Independent third-party
package-manager dependencies and container images are not relicensed by that
file and remain under their own terms.

Exact runtime inventory
-----------------------

The dependency inventory and license texts below are generated from the exact
checked-in Apple SwiftPM, Android Gradle, and server Python runtime graphs.
`python3 Tools/release-legal-gate.py check` rejects unresolved dependency drift,
missing license text, stale generated notices, or unsynchronized NOOP license
copies.

NOOP source ownership
---------------------

The repository owner's source-ownership and distribution authorization is
recorded in `docs/provenance/OWNER-RIGHTS-DECLARATION.md`. The release gate
verifies that record independently from this dependency inventory.

Container boundary
------------------

The API and encrypted-backup images are built on digest-pinned official base
images. Their operating-system package notices remain inside `/usr/share/doc` in
the resulting image. The TimescaleDB image in Compose is pulled by the operator,
not copied into NOOP. Anyone who republishes a composed or flattened image must
also preserve and audit all notices supplied by those base images.

Additional research credits, interoperability boundaries, trademark
disclaimers, and component-specific links are maintained in `ATTRIBUTION.md`
and `DISCLAIMER.md`.
