"""Auth, admin seeding, and user-management endpoints."""

import pytest
from conftest import ADMIN_TOKEN, auth


# --- auth ---------------------------------------------------------------

async def test_protected_route_requires_token(client):
    resp = await client.get("/api/videos")
    assert resp.status_code == 401


async def test_protected_route_accepts_valid_token(client):
    resp = await client.get("/api/videos", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200


async def test_invalid_token_rejected(client):
    resp = await client.get("/api/videos", headers=auth("nope"))
    assert resp.status_code == 401


async def test_health_always_200_and_reports_validity(client):
    no_tok = await client.get("/api/health")
    assert no_tok.status_code == 200
    body = no_tok.json()
    assert body["token_required"] is True
    assert body["token_valid"] is False

    good = await client.get("/api/health", headers=auth(ADMIN_TOKEN))
    assert good.json()["token_valid"] is True


# --- seeding ------------------------------------------------------------

async def _admin_row(client, token):
    resp = await client.get("/api/users", headers=auth(token))
    assert resp.status_code == 200
    return next(u for u in resp.json()["users"] if u["username"] == "admin")


async def test_admin_seeded_from_access_token(client):
    admin = await _admin_row(client, ADMIN_TOKEN)
    assert admin["is_admin"] is True
    assert admin["token"] == ADMIN_TOKEN


async def test_access_token_change_updates_existing_admin(
    client, app_module, monkeypatch
):
    """ACCESS_TOKEN is authoritative — the only way back into a deployment whose
    admin token was randomly generated on a boot without ACCESS_TOKEN."""
    monkeypatch.setenv("ACCESS_TOKEN", "rotated-token")
    await app_module.ensure_admin()

    admin = await _admin_row(client, "rotated-token")
    assert admin["token"] == "rotated-token"
    # The superseded token stops working.
    assert (await client.get("/api/videos", headers=auth(ADMIN_TOKEN))).status_code == 401


async def test_empty_access_token_leaves_admin_alone(client, app_module, monkeypatch):
    monkeypatch.setenv("ACCESS_TOKEN", "")
    await app_module.ensure_admin()

    admin = await _admin_row(client, ADMIN_TOKEN)
    assert admin["token"] == ADMIN_TOKEN


async def test_access_token_clashing_with_another_user_is_refused(
    client, app_module, monkeypatch
):
    created = await client.post(
        "/api/users", json={"username": "someone", "token": "taken-token"},
        headers=auth(ADMIN_TOKEN),
    )
    assert created.status_code == 201

    monkeypatch.setenv("ACCESS_TOKEN", "taken-token")
    await app_module.ensure_admin()

    # Admin keeps its own token rather than colliding with someone else's.
    admin = await _admin_row(client, ADMIN_TOKEN)
    assert admin["token"] == ADMIN_TOKEN


# --- user management ----------------------------------------------------

async def test_create_user_returns_token_and_lists(client):
    resp = await client.post(
        "/api/users", json={"username": "bob"}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 201
    created = resp.json()
    assert created["username"] == "bob"
    assert created["token"]
    assert created["is_admin"] is False

    listed = (await client.get("/api/users", headers=auth(ADMIN_TOKEN))).json()["users"]
    assert any(u["username"] == "bob" for u in listed)


async def test_create_user_with_explicit_token(client):
    resp = await client.post(
        "/api/users",
        json={"username": "carol", "token": "carol-token"},
        headers=auth(ADMIN_TOKEN),
    )
    assert resp.status_code == 201
    assert resp.json()["token"] == "carol-token"


async def test_create_duplicate_username_conflicts(client):
    await client.post("/api/users", json={"username": "dup"}, headers=auth(ADMIN_TOKEN))
    resp = await client.post(
        "/api/users", json={"username": "dup"}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 409


async def test_new_user_token_authenticates(client):
    created = (
        await client.post(
            "/api/users",
            json={"username": "eve", "token": "eve-token"},
            headers=auth(ADMIN_TOKEN),
        )
    ).json()
    resp = await client.get("/api/videos", headers=auth(created["token"]))
    assert resp.status_code == 200


async def test_non_admin_cannot_manage_users(client):
    await client.post(
        "/api/users",
        json={"username": "frank", "token": "frank-token"},
        headers=auth(ADMIN_TOKEN),
    )
    resp = await client.post(
        "/api/users", json={"username": "x"}, headers=auth("frank-token")
    )
    assert resp.status_code == 403


async def test_update_user_token(client):
    created = (
        await client.post(
            "/api/users",
            json={"username": "grace", "token": "grace-old"},
            headers=auth(ADMIN_TOKEN),
        )
    ).json()
    resp = await client.patch(
        f"/api/users/{created['id']}",
        json={"token": "grace-new"},
        headers=auth(ADMIN_TOKEN),
    )
    assert resp.status_code == 200
    # old token no longer works, new one does
    assert (await client.get("/api/videos", headers=auth("grace-old"))).status_code == 401
    assert (await client.get("/api/videos", headers=auth("grace-new"))).status_code == 200


async def test_update_user_rename(client):
    created = (
        await client.post(
            "/api/users", json={"username": "heidi"}, headers=auth(ADMIN_TOKEN)
        )
    ).json()
    resp = await client.patch(
        f"/api/users/{created['id']}",
        json={"username": "heidi2"},
        headers=auth(ADMIN_TOKEN),
    )
    assert resp.status_code == 200
    assert resp.json()["username"] == "heidi2"


async def test_admin_cannot_be_renamed(client):
    users = (await client.get("/api/users", headers=auth(ADMIN_TOKEN))).json()["users"]
    admin_id = next(u["id"] for u in users if u["username"] == "admin")
    resp = await client.patch(
        f"/api/users/{admin_id}",
        json={"username": "root"},
        headers=auth(ADMIN_TOKEN),
    )
    assert resp.status_code == 400


async def test_admin_token_can_change(client):
    users = (await client.get("/api/users", headers=auth(ADMIN_TOKEN))).json()["users"]
    admin_id = next(u["id"] for u in users if u["username"] == "admin")
    resp = await client.patch(
        f"/api/users/{admin_id}",
        json={"token": "new-admin-token"},
        headers=auth(ADMIN_TOKEN),
    )
    assert resp.status_code == 200
    assert (
        await client.get("/api/videos", headers=auth("new-admin-token"))
    ).status_code == 200


async def test_admin_cannot_be_deleted(client):
    users = (await client.get("/api/users", headers=auth(ADMIN_TOKEN))).json()["users"]
    admin_id = next(u["id"] for u in users if u["username"] == "admin")
    resp = await client.delete(f"/api/users/{admin_id}", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 400


async def test_delete_user(client):
    created = (
        await client.post(
            "/api/users",
            json={"username": "ivan", "token": "ivan-token"},
            headers=auth(ADMIN_TOKEN),
        )
    ).json()
    resp = await client.delete(f"/api/users/{created['id']}", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 204
    assert (await client.get("/api/videos", headers=auth("ivan-token"))).status_code == 401
