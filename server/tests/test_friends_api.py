from __future__ import annotations

import hashlib
from datetime import UTC, datetime, timedelta
from uuid import uuid4

from fastapi.testclient import TestClient

from app.repository import MemoryRepository


def _member_token(character: str) -> str:
    return f"noop_member_{character * 43}"


def _bootstrap(
    client: TestClient,
    admin_headers: dict[str, str],
    *,
    display_name: str,
    installation_id: str,
) -> tuple[dict, dict[str, str]]:
    response = client.post(
        "/v1/social/bootstrap",
        headers=admin_headers,
        json={
            "display_name": display_name,
            "installation_id": installation_id,
            "daily_device_id": f"ios:{installation_id}:noop-friends",
        },
    )
    assert response.status_code == 201, response.text
    body = response.json()
    return body["profile"], {"Authorization": f"Bearer {body['member_token']}"}


def _computed_payload(
    installation_id: str,
    day: str,
    metrics: dict[str, float],
    *,
    namespace: str = "noop_computed",
) -> dict:
    provenance = (
        "noop_transparent_algorithm"
        if namespace == "noop_computed"
        else "user_imported_whoop_export"
    )
    metadata = {
        "installation_id": installation_id,
        "logical_source_id": "noop-friends",
        "namespace": namespace,
        "paired_device_id": "strap-test",
        "privacy": "explicit_opt_in",
        "score_provenance": provenance,
    }
    if namespace == "noop_computed":
        metadata["algorithm_revision"] = "charge-v1+effort-v1+rest-v1"
    return {
        "schema_version": 1,
        "batch_id": str(uuid4()),
        "source": {
            "device_id": f"ios:{installation_id}:noop-friends",
            "sent_at": f"{day}T18:30:00Z",
            "platform": "ios",
            "metadata": metadata,
        },
        "streams": {},
        "daily_metrics": {day: metrics},
        "sleep_sessions": [],
        "workouts": [],
        "journal": [],
    }


def _become_friends(
    client: TestClient,
    inviter_headers: dict[str, str],
    requester_headers: dict[str, str],
) -> tuple[str, str]:
    invite_response = client.post(
        "/v1/social/invites",
        headers=inviter_headers,
        json={"expires_in_hours": 24},
    )
    assert invite_response.status_code == 201, invite_response.text
    invite = invite_response.json()
    request_response = client.post(
        "/v1/social/invites/redeem",
        headers=requester_headers,
        json={"code": invite["code"]},
    )
    assert request_response.status_code == 201, request_response.text
    request_id = request_response.json()["request"]["request_id"]
    accepted = client.post(
        f"/v1/social/requests/{request_id}",
        headers=inviter_headers,
        json={"decision": "accept"},
    )
    assert accepted.status_code == 200, accepted.text
    return invite["invite"]["invite_id"], request_id


