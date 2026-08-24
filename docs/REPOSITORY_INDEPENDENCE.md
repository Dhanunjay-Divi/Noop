# Repository independence

**Status:** hosting is standalone; commercial code independence is not yet established.

The canonical destination is
[`Dhanunjay-Divi/Noop`](https://github.com/Dhanunjay-Divi/Noop). On 2026-08-23,
the local checkout stopped using the prior remote and its cached
remote-tracking branches were removed. Authenticated GitHub inspection on
2026-08-24 verified the canonical repository is private, reports
`isFork=false`, has no parent, and has zero child forks.

Changing a remote, repository name, visibility, fork badge, or Git history does
not change the rights attached to source code. This checkout still contains the
existing multi-author codebase and therefore is not the clean commercial
repository merely because its `origin` changed.

GitHub's current
[fork-detachment procedure](https://docs.github.com/en/pull-requests/how-tos/work-with-forks/detaching-a-fork)
offers **Leave fork network** only for a public fork under 1 GB with no child
forks. Other cases require GitHub Support or the destructive
delete-and-recreate procedure, which loses repository metadata. Do not use the
destructive route without a verified backup and explicit approval. Detachment
preserves commit authorship and does not establish source ownership.

## Current decision

The intended posture is a commercially independent NOOP product. Until the
rights state in
[`provenance/rights-status.json`](provenance/rights-status.json) is cleared with
reviewable evidence:

- do not publish this source tree or an app archive as commercially cleared;
- retain `LICENSE`, `NOTICE`, `ATTRIBUTION.md`, and required dependency notices;
- do not treat an orphan commit, squash, source export, or new GitHub repository
  as a provenance fix; and
- keep release workflows behind
  `python3 Tools/release-legal-gate.py distribution`.

## Valid completion routes

1. Obtain grants covering modification and commercial source/binary
   redistribution from every relevant rightsholder and contributor.
2. Independently replace or remove every affected implementation, with a
   file/function manifest and independent overlap review.
3. Start a genuinely new repository containing only newly authored or
   separately licensed code. Use this repository as behavior/provenance
   reference only; do not copy its implementation into the new tree.

The analyst who prepares a behavior-only specification may inspect this
codebase. The clean-room implementer must not have inspected the restricted
implementation. The final reviewer records the implementation scope, evidence,
and approved commit without adding private contracts or credentials to Git.

## Completion gate

Commercial independence is complete only when all of the following are true:

- every blocker in `docs/provenance/rights-status.json` is `resolved` and has
  the required evidence;
- `distributionStatus` is changed to `cleared` in the same reviewed change;
- the release legal gate and its tests pass;
- the replacement build passes cross-platform protocol, migration, and
  physical-device validation; and
- GitHub reports the canonical repository is not a fork, or the team records
  why fork metadata is intentionally retained.

Removing attribution comes last, after the implementation and rights evidence
support it. Third-party dependency notices remain even in a fully independent
commercial repository.
