# Backend: users, request logging, token-based auth, subtitle fix

Date: 2026-06-22
Scope: backend only.

## Goals

1. Introduce a `user` concept with two new DB tables: `users` and `requests`.
2. Authenticate every request by its access token (look the user up by token);
   remove the hard-coded single `ACCESS_TOKEN` check.
3. Log every "expensive" operation (anything that uses the YouTube API or
   downloads) to the `requests` table, attributed to the calling user.
4. Seed a default `admin` user. Add admin-only endpoints to add / remove /
   update users.
5. Fix Traditional-Chinese subtitle conversion (`zh` / `zh-Hans` must be
   converted before saving).

Constraints: backend runs in Docker on SQLite. New tables must be added with
create-if-not-exist so existing `videos` data is preserved.

## Data model (`app/models.py`)

### `users`
| col | type | notes |
|---|---|---|
| `id` | int PK autoincrement | |
| `username` | str, unique, not null | |
| `token` | str, unique, not null, indexed | identifies the user on each request |
| `is_admin` | bool, default false | admin guard |
| `created_at` | timestamp | server default now |

### `requests`
| col | type | notes |
|---|---|---|
| `id` | int PK autoincrement | |
| `user_id` | int, FK users.id, not null | who made the request |
| `method` | str | HTTP method |
| `path` | str | endpoint path |
| `argument` | text, nullable | main arg: url / video id / channel id / query |
| `status_code` | int | response status |
| `created_at` | timestamp | server default now |

Both created via `Base.metadata.create_all` in the existing `lifespan`
(create-if-not-exist). SQLite-compatible. `videos` is untouched.

## Auth (`app/main.py`)

- New dependency `get_current_user(x_access_token, session) -> User`: returns the
  user whose `token` matches the header; raises **401** if the header is missing
  or matches no user. Auth is now always on.
- Every protected route replaces `Depends(_verify_token)` with
  `Depends(get_current_user)` and receives the `User` (needed for logging).
- `ACCESS_TOKEN` env is no longer used for verification — only for seeding.
- `/api/health` stays open (never 401s). `token_valid` now means "matches a
  real user"; `token_required` is always true.

## Admin seeding (`lifespan`, idempotent)

After `create_all`: if no `admin` user exists, create one with `is_admin=true`
and token = `ACCESS_TOKEN` env if non-empty, else `secrets.token_urlsafe(24)`
printed to the logs. An existing admin is never overwritten (preserves a changed
token). This keeps the current Flutter client working when its token already
equals `ACCESS_TOKEN`.

## Request logging (expensive ops only)

Logged: `/api/download`, `/api/metadata`, `/api/channel/resolve`,
`/api/channel/{id}/videos`. Not logged: health, audio/thumbnail/subtitle
serving, `/api/videos` listing, progress polling.

Implemented with an async context manager `log_operation(user, request,
argument)` wrapping each of the four handlers. It captures the final status
(including `HTTPException.status_code`) and writes the row using a **fresh DB
session** so logging can't interfere with the request or be lost on error.

## User management endpoints (admin only)

`require_admin` dependency → **403** for non-admins.

- `GET /api/users` — list users (includes token so admin can distribute it).
- `POST /api/users` — `{username, token?}`; random token if omitted; **409** on
  duplicate username.
- `PATCH /api/users/{id}` — `{username?, token?}`; an `is_admin` user cannot be
  renamed (**400**) but its token can change; **409** on duplicate username.
- `DELETE /api/users/{id}` — an `is_admin` user cannot be deleted (**400**).

Rule: a user with `is_admin=true` can be neither renamed nor deleted.

## Subtitle fix (`app/downloader.py`)

Keep label-based selection (trust `zh-Hant`/`zh-TW`/`zh-HK` as-is; convert
`zh-Hans`/`zh-CN`/`zh`). Root cause of "not working": the conversion failure was
swallowed silently (e.g. `chinese_converter` not present in the running image).
Fix: keep conversion non-fatal but log loudly on failure, and guarantee `zh` and
`zh-Hans` are converted, verified by a unit test (simplified sample → asserts
Traditional output).

## Tests (`backend/tests/`, pytest + httpx AsyncClient over temp SQLite)

- no token → 401; valid user token → 200.
- admin seeded on startup; seeded token comes from `ACCESS_TOKEN`.
- user CRUD; admin cannot be renamed/deleted; non-admin → 403; duplicate
  username → 409.
- an expensive op writes a `requests` row; health / `/api/videos` do not.
- subtitle s2t conversion turns Simplified into Traditional.

## Docs

Update `backend/CLAUDE.md`: new tables, token-based auth, seeding, `/api/users`,
request logging, subtitle note.