def test_social_credentials_are_scoped_and_invites_are_one_time(
    client: TestClient,
    auth_headers: dict[str, str],
    repository: MemoryRepository,
) -> None:
    alice_install = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    bob_install = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    alice, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id=alice_install,
    )
    bob, bob_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Bob",
        installation_id=bob_install,
    )

    alice_token = alice_headers["Authorization"].removeprefix("Bearer ")
    assert alice_token.startswith("noop_member_")
    assert alice_token not in repository._friend_tokens
    assert hashlib.sha256(alice_token.encode()).hexdigest() in repository._friend_tokens

    assert client.get("/v1/social/me", headers=auth_headers).status_code == 401
    assert client.get("/v1/devices", headers=alice_headers).status_code == 401
    assert client.get("/v1/social/me").status_code == 401
    member_status = client.get("/v1/status", headers=alice_headers)
    assert member_status.status_code == 200
    assert member_status.json()["scope"] == "social_member"
    assert "stats" not in member_status.json()

    invite_response = client.post(
        "/v1/social/invites",
        headers=alice_headers,
        json={"expires_in_hours": 24},
    )
    assert invite_response.status_code == 201
    invite = invite_response.json()
    code = invite["code"]
    assert code.startswith("NOOP-")
    assert alice_token not in code
    assert auth_headers["Authorization"].removeprefix("Bearer ") not in code
    assert code.replace("-", "") not in {
        row["code_hash"] for row in repository._friend_invites.values()
    }

    redeemed = client.post(
        "/v1/social/invites/redeem",
        headers=bob_headers,
        json={"code": code.lower()},
    )
    assert redeemed.status_code == 201, redeemed.text
    request_id = redeemed.json()["request"]["request_id"]
    assert redeemed.json()["request"]["recipient"]["display_name"] == "Alice"

    replay = client.post(
        "/v1/social/invites/redeem",
        headers=bob_headers,
        json={"code": code},
    )
    assert replay.status_code == 404

    bob_cannot_accept = client.post(
        f"/v1/social/requests/{request_id}",
        headers=bob_headers,
        json={"decision": "accept"},
    )
    assert bob_cannot_accept.status_code == 404

    alice_requests = client.get("/v1/social/requests", headers=alice_headers).json()[
        "requests"
    ]
    assert alice_requests[0]["direction"] == "incoming"
    assert alice_requests[0]["profile"]["profile_id"] == bob["profile_id"]
    accepted = client.post(
        f"/v1/social/requests/{request_id}",
        headers=alice_headers,
        json={"decision": "accept"},
    )
    assert accepted.status_code == 200

    alice_friends = client.get("/v1/social/friends", headers=alice_headers).json()[
        "friends"
    ]
    assert alice_friends == [
        {
            "profile_id": bob["profile_id"],
            "display_name": "Bob",
            "friends_since": alice_friends[0]["friends_since"],
            "sharing": {
                "charge": True,
                "effort": True,
                "rest": True,
                "sleep_duration": False,
                "hrv": False,
                "rhr": False,
            },
            "shared_with_me": {
                "charge": True,
                "effort": True,
                "rest": True,
                "sleep_duration": False,
                "hrv": False,
                "rhr": False,
            },
        }
    ]


def test_invite_join_atomically_bootstraps_without_admin_credential(
    client: TestClient,
    auth_headers: dict[str, str],
    repository: MemoryRepository,
) -> None:
    _, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id="56565656-5656-4656-8656-565656565656",
    )
    invite = client.post("/v1/social/invites", headers=alice_headers, json={}).json()
    profile_count = len(repository._friend_profiles)

    invalid_secret = "plaintext-member-token-that-must-never-be-reflected"
    invalid_token = client.post(
        "/v1/social/invites/join",
        json={
            "code": invite["code"],
            "display_name": "Mallory",
            "installation_id": "67676767-6767-4767-8767-676767676767",
            "daily_device_id": (
                "ios:67676767-6767-4767-8767-676767676767:noop-friends"
            ),
            "enrollment_id": str(uuid4()),
            "member_token": invalid_secret,
        },
    )
    assert invalid_token.status_code == 422
    assert invalid_secret not in invalid_token.text
    assert invalid_token.json()["detail"][0]["input"] == "[redacted]"

    invalid = client.post(
        "/v1/social/invites/join",
        json={
            "code": "NOOP-DOES-NOT-EXIST",
            "display_name": "Mallory",
            "installation_id": "67676767-6767-4767-8767-676767676767",
            "daily_device_id": (
                "ios:67676767-6767-4767-8767-676767676767:noop-friends"
            ),
            "enrollment_id": str(uuid4()),
            "member_token": _member_token("M"),
        },
    )
    assert invalid.status_code == 404
    assert len(repository._friend_profiles) == profile_count

    bob_install = "78787878-7878-4878-8878-787878787878"
    bob_enrollment = str(uuid4())
    bob_token = _member_token("B")
    join_body = {
        "code": invite["code"],
        "display_name": "Bob",
        "installation_id": bob_install,
        "daily_device_id": f"ios:{bob_install}:noop-friends",
        "enrollment_id": bob_enrollment,
        "member_token": bob_token,
    }
    joined = client.post(
        "/v1/social/invites/join",
        json=join_body,
    )
    assert joined.status_code == 201, joined.text
    body = joined.json()
    assert body["profile"]["display_name"] == "Bob"
    assert body["request"]["status"] == "pending"
    assert body["request"]["recipient"] == {"display_name": "Alice"}
    assert "inviter_id" not in body["request"]
    assert "invite_id" not in body["request"]
    assert "member_token" not in body
    assert body["profile"]["enrollment_id"] == bob_enrollment
    assert body["idempotent_replay"] is False
    assert bob_token not in repository._friend_tokens
    assert hashlib.sha256(bob_token.encode()).hexdigest() in repository._friend_tokens

    repository._friend_invites[invite["invite"]["invite_id"]]["expires_at"] = (
        datetime.now(UTC) - timedelta(seconds=1)
    )
    replay = client.post("/v1/social/invites/join", json=join_body)
    assert replay.status_code == 201
    assert replay.json()["idempotent_replay"] is True
    assert replay.json()["profile"]["profile_id"] == body["profile"]["profile_id"]
    assert replay.json()["request"]["request_id"] == body["request"]["request_id"]

    wrong_token = client.post(
        "/v1/social/invites/join",
        json={**join_body, "member_token": _member_token("X")},
    )
    assert wrong_token.status_code == 409

    raced = client.post(
        "/v1/social/invites/join",
        json={
            "code": invite["code"],
            "display_name": "Eve",
            "installation_id": "89898989-8989-4989-8989-898989898989",
            "daily_device_id": (
                "ios:89898989-8989-4989-8989-898989898989:noop-friends"
            ),
            "enrollment_id": str(uuid4()),
            "member_token": _member_token("E"),
        },
    )
    assert raced.status_code == 409
    assert len(repository._friend_profiles) == profile_count + 1

    bob_headers = {"Authorization": f"Bearer {bob_token}"}
    accepted = client.post(
        f"/v1/social/requests/{body['request']['request_id']}",
        headers=alice_headers,
        json={"decision": "accept"},
    )
    assert accepted.status_code == 200
    accepted_replay = client.post("/v1/social/invites/join", json=join_body)
    assert accepted_replay.status_code == 201
    assert accepted_replay.json()["idempotent_replay"] is True
    assert accepted_replay.json()["request"]["status"] == "accepted"
    assert (
        client.get("/v1/social/friends", headers=bob_headers).json()["friends"][0][
            "display_name"
        ]
        == "Alice"
    )


