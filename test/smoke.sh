#!/bin/bash
# test/smoke.sh: prove a built Endurain image runs the Cloudron way, on this
# workstation, with rootless podman, before any real Cloudron install is
# attempted.
#
# Deliberately NOT run under `set -e`: the point of this script is to
# execute every assertion and report a full PASS/FAIL summary, not to stop
# at the first failing one. Infrastructure setup (network, postgres, redis,
# the app container itself) is the exception: a setup failure aborts
# immediately via die(), because there is no useful assertion to run
# against infrastructure that never came up.
#
# Usage: test/smoke.sh IMAGE

set -uo pipefail

IMAGE="${1:?usage: test/smoke.sh IMAGE}"

NET=endurain-smoke
VOLUME=endurain-smoke-data
APP_CONTAINER=endurain-smoke-app
PG_CONTAINER=endurain-smoke-pg
REDIS_CONTAINER=endurain-smoke-redis
BOOTSTOP_CONTAINER=endurain-smoke-bootstop
HOST_PORT=18080
ORIGIN="http://127.0.0.1:${HOST_PORT}"

PG_USER=endurain
PG_DB=endurain
PG_PASSWORD="$(openssl rand -hex 16)"

FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures" && pwd)"
SCRATCH_DIR="$(mktemp -d)"

FAILED=0

log() {
    echo "==> $*"
}

pass() {
    echo "PASS: $*"
}

fail() {
    echo "FAIL: $*"
    FAILED=1
}

# die() is for infrastructure setup only: a problem here means there is
# nothing left to usefully assert against, so it prints an error and exits
# immediately rather than being recorded as one FAIL among many.
die() {
    echo "FAIL: $*"
    exit 1
}

