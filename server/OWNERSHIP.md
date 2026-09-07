# NOOP Band ownership authority

The ownership service is a narrow control plane for a first-party NOOP Band. It
does not store health data and is independent of NOOP+ storage, consent,
entitlement, and payment.

## Runtime boundary

Run the service with:

```sh
uvicorn app.ownership_main:app --host 127.0.0.1 --port 8081 --no-access-log
```

Startup requires `NOOP_OWNERSHIP_SERVICE_ENABLED=true`, PostgreSQL, the
configured Firebase project and app IDs, and at least one active immutable
terms manifest in `ownership_terms_documents`. The service verifies:

- Firebase App Check for the exact Apple or Android app;
- a fresh Firebase email/password identity with a verified email;
- a random per-installation credential whose plaintext exists only in the
  platform Keychain or Keystore-backed store;
- an expiring physical-band possession response before claim or replacement
  installation authorization.

The default `UnavailableOwnershipPossessionVerifier` always returns `503`.
That is the only production verifier until the approved supplier SDK provides a
cryptographically challenge-bound proof. A simulator or virtual proof must
never be selected by deployment configuration.

## Stored data

Migration `026_band_ownership.sql` adds accounts, hashed external identities,
terms acceptance metadata, installation-token digests, provisioned-band
identity digests, claims, plan selections, entitlements, release records, and
bounded audit events. It stores no email address, phone number, password, OTP,
printed band number, raw possession response, or health payload.

Selecting NOOP+ records preference only. It cannot write
`ownership_entitlements`, activate managed storage, or alter band ownership.
V1 has no customer unpair, transfer, or release endpoint.

## GCP staging

`infra/gcp` can enable email/password identity separately with
`enable_ownership_identity`, then create an IAM-only Cloud Run service with
`enable_ownership_runtime`. The service receives only Cloud SQL access and the
separate secret named by `ownership_database_url_secret_id`. That secret must
contain a PostgreSQL URL for a role granted only the schema access needed by
`ownership_*` tables; it must not reuse the managed API, processor, lifecycle,
migration, or Safety credential. There is deliberately no public invoker
resource. `/readyz` rejects superuser or role-administration credentials and
any effective table or column privilege outside `ownership_*`, so substituting
the shared database URL fails closed.

Before the private service can become ready, an operator must publish an
approved immutable terms object and insert its exact HTTPS URI, locale,
effective time, and SHA-256 digest. Do not use a draft policy or place terms
content in app configuration.

After migration `026` and before enabling the ownership runtime, provision the
dedicated database principal with
`infra/gcp/scripts/configure-ownership-database.sh`. The command strips excess
effective privileges, grants only the allowlist enforced by `/readyz`, verifies
the result while authenticated as that principal, and publishes the URL
directly to Secret Manager without exposing it in arguments or output. It must
not be run against an active ownership runtime.

Public invocation, released mobile configuration, real customer identity, and
physical-band claims remain blocked until supplier possession proof, legal
terms, App Check, abuse, recovery, support, restore, and signed physical-device
gates pass.
