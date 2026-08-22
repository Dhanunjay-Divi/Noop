# Security Policy

## Scope

NOOP is local-first: strap collection, storage, and analysis work without a
NOOP account or required cloud. Optional network features add deliberately
bounded attack surfaces:

- **Bluetooth Low Energy** — the link to your WHOOP strap.
- **Local SQLite database** — every reading is stored on your own device.
- **File imports** — WHOOP CSV exports and Apple Health ZIP files you choose to open.
- **AI Coach (optional, off by default)** — sends a bounded text summary and the
  user's question to the provider/endpoint they configure.
- **Oura cloud import (optional build, user initiated)** — pulls the user's own
  history from Oura under their OAuth grant.
- **Self-hosted Sync (optional, off by default)** — sends the documented v1
  subset to the endpoint and bearer token the user configures.

A useful security report is one that lets data leave the device when it shouldn't,
lets a malicious strap or crafted import file corrupt the database or run code, or
breaks the endpoint validation, authorization, namespace separation, provenance,
or deletion controls of an enabled network feature.

## Reporting a vulnerability

**Report security issues through the
[`Dhanunjay-Divi/Noop` issue tracker](https://github.com/Dhanunjay-Divi/Noop/issues/new/choose).**

If a public report would put users at immediate risk before a fix can ship,
open an issue with a short, non-exploitable summary (what is affected and how
severe) and hold the proof-of-concept details until a fix is released.

Please include, as far as you can without putting anyone at risk:

- A description of the issue and the guarantee it breaks
- Steps to reproduce
- The potential impact
- A suggested fix, if you have one

Because there is no staffed inbox, response times depend on maintainer
availability — there is no guaranteed SLA. Confirmed issues are prioritised for
the next release.

## Supported versions

Before the first supported binary release, security fixes land on the latest
source revision. After releases begin, only the latest release is supported.
Rebuild or update from the canonical repository to pick up fixes.

## Out of scope

- Vulnerabilities that require physical access to an already-unlocked device
- Issues in third-party dependencies — please report those upstream (see
  [`NOTICE`](NOTICE) for the bundled libraries and their licences)
- The WHOOP strap firmware itself, which NOOP does not ship or modify
- A provider/server legitimately processing data the user explicitly chose to
  send under that provider's terms
- A user's own API token being misused after the device/OS secure store itself
  has been compromised
