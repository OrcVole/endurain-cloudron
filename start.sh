#!/bin/bash
# start.sh: Cloudron entrypoint for the Endurain package.
#
# Runs as root (the image sets no USER). Every persisted-state operation is
# re-applied on every boot, not only on first run, because a restore can
# reset ownership and mode. Every package-level log line is prefixed "==> "
# so it is easy to pick out of the combined Cloudron log stream.
#
# Secrets are generated once, on the first boot only, and are never
# regenerated afterwards. FERNET_KEY in particular encrypts Strava and
# Garmin Connect tokens, per-user Strava client credentials, MFA setup
# secrets, identity-provider link tokens and the map tile server key, so
# losing byte-identity across a restart, update or restore is a data-loss
# event, not a cosmetic one (ADR 0003).

set -euo pipefail

# --- signal handling for the whole boot sequence ---------------------------
#
# Re-exec under tini before doing anything else, so tini is PID 1 for the
# ENTIRE script rather than only for uvicorn at the end.
#
# Without this, bash is PID 1 for the whole pre-serve sequence (secret
# seeding, the frontend farm rebuild, `alembic upgrade head`, provision.py).
# Bash running non-interactively does not act on SIGTERM while it waits for a
# foreground child, and PID 1 has no default disposition for it either, so a
# stop or restart arriving in that window is not merely delayed: it is
# ignored until the platform gives up and sends SIGKILL. Cloudron restarts an
# app during updates and after configuration changes, and first-boot
# migrations are exactly when a restart is most likely, so this window is not
# theoretical. It was observed directly: a restart issued mid-boot sat out
# the full ten second grace period and ended in SIGKILL.
#
# -g makes tini signal the whole process group rather than just its immediate
# child, which is what actually reaches alembic or provision.py mid-run; bash
# alone would still sit on the signal until its foreground child finished.
# The guard variable keeps the re-exec to one level, and CMD stays
# ["/app/code/start.sh"] so Cloudron's debug mode still works (ADR 0001).
if [[ "${ENDURAIN_TINI_PID1:-}" != "1" ]]; then
    export ENDURAIN_TINI_PID1=1
    exec /usr/bin/tini -g -- "$0" "$@"
fi

CODE=/app/code
DATA=/app/data
RUN_DIR=/run/endurain
UP="$CODE/upstream/backend"
VENV_PYTHON="$CODE/venv/bin/python"

log() {
    echo "==> $*"
}

fail() {
    echo "==> ERROR: $*" >&2
    exit 1
}

# --- writable directories ------------------------------------------------
#
# core/config.py's check_required_dirs(), called from create_app() on
# every uvicorn start, creates the application's own subtree under
# DATA_DIR (user_images, activity_files/bulk_import, and so on). Only the
# root of that subtree is pre-created here; the children are left to the
# application itself.
log "preparing writable directories"
mkdir -p "$DATA/storage" "$DATA/.secrets" "$RUN_DIR/logs" "$RUN_DIR/frontend" /run/secrets
# $RUN_DIR is chowned here too, not only $DATA: core/logger.py's
# setup_main_logger() opens a FileHandler on $LOGS_DIR/app.log as the
# cloudron user, which needs write access to $RUN_DIR/logs itself, not
# just to the files inside it. The frontend farm below re-asserts
# ownership on $RUN_DIR/frontend again after repopulating it, since that
# happens later in this script, still as root.
chown -R cloudron:cloudron "$DATA" "$RUN_DIR"
chmod 0700 "$DATA/.secrets"

# --- secret seeding: first run only, idempotent, fail loud ---------------
SECRET_KEY_PATH="$DATA/.secrets/secret-key"
FERNET_KEY_PATH="$DATA/.secrets/fernet-key"

# -s (exists and non-empty) rather than a bare -f: a zero-byte file left
# behind by a previous crashed write is treated the same as "absent"
# rather than mistaken for an already-seeded secret.
if [[ ! -s "$SECRET_KEY_PATH" ]]; then
    log "generating new secret: secret-key"
    ( umask 077 && openssl rand -hex 32 > "$SECRET_KEY_PATH" )
else
    log "existing secret found: secret-key"
fi

if [[ ! -s "$FERNET_KEY_PATH" ]]; then
    log "generating new secret: fernet-key"
    ( umask 077 && "$VENV_PYTHON" -c \
        "from cryptography.fernet import Fernet; import sys; sys.stdout.write(Fernet.generate_key().decode())" \
        > "$FERNET_KEY_PATH" )
