# Security Policy

## Scope

NOOP is local-first: compatible-band collection, local storage, analysis,
history, and export do not require a NOOP account or cloud. Reports are in scope
when they affect the confidentiality, integrity, availability, isolation,
provenance, deletion, update, or safe failure behavior of:

- Apple, Android, and macOS applications;
- Bluetooth transport and supported compatible-band parsing;
- local databases, backups, exports, diagnostics, and file imports;
- wellness metrics, source attribution, calibration, Coach, and notifications;
- optional AI, Oura import, self-hosted sync, NOOP+, Friends, account, and
  manual Safety paging paths;
- backend, cloud, build, signing, dependency, and release systems;
- first-party NOOP hardware, firmware, manufacturing, and OTA after those
  components exist.

An integrated dependency vulnerability is in scope when NOOP exposes or
depends on the vulnerable behavior. Reporting it upstream as well is helpful
but does not remove NOOP's responsibility to assess and update its product.

## Reporting A Vulnerability

Do not publish exploit details, credentials, identifiers, location, or health
data in a GitHub issue.

Before public launch, NOOP must enable GitHub private vulnerability reporting
or publish a staffed confidential security contact. That channel is not
verified today, so public production release remains blocked on its activation
and an end-to-end intake exercise.

Until then:

- authorized repository collaborators should create a private GitHub Security
  Advisory;
- other reporters may open a public issue containing only a request for a
  private contact and a non-sensitive affected component/severity summary;
- hold reproduction details until a confidential path is established.

Include, without collecting anyone else's data:

- affected component and version;
- the guarantee that fails and likely impact;
- minimal synthetic/local reproduction steps;
- whether exploitation is active or credentials may be exposed;
- a suggested mitigation, if known;
- preferred credit and disclosure timing.

The project will not ask a reporter to access another person's account, band,
location, or health data. Test only systems and identities you own or are
explicitly authorized to use, avoid denial of service and social engineering,
stop if personal data appears, and retain the minimum evidence. Good-faith
reports following these boundaries will be handled as defensive research; this
policy does not grant authorization outside applicable law or third-party
systems.

## Response And Disclosure

Once launch security operations are activated, NOOP targets acknowledgement
within one hour for Critical or actively exploited reports, one business day
for High, three business days for Medium, and five business days for Low. The
private response process covers triage, containment, credential revocation,
fix verification, coordinated disclosure, user or regulator communication,
and a privacy-safe post-incident review. Current pre-release maintainer
availability does not yet satisfy or promise those targets.

Reporters will receive status checkpoints while a confirmed issue is under
embargo. NOOP will coordinate a reasonable disclosure date, credit the
reporter if requested, and publish an advisory after affected users can obtain
the fix. Immediate user protection, legal notification, or active exploitation
may require earlier containment or communication.

## Security Updates And Supported Versions

Before the first supported binary release, fixes land only on the latest
source revision. After launch:

- the current generally available mobile release is supported;
- the immediately previous minor release receives security fixes for up to 90
  days when platform and schema compatibility permit;
- a Critical issue may require withdrawal or a minimum supported version when
  continued use is less safe than interruption;
- backend fixes roll out progressively with monitored rollback;
- first-party firmware updates must be signed, hardware-compatible,
  anti-rollback aware, recoverable, and bound to a published support matrix.

NOOP will announce normal end of support at least 90 days in advance. Emergency
retirement of a compromised release or key may be immediate, with clear user
instructions and the safest available local-data path. Hardware support
duration cannot be promised until the final supplier, firmware, signing, and
repair contracts exist.

## Not A Security Vulnerability

- Product suggestions without a broken security or privacy guarantee.
- Access that requires an already-unlocked device and does not cross an
  additional NOOP protection boundary.
- A provider processing data the user explicitly sent as disclosed, unless
  NOOP sent excess data, bypassed consent, or broke its transport or access
  contract.
- A user token used after the operating system's secure store and device
  account are fully compromised, unless NOOP failed to support revocation,
  minimized scope, or leaked the token elsewhere.

Internal handling and update steps are defined in
[`docs/SECURITY_OPERATIONS.md`](docs/SECURITY_OPERATIONS.md). Key lifecycle
requirements are defined in
[`docs/KEY_MANAGEMENT.md`](docs/KEY_MANAGEMENT.md).
