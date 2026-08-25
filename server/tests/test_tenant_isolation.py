from __future__ import annotations

from contextlib import contextmanager
from typing import Iterator
from uuid import uuid4

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app
from app.repository import MemoryRepository
from app.tenancy import MemoryInstallationRepository

ADMIN_TOKEN = "shared-admin-token-abcdefghijklmnopqrstuvwxyz-0123456789"


def _installation_token(character: str) -> str:
    return "noop_install_" + character * 43


def _headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def _payload(installation_id: str) -> dict:
    device_id = f"ios:{installation_id}:strap"
    return {
        "schema_version": 1,
        "batch_id": str(uuid4()),
        "source": {
            "device_id": device_id,
            "sent_at": "2026-08-24T12:00:00Z",
            "platform": "ios",
            "device": {"display_name": "Noop Band"},
            "metadata": {
                "installation_id": installation_id,
                "logical_source_id": "strap",
                "namespace": "strap_measured",
                "paired_device_id": "band",
                "privacy": "explicit_opt_in",
                "score_provenance": "strap_measured",
            },
        },
        "streams": {
            "hr": [
                {
                    "recorded_at": "2026-08-24T11:59:00Z",
                    "value": 70,
                    "metadata": {"unit": "bpm"},
                }
            ]
        },
    }


def _social_payload(
    installation_id: str,
    *,
    recovery: float,
) -> dict:
    device_id = f"ios:{installation_id}:noop-friends"
    return {
        "schema_version": 1,
        "batch_id": str(uuid4()),
        "source": {
            "device_id": device_id,
            "sent_at": "2026-08-24T18:30:00Z",
            "platform": "ios",
            "metadata": {
                "installation_id": installation_id,
                "logical_source_id": "noop-friends",
                "namespace": "noop_computed",
                "paired_device_id": "band",
                "privacy": "explicit_opt_in",
                "score_provenance": "noop_transparent_algorithm",
                "algorithm_revision": "tenant-isolation-test-v1",
            },
        },
        "streams": {},
        "daily_metrics": {
            "2026-08-24": {
                "recovery": recovery,
            }
        },
        "sleep_sessions": [],
        "workouts": [],
        "journal": [],
    }


@contextmanager
def _shared_client(
    *,
    export_max_rows: int = 100_000,
) -> Iterator[tuple[TestClient, MemoryRepository, MemoryInstallationRepository]]:
    repository = MemoryRepository()
    installations = MemoryInstallationRepository()
    app = create_app(
        settings=Settings(
            api_token=ADMIN_TOKEN,
            database_url=None,
            auth_mode="shared",
            max_request_bytes=1_000_000,
            export_max_rows=export_max_rows,
        ),
        repository=repository,
        installation_repository=installations,
    )
    with TestClient(app) as client:
        yield client, repository, installations


def _bootstrap(
    client: TestClient,
    installation_id: str,
    token: str,
    *,
    enrollment_id: str | None = None,
) -> dict:
    response = client.post(
        "/v1/admin/installations",
        headers=_headers(ADMIN_TOKEN),
        json={
            "installation_id": installation_id,
            "enrollment_id": enrollment_id or str(uuid4()),
            "installation_token": token,
        },
    )
    assert response.status_code == 201, response.text
    assert token not in response.text
    assert "token_hash" not in response.text
    return response.json()["installation"]


def _sync(client: TestClient, token: str, payload: dict):
    return client.post(
        "/v1/sync",
        headers={
            **_headers(token),
            "Idempotency-Key": payload["batch_id"],
        },
        json=payload,
    )


def test_shared_admin_cannot_read_or_write_biometric_data() -> None:
    with _shared_client() as (client, _, _):
        installation_id = str(uuid4())
        _bootstrap(client, installation_id, _installation_token("a"))
        payload = _payload(installation_id)

        status = client.get("/v1/status", headers=_headers(ADMIN_TOKEN))
        devices = client.get("/v1/devices", headers=_headers(ADMIN_TOKEN))
        sync = _sync(client, ADMIN_TOKEN, payload)
        export = client.get(
            f"/v1/devices/{payload['source']['device_id']}/export",
            headers=_headers(ADMIN_TOKEN),
        )

        assert status.status_code == 200
        assert status.json()["scope"] == "administrator"
        assert "stats" not in status.json()
        assert devices.status_code == 403
        assert sync.status_code == 403
        assert export.status_code == 403


