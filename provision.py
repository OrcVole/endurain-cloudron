#!/usr/bin/env python3
"""provision.py: post-migration, pre-serve provisioning for the Endurain package.

Invoked by start.sh as the cloudron user, after ``alembic upgrade head`` and
before uvicorn is started, with ``PYTHONPATH`` set to the backend's ``app``
directory so it can import the application's own modules directly (the same
convention ``[tool.pytest.ini_options] pythonpath = ["app"]`` uses for tests).

Two independent parts, run in this order:

Part 1, admin neutralisation (first run only, marker-guarded). Upstream's
first database migration seeds a live ``admin`` / ``admin`` account, which is
public knowledge from the moment the schema exists. Before the application
ever serves a request, this part finds that seeded account, generates a
random password, and hashes and stores it exactly the way the application
itself would (``auth.password_hasher`` and ``auth.credentials.crud``). Any
failure here on first run is fatal: an install that failed loudly is a better
outcome than one that came up quietly serving ``admin`` / ``admin`` (ADR
0003).

Part 2, Cloudron OIDC identity-provider sync (every boot, fail-soft). When
the platform's ``oidc`` addon is configured, this part upserts an identity
provider record under the fixed slug ``cloudron`` from the addon's
environment variables, so that Cloudron single sign-on feeds Endurain's own
OpenID Connect login rather than sitting in front of it (ADR 0002). This part
never aborts the boot: a problem here should not stop local-account users
from logging in, so every failure is logged loudly and swallowed.

Neither part ever prints a secret value; every log line carries the
"==> [provision]" prefix used across this package's boot sequence.
"""

from __future__ import annotations

import os
import secrets
import sys
from importlib import import_module
from pathlib import Path

# The app's own modules, importable because PYTHONPATH points at
# backend/app (see start.sh's provisioning step).
import auth.credentials.crud as auth_credentials_crud  # noqa: E402
import auth.identity_providers.crud as idp_crud  # noqa: E402
import auth.identity_providers.schema as idp_schema  # noqa: E402
import auth.password_hasher as auth_password_hasher  # noqa: E402
import core.database as core_database  # noqa: E402
import users.users.crud as users_crud  # noqa: E402
import users.users.schema as users_schema  # noqa: E402

SECRETS_DIR = Path("/app/data/.secrets")
MARKER_PATH = SECRETS_DIR / ".admin-provisioned"
PASSWORD_FILE_PATH = SECRETS_DIR / "admin-initial-password"

SEEDED_ADMIN_USERNAME = "admin"
# Upstream's first migration seeds this password; it is public knowledge, not
# a secret, and is used only to detect that the seeded credential is still live.
SEEDED_ADMIN_PASSWORD = "admin"
CLOUDRON_IDP_SLUG = "cloudron"
CLOUDRON_IDP_NAME = "Cloudron"
_WELL_KNOWN_SUFFIX = "/.well-known/openid-configuration"


def _import_all_models() -> None:
    """Import every ``models.py`` so the ORM registry resolves completely.

    SQLAlchemy configures a mapper lazily, on first use, and resolves the
    string targets of its ``relationship()`` declarations against the class
    registry at that moment. ``Users`` declares a relationship to
    ``PasswordResetToken``, so querying a user from a process that imported
    only the handful of modules this script names directly raises
    ``InvalidRequestError: failed to locate a name``. The application never
    hits this because ``main.py`` transitively imports the whole model tree
    on the way to building its router.

    This is upstream's own ``_import_all_models()`` from
    ``backend/app/alembic/env.py``, reproduced rather than imported: that
    module is an Alembic script which touches ``alembic.context`` and calls
    ``fileConfig()`` at import time, neither of which is valid outside an
    Alembic run. Keep the two in step at version bumps.
    """
    app_dir = Path(core_database.__file__).resolve().parents[1]
    for path in sorted(app_dir.glob("**/models.py")):
        import_module(".".join(path.relative_to(app_dir).with_suffix("").parts))


def _log(message: str) -> None:
    """Print a single provisioning log line with the package-wide prefix.

    Writes straight to stdout (flushed immediately) rather than through the
    application's own logger, which is only configured by
    ``core.logger.setup_main_logger()`` inside ``create_app()`` and is not
    set up in this standalone script.
    """
    print(f"==> [provision] {message}", flush=True)


def _write_marker(marker: Path) -> None:
    """Create the first-run marker so admin neutralisation never re-runs.

    The marker is what future boots check, not whether the current password
    still looks like a generated one, so an operator who deliberately
    changes the admin password back to something that happens to collide is
    never silently overwritten.
    """
    marker.touch(exist_ok=True)
    os.chmod(marker, 0o600)


def _write_initial_password_file(password: str) -> None:
    """Write the generated admin password once, for the operator to read.

    A single explanatory header line is safe here because this file is read
    by a human through the Cloudron file manager, not parsed by any
    application code, unlike the secret-key/fernet-key files start.sh
    manages.
    """
    PASSWORD_FILE_PATH.write_text(
        "# Endurain admin initial password. Change it in Settings, then delete this file.\n"
        f"{password}\n"
    )
    os.chmod(PASSWORD_FILE_PATH, 0o600)