def test_member_sync_accepts_only_exact_computed_social_daily_envelope(
    client: TestClient,
    auth_headers: dict[str, str],
) -> None:
    installation_id = "90909090-9090-4090-8090-909090909090"
    _, member_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Scoped member",
        installation_id=installation_id,
    )
    allowed = _computed_payload(
        installation_id,
        "2026-07-24",
        {
            "recovery": 72,
            "effort": 59,
            "sleep_performance": 81,
            "total_sleep_min": 455,
            "avg_hrv": 63.5,
            "resting_hr": 52,
        },
    )
    accepted = client.post("/v1/sync", headers=member_headers, json=allowed)
    assert accepted.status_code == 200, accepted.text

    replacement = _computed_payload(
        installation_id,
        "2026-07-24",
        {"recovery": 73, "effort": 60},
    )
    replaced = client.post("/v1/sync", headers=member_headers, json=replacement)
    assert replaced.status_code == 200, replaced.text
    stored_day = client.get(
        f"/v1/devices/ios:{installation_id}:noop-friends/daily",
        headers=auth_headers,
        params={"start": "2026-07-24", "end": "2026-07-24"},
    ).json()["days"][0]["metrics"]
    assert stored_day == {"effort": 60.0, "recovery": 73.0}

    clear_day = _computed_payload(installation_id, "2026-07-24", {})
    cleared = client.post("/v1/sync", headers=member_headers, json=clear_day)
    assert cleared.status_code == 200, cleared.text
    assert (
        client.get(
            f"/v1/devices/ios:{installation_id}:noop-friends/daily",
            headers=auth_headers,
            params={"start": "2026-07-24", "end": "2026-07-24"},
        ).json()["days"]
        == []
    )

    cross_install = _computed_payload(
        "91919191-9191-4191-8191-919191919191",
        "2026-07-24",
        {"recovery": 90},
    )
    rejected = client.post("/v1/sync", headers=member_headers, json=cross_install)
    assert rejected.status_code == 403

    imported = _computed_payload(
        installation_id,
        "2026-07-25",
        {"recovery": 99},
        namespace="official_reference",
    )
    assert (
        client.post("/v1/sync", headers=member_headers, json=imported).status_code
        == 403
    )

    extra_daily = _computed_payload(
        installation_id,
        "2026-07-26",
        {"recovery": 80, "steps": 10_000},
    )
    assert (
        client.post("/v1/sync", headers=member_headers, json=extra_daily).status_code
        == 403
    )

    out_of_range = _computed_payload(
        installation_id,
        "2026-07-26",
        {"recovery": 101},
    )
    assert (
        client.post("/v1/sync", headers=member_headers, json=out_of_range).status_code
        == 403
    )

    derived_workout = _computed_payload(
        installation_id,
        "2026-07-27",
        {"recovery": 80},
    )
    derived_workout["workouts"] = [
        {
            "workout_id": "private-workout",
            "start_ts": "2026-07-27T12:00:00Z",
            "end_ts": "2026-07-27T13:00:00Z",
            "sport": "Running",
        }
    ]
    assert (
        client.post(
            "/v1/sync", headers=member_headers, json=derived_workout
        ).status_code
        == 403
    )

    raw = _computed_payload(
        installation_id,
        "2026-07-28",
        {},
    )
    raw["source"]["metadata"].update(
        {
            "namespace": "strap_measured",
            "score_provenance": "strap_measured",
        }
    )
    raw["source"]["metadata"].pop("algorithm_revision")
    raw["daily_metrics"] = {}
    raw["streams"] = {"hr": [{"recorded_at": "2026-07-28T12:00:00Z", "value": 70}]}
    assert client.post("/v1/sync", headers=member_headers, json=raw).status_code == 403


