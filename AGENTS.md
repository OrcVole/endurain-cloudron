# AGENTS.md: Endurain Cloudron package working contract

The settled-decisions record for packaging **Endurain** (`endurain`, AGPL-3.0-or-later)
as a Cloudron community app. Read this before changing anything. Do not relitigate these
decisions without a concrete reason found on a running box. **The box is the authority,
not the docs.**

## What this package is

Endurain is a self-hosted fitness tracking platform (FastAPI backend serving a built
Vue single-page frontend from one process). This package builds upstream tag
`v0.19.0` from source onto `cloudron/base` and wires it to Cloudron addons.

Topology, all logging to stdout:

| Process | Role | Port |
|---|---|---|
| uvicorn (single worker) | API + SPA + in-process background scheduler | 8080 (the manifest httpPort) |

State: PostgreSQL via the `postgresql` addon; rate-limit and auth-security state via
the `redis` addon (upstream treats Redis as disposable); user files under `/app/data`;
outgoing mail via `sendmail`; SSO via the `oidc` addon into Endurain's native OIDC.
Nothing is bundled; no `persistentDirs`, no `backupCommand`.

## Golden rules

1. **Conformance to the Cloudron contract first.** Adapt the runtime environment only.
   Never patch the application itself.
2. **Pin everything**: the base image and the upstream tag (one `ARG
   ENDURAIN_VERSION`, mirrored in the manifest `upstreamVersion`); the build verifies
   the tag's commit hash; every downloaded tool is fetched by URL plus SHA256 (uv is
   pinned to the exact version the project's `required-version` demands).
3. **Persisted state only in `/app/data`.** Re-assert ownership and mode on **every**
   boot; a restore drifts them.
4. **Fail loud.** Never silently regenerate `FERNET_KEY` (data-loss-critical: it
   encrypts Strava and Garmin tokens, per-user Strava client credentials, MFA setup
   secrets, identity-provider link tokens and the tile-server key). Never clobber an
   operator's changed admin password (the neutralisation is marker-guarded, first run
   only).
5. **Code and docs ship together.** ADRs in `docs/decisions/`; the
   verified-versus-assumed log in `docs/PACKAGING-NOTES.md`, newest first; gate
   evidence in `docs/DEBUGGING.md`.
6. **`CMD`, never `ENTRYPOINT`.** Maintain `.dockerignore` (allowlist style) as
   carefully as `.gitignore`.
7. **Open source only.** Everything in upstream's AGPL tree ships; there is no
   commercial split. Branding is used nominatively per upstream's TRADEMARK.md; this
   package must stay free and non-commercial.
8. **Anonymise before every push.** `test/secret-scan.sh` over both surfaces (repo and
   image) is the release gate; `.anonymize-list` is gitignored.
9. **Git hygiene.** Commit as the maintainer identity, set repo-local. No AI
   co-authorship or tool-attribution trailers.

## Locked decisions (Phase 0/1, 2026-08-01)

- **Manifest id** `io.github.orcvole.endurain`; repo and image carry the `-cloudron`
  suffix; image `ghcr.io/orcvole/endurain-cloudron`, tags `<upstream>-<rev>`.
- **Build from source at the tag, not from the upstream image** (ADR 0001): upstream's
  image is Alpine/musl with an ENTRYPOINT-only contract, and its registry moved twice
  in a year. Two-stage build, both stages on the pinned `cloudron/base`; uv-managed
  CPython 3.13 venv from `uv.lock` (`uv sync --frozen`); frontend built with the
  base's Node 24 (`npm ci && npm run build`).
- **Auth topology** (ADR 0002): no `proxyAuth` anywhere; the app has real auth.
  `oidc` addon feeds a provisioned identity-provider record (slug `cloudron`, so the
  callback is `/api/v1/public/idp/callback/cloudron`); `optionalSso: true`; the
  upload endpoint, auth endpoints and public IdP routes stay open at the network
  layer, protected by Endurain's own JWT and API keys. Login requires the
  `X-Client-Type` header; a missing header 401s in a way that mimics bad credentials.
- **Secrets** (ADR 0003): `SECRET_KEY` and `FERNET_KEY` generated first run only into
  `/app/data/.secrets` (0700/0600, re-asserted every boot), delivered to the app via
  its `_FILE` convention through copies in `/run/secrets` (the app's safe-path roots
  do not include `/app/data`). `FERNET_KEY` byte-identity across restart, update and
  restore is a standing gate. The upstream-seeded `admin/admin` account gets a
  generated password before first serve, marker-guarded, written to
  `/app/data/.secrets/admin-initial-password` for the operator.
- **PG14 is proven**: the full Alembic chain, boot, health and an authenticated login
  ran against Postgres 14 (2026-08-01, workstation). The addon suffices; no bundled
  Postgres.
- **Health**: `healthCheckPath /api/v1/about` (unauthenticated, static, on the
  primary port).
- **memoryLimit**: provisional 1.5 GiB; Gate 4 sets the shipped value from
  `memory.stat` anon plus file, not `memory.peak` alone.
- **Frontend runtime config**: `FRONTEND_DIR=/run/endurain/frontend`, a per-boot
  symlink farm over the read-only built dist with real copies of `index.html` and
  `env.js`, reproducing upstream's env.js write and CSP connect-src rewrite
  (`https://codeberg.org` stays allow-listed for the SPA's update check; documented).

## Pinned upstream

- `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`
- Endurain `v0.19.0`, commit `bc88c2a72c286e1dc1eae636ef14550b696c3fe2`, AGPL-3.0-or-later,
  from `https://codeberg.org/endurain-project/endurain.git`
- uv `0.11.18` (project-pinned), tarball sha256
  `588f3e360f69ce02b6982aa99f2240e803933a6b7e176ac01617830adf955add`

## Environment mapping (translated on every boot)

| Application variable | Source |
|---|---|
| `DB_HOST/PORT/USER/PASSWORD/DATABASE` | `CLOUDRON_POSTGRESQL_*` |
| `RATE_LIMIT_STORAGE_URI`, `AUTH_SECURITY_STORAGE_URI` | `CLOUDRON_REDIS_URL` |
| `SMTP_HOST/PORT/USERNAME/PASSWORD/FROM` | `CLOUDRON_MAIL_SMTP_*`, `CLOUDRON_MAIL_FROM` |
| `ENDURAIN_HOST` | `CLOUDRON_APP_ORIGIN` |
| `BEHIND_PROXY` | `true` |
| `TRUSTED_PROXIES` | `CLOUDRON_PROXY_IP` |
| `ENVIRONMENT` | `production` |
| `DATA_DIR` | `/app/data/storage` |
| `SECRET_KEY_FILE`, `FERNET_KEY_FILE` | `/run/secrets/*` copies of `/app/data/.secrets/*` |

## Backup and restore

Platform-native: the addon dumps Postgres logically; `/app/data` rides the file
backup; Redis state is disposable by upstream's own guidance. The restore gate proves
`FERNET_KEY` byte-identity and ownership re-assertion.

## Future compatibility

Version bumps: change `ARG ENDURAIN_VERSION` (and the expected commit), rebuild,
re-ladder. Alembic migrates forward automatically at boot. Watch: upstream's declared
monthly cadence; the uv `required-version` pin moves with upstream; the frontend
rewrite at 0.19.0 means UI-level docs and screenshots date quickly.