def _neutralise_seeded_admin() -> None:
    """Part 1: generate a fresh password for the seeded admin account.

    First run only, guarded by ``MARKER_PATH``. Any exception here is
    treated as fatal on a first run: it is printed loudly (by exception
    type only, following ``core.logger``'s own convention of never logging
    a raw exception message, since those can embed bound SQL parameter
    values) and the process exits non-zero so start.sh's ``set -e`` aborts
    the boot rather than serving with ``admin`` / ``admin`` still live.
    """
    if MARKER_PATH.exists():
        # Marker present: this has already run. Skip silently, exactly as
        # specified, so a routine restart does not add log noise for a
        # step that has nothing left to do.
        return

    try:
        with core_database.SessionLocal() as db:
            admin_user = users_crud.get_user_by_username(SEEDED_ADMIN_USERNAME, db)

            # normalize_access_type() is upstream's own helper, and it is
            # required rather than decorative: UsersRead carries
            # access_type as the plain string "admin", while
            # UserAccessType is a bare Enum (not a StrEnum), so a direct
            # `!=` against the enum member is ALWAYS true. Comparing
            # directly made this branch silently conclude there was no
            # seeded admin, write the marker, and leave admin/admin live
            # for good (found by smoke test, 2026-08-01).
            is_admin = admin_user is not None and (
                users_schema.normalize_access_type(admin_user.access_type)
                == users_schema.UserAccessType.ADMIN.value
            )

            # Defence in depth against exactly the bug above. The decision
            # that actually matters is not "does this account look like the
            # seeded one" but "does the publicly known seeded password still
            # open it", so ask that question directly: any account still
            # holding the seeded credential gets neutralised whatever its
            # access level says. A guard that answers the real question
            # cannot fail silently the way an attribute comparison can.
            seeded_password_works = False
            if admin_user is not None:
                credential = auth_credentials_crud.get_credential(admin_user.id, db)
                if credential is not None:
                    seeded_password_works = auth_password_hasher.get_password_hasher(
                    ).verify_password(SEEDED_ADMIN_PASSWORD, credential.password_hash)

            if not (is_admin or seeded_password_works):
                # The operator has already renamed or deleted the seeded
                # account (or changed its access level away from admin) and
                # no account is left holding the seeded password. There is
                # nothing to neutralise; record that and move on.
                _log(
                    f"no seeded '{SEEDED_ADMIN_USERNAME}' admin account found "
                    "(renamed, deleted or demoted); nothing to neutralise"
                )
                _write_marker(MARKER_PATH)
                return

            new_password = secrets.token_urlsafe(24)
            password_hasher = auth_password_hasher.get_password_hasher()
            password_hash = password_hasher.hash_password(new_password)

            # Same write path the application itself uses for a local
            # password change: matches column names and updated_at
            # semantics (server-side onupdate=func.now() on the
            # users_local_credentials row) exactly.
            auth_credentials_crud.upsert_password_hash(admin_user.id, password_hash, db)

        _write_initial_password_file(new_password)
        _write_marker(MARKER_PATH)
        _log(
            f"neutralised the seeded '{SEEDED_ADMIN_USERNAME}' account with a generated "
            f"password; see {PASSWORD_FILE_PATH}"
        )
    except Exception as exc:  # noqa: BLE001 - deliberately broad: any failure here is fatal
        _log(f"FATAL: admin neutralisation failed: {type(exc).__name__}")
        sys.exit(1)


def _strip_well_known_suffix(url: str) -> str:
    """Best-effort recovery of a bare issuer URL from a discovery URL.

    Only used when CLOUDRON_OIDC_ISSUER itself is absent but
    CLOUDRON_OIDC_DISCOVERY_URL is present; in normal operation the oidc
    addon supplies both together, so this is a defensive fallback rather
    than the expected path.
    """
    if url.endswith(_WELL_KNOWN_SUFFIX):
        return url[: -len(_WELL_KNOWN_SUFFIX)]
    return url


