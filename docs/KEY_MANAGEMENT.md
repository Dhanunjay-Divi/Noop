# Key management

**Status:** lifecycle and ownership policy defined. It does not claim that
production signing, provider, manufacturing, firmware, or first-party band keys
exist or have completed a rotation drill.

This policy covers every credential, token, certificate, encryption key,
signing key, installation secret, and device identity used by NOOP. Public
identifiers such as restricted Firebase mobile API keys are not bearer
secrets, but they still require origin/application restrictions and inventory.

## Required controls

### Generation

- Generate secrets with an approved cryptographic random generator or managed
  KMS/HSM. Do not derive production secrets from names, serial numbers,
  passwords, source commits, dates, or shared test fixtures.
- Use distinct keys for development, staging, production, signing, encryption,
  authentication, paging, backup, and manufacturing purposes.
- First-party bands must receive unique per-device identities. A shared fleet
  secret is forbidden. Device, boot, application, and OTA trust must be
  designed with the supplier and recorded before firmware integration.
- Test credentials and Firebase synthetic phone codes must be fictional,
  environment-bound, untracked, and incapable of authorizing production data.

### Custody and access

- Repository source, build logs, diagnostics, support bundles, analytics,
  screenshots, chat, tickets, and app binaries must not contain bearer
  credentials or private key material.
- Managed service secrets live in Secret Manager/KMS or the platform-approved
  signing service. Mobile user/install credentials live in Keychain or
  Keystore-backed encrypted storage and are never synced through ordinary app
  preferences.
- Production access is least privilege, time bounded where supported, audited,
  and separate from staging. Human administrators do not use runtime service
  identities for routine access.
- High-impact production actions require two-person review once the operations
  team has more than one authorized operator: signing-key export, KMS
  destruction, production database credential replacement, firmware root
  changes, provider master-token use, and emergency access.

### Backup and recovery

- Prefer non-exportable managed or hardware-backed keys. Back up private key
  material only when loss would make supported recovery impossible.
- Required backups are encrypted under a separate recovery authority, stored
  outside the primary failure domain, access logged, restore-tested, and
  inventoried by key identifier rather than secret value.
- Installation credentials, one-time invite capabilities, provider access
  tokens, and user-entered endpoint/API tokens are not centrally backed up.
  Recovery creates a new credential and revokes the old one.
- Database and object backups retain their original KMS dependency until an
  explicit re-encryption and restore test succeeds.

### Rotation

- Rotate immediately after suspected disclosure, unexpected access, personnel
  departure affecting custody, provider incident, algorithm/key-strength
  change, or failed inventory/reconciliation.
- Managed encryption keys use automatic rotation where supported. The current
  GCP source policy sets a 90-day rotation period for managed data keys.
- Runtime database, replay, bootstrap, provider, CI, and deployment credentials
  require staged dual-read/dual-key rollover or an equivalent no-downtime
  procedure, followed by verification and revocation of the old version.
- Mobile installation and social capability credentials rotate on device
  removal, account recovery, leave/delete, block, suspected link/token leak,
  or explicit user action.
- Signing roots rotate only through a compatibility, recovery, and
  anti-rollback plan. Expiry alone must not strand supported clients or bands.

### Compromise, revocation, and destruction

1. Treat any credential pasted into chat, logs, issue text, screenshots, or
   source history as compromised even if no misuse is observed.
2. Stop or isolate the affected capability; preserve bounded audit evidence;
   identify key class, environment, grants, versions, and dependent data.
3. Revoke/disable the credential at the authority, issue a distinct
   replacement, update dependents, and verify old-key rejection.
4. Review access logs and affected data without copying health values or
   credentials into the incident record. Follow breach/legal escalation when
   exposure cannot be excluded.
5. Destroy retired exportable material and backups after the overlap,
   rollback, legal-hold, and restore windows expire. Schedule KMS destruction
   with a recovery window; never delete a key still required by retained data.

## Key classes and current boundary

| Key class | Required authority | Current source boundary |
|---|---|---|
| GitHub/CI/deployment | Repository/environment secret store; scoped tokens; protected approvals | Source excludes known credential files/formats and pins release inputs. Hosted protection and final credential inventory remain owner gates. |
| Apple distribution/notarization/APNs | Apple-managed team roles and approved signing pipeline | Unsigned builds are verified. Production certificates, profiles, APNs key, custody, and rotation evidence are not present. |
| Android signing/Play/FCM | Non-exportable or tightly controlled release key plus Play roles | Unsigned/debug builds are verified. Production keystore, Play signing, FCM server authority, and recovery evidence are not present. |
| GCP data/runtime | Workload identities, KMS, Secret Manager, restricted database roles | Private synthetic staging uses source-defined least privilege, KMS, secret bindings, PITR, and no broad invoker. Production projects and drills remain gated. |
| Firebase identity/App Check | Restricted app identifiers plus provider-side identity/attestation policy | Synthetic app identities are source-defined. Signed physical-client enforcement and recovery remain gated. |
| Paging provider | Restricted outbound API credential; separate webhook-verification secret; environment-specific senders | Real provider credentials, India registration, callback origin, carrier tests, failover, and 24/7 operation are absent. Previously disclosed credentials must never be reused. |
| User/self-hosted services | User-controlled token in Keychain/Keystore; origin-bound transport | Implemented locally; NOOP diagnostics and reports exclude values. |
| First-party band/manufacturing/OTA | Per-device identity, protected factory injection, secure boot and signed anti-rollback OTA | Blocked until the supplier firmware, SDK, hardware trust boundary, and manufacturing dossier exist. |

## Evidence required before production

- key inventory with owner, purpose, environment, authority, identifier,
  creation/expiry, rotation trigger, consumers, backup rule, and revocation
  method;
- least-privilege grants and access-log retention;
- generation/provisioning ceremony for signing, manufacturing, and device
  roots;
- successful rotation, old-key rejection, emergency revocation, restore, and
  destruction drills for each enabled key class;
- exact release manifest references without secret values;
- independent review for first-party firmware, mobile signing, public cloud,
  paging, and any health-data encryption boundary.

The coordinated incident and update procedure is in
[`SECURITY_OPERATIONS.md`](SECURITY_OPERATIONS.md). Repository release controls
are in [`RELEASE_CONTROLS.md`](RELEASE_CONTROLS.md).