def test_installations_are_isolated_on_list_read_export_and_delete() -> None:
    with _shared_client() as (client, _, _):
        first_id = str(uuid4())
        second_id = str(uuid4())
        first_token = _installation_token("a")
        second_token = _installation_token("b")
        _bootstrap(client, first_id, first_token)
        _bootstrap(client, second_id, second_token)
        first_payload = _payload(first_id)

        accepted = _sync(client, first_token, first_payload)
        assert accepted.status_code == 200, accepted.text
        device_id = first_payload["source"]["device_id"]

        first_devices = client.get("/v1/devices", headers=_headers(first_token))
        second_devices = client.get("/v1/devices", headers=_headers(second_token))
        foreign_latest = client.get(
            f"/v1/devices/{device_id}/latest",
            headers=_headers(second_token),
        )
        foreign_export = client.get(
            f"/v1/devices/{device_id}/export",
            headers=_headers(second_token),
        )
        foreign_delete = client.delete(
            f"/v1/devices/{device_id}",
            headers={
                **_headers(second_token),
                "X-Noop-Confirm": f"DELETE {device_id}",
            },
        )

        assert [row["device_id"] for row in first_devices.json()["devices"]] == [
            device_id
        ]
        assert second_devices.json()["devices"] == []
        assert foreign_latest.status_code == 404
        assert foreign_export.status_code == 404
        assert foreign_delete.status_code == 404
        assert (
            client.get(
                f"/v1/devices/{device_id}/latest",
                headers=_headers(first_token),
            ).status_code
            == 200
        )


def test_installation_cannot_forge_another_namespace_or_claim_its_device() -> None:
    with _shared_client() as (client, _, _):
        first_id = str(uuid4())
        second_id = str(uuid4())
        first_token = _installation_token("a")
        second_token = _installation_token("b")
        _bootstrap(client, first_id, first_token)
        _bootstrap(client, second_id, second_token)
        first_payload = _payload(first_id)
        assert _sync(client, first_token, first_payload).status_code == 200

        forged = _payload(first_id)
        rejected = _sync(client, second_token, forged)

        assert rejected.status_code == 403
        assert (
            client.get(
                "/v1/devices",
                headers=_headers(second_token),
            ).json()["devices"]
            == []
        )


def test_friend_join_and_member_sync_cannot_inject_into_another_tenant() -> None:
    with _shared_client() as (client, _, _):
        inviter_id = str(uuid4())
        attacker_id = str(uuid4())
        victim_id = str(uuid4())
        inviter_token = _installation_token("a")
        attacker_token = _installation_token("b")
        victim_token = _installation_token("c")
        for installation_id, token in (
            (inviter_id, inviter_token),
            (attacker_id, attacker_token),
            (victim_id, victim_token),
        ):
            _bootstrap(client, installation_id, token)

        victim_payload = _social_payload(victim_id, recovery=88)
        assert _sync(client, victim_token, victim_payload).status_code == 200

        inviter = client.post(
            "/v1/social/bootstrap",
            headers=_headers(inviter_token),
            json={
                "display_name": "Inviter",
                "installation_id": inviter_id,
                "daily_device_id": f"ios:{inviter_id}:noop-friends",
            },
        )
        assert inviter.status_code == 201, inviter.text
        invite = client.post(
            "/v1/social/invites",
            headers=_headers(inviter.json()["member_token"]),
            json={},
        )
        assert invite.status_code == 201, invite.text

        enrollment_id = str(uuid4())
        member_token = "noop_member_" + "m" * 43
        forged_join = client.post(
            "/v1/social/invites/join",
            headers=_headers(attacker_token),
            json={
                "code": invite.json()["code"],
                "display_name": "Attacker",
                "installation_id": victim_id,
                "daily_device_id": f"ios:{victim_id}:noop-friends",
                "enrollment_id": enrollment_id,
                "member_token": member_token,
            },
        )
        assert forged_join.status_code == 403

        legitimate_join = client.post(
            "/v1/social/invites/join",
            headers=_headers(attacker_token),
            json={
                "code": invite.json()["code"],
                "display_name": "Attacker",
                "installation_id": attacker_id,
                "daily_device_id": f"ios:{attacker_id}:noop-friends",
                "enrollment_id": enrollment_id,
                "member_token": member_token,
            },
        )
        assert legitimate_join.status_code == 201, legitimate_join.text

        injected = _sync(
            client,
            member_token,
            _social_payload(victim_id, recovery=1),
        )
        assert injected.status_code == 403
        victim_daily = client.get(
            f"/v1/devices/ios:{victim_id}:noop-friends/daily",
            headers=_headers(victim_token),
            params={
                "start": "2026-08-24",
                "end": "2026-08-24",
            },
        )
        assert victim_daily.status_code == 200, victim_daily.text
        assert victim_daily.json()["days"][0]["metrics"]["recovery"] == 88