else
    log "existing secret found: fernet-key"
fi

# Re-assert ownership and mode on every boot regardless of which branch
# ran above; a restore can reset both.
chown cloudron:cloudron "$SECRET_KEY_PATH" "$FERNET_KEY_PATH"
chmod 0600 "$SECRET_KEY_PATH" "$FERNET_KEY_PATH"

# The two files provision.py writes live in the same directory and carry the
# same exposure, but provision.py sets their modes once, inside a branch that
# a marker file stops it from ever entering again. That leaves them relying
# on a previous boot having got it right, which is the assumption this script
# refuses to make everywhere else. Re-asserted here when present, so a
# restore that resets ownership cannot leave a readable admin password behind.
for provisioned in "$DATA/.secrets/.admin-provisioned" "$DATA/.secrets/admin-initial-password"; do
    if [[ -e "$provisioned" ]]; then
        chown cloudron:cloudron "$provisioned"
        chmod 0600 "$provisioned"
    fi
done

# Validate the Fernet key loads before it is ever handed to the
# application. Never regenerate on failure: a key that fails to load here
# almost always means the volume was truncated or otherwise damaged, and
# silently minting a replacement would orphan every Strava/Garmin token,
# MFA secret and identity-provider link token already encrypted under the
# old one.
if ! "$VENV_PYTHON" -c \
    "from cryptography.fernet import Fernet; import sys; Fernet(open(sys.argv[1], 'rb').read().strip())" \
    "$FERNET_KEY_PATH" >/dev/null 2>&1; then
    fail "fernet-key at $FERNET_KEY_PATH failed to load; refusing to regenerate it. Restore it from backup."
fi

# The same treatment for secret-key, for the same reason. The seeding test
# above is only -s (non-empty), which cannot tell a complete key from a
# partial one: if `openssl rand -hex 32` is interrupted after the redirection
# has created the file but before openssl has written all 64 characters, the
# short value survives on disk and every later boot accepts it as already
# seeded. A truncated SECRET_KEY is not a crash, which is what makes it worth
# checking: it silently weakens the key that signs every session token.
# Validated rather than regenerated, exactly as ADR 0003 prescribes for
# fernet-key, because a regenerated SECRET_KEY invalidates live sessions and
# a damaged volume is the operator's decision to make, not this script's.
if [[ ! "$(cat "$SECRET_KEY_PATH")" =~ ^[0-9a-f]{64}$ ]]; then
    fail "secret-key at $SECRET_KEY_PATH is not 64 hex characters; refusing to regenerate it. Restore it from backup."
fi

# --- /run/secrets bridge ---------------------------------------------------
#
# core/config.py's read_secret()/_is_safe_path() accept /run/secrets,
# /var/run/secrets and /secrets as roots for the <VAR>_FILE convention, but
# not /app/data, so the persisted keys are copied into /run/secrets (tmpfs,
# rebuilt from the persisted originals on every boot) rather than pointed
# at directly. The originals in /app/data/.secrets remain the single
# source of truth.
cp "$SECRET_KEY_PATH" /run/secrets/endurain_secret_key
cp "$FERNET_KEY_PATH" /run/secrets/endurain_fernet_key
chown cloudron:cloudron /run/secrets/endurain_secret_key /run/secrets/endurain_fernet_key
chmod 0400 /run/secrets/endurain_secret_key /run/secrets/endurain_fernet_key

export SECRET_KEY_FILE=/run/secrets/endurain_secret_key
export FERNET_KEY_FILE=/run/secrets/endurain_fernet_key

# --- addon mapping: every boot ---------------------------------------------
: "${CLOUDRON_POSTGRESQL_HOST:?CLOUDRON_POSTGRESQL_HOST is not set; is the postgresql addon installed?}"
: "${CLOUDRON_REDIS_URL:?CLOUDRON_REDIS_URL is not set; is the redis addon installed?}"
: "${CLOUDRON_APP_ORIGIN:?CLOUDRON_APP_ORIGIN is not set}"

export DB_HOST="$CLOUDRON_POSTGRESQL_HOST"
export DB_PORT="$CLOUDRON_POSTGRESQL_PORT"
export DB_USER="$CLOUDRON_POSTGRESQL_USERNAME"
export DB_PASSWORD="$CLOUDRON_POSTGRESQL_PASSWORD"
export DB_DATABASE="$CLOUDRON_POSTGRESQL_DATABASE"

