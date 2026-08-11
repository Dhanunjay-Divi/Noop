# Invitation-only Friends API

Friends is an optional, self-hosted sharing layer for small groups. It is
designed around explicit consent and deliberately does not expose the server's
existing data APIs.

## Security and privacy boundary

- The existing server-wide `NOOP_API_TOKEN` continues to protect full-data
  routes and is also used to bootstrap/administer local friend profiles. It is
  never included in an invite.
- Bootstrap creates a 256-bit `noop_member_…` Bearer token scoped to one app
  installation and its dedicated `noop_computed` Friends producer. Invite join
  instead accepts a token generated and saved by the client before the request,
  which makes a lost response safely retryable. In either flow only the SHA-256
  digest is stored.
- Invite codes contain 96 random bits, expire within one to 168 hours, are
  single-use, and are also stored only as SHA-256 digests.
- There is no public discovery, handle lookup, contacts upload, follower model,
  or unauthenticated profile route.
- A friendship begins only after one member redeems an invite and the inviter
  explicitly accepts the resulting request.
- Visibility is directional. Each member controls exactly which fields that
  specific friend can read.
- The feed reads only `daily_metrics` rows whose provenance namespace is
  `noop_computed` and whose day is on or after that friendship's UTC creation
  date. It never queries raw metric samples, protocol events, location, journals,
  workouts, sleep stages, notes, metadata, or imported WHOOP reference rows.
- Blocking removes an existing friendship, removes both visibility records, and
  cancels pending requests between the two profiles.

Member credentials are bearer credentials. Deploy the server behind HTTPS before
using Friends outside a private trusted network, keep tokens in the platform
keychain/keystore, and rotate a token immediately if it may have leaked.

## Authentication

Bootstrap and administration:

```text
Authorization: Bearer <NOOP_API_TOKEN>
```

All other `/v1/social` routes except invite join:

```text
Authorization: Bearer <noop_member_...>
```

The two credential types are intentionally not interchangeable.
`POST /v1/social/invites/join` uses its one-time invite code to authorize the
client-generated enrollment and therefore does not take either Bearer
credential.

## Bootstrap

The selected producer must be scoped to the same installation and should be the
app's dedicated, sparse Friends producer. Do not reuse the normal self-hosted
archive producer:

```http
POST /v1/social/bootstrap
Authorization: Bearer <NOOP_API_TOKEN>
Content-Type: application/json

{
  "display_name": "Alice",
  "installation_id": "11111111-1111-4111-8111-111111111111",
  "daily_device_id": "ios:11111111-1111-4111-8111-111111111111:strap-abc-noop-friends-alg-a1b2c3"
}
```

Response `201`:

```json
{
  "profile": {
    "profile_id": "c62079b5-0111-44fd-a2aa-bda5528eb50f",
    "enrollment_id": "70cb28e1-c66f-4728-8e05-19a3f6257fbb",
    "display_name": "Alice",
    "installation_id": "11111111-1111-4111-8111-111111111111",
    "daily_device_id": "ios:11111111-1111-4111-8111-111111111111:strap-abc-noop-friends-alg-a1b2c3",
    "created_at": "2026-07-25T15:00:00Z",
    "updated_at": "2026-07-25T15:00:00Z",
    "disabled_at": null
  },
  "member_token": "noop_member_<returned-once-secret>",
  "token_notice": "Store this member token securely. It is returned only once and can access computed daily sync and social summary routes only."
}
```

Only one active profile may be bootstrapped for an installation. A lost token
can be replaced with:

```http
POST /v1/social/admin/profiles/{profile_id}/rotate-token
Authorization: Bearer <NOOP_API_TOKEN>
```

The previous member token stops working immediately.

Admin routes also support listing profiles, changing the display name or scoped
daily producer, and disabling a profile:

```text
GET    /v1/social/admin/profiles
PATCH  /v1/social/admin/profiles/{profile_id}
DELETE /v1/social/admin/profiles/{profile_id}
       X-Noop-Confirm: DISABLE <profile_id>
```

## Invite, request, and acceptance

Create a single-use invite:

```http
POST /v1/social/invites
Authorization: Bearer <member token>
Content-Type: application/json

{"expires_in_hours": 72}
```

The response contains an `invite` object and a human-readable `code`, such as
`NOOP-6A71B2-11E0F9-8802A1-44C90C`. The code is the only value that should be
shared. It contains neither the server token nor a member token. Revoke an
unused code with `DELETE /v1/social/invites/{invite_id}`.

The other member redeems it:

```http
POST /v1/social/invites/redeem
Authorization: Bearer <other member token>
Content-Type: application/json

{"code": "NOOP-6A71B2-11E0F9-8802A1-44C90C"}
```

This creates a pending request; it does not create a friendship. Requests are
listed with `GET /v1/social/requests`. Only the original inviter can decide an
incoming request:

```http
POST /v1/social/requests/{request_id}
Authorization: Bearer <inviter member token>
Content-Type: application/json

{"decision": "accept"}
```

`decision` is either `accept` or `decline`.

### Joining without an administrator token

A person who does not yet have a profile exchanges the invite code directly:

```http
POST /v1/social/invites/join
Content-Type: application/json

{
  "code": "NOOP-6A71B2-11E0F9-8802A1-44C90C",
  "display_name": "Bob",
  "installation_id": "22222222-2222-4222-8222-222222222222",
  "daily_device_id": "ios:22222222-2222-4222-8222-222222222222:strap-def-noop-friends-alg-d4e5f6",
  "enrollment_id": "f579774e-6612-4694-92ef-a40463752c6a",
  "member_token": "noop_member_<43-or-more-URL-safe-characters>"
}
```

Before the first request, the client must generate and securely save both a UUID
`enrollment_id` and a token with at least 256 bits of randomness, encoded as
`noop_member_` plus 43 URL-safe Base64 characters. The invite code authorizes
only that atomic enrollment. The server consumes the code, stores the token
digest, creates the profile, and creates the pending request in one transaction.
It never echoes the supplied token.

If the response is lost, retry the same code with exactly the same enrollment
UUID, token, installation, producer, and display name. Even if the code has
since expired or the request has since been accepted, the server returns the
same profile and request with `idempotent_replay: true`. Any mismatch returns
HTTP 409. An invalid, expired, revoked, or concurrently consumed code cannot
leave an orphan profile.

```json
{
  "profile": {
    "profile_id": "d00d21c8-ffeb-431b-a46a-3f4cac878617",
    "enrollment_id": "f579774e-6612-4694-92ef-a40463752c6a",
    "display_name": "Bob",
    "installation_id": "22222222-2222-4222-8222-222222222222",
    "daily_device_id": "ios:22222222-2222-4222-8222-222222222222:strap-def-noop-friends-alg-d4e5f6",
    "created_at": "2026-07-25T15:05:00Z",
    "updated_at": "2026-07-25T15:05:00Z",
    "disabled_at": null
  },
  "request": {
    "request_id": "af47c9a4-1255-4b84-9c7c-f25f64749641",
    "status": "pending",
    "created_at": "2026-07-25T15:05:00Z",
    "decided_at": null,
    "recipient": {"display_name": "Alice"}
  },
  "idempotent_replay": false,
  "token_notice": "The supplied member token was stored only as a digest; the request field contains the current friendship decision state."
}
```

## Member summary upload

A joined installation can upload the exact daily producer bound to its profile
without learning `NOOP_API_TOKEN`:

```http
POST /v1/sync
Authorization: Bearer <member token>
```

Member authorization applies a stricter contract than administrator sync:

- `source.device_id` must exactly equal the profile's `daily_device_id`.
- `source.metadata.installation_id` must equal the profile installation.
- `source.metadata.namespace` must be `noop_computed`.
- Streams, events, sleep sessions, workouts, and journal entries must be empty.
- Daily keys are restricted to `recovery`, `effort`, `sleep_performance`,
  `total_sleep_min`, `avg_hrv`, and `resting_hr`.
- Score values must be `0...100`, sleep duration `0...2880` minutes, HRV
  `0...1000` ms, and resting heart rate `20...260` bpm.