cleanup() {
    log "cleaning up"
    podman rm -f "$APP_CONTAINER" "$BOOTSTOP_CONTAINER" "$PG_CONTAINER" "$REDIS_CONTAINER" >/dev/null 2>&1 || true
    podman volume rm -f "$VOLUME" >/dev/null 2>&1 || true
    podman network rm -f "$NET" >/dev/null 2>&1 || true
    rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

wait_for_postgres() {
    local attempts=30 i=1
    while [[ "$i" -le "$attempts" ]]; do
        if podman exec "$PG_CONTAINER" pg_isready -U "$PG_USER" -d "$PG_DB" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    return 1
}

wait_for_redis() {
    local attempts=30 i=1
    while [[ "$i" -le "$attempts" ]]; do
        if podman exec "$REDIS_CONTAINER" redis-cli ping 2>/dev/null | grep -q PONG; then
            return 0
        fi
        sleep 2
        i=$((i + 1))
    done
    return 1
}

# The app is unreachable for the whole window between "container started"
# and "uvicorn is accepting connections", because secret seeding, migrations
# and provisioning all run first. Waiting that out needs --retry-all-errors,
# not just --retry-connrefused: under rootless podman the port forwarder
# (pasta) ACCEPTS the connection and then resets it when nothing is
# listening inside the container yet, so curl reports error 56 "Recv failure:
# Connection reset by peer" rather than a refusal. --retry treats only
# timeouts and 5xx as transient and --retry-connrefused adds refusals alone,
# so error 56 ends the whole retry loop on the first attempt and the
# assertion fails against a container that was merely still booting.
wait_for_about() {
    local out_file="$1"
    curl -sS --retry 40 --retry-delay 3 --retry-connrefused --retry-all-errors --fail \
        -o "$out_file" "$ORIGIN/api/v1/about"
}

json_field() {
    # json_field FILE KEY: print a top-level string/number field, or
    # nothing if the file is not valid JSON or the key is absent.
    python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    value = data.get(sys.argv[2], '')
    sys.stdout.write('' if value is None else str(value))
except Exception:
    pass
" "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Setup (fail fast: a problem here means there is nothing to assert against)
# ---------------------------------------------------------------------------

log "creating network $NET"
podman network create "$NET" >/dev/null || die "could not create podman network $NET"

log "starting postgres (throwaway credentials)"
podman run -d --name "$PG_CONTAINER" --network "$NET" \
    -e POSTGRES_USER="$PG_USER" \
    -e POSTGRES_PASSWORD="$PG_PASSWORD" \
    -e POSTGRES_DB="$PG_DB" \
    docker.io/library/postgres:14 >/dev/null || die "could not start postgres"

log "starting redis"
podman run -d --name "$REDIS_CONTAINER" --network "$NET" \
    docker.io/library/redis:8-alpine >/dev/null || die "could not start redis"

log "waiting for postgres to accept connections"
wait_for_postgres || die "postgres did not become ready in time"

log "waiting for redis to accept connections"
wait_for_redis || die "redis did not become ready in time"

GATEWAY="$(podman network inspect "$NET" | python3 -c "
import json, sys
nets = json.load(sys.stdin)
print(nets[0]['subnets'][0]['gateway'])
")"
[[ -n "$GATEWAY" ]] || die "could not determine the $NET network gateway IP"
log "network gateway is $GATEWAY (used as CLOUDRON_PROXY_IP)"

podman volume create "$VOLUME" >/dev/null || die "could not create volume $VOLUME"

# The extra tmpfs at /run/secrets is a podman workaround, not part of the
# Cloudron contract. Fedora and RHEL ship
# /usr/share/containers/mounts.conf containing
# "/usr/share/rhel/secrets:/run/secrets", and podman honours it by
# bind-mounting that host directory READ ONLY over /run/secrets, on top of
# the /run tmpfs above. start.sh's _FILE bridge then dies with
# "cp: cannot create regular file '/run/secrets/...': Read-only file
# system". Docker does not read mounts.conf, so Cloudron itself is
# unaffected; mounting our own tmpfs at the same path shadows the bind and
# restores the platform's real behaviour for this test.
log "starting endurain ($IMAGE), Cloudron style: read-only root, tmpfs /run and /tmp, no OIDC vars"
podman run -d --name "$APP_CONTAINER" \
    --network "$NET" \
    --read-only --tmpfs /run --tmpfs /run/secrets --tmpfs /tmp \
    -v "${VOLUME}:/app/data" \
    -p "${HOST_PORT}:8080" \
    -e CLOUDRON_POSTGRESQL_HOST="$PG_CONTAINER" \
    -e CLOUDRON_POSTGRESQL_PORT=5432 \
    -e CLOUDRON_POSTGRESQL_USERNAME="$PG_USER" \
    -e CLOUDRON_POSTGRESQL_PASSWORD="$PG_PASSWORD" \
    -e CLOUDRON_POSTGRESQL_DATABASE="$PG_DB" \
    -e CLOUDRON_REDIS_URL="redis://${REDIS_CONTAINER}:6379" \
    -e CLOUDRON_APP_ORIGIN="$ORIGIN" \
    -e CLOUDRON_PROXY_IP="$GATEWAY" \
    "$IMAGE" >/dev/null || die "could not start $IMAGE"

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

log "waiting for the container to become healthy"
about_file="$SCRATCH_DIR/about.json"
if wait_for_about "$about_file"; then
    pass "GET /api/v1/about returned 200 within the retry window"
else
    fail "GET /api/v1/about did not return 200 within the retry window"
fi

about_version="$(json_field "$about_file" version)"
if [[ "$about_version" == "v0.19.0" ]]; then
    pass "/api/v1/about reports version v0.19.0"
else
    fail "/api/v1/about reported version '$about_version', expected v0.19.0"
fi

# --- init: tini must be PID 1 for the WHOLE boot, not just for uvicorn ------
# start.sh re-execs itself under `tini -g` on its first line. Before that, bash
# was PID 1 for the entire pre-serve sequence (secret seeding, migrations,
# provisioning), and bash running non-interactively does not act on SIGTERM
# while it waits for a foreground child, so a stop arriving in that window was
# ignored until the platform gave up and sent SIGKILL. Asserting on PID 1 here
# is the structural half of that guarantee; the timed stop at the end of this
# script is the behavioural half.
pid1_comm="$(podman exec "$APP_CONTAINER" ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')"
if [[ "$pid1_comm" == "tini" ]]; then
    pass "PID 1 is tini, so signals are handled from the first line of the boot"
else
    fail "PID 1 is '${pid1_comm:-<unknown>}', expected tini"
fi

# --- process identity -------------------------------------------------------
python_user="$(podman exec "$APP_CONTAINER" ps -eo user,comm --no-headers 2>/dev/null \
    | awk 'tolower($2) ~ /python/ {print $1; exit}')"
if [[ "$python_user" == "cloudron" ]]; then
    pass "the application process runs as the cloudron user"
else
    fail "the application process runs as '${python_user:-<not found>}', expected cloudron"
fi

# --- admin/admin must fail, the generated password must work ---------------
bad_login_file="$SCRATCH_DIR/login-bad.json"
bad_login_status="$(curl -sS -o "$bad_login_file" -w '%{http_code}' \
    -X POST "$ORIGIN/api/v1/auth/login" \
    -H 'X-Client-Type: web' \
    --data-urlencode 'username=admin' \
    --data-urlencode 'password=admin')"
if [[ "$bad_login_status" == "401" ]]; then
    pass "admin/admin login fails with 401 (seeded credential was neutralised)"
else
    fail "admin/admin login returned $bad_login_status, expected 401"
fi

admin_password="$(podman exec "$APP_CONTAINER" grep -v '^#' /app/data/.secrets/admin-initial-password 2>/dev/null || true)"
if [[ -n "$admin_password" ]]; then
    pass "read a non-empty generated admin password from the volume"
else
    fail "could not read a generated admin password from /app/data/.secrets/admin-initial-password"
fi

good_login_file="$SCRATCH_DIR/login-good.json"
good_login_status="$(curl -sS -o "$good_login_file" -w '%{http_code}' \
    -X POST "$ORIGIN/api/v1/auth/login" \
    -H 'X-Client-Type: web' \
    --data-urlencode 'username=admin' \
    --data-urlencode "password=${admin_password}")"
if [[ "$good_login_status" == "200" ]]; then
    pass "login with the generated admin password succeeds"
else
    fail "login with the generated admin password returned $good_login_status, expected 200"
fi

access_token="$(json_field "$good_login_file" access_token)"
# The login response's csrf_token is required on the upload call below:
# core/middleware.py's CSRFMiddleware demands an X-CSRF-Token header on
# every POST/PUT/DELETE/PATCH whose X-Client-Type is "web", except for a
# short exempt-path list (login, mfa/verify, refresh, password-reset,
# sign-up, the public idp session endpoint). /activities/create/upload is
# not on that list, so sending X-Client-Type: web without also sending the
# matching X-CSRF-Token would 403 rather than exercise the upload path.
csrf_token="$(json_field "$good_login_file" csrf_token)"

# --- who am I, so the activities list can be scoped to this user -----------
profile_file="$SCRATCH_DIR/profile.json"
profile_status="$(curl -sS -o "$profile_file" -w '%{http_code}' \
    "$ORIGIN/api/v1/profile" \
    -H "Authorization: Bearer ${access_token}" \
    -H 'X-Client-Type: web')"
user_id="$(json_field "$profile_file" id)"
if [[ "$profile_status" == "200" && -n "$user_id" ]]; then
    pass "resolved the logged-in user id ($user_id) via GET /api/v1/profile"
else
    fail "GET /api/v1/profile returned $profile_status, could not resolve a user id"
fi

# --- the dlopen-class gate: upload a real GPX file and see it parsed -------
upload_file="$SCRATCH_DIR/upload.json"
upload_status="$(curl -sS -o "$upload_file" -w '%{http_code}' \
    -X POST "$ORIGIN/api/v1/activities/create/upload" \
    -H "Authorization: Bearer ${access_token}" \
    -H 'X-Client-Type: web' \
    -H "X-CSRF-Token: ${csrf_token}" \
    -F "file=@${FIXTURES_DIR}/tiny.gpx;type=application/gpx+xml;filename=tiny.gpx")"
if [[ "$upload_status" =~ ^2[0-9][0-9]$ ]]; then
    pass "tiny.gpx upload returned $upload_status"
else
    fail "tiny.gpx upload returned $upload_status, expected 2xx ($(cat "$upload_file" 2>/dev/null))"
fi

list_file="$SCRATCH_DIR/activities.json"
list_status="$(curl -sS -o "$list_file" -w '%{http_code}' \
    "$ORIGIN/api/v1/activities/user/${user_id}/page_number/1/num_records/10" \
    -H "Authorization: Bearer ${access_token}" \
    -H 'X-Client-Type: web')"
activity_count="$(python3 -c "
import json, sys
try:
    data = json.load(open(sys.argv[1]))
    print(len(data) if isinstance(data, list) else 0)
except Exception:
    print(0)
" "$list_file" 2>/dev/null)"
if [[ "$list_status" == "200" && "${activity_count:-0}" -ge 1 ]]; then
    pass "activities list shows $activity_count activity/activities after the upload"
else
    fail "activities list check failed (status=$list_status count=${activity_count:-0})"
fi

# --- secret file ownership, mode and byte-identity across a restart --------
secret_key_stat="$(podman exec "$APP_CONTAINER" stat -c '%a %U:%G' /app/data/.secrets/secret-key 2>/dev/null || true)"
fernet_key_stat="$(podman exec "$APP_CONTAINER" stat -c '%a %U:%G' /app/data/.secrets/fernet-key 2>/dev/null || true)"
if [[ "$secret_key_stat" == "600 cloudron:cloudron" ]]; then
    pass "secret-key is 0600 cloudron:cloudron"
else
    fail "secret-key is '${secret_key_stat:-<not found>}', expected '600 cloudron:cloudron'"
fi
if [[ "$fernet_key_stat" == "600 cloudron:cloudron" ]]; then
    pass "fernet-key is 0600 cloudron:cloudron"
else
    fail "fernet-key is '${fernet_key_stat:-<not found>}', expected '600 cloudron:cloudron'"
fi

secret_key_sha_before="$(podman exec "$APP_CONTAINER" sha256sum /app/data/.secrets/secret-key 2>/dev/null | awk '{print $1}')"
fernet_key_sha_before="$(podman exec "$APP_CONTAINER" sha256sum /app/data/.secrets/fernet-key 2>/dev/null | awk '{print $1}')"
log "secret-key sha256 before restart: ${secret_key_sha_before:-<unknown>}"
log "fernet-key sha256 before restart: ${fernet_key_sha_before:-<unknown>}"

log "restarting the container"
podman restart "$APP_CONTAINER" >/dev/null || fail "podman restart failed"

restart_about_file="$SCRATCH_DIR/about-restart.json"
if wait_for_about "$restart_about_file"; then
    pass "container became healthy again after restart"
else
    fail "container did not become healthy again after restart"
fi

secret_key_sha_after="$(podman exec "$APP_CONTAINER" sha256sum /app/data/.secrets/secret-key 2>/dev/null | awk '{print $1}')"
fernet_key_sha_after="$(podman exec "$APP_CONTAINER" sha256sum /app/data/.secrets/fernet-key 2>/dev/null | awk '{print $1}')"
if [[ -n "$secret_key_sha_before" && "$secret_key_sha_before" == "$secret_key_sha_after" ]]; then
    pass "secret-key sha256 unchanged across restart"
else
    fail "secret-key sha256 changed across restart (before=${secret_key_sha_before:-?} after=${secret_key_sha_after:-?})"
fi
if [[ -n "$fernet_key_sha_before" && "$fernet_key_sha_before" == "$fernet_key_sha_after" ]]; then
    pass "fernet-key sha256 unchanged across restart (FERNET_KEY byte-identity gate)"
else
    fail "fernet-key sha256 changed across restart (before=${fernet_key_sha_before:-?} after=${fernet_key_sha_after:-?})"
fi

restart_logs="$(podman logs "$APP_CONTAINER" 2>&1)"
if printf '%s\n' "$restart_logs" | grep -q "existing secret found: secret-key" \
    && printf '%s\n' "$restart_logs" | grep -q "existing secret found: fernet-key"; then
    pass "logs show the existing-secret branch after restart, for both keys"
else
    fail "logs do not show the existing-secret branch after restart for both keys"
fi

restart_login_status="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X POST "$ORIGIN/api/v1/auth/login" \
    -H 'X-Client-Type: web' \
    --data-urlencode 'username=admin' \
    --data-urlencode "password=${admin_password}")"
if [[ "$restart_login_status" == "200" ]]; then
    pass "the generated admin password still works after restart"
else
    fail "the generated admin password no longer works after restart (status=$restart_login_status)"
fi

# --- no secret value should ever reach the logs -----------------------------
secret_key_value="$(podman exec "$APP_CONTAINER" cat /app/data/.secrets/secret-key 2>/dev/null || true)"
fernet_key_value="$(podman exec "$APP_CONTAINER" cat /app/data/.secrets/fernet-key 2>/dev/null || true)"
full_logs="$(podman logs "$APP_CONTAINER" 2>&1)"

secret_leaked=0
if [[ -n "$admin_password" ]] && printf '%s\n' "$full_logs" | grep -qF -- "$admin_password"; then
    fail "the generated admin password appears in container logs"
    secret_leaked=1
fi
if [[ -n "$secret_key_value" ]] && printf '%s\n' "$full_logs" | grep -qF -- "$secret_key_value"; then
    fail "the secret-key value appears in container logs"
    secret_leaked=1
fi
if [[ -n "$fernet_key_value" ]] && printf '%s\n' "$full_logs" | grep -qF -- "$fernet_key_value"; then
    fail "the fernet-key value appears in container logs"
    secret_leaked=1
fi
if [[ "$secret_leaked" -eq 0 ]]; then
    pass "no secret value (admin password, secret-key, fernet-key) appears in container logs"
fi

# --- a stop DURING the boot sequence must be answered, not waited out -------
#
# Regression test for the defect the pre-install review panel found: with bash
# as PID 1 and no trap, a SIGTERM arriving before the final exec had no
# destination, so a stop mid-migration sat out the platform's whole grace
# period and ended in SIGKILL. Cloudron restarts an app on update and after
# configuration changes, and a first boot running migrations is exactly when
# that is most likely, so this is worth a standing assertion rather than a
# one-off check.
#
# A fresh database is what makes the window real: it forces the full migration
# chain to run, giving a pre-serve window of several seconds to aim at. The
# container is throwaway, so /app/data is a tmpfs rather than a volume.
BOOTSTOP_DB=endurain_bootstop
BOOTSTOP_GRACE=20

log "checking that a stop DURING the boot sequence is answered promptly"
if podman exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "CREATE DATABASE ${BOOTSTOP_DB};" >/dev/null 2>&1; then
    podman run -d --name "$BOOTSTOP_CONTAINER" \
        --network "$NET" \
        --read-only --tmpfs /run --tmpfs /run/secrets --tmpfs /tmp --tmpfs /app/data \
        -e CLOUDRON_POSTGRESQL_HOST="$PG_CONTAINER" \
        -e CLOUDRON_POSTGRESQL_PORT=5432 \
        -e CLOUDRON_POSTGRESQL_USERNAME="$PG_USER" \
        -e CLOUDRON_POSTGRESQL_PASSWORD="$PG_PASSWORD" \
        -e CLOUDRON_POSTGRESQL_DATABASE="$BOOTSTOP_DB" \
        -e CLOUDRON_REDIS_URL="redis://${REDIS_CONTAINER}:6379" \
        -e CLOUDRON_APP_ORIGIN="$ORIGIN" \
        -e CLOUDRON_PROXY_IP="$GATEWAY" \
        "$IMAGE" >/dev/null 2>&1

    # Wait for the migration step specifically, rather than sleeping a fixed
    # interval and hoping. A fixed sleep is what makes a timing test lie: too
    # short and the container has barely started, too long and it has already
    # reached the final exec, at which point uvicorn is handling signals and
    # the very window under test has been skipped. Polling for the log line
    # puts the stop inside `alembic upgrade head`, which is both the longest
    # step before the exec and the one a platform restart is most likely to
    # interrupt on a first install.
    bootstop_phase="(never reached the migration step)"
    for _ in $(seq 200); do
        if podman logs "$BOOTSTOP_CONTAINER" 2>&1 | grep -q "running database migrations"; then
            bootstop_phase="mid-migration"
            break
        fi
        sleep 0.25
    done

    stop_started="$SECONDS"
    podman stop -t "$BOOTSTOP_GRACE" "$BOOTSTOP_CONTAINER" >/dev/null 2>&1
    stop_elapsed="$((SECONDS - stop_started))"
    bootstop_exit="$(podman inspect "$BOOTSTOP_CONTAINER" --format '{{.State.ExitCode}}' 2>/dev/null)"

    # Generous threshold: the point is "answered" versus "waited out to the
    # SIGKILL", not a precise shutdown budget. Hitting the full grace period
    # is the failure being guarded against.
    if [[ "$bootstop_phase" != "mid-migration" ]]; then
        # Say so rather than reporting a pass that tested the wrong moment.
        fail "the mid-boot stop check never caught the migration step, so it proved nothing"
    elif [[ "$stop_elapsed" -lt "$BOOTSTOP_GRACE" && "$bootstop_exit" != "137" ]]; then
        pass "stop during migrations answered in ${stop_elapsed}s (exit ${bootstop_exit}), well inside the ${BOOTSTOP_GRACE}s grace"
    else
        fail "stop during migrations took ${stop_elapsed}s and exited ${bootstop_exit} (137 = SIGKILL): the boot sequence is ignoring SIGTERM"
    fi

    podman rm -f "$BOOTSTOP_CONTAINER" >/dev/null 2>&1
    podman exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "DROP DATABASE ${BOOTSTOP_DB};" >/dev/null 2>&1
else
    fail "could not create the ${BOOTSTOP_DB} database, so the mid-boot stop check did not run"
fi

# ---------------------------------------------------------------------------
echo "==================================================="
if [[ "$FAILED" -eq 0 ]]; then
    echo "SMOKE TEST: ALL ASSERTIONS PASSED"
    exit 0
else
    echo "SMOKE TEST: ONE OR MORE ASSERTIONS FAILED"
    exit 1
fi