# core/redis.py's is_redis_storage_uri() accepts a bare "redis://" (or
# "rediss://"/"unix://") prefix and hands the whole URI straight to
# Redis.from_url(). CLOUDRON_REDIS_URL already arrives in exactly that
# form, redis://:PASSWORD@HOST:PORT, so it is passed through unchanged.
export RATE_LIMIT_STORAGE_URI="$CLOUDRON_REDIS_URL"
export AUTH_SECURITY_STORAGE_URI="$CLOUDRON_REDIS_URL"

if [[ -n "${CLOUDRON_MAIL_SMTP_SERVER:-}" ]]; then
    export SMTP_HOST="$CLOUDRON_MAIL_SMTP_SERVER"
    export SMTP_PORT="$CLOUDRON_MAIL_SMTP_PORT"
    export SMTP_USERNAME="$CLOUDRON_MAIL_SMTP_USERNAME"
    export SMTP_PASSWORD="$CLOUDRON_MAIL_SMTP_PASSWORD"
    export SMTP_FROM="$CLOUDRON_MAIL_FROM"
    # CLOUDRON_MAIL_SMTP_PORT is the sendmail addon's plain relay port,
    # documented as having STARTTLS disabled (CLOUDRON_MAIL_SMTPS_PORT is
    # the separate implicit-TLS port and is not used here). core/apprise.py's
    # AppriseService._build_smtp_url() only switches to the "mailtos://"
    # scheme and adds a "mode=" (starttls/ssl) parameter when SMTP_SECURE
    # is true; SMTP_SECURE=false is therefore the combination that
    # actually matches this port, a plain "mailto://" URL with no
    # encryption negotiated.
    export SMTP_SECURE=false
    log "SMTP configured via the sendmail addon (host=$SMTP_HOST port=$SMTP_PORT)"
else
    log "sendmail addon not configured (CLOUDRON_MAIL_SMTP_SERVER unset); email disabled"
fi

export ENDURAIN_HOST="$CLOUDRON_APP_ORIGIN"
# BEHIND_PROXY is exported per AGENTS.md's mapping table, but a full grep
# of backend/app found no reference to it anywhere in v0.19.0's Python
# code; it is not a core/config.py Settings field. Upstream's own
# docker/start.sh reads it as a plain shell variable to decide whether to
# append --proxy-headers to the uvicorn invocation, which this script does
# unconditionally instead (see the final exec line below, always behind
# Cloudron's own reverse proxy). Kept here as harmless, documented and
# forward-compatible rather than silently dropped.
export BEHIND_PROXY=true
export ENVIRONMENT=production
export TZ="${TZ:-UTC}"

# core/config.py types TRUSTED_PROXIES as Annotated[list[str], NoDecode].
# NoDecode turns off pydantic-settings' default JSON-array parsing for the
# field, and its own _parse_trusted_proxies validator then does a plain
# value.split(","). The environment value therefore has to be a bare
# comma-separated string (a single IP is a one-element list), never a JSON
# array: a JSON-array string is read back as one malformed entry and fails
# _validate_trusted_proxies at Settings() construction, aborting startup.
export TRUSTED_PROXIES="${CLOUDRON_PROXY_IP:-}"

export DATA_DIR="$DATA/storage"
export LOGS_DIR="$RUN_DIR/logs"
export FRONTEND_DIR="$RUN_DIR/frontend"
export BACKEND_DIR="$UP"

# UID and GID are retired as of v0.19.x: core/config.py's
# check_deprecated_env_vars() aborts startup if either is present in the
# environment at all, regardless of value ("Endurain will not start until
# they are removed"), so neither is exported here.