- Each supplied day is a replacement for those six social keys. Before
  upserting the submitted values, the server removes any of the six keys omitted
  for that day. This prevents a disabled privacy field from lingering in the
  social copy. Days absent from the payload are unchanged.

Any cross-installation, imported-reference, raw, or extra-field payload returns
HTTP 403. The admin-token sync contract remains unchanged. A member token may
also call `GET /v1/status`, which returns version/scope but omits server-wide
storage statistics; it cannot call device, stream, export, or admin routes.

## Friends and directional visibility

`GET /v1/social/friends` returns each accepted friend with two allowlists:

```json
{
  "friends": [
    {
      "profile_id": "d00d21c8-ffeb-431b-a46a-3f4cac878617",
      "display_name": "Bob",
      "friends_since": "2026-07-25T15:10:00Z",
      "sharing": {
        "charge": true,
        "effort": true,
        "rest": true,
        "sleep_duration": false,
        "hrv": false,
        "rhr": false
      },
      "shared_with_me": {
        "charge": true,
        "effort": true,
        "rest": true,
        "sleep_duration": false,
        "hrv": false,
        "rhr": false
      }
    }
  ]
}
```

`sharing` is what the caller exposes to that friend. `shared_with_me` is the
friend's independently controlled allowlist. Patch any subset:

```http
PATCH /v1/social/friends/{friend_profile_id}/privacy
Authorization: Bearer <member token>
Content-Type: application/json

{"sleep_duration": true, "hrv": true}
```

Unknown fields are rejected. There is intentionally no toggle for raw heart
rate, R-R intervals, SpO₂, temperature, location, workouts, journal answers, or
sleep stages. An explicit JSON `null` is also rejected; send `true` or `false`
for every field included in a patch.

Remove a friendship with `DELETE /v1/social/friends/{friend_profile_id}`.
Block/unblock with:

```text
POST   /v1/social/blocks/{profile_id}
DELETE /v1/social/blocks/{profile_id}
```

## Feed

```http
GET /v1/social/feed?start=2026-07-20&end=2026-07-25
Authorization: Bearer <member token>
```

The default window is seven days and the maximum is 90 days. A result is a
projection, not a copy of the source row. The server never returns a friend's
day from before the UTC calendar date on which that friendship was accepted:

```json
{
  "start": "2026-07-20",
  "end": "2026-07-25",
  "days": [
    {
      "profile_id": "c62079b5-0111-44fd-a2aa-bda5528eb50f",
      "display_name": "Alice",
      "day": "2026-07-24",
      "summary": {
        "charge": 72.0,
        "effort": 59.0,
        "rest": 81.0
      }
    }
  ],
  "units": {
    "charge": "score_0_to_100",
    "effort": "score_0_to_100",
    "rest": "score_0_to_100",
    "sleep_duration": "minutes",
    "hrv": "milliseconds",
    "rhr": "beats_per_minute"
  },
  "privacy": "Only the owner's enabled daily summary fields are returned. Raw streams, location, journal, sleep stages, and workouts are never part of this endpoint."
}
```

The wire mapping is fixed:

| Friend field | Accepted `noop_computed` daily key |
| --- | --- |
| `charge` | `recovery` |
| `effort` | `effort` |
| `rest` | `sleep_performance` |
| `sleep_duration` | `total_sleep_min` |
| `hrv` | `avg_hrv` |
| `rhr` | `resting_hr` |

No other daily key can cross this projection boundary.

## Delete my social profile

A member can permanently leave the server-side social layer without receiving
or using the administrator credential:

```http
DELETE /v1/social/me
Authorization: Bearer <member token>
X-Noop-Confirm: DELETE MY SOCIAL PROFILE
```

The confirmation value must match exactly. The request has no JSON body and a
successful deletion returns `204 No Content`. In one protected operation the
server removes the authenticated profile and credential, its invites, requests,
friendships, visibility rows, blocks, sync receipts, and daily rows belonging to
the exact `daily_device_id` stored on that profile. It cannot select or erase a
different producer, including the user's normal self-hosted archive. The old
member token stops authenticating immediately.
