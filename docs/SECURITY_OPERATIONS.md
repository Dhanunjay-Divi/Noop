# Security operations

**Status:** source-defined response and update runbook. Public launch remains
blocked until a confidential intake channel, named responders, alerting,
on-call coverage, and communication authority are verified.

This runbook supports the public policy in [`../SECURITY.md`](../SECURITY.md).
It applies to mobile apps, backend/cloud, accounts, imports, local storage,
Friends, Safety paging, first-party hardware/firmware when available, build and
release systems, and dependencies integrated into NOOP.

## Intake and evidence

1. Receive sensitive reports only through the approved confidential channel.
   Until that channel is active, authorized repository collaborators may use a
   private GitHub Security Advisory. A public issue may request private contact
   but must not contain exploit details, credentials, identifiers, or health
   data.
2. Create a restricted incident record with a random incident ID, receipt
   time, affected release/service class, bounded severity, reporter contact,
   and evidence location. Do not copy raw biometric data, user content,
   access tokens, private keys, or full request payloads into the record.
3. Acknowledge receipt, establish an encrypted/private communication path,
   avoid asking the reporter to collect other users' data, and preserve only
   the minimum evidence needed to reproduce with synthetic identities.

## Triage

- Assign a response owner and a second reviewer for Critical/High findings.
- Confirm scope on synthetic/local fixtures, identify affected versions,
  environments, tenants, key classes, data classes, claims, and exploit
  prerequisites.
- Score technical severity and separately assess health-data exposure,
  cross-tenant access, unsafe wellness guidance, paging/physical-safety impact,
  signing/update compromise, and active exploitation.
- Treat uncertainty as exposure until bounded evidence disproves it. Do not
  lower severity because the product is pre-release or the repository is
  private.

## Containment and recovery

- Disable the smallest affected capability with a server flag, enrollment
  gate, minimum-version rule, credential revocation, route isolation, or
  release withdrawal. Keep unrelated local collection available when safe.
- Follow [`KEY_MANAGEMENT.md`](KEY_MANAGEMENT.md) for any credential or key
  exposure. Verify rejection of the old credential before declaring
  containment.
- Preserve raw/source records and audit evidence. Do not repair a derived
  metric by rewriting source data; use
  [`METRIC_REPROCESSING_AND_ROLLBACK.md`](METRIC_REPROCESSING_AND_ROLLBACK.md).
- Patch from a reviewed branch, add a regression test that does not embed
  exploit secrets or personal data, run the full applicable release gates, and
  bind artifacts/SBOM/evidence to the fixing commit.
- For backend fixes, deploy progressively with rollback. For mobile fixes,
  submit expedited updates where available and enforce a minimum version only
  when continued use is less safe. Firmware fixes require signed,
  hardware-compatible, anti-rollback evidence before rollout.

## Severity targets after launch operations are activated

| Severity | Initial acknowledgement | Containment target | Fix/update target |
|---|---:|---:|---:|
| Critical or actively exploited | 1 hour | 4 hours | 24 hours for mitigation; 7 days for durable fix |
| High | 1 business day | 3 days | 14 days |
| Medium | 3 business days | 14 days | 60 days |
| Low | 5 business days | As scheduled | 90 days or next planned release |

These are operational targets, not a claim that current staffing meets them.
If a target is missed, the incident record must state owner, reason, temporary
control, user risk, and next checkpoint.

## Disclosure and communication

- Agree on a disclosure date with the reporter when possible. Do not suppress
  good-faith research, but delay exploit detail only as needed to protect users
  while a fix is distributed.
- Notify affected users and authorities according to verified legal and breach
  obligations. Messages state affected versions/data/capabilities, what NOOP
  did, what the user must do, and how to obtain the fixed version; they do not
  minimize uncertainty or claim no exposure without evidence.
- Publish a security advisory for release-relevant issues after remediation,
  including affected/fixed versions, severity, impact, mitigations, credit if
  requested, and update instructions. Never publish credentials, personal
  data, or weaponized detail that remains unsafe.

## Closure

Closure requires:

- reproduction and root cause;
- containment and old-key/old-version rejection where applicable;
- regression and release-gate evidence from the fixing commit;
- deployment/update adoption evidence;
- affected-data and notification decision;
- reporter communication;
- follow-up actions, owners, and dates;
- a privacy-safe post-incident review.

The public support window and end-of-support rules are defined in
[`../SECURITY.md`](../SECURITY.md). Hardware/firmware response remains
incomplete until the supplier trust, signing, revocation, recovery, and update
contracts exist.