def _sync_cloudron_identity_provider() -> None:
    """Part 2: upsert or disable the 'cloudron' identity provider.

    Every boot, fail-soft. Never raises and never calls ``sys.exit``: any
    problem is logged loudly and swallowed so a misconfigured or briefly
    unreachable OIDC addon can never prevent local-account users from
    logging in.

    The env vars read here are the Cloudron oidc addon's documented set
    (CLOUDRON_OIDC_ISSUER, _DISCOVERY_URL, _AUTH_ENDPOINT, _TOKEN_ENDPOINT,
    _KEYS_ENDPOINT, _PROFILE_ENDPOINT, _CLIENT_ID, _CLIENT_SECRET). They
    are mapped directly onto the IdentityProvider model's own
    issuer_url/authorization_endpoint/token_endpoint/userinfo_endpoint/
    jwks_uri/client_id fields; auth/identity_providers/crud.py encrypts
    client_id and client_secret with the same Fernet key used everywhere
    else (core.cryptography.encrypt_token_fernet) before they are ever
    written to the database, exactly as it does for an operator-configured
    identity provider entered through the admin UI.
    """
    try:
        issuer = os.environ.get("CLOUDRON_OIDC_ISSUER", "").strip()
        discovery_url = os.environ.get("CLOUDRON_OIDC_DISCOVERY_URL", "").strip()
        client_id = os.environ.get("CLOUDRON_OIDC_CLIENT_ID", "").strip()
        client_secret = os.environ.get("CLOUDRON_OIDC_CLIENT_SECRET", "").strip()

        configured = bool((issuer or discovery_url) and client_id and client_secret)

        with core_database.SessionLocal() as db:
            existing = idp_crud.get_identity_provider_by_slug(CLOUDRON_IDP_SLUG, db)

            if not configured:
                if existing is not None and existing.enabled:
                    idp_crud.update_identity_provider(
                        existing.id,
                        idp_schema.IdentityProviderUpdate(
                            name=existing.name,
                            slug=existing.slug,
                            enabled=False,
                        ),
                        db,
                    )
                    _log(
                        f"Cloudron OIDC environment variables absent; disabled the "
                        f"existing '{CLOUDRON_IDP_SLUG}' identity provider (not deleted)"
                    )
                else:
                    _log("Cloudron OIDC environment variables absent; nothing to do")
                return

            issuer_url = issuer or _strip_well_known_suffix(discovery_url)
            # Addon-sourced connection fields: these are re-derived from
            # the environment and re-asserted on every boot regardless of
            # whether the record already exists, because ADR 0002's reason
            # for re-provisioning every boot (rather than only on first
            # run) is specifically that the addon's client credentials
            # rotate, and a stale record would silently stop
            # authenticating.
            connection_fields = {
                "enabled": True,
                "issuer_url": issuer_url or None,
                "authorization_endpoint": os.environ.get("CLOUDRON_OIDC_AUTH_ENDPOINT") or None,
                "token_endpoint": os.environ.get("CLOUDRON_OIDC_TOKEN_ENDPOINT") or None,
                "userinfo_endpoint": os.environ.get("CLOUDRON_OIDC_PROFILE_ENDPOINT") or None,
                # Stored on the model for completeness, but note that
                # auth/identity_providers/service.py's callback handler
                # (handle_callback) re-derives its own jwks_uri and
                # expected issuer from a live OIDC discovery fetch against
                # issuer_url every time; it never reads this stored field
                # back for ID-token verification. issuer_url therefore has
                # to be the correct, reachable bare issuer for SSO login to
                # verify cryptographically, independent of this field.
                "jwks_uri": os.environ.get("CLOUDRON_OIDC_KEYS_ENDPOINT") or None,
                "client_id": client_id,
            }

            if existing is None:
                idp_crud.create_identity_provider(
                    idp_schema.IdentityProviderCreate(
                        name=CLOUDRON_IDP_NAME,
                        slug=CLOUDRON_IDP_SLUG,
                        provider_type="oidc",
                        scopes="openid profile email",
                        auto_create_users=True,
                        sync_user_info=True,
                        client_secret=client_secret,
                        **connection_fields,
                    ),
                    db,
                )
                _log(f"created the '{CLOUDRON_IDP_SLUG}' identity provider")
            else:
                # Only the addon-sourced connection fields above are
                # refreshed on an existing record. name/provider_type/
                # scopes/auto_create_users/sync_user_info are deliberately
                # left alone: an operator may have customised them through
                # Endurain's own admin UI after the record was first
                # created, and "idempotent: running twice changes nothing
                # but refreshed credentials" means this step must not
                # silently revert that. name/slug still have to be passed
                # because IdentityProviderUpdate requires them, but they
                # are set back to their own current values, not changed.
                idp_crud.update_identity_provider(
                    existing.id,
                    idp_schema.IdentityProviderUpdate(
                        name=existing.name,
                        slug=existing.slug,
                        client_secret=client_secret,
                        **connection_fields,
                    ),
                    db,
                )
                _log(
                    f"refreshed the '{CLOUDRON_IDP_SLUG}' identity provider's connection "
                    "details and credentials from the current environment"
                )
    except Exception as exc:  # noqa: BLE001 - deliberately broad: this half is fail-soft
        _log(f"Cloudron OIDC provisioning failed (non-fatal, local accounts are unaffected): {type(exc).__name__}")


def main() -> None:
    # Before any query: both parts below load ORM entities whose mappers
    # reference models this script never imports by name.
    _import_all_models()

    # Fail loud, on purpose: an unguarded call, so a first-run failure's
    # sys.exit(1) propagates straight out of main() to the process exit
    # code, which start.sh's `set -e` turns into a boot failure.
    _neutralise_seeded_admin()

    # Fail soft, on purpose: this call can never raise or exit non-zero
    # (see its own try/except), so it always runs after Part 1 succeeds
    # (or is a silent no-op).
    _sync_cloudron_identity_provider()


if __name__ == "__main__":
    main()