def test_member_can_delete_profile_and_only_its_scoped_social_producer(
    client: TestClient,
    auth_headers: dict[str, str],
    repository: MemoryRepository,
) -> None:
    alice_install = "14141414-1414-4414-8414-141414141414"
    bob_install = "15151515-1515-4515-8515-151515151515"
    other_install = "16161616-1616-4616-8616-161616161616"
    alice, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id=alice_install,
    )
    _, bob_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Bob",
        installation_id=bob_install,
    )
    _become_friends(client, alice_headers, bob_headers)
    spare_invite = client.post(
        "/v1/social/invites", headers=alice_headers, json={}
    ).json()

    day = datetime.now(UTC).date().isoformat()
    own_summary = _computed_payload(
        alice_install,
        day,
        {"recovery": 72, "effort": 59, "sleep_performance": 81},
    )
    assert (
        client.post("/v1/sync", headers=alice_headers, json=own_summary).status_code
        == 200
    )
    other_summary = _computed_payload(
        other_install,
        day,
        {"recovery": 88, "effort": 42, "sleep_performance": 90},
    )
    assert (
        client.post("/v1/sync", headers=auth_headers, json=other_summary).status_code
        == 200
    )

    missing_confirmation = client.delete("/v1/social/me", headers=alice_headers)
    assert missing_confirmation.status_code == 412
    assert client.get("/v1/social/me", headers=alice_headers).status_code == 200

    deleted = client.delete(
        "/v1/social/me",
        headers={
            **alice_headers,
            "X-Noop-Confirm": "DELETE MY SOCIAL PROFILE",
        },
    )
    assert deleted.status_code == 204
    assert deleted.content == b""
    assert client.get("/v1/social/me", headers=alice_headers).status_code == 401
    assert (
        client.post("/v1/sync", headers=alice_headers, json=own_summary).status_code
        == 401
    )

    own_days = client.get(
        f"/v1/devices/{alice['daily_device_id']}/daily",
        headers=auth_headers,
        params={"start": day, "end": day},
    ).json()["days"]
    assert own_days == []
    other_days = client.get(
        f"/v1/devices/ios:{other_install}:noop-friends/daily",
        headers=auth_headers,
        params={"start": day, "end": day},
    ).json()["days"]
    assert other_days[0]["metrics"]["recovery"] == 88
    assert client.get("/v1/social/friends", headers=bob_headers).json() == {
        "friends": []
    }
    assert all(
        profile["profile_id"] != alice["profile_id"]
        for profile in client.get(
            "/v1/social/admin/profiles", headers=auth_headers
        ).json()["profiles"]
    )
    assert alice["profile_id"] not in repository._friend_profiles
    assert alice["profile_id"] not in repository._friend_tokens.values()

    rejected_join = client.post(
        "/v1/social/invites/join",
        json={
            "code": spare_invite["code"],
            "display_name": "Charlie",
            "installation_id": "17171717-1717-4717-8717-171717171717",
            "daily_device_id": (
                "ios:17171717-1717-4717-8717-171717171717:noop-friends"
            ),
            "enrollment_id": str(uuid4()),
            "member_token": _member_token("C"),
        },
    )
    assert rejected_join.status_code == 404