def test_rotation_is_retry_safe_and_immediately_invalidates_old_token() -> None:
    with _shared_client() as (client, _, _):
        installation_id = str(uuid4())
        old_token = _installation_token("a")
        new_token = _installation_token("c")
        _bootstrap(client, installation_id, old_token)
        rotation = {
            "rotation_id": str(uuid4()),
            "expected_version": 1,
            "installation_token": new_token,
        }

        first = client.put(
            "/v1/installation/me/token",
            headers=_headers(old_token),
            json=rotation,
        )
        old_status = client.get("/v1/status", headers=_headers(old_token))
        replay = client.put(
            "/v1/installation/me/token",
            headers=_headers(new_token),
            json=rotation,
        )

        assert first.status_code == 200, first.text
        assert first.json()["installation"]["token_version"] == 2
        assert old_status.status_code == 401
        assert replay.status_code == 200
        assert replay.json() == first.json()


def test_installation_export_and_hard_delete_cover_every_owned_device() -> None:
    with _shared_client() as (client, _, _):
        installation_id = str(uuid4())
        token = _installation_token("a")
        _bootstrap(client, installation_id, token)
        payload = _payload(installation_id)
        assert _sync(client, token, payload).status_code == 200

        exported = client.get(
            "/v1/installation/me/export",
            headers=_headers(token),
        )
        deleted = client.delete(
            "/v1/installation/me",
            headers={
                **_headers(token),
                "X-Noop-Confirm": "DELETE MY INSTALLATION",
            },
        )

        assert exported.status_code == 200
        assert exported.json()["installation"]["installation_id"] == installation_id
        assert len(exported.json()["devices"]) == 1
        assert deleted.status_code == 200, deleted.text
        assert deleted.json()["devices"] == 1
        assert client.get("/v1/status", headers=_headers(token)).status_code == 401
        replacement_token = _installation_token("d")
        _bootstrap(client, installation_id, replacement_token)
        assert (
            client.get(
                "/v1/devices",
                headers=_headers(replacement_token),
            ).json()["devices"]
            == []
        )


def test_device_and_installation_exports_fail_closed_at_aggregate_limit() -> None:
    with _shared_client(export_max_rows=1) as (client, _, _):
        installation_id = str(uuid4())
        token = _installation_token("a")
        _bootstrap(client, installation_id, token)
        payload = _payload(installation_id)
        assert _sync(client, token, payload).status_code == 200
        device_id = payload["source"]["device_id"]

        device_export = client.get(
            f"/v1/devices/{device_id}/export",
            headers=_headers(token),
        )
        installation_export = client.get(
            "/v1/installation/me/export",
            headers=_headers(token),
        )
        bounded_window = client.get(
            "/v1/installation/me/export",
            headers=_headers(token),
            params={"start": "2026-08-25T00:00:00Z"},
        )

        assert device_export.status_code == 413
        assert device_export.json()["max_rows"] == 1
        assert "start/end" in device_export.json()["detail"]
        assert installation_export.status_code == 413
        assert bounded_window.status_code == 200, bounded_window.text
        assert bounded_window.json()["row_count"] == 1
        assert bounded_window.json()["devices"][0]["metric_samples"] == []


def test_installation_hard_delete_erases_social_and_safety_credentials() -> None:
    with _shared_client() as (client, _, _):
        installation_id = str(uuid4())
        installation_token = _installation_token("a")
        _bootstrap(client, installation_id, installation_token)
        daily_device_id = f"ios:{installation_id}:noop-computed"
        social = client.post(
            "/v1/social/bootstrap",
            headers=_headers(installation_token),
            json={
                "display_name": "Jordan",
                "installation_id": installation_id,
                "daily_device_id": daily_device_id,
            },
        )
        safety_token = "noop_safety_" + "s" * 43
        safety = client.post(
            "/v1/safety/bootstrap",
            headers=_headers(installation_token),
            json={
                "display_name": "Jordan",
                "installation_id": installation_id,
                "enrollment_id": str(uuid4()),
                "safety_token": safety_token,
            },
        )
        assert social.status_code == 201, social.text
        assert safety.status_code == 201, safety.text
        member_token = social.json()["member_token"]

        deleted = client.delete(
            "/v1/installation/me",
            headers={
                **_headers(installation_token),
                "X-Noop-Confirm": "DELETE MY INSTALLATION",
            },
        )

        assert deleted.status_code == 200, deleted.text
        assert deleted.json()["social_counts"]["friend_profiles"] == 1
        assert deleted.json()["safety_counts"]["profiles"] == 1
        assert (
            client.get("/v1/social/me", headers=_headers(member_token)).status_code
            == 401
        )
        assert (
            client.get("/v1/safety/me", headers=_headers(safety_token)).status_code
            == 401
        )
