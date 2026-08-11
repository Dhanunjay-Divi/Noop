# NOOP private reference-study harness

This executable compares a person's official WHOOP export with NOOP without
putting multiple people into the app's single-user database.

The tool has five commands:

- `lock`: HMAC-sign the pseudonymous subject split and hash every official
  reference export before outcomes are inspected.
- `audit`: parse schema and coverage, discard journal content, and emit only
  cohort-level counts.
- `fit`: derive and HMAC-sign a bounded, equal-subject bias correction using
  discovery subjects only.
- `discover`: evaluate discovery subjects.
- `validate`: reveal the sealed validation subjects only after an explicit
  acknowledgement, using the signed candidate. A private reveal receipt
  prevents silently trying a second candidate on the same holdout.

See [`docs/REFERENCE_STUDY.md`](../../docs/REFERENCE_STUDY.md) for the complete
workflow and interpretation rules.

Run the synthetic tests:

```bash
swift test --package-path Tools/StudyHarness
```