def test_feed_enforces_directional_daily_allowlist_and_computed_namespace(
    client: TestClient,
    auth_headers: dict[str, str],
) -> None:
    alice_install = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
    bob_install = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    alice, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id=alice_install,
    )
    bob, bob_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Bob",
        installation_id=bob_install,
    )
    _become_friends(client, alice_headers, bob_headers)

    friends_since = client.get("/v1/social/friends", headers=alice_headers).json()[
        "friends"
    ][0]["friends_since"]
    friendship_day = datetime.fromisoformat(friends_since).date()
    prior_day = friendship_day - timedelta(days=1)
    official_day = friendship_day + timedelta(days=1)
    before_friendship = _computed_payload(
        alice_install,
        prior_day.isoformat(),
        {"recovery": 5, "effort": 5, "sleep_performance": 5},
    )
    uploaded = client.post("/v1/sync", headers=auth_headers, json=before_friendship)
    assert uploaded.status_code == 200, uploaded.text

    computed = _computed_payload(
        alice_install,
        friendship_day.isoformat(),
        {
            "recovery": 72,
            "effort": 59,
            "sleep_performance": 81,
            "total_sleep_min": 455,
            "avg_hrv": 63.5,
            "resting_hr": 52,
            "steps": 12_345,
            "spo2_pct": 98,
        },
    )
    uploaded = client.post("/v1/sync", headers=auth_headers, json=computed)
    assert uploaded.status_code == 200, uploaded.text

    official_only = _computed_payload(
        alice_install,
        official_day.isoformat(),
        {"recovery": 99, "effort": 99, "sleep_performance": 99},
        namespace="official_reference",
    )
    uploaded = client.post("/v1/sync", headers=auth_headers, json=official_only)
    assert uploaded.status_code == 200, uploaded.text

    default_feed = client.get(
        "/v1/social/feed",
        headers=bob_headers,
        params={"start": prior_day.isoformat(), "end": official_day.isoformat()},
    )
    assert default_feed.status_code == 200
    days = default_feed.json()["days"]
    assert days == [
        {
            "profile_id": alice["profile_id"],
            "display_name": "Alice",
            "day": friendship_day.isoformat(),
            "summary": {"charge": 72.0, "effort": 59.0, "rest": 81.0},
        }
    ]
    assert "steps" not in default_feed.text
    assert "spo2" not in default_feed.text
    assert "journal" in default_feed.json()["privacy"]

    invalid_field = client.patch(
        f"/v1/social/friends/{bob['profile_id']}/privacy",
        headers=alice_headers,
        json={"raw_hr": True},
    )
    assert invalid_field.status_code == 422

    explicit_null = client.patch(
        f"/v1/social/friends/{bob['profile_id']}/privacy",
        headers=alice_headers,
        json={"hrv": None},
    )
    assert explicit_null.status_code == 422
    assert (
        client.get("/v1/social/friends", headers=alice_headers).json()["friends"][0][
            "sharing"
        ]["hrv"]
        is False
    )

    expanded = client.patch(
        f"/v1/social/friends/{bob['profile_id']}/privacy",
        headers=alice_headers,
        json={"sleep_duration": True, "hrv": True, "rhr": True},
    )
    assert expanded.status_code == 200
    assert expanded.json()["sharing"] == {
        "charge": True,
        "effort": True,
        "rest": True,
        "sleep_duration": True,
        "hrv": True,
        "rhr": True,
    }

    expanded_feed = client.get(
        "/v1/social/feed",
        headers=bob_headers,
        params={
            "start": friendship_day.isoformat(),
            "end": friendship_day.isoformat(),
        },
    ).json()["days"]
    assert expanded_feed[0]["summary"] == {
        "charge": 72.0,
        "effort": 59.0,
        "rest": 81.0,
        "sleep_duration": 455.0,
        "hrv": 63.5,
        "rhr": 52.0,
    }

    bob_view = client.get("/v1/social/friends", headers=bob_headers).json()["friends"][
        0
    ]
    assert bob_view["sharing"]["hrv"] is False
    assert bob_view["shared_with_me"]["hrv"] is True

    removed = client.delete(
        f"/v1/social/friends/{alice['profile_id']}", headers=bob_headers
    )
    assert removed.status_code == 204
    assert (
        client.get(
            "/v1/social/feed",
            headers=bob_headers,
            params={
                "start": friendship_day.isoformat(),
                "end": friendship_day.isoformat(),
            },
        ).json()["days"]
        == []
    )