# --- frontend farm: every boot ---------------------------------------------
#
# /app/code/frontend-dist is part of the read-only image and cannot be
# edited in place, so env.js and the CSP-rewritten index.html are real,
# writable files under $RUN_DIR/frontend, while every other built asset is
# a cheap symlink back into the read-only tree.
log "rebuilding the frontend runtime tree at $RUN_DIR/frontend"
find "$RUN_DIR/frontend" -mindepth 1 -delete
shopt -s nullglob dotglob
for entry in "$CODE/frontend-dist"/*; do
    name="$(basename "$entry")"
    case "$name" in
        index.html)
            cp "$entry" "$RUN_DIR/frontend/index.html"
            ;;
        env.js)
            # The built dist ships a placeholder env.js (frontend/public/
            # env.js). Symlinking it would make the write below go through
            # the symlink into the read-only image and fail with EROFS, so
            # it is skipped here and written fresh as a real file instead.
            ;;
        *)
            ln -s "$entry" "$RUN_DIR/frontend/$name"
            ;;
    esac
done
shopt -u nullglob dotglob

echo "window.env = { ENDURAIN_HOST: \"$ENDURAIN_HOST\" };" > "$RUN_DIR/frontend/env.js"

# Faithful port of upstream's docker/start.sh CSP connect-src rewrite onto
# the copied index.html: clean the configured origin, derive its WebSocket
# counterpart, and rewrite the built page's meta CSP in place.
API_ORIGIN="$ENDURAIN_HOST"
while [[ "${API_ORIGIN%/}" != "$API_ORIGIN" ]]; do
    API_ORIGIN="${API_ORIGIN%/}"
done

WS_ORIGIN=""
case "$API_ORIGIN" in
    https://*) WS_ORIGIN="wss://${API_ORIGIN#https://}" ;;
    http://*)  WS_ORIGIN="ws://${API_ORIGIN#http://}" ;;
esac
# Reject anything that is not a clean http(s) origin so a malformed
# ENDURAIN_HOST cannot inject extra CSP directives or break the meta tag.
case "$API_ORIGIN" in
    *[!A-Za-z0-9.:/_-]*) WS_ORIGIN="" ;;
esac

INDEX_HTML="$RUN_DIR/frontend/index.html"
if [[ -n "$WS_ORIGIN" ]]; then
    # https://codeberg.org stays allow-listed: it is the single-page app's
    # build-time update-check origin (frontend/vite.config.ts), preserved
    # verbatim from the built default. connect-src is the LAST directive
    # in that build-time default, so the match below has to run to the
    # closing '"' of the meta content attribute, not to the next ';': the
    # built HTML encodes literal quotes as character references whose
    # trailing ';' would terminate the match early and corrupt the policy.
    EXTERNAL_CONNECT="https://codeberg.org"
    tmp_file="$(mktemp)"
    sed "s#connect-src [^\"]*#connect-src 'self' $API_ORIGIN $WS_ORIGIN $EXTERNAL_CONNECT#g" \
        "$INDEX_HTML" > "$tmp_file"
    cat "$tmp_file" > "$INDEX_HTML"
    rm -f "$tmp_file"
    log "hardened CSP connect-src to 'self' $API_ORIGIN $WS_ORIGIN $EXTERNAL_CONNECT"
else
    log "ENDURAIN_HOST is not a clean http(s) origin; left CSP connect-src as the single-page app's build-time default"
fi

chown -R -h cloudron:cloudron "$RUN_DIR/frontend"

# --- migrations before serve -----------------------------------------------
log "running database migrations"
if ! ( cd "$UP/app" && gosu cloudron:cloudron "$VENV_PYTHON" -m alembic upgrade head ); then
    fail "alembic upgrade head failed; refusing to start"
fi

# --- provisioning: first-run admin neutralisation, every-boot OIDC sync ---
log "running provisioning"
( cd "$UP/app" && PYTHONPATH="$UP/app" gosu cloudron:cloudron "$VENV_PYTHON" /app/code/provision.py )
# provision.py exits non-zero only on a first-run admin-neutralisation
# failure (its Cloudron-OIDC half is fail-soft and never exits non-zero).
# set -e above turns that non-zero exit straight into a boot failure here,
# rather than serving with the seeded admin/admin account still live.

# --- serve -------------------------------------------------------------
case "${LOG_LEVEL:-info}" in
    critical|error|warning|info|debug|trace) ;;
    *)
        log "invalid LOG_LEVEL '${LOG_LEVEL:-}'; supported levels are critical, error, warning, info, debug, trace; defaulting to info"
        LOG_LEVEL=info
        ;;
esac

log "starting uvicorn on :8080 (log-level=${LOG_LEVEL:-info})"
cd "$UP/app"
# No tini here: the re-exec at the top of this script already made tini PID 1,
# and it stays PID 1 across this exec, so uvicorn is reaped and signalled
# correctly. Invoking tini a second time would nest a second init inside the
# first for no benefit.
exec gosu cloudron:cloudron "$VENV_PYTHON" -m uvicorn main:app \
    --host 0.0.0.0 --port 8080 --log-level "${LOG_LEVEL:-info}" --proxy-headers