def test_incoming_request_can_be_declined(
    client: TestClient,
    auth_headers: dict[str, str],
) -> None:
    _, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id="31313131-3131-4131-8131-313131313131",
    )
    _, bob_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Bob",
        installation_id="32323232-3232-4232-8232-323232323232",
    )
    invite = client.post("/v1/social/invites", headers=alice_headers, json={}).json()
    request = client.post(
        "/v1/social/invites/redeem",
        headers=bob_headers,
        json={"code": invite["code"]},
    ).json()["request"]
    declined = client.post(
        f"/v1/social/requests/{request['request_id']}",
        headers=alice_headers,
        json={"decision": "decline"},
    )
    assert declined.status_code == 200
    assert declined.json()["request"]["status"] == "declined"
    assert client.get("/v1/social/requests", headers=alice_headers).json() == {
        "requests": []
    }
    assert client.get("/v1/social/friends", headers=bob_headers).json() == {
        "friends": []
    }


def test_block_cancels_relationship_and_suppresses_future_invites(
    client: TestClient,
    auth_headers: dict[str, str],
) -> None:
    alice, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id="eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
    )
    bob, bob_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Bob",
        installation_id="ffffffff-ffff-4fff-8fff-ffffffffffff",
    )
    _become_friends(client, alice_headers, bob_headers)

    blocked = client.post(
        f"/v1/social/blocks/{alice['profile_id']}", headers=bob_headers
    )
    assert blocked.status_code == 204
    assert client.get("/v1/social/friends", headers=bob_headers).json() == {
        "friends": []
    }

    next_invite = client.post(
        "/v1/social/invites", headers=alice_headers, json={}
    ).json()["code"]
    hidden = client.post(
        "/v1/social/invites/redeem",
        headers=bob_headers,
        json={"code": next_invite},
    )
    assert hidden.status_code == 404
    assert hidden.json()["detail"] == "invite is invalid or expired"

    assert (
        client.delete(
            f"/v1/social/blocks/{alice['profile_id']}", headers=bob_headers
        ).status_code
        == 204
    )


def test_bootstrap_requires_installation_scoped_device_and_admin_token(
    client: TestClient,
    auth_headers: dict[str, str],
) -> None:
    body = {
        "display_name": "Alice",
        "installation_id": "11111111-1111-4111-8111-111111111111",
        "daily_device_id": ("ios:22222222-2222-4222-8222-222222222222:noop-friends"),
    }
    assert client.post("/v1/social/bootstrap", json=body).status_code == 401
    mismatch = client.post("/v1/social/bootstrap", headers=auth_headers, json=body)
    assert mismatch.status_code == 422

    _, member_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Scoped",
        installation_id="11111111-1111-4111-8111-111111111111",
    )
    duplicate = client.post(
        "/v1/social/bootstrap",
        headers=auth_headers,
        json={
            "display_name": "Duplicate",
            "installation_id": "11111111-1111-4111-8111-111111111111",
            "daily_device_id": (
                "ios:11111111-1111-4111-8111-111111111111:noop-friends"
            ),
        },
    )
    assert duplicate.status_code == 409
    assert (
        client.get("/v1/social/admin/profiles", headers=member_headers).status_code
        == 401
    )


def test_expired_and_revoked_invites_are_indistinguishable(
    client: TestClient,
    auth_headers: dict[str, str],
    repository: MemoryRepository,
) -> None:
    _, alice_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Alice",
        installation_id="12121212-1212-4212-8212-121212121212",
    )
    _, bob_headers = _bootstrap(
        client,
        auth_headers,
        display_name="Bob",
        installation_id="34343434-3434-4434-8434-343434343434",
    )
    invite = client.post("/v1/social/invites", headers=alice_headers, json={}).json()
    invite_id = invite["invite"]["invite_id"]
    repository._friend_invites[invite_id]["expires_at"] = datetime.now(UTC) - timedelta(
        seconds=1
    )
    expired = client.post(
        "/v1/social/invites/redeem",
        headers=bob_headers,
        json={"code": invite["code"]},
    )
    assert expired.status_code == 404
    assert expired.json()["detail"] == "invite is invalid or expired"

    active = client.post("/v1/social/invites", headers=alice_headers, json={}).json()
    assert (
        client.delete(
            f"/v1/social/invites/{active['invite']['invite_id']}",
            headers=alice_headers,
        ).status_code
        == 204
    )
    revoked = client.post(
        "/v1/social/invites/redeem",
        headers=bob_headers,
        json={"code": active["code"]},
    )
    assert revoked.status_code == 404
    assert revoked.json()["detail"] == "invite is invalid or expired"
