# Endurain on Cloudron.
#
# Two stages, both pinned to the same cloudron/base digest (ADR 0001): the
# platform's file manager, web terminal and log viewer depend on utilities
# that image provides, so the final stage has to be cloudron/base regardless
# of what the builder stage does. Upstream's own image is Alpine/musl with an
# ENTRYPOINT-only contract and a registry that has moved twice in a year, so
# this package builds Endurain from source at a pinned git tag instead of
# extending upstream's image.
#
# Builder stage: clone the pinned upstream tag, verify its commit, fetch a
# pinned uv, sync the backend's locked dependencies into a uv-managed
# venv/interpreter pair, build the frontend with the base image's own
# Node 24, and gate all of it before anything is copied forward.

FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c AS builder

ARG ENDURAIN_VERSION=0.19.2
ARG ENDURAIN_COMMIT=2d8a1aa7e1048e428e17840a41245537f8cda9aa

# Build-only OS packages. git/curl/ca-certificates/tar fetch and verify
# upstream and the pinned uv release. The compiler toolchain mirrors
# upstream's own requirements-stage apt list (docker/Dockerfile:
# build-base pkgconfig musl-dev python3-dev libffi-dev openssl-dev gcc),
# translated from Alpine package names to this image's Ubuntu 24.04 base,
# in case uv ever has to build a dependency from an sdist rather than
# pulling a prebuilt wheel.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        libffi-dev \
        libssl-dev \
        pkg-config \
        python3-dev \
        tar \
 && rm -rf /var/lib/apt/lists/*

# Clone the pinned tag, then verify the checked-out commit matches
# ENDURAIN_COMMIT exactly. A tag is a mutable ref in git (it can be
# force-moved on the remote); the commit comparison is what actually pins
# the build, not the tag name alone. Verified locally against the real
# clone before this Dockerfile was written: `git rev-parse HEAD` at
# `v0.19.0` on https://codeberg.org/endurain-project/endurain.git resolves
# to exactly bc88c2a72c286e1dc1eae636ef14550b696c3fe2.
RUN git clone --depth 1 --branch "v${ENDURAIN_VERSION}" \
        https://codeberg.org/endurain-project/endurain.git /build/upstream \
 && cd /build/upstream \
 && resolved_commit="$(git rev-parse HEAD)" \
 && if [ "$resolved_commit" != "$ENDURAIN_COMMIT" ]; then \
        echo "==> upstream commit mismatch for v${ENDURAIN_VERSION}: expected ${ENDURAIN_COMMIT}, got ${resolved_commit}" >&2; \
        exit 1; \
    fi \
 && echo "==> verified upstream v${ENDURAIN_VERSION} at commit ${resolved_commit}"

# Fetch uv EXACTLY 0.11.18. backend/pyproject.toml pins
# [tool.uv] required-version = "0.11.18" and uv refuses to run at all
# inside that tree under any other version, so the build tool itself has
# to match before anything else happens. The tarball sha256 below was
# independently reproduced (not merely copied) by downloading this exact
# URL and hashing it.
RUN curl -fsSL -o /tmp/uv.tar.gz \
        https://github.com/astral-sh/uv/releases/download/0.11.18/uv-x86_64-unknown-linux-gnu.tar.gz \
 && echo "588f3e360f69ce02b6982aa99f2240e803933a6b7e176ac01617830adf955add  /tmp/uv.tar.gz" | sha256sum -c - \
 && tar -xzf /tmp/uv.tar.gz -C /tmp \
 && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uv /usr/local/bin/uv \
 && install -m 0755 /tmp/uv-x86_64-unknown-linux-gnu/uvx /usr/local/bin/uvx \
 && rm -rf /tmp/uv.tar.gz /tmp/uv-x86_64-unknown-linux-gnu \
 && uv --version \
 && uv --version | grep -q '0\.11\.18' \
        || { echo "==> build gate failed: uv --version did not report 0.11.18" >&2; exit 1; }

# uv-managed CPython and the synced venv both land under /app/code so the
# tree copied into the runtime stage is self-contained: every interpreter
# symlink under venv/bin resolves to a path under python/, and both are
# copied forward to the SAME absolute paths, so nothing points back at a
# builder-only location.
ENV UV_PYTHON_INSTALL_DIR=/app/code/python \
    UV_PROJECT_ENVIRONMENT=/app/code/venv

# PYTHON_VERSION resolved out of band from upstream's own pinned backend
# base image (docker/Dockerfile: python:3.13-alpine@sha256:420cd0bf0f3998
# 275875e02ecd5808168cf0843cbb4d3c536432f729247b2acc), via
# `skopeo inspect docker://python@sha256:420cd0bf...`, whose Env reports
# PYTHON_VERSION=3.13.13. Installing the identical patch keeps this
# package behaviourally aligned with the interpreter upstream actually
# ships and tests against.
RUN uv python install 3.13.13

WORKDIR /build/upstream/backend

# --frozen: fail rather than silently re-resolve if uv.lock and
# pyproject.toml disagree. --no-install-project: the project is never
# imported as an installed package (the app runs with backend/app/ as its
# working directory and implicit sys.path root, the same convention
# [tool.pytest.ini_options] pythonpath = ["app"] uses for tests); only its
# locked third-party dependencies need to land in the venv.
# --no-dev: excludes the "dev" dependency-group, which transitively pulls
# in lint/test/typecheck/docs, giving the same runtime-only scope
# upstream's own Dockerfile achieves with `uv export --no-emit-project
# --no-dev` (ADR 0001 chooses `uv sync --frozen` over that export-and-pip
# mechanism, so the flags are mirrored in intent, not the literal command).
RUN uv sync --frozen --no-install-project --no-dev --python 3.13.13

# Assemble the runtime layout. Only backend/app (which contains
# alembic.ini and the alembic/ package exactly as upstream has them,
# alembic.ini's script_location = alembic being a path resolved relative
# to the working directory, not to pyproject.toml) is carried forward.
# backend/pyproject.toml and backend/uv.lock stay in the builder: nothing
# at runtime re-runs uv, so they would be dead weight; carrying them would
# also risk implying a running container can `uv sync` itself, which it
# cannot (uv is a builder-only tool, not part of this image).
# backend/tests, conftest.py, .env.test, .importlinter and scripts/ are
# development-only and stay out of the shipped image for the same reason.
RUN mkdir -p /app/code/upstream/backend \
 && cp -a /build/upstream/backend/app /app/code/upstream/backend/app

# Build gate: the synced venv actually imports the heavy runtime
# dependencies backend/pyproject.toml declares. fastapi, sqlalchemy,
# alembic; psycopg (the pyproject.toml entry is "psycopg[binary,pool]",
# which imports as psycopg); stravalib; garminconnect; the FIT/GPX/TCX
# parsers the app imports directly (fitdecode, gpxpy, tcxreader, confirmed
# against activities/activity_file_import/utils_fit.py, utils_gpx.py,
# utils_tcx.py); cryptography.fernet (a transitive dependency, confirmed
# against core/config.py's `from cryptography.fernet import Fernet`); and
# PIL (Pillow, pulled in at runtime by the qrcode[pil] extra that
# auth/mfa/service.py's `import qrcode` relies on for TOTP QR codes).
RUN /app/code/venv/bin/python -c "import fastapi, sqlalchemy, alembic, psycopg, stravalib, garminconnect, fitdecode, gpxpy, tcxreader, cryptography.fernet, PIL; print('==> builder import gate OK')"

# --- Frontend toolchain. cloudron/base:5.0.0 at this digest ships ONLY
# node 22.14.0 with npm 10.9.2 (verified 2026-08-01 by running the base
# image directly; /usr/local/node-22.14.0 is the sole node installation).
# That fails frontend/package.json's engines floor ("^22.18.0 ||
# >=24.12.0") outright, and npm 10 additionally rejects upstream's modern
# package-lock.json ("Missing: @esbuild/<foreign-platform> from lock
# file": npm 11+ lockfiles omit foreign-platform optional entries that
# npm 10 insists on). A pinned Node 24 is therefore installed for the
# BUILD STAGE ONLY, by URL and sha256 from the official distribution; its
# bundled npm 11 handles the lockfile as upstream intends. The runtime
# stage never needs node: uvicorn serves the built static dist.
RUN curl -fsSL -o /tmp/node.tar.xz \
        https://nodejs.org/dist/v24.15.0/node-v24.15.0-linux-x64.tar.xz \
 && echo "472655581fb851559730c48763e0c9d3bc25975c59d518003fc0849d3e4ba0f6  /tmp/node.tar.xz" | sha256sum -c - \
 && mkdir -p /usr/local/node24 \
 && tar -xJf /tmp/node.tar.xz -C /usr/local/node24 --strip-components=1 \
 && rm /tmp/node.tar.xz
ENV PATH=/usr/local/node24/bin:$PATH
RUN node --version && npm --version \
 && node --version | grep -qx 'v24\.15\.0' \
        || { echo "==> build gate failed: node --version did not report v24.15.0" >&2; exit 1; }

WORKDIR /build/upstream/frontend
RUN npm ci && npm run build \
 && mkdir -p /app/code/frontend-dist \
 && cp -a /build/upstream/frontend/dist/. /app/code/frontend-dist/

# Build gate: the built single-page app actually produced a non-empty
# entry point.
RUN test -s /app/code/frontend-dist/index.html \
        || { echo "==> build gate failed: frontend-dist/index.html missing or empty" >&2; exit 1; }


# -----------------------------------------------------------------------
# Runtime stage.
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

ARG ENDURAIN_VERSION=0.19.2
ENV ENDURAIN_VERSION=${ENDURAIN_VERSION}

# Package revision, baked in so a RUNNING container can say which build it
# is. The manifest pins an image by digest and the platform reports its own
# app version, but neither answers "which packaging revision is actually
# serving right now" from inside the container, which is the question that
# matters when triaging a rig you did not deploy an hour ago. Passed with
# --build-arg PACKAGE_REVISION=<tag> at build time; the default is honest
# about not having been told.
ARG PACKAGE_REVISION=unspecified
RUN mkdir -p /app/code \
 && printf 'upstream=%s\npackage_revision=%s\n' "${ENDURAIN_VERSION}" "${PACKAGE_REVISION}" \
      > /app/code/build-info \
 && chmod 0644 /app/code/build-info

# uv-managed interpreter and venv, at the same absolute paths they were
# built at, so venv/bin/python's interpreter symlinks keep resolving.
COPY --from=builder /app/code/python /app/code/python
COPY --from=builder /app/code/venv /app/code/venv
# Application source only (no build caches: uv's own cache lives outside
# /app/code and is never part of either COPY --from source directory).
COPY --from=builder /app/code/upstream/backend /app/code/upstream/backend
COPY --from=builder /app/code/frontend-dist /app/code/frontend-dist

COPY start.sh /app/code/start.sh
COPY provision.py /app/code/provision.py
RUN chmod 0755 /app/code/start.sh \
 && chmod 0644 /app/code/provision.py

# Runtime-stage import gate: proves the copied venv/python pair still
# resolves and imports correctly on this stage, outside the builder, with
# the exact same module list as the builder-stage gate above, before
# Cloudron ever starts a container from this image.
RUN /app/code/venv/bin/python -c "import fastapi, sqlalchemy, alembic, psycopg, stravalib, garminconnect, fitdecode, gpxpy, tcxreader, cryptography.fernet, PIL; print('==> runtime import gate OK')"

# The gate that actually covers the application. The named-module list above
# is a hand-picked eleven out of the forty-seven runtime dependencies
# backend/pyproject.toml declares, so it can pass while something the app
# genuinely imports is missing or broken. Importing main builds the real
# module graph, including the FastAPI app object and every router, so a
# missing dependency or an import-time error fails the BUILD instead of the
# first boot on someone's server.
#
# Safe to do at build time, and verified so rather than assumed: the import
# opens no database connection (SQLAlchemy connects lazily) and starts no
# scheduler (that happens in the lifespan handler, not at import). The
# placeholder secrets exist only to satisfy config validation and never reach
# the image; the path overrides keep core/config.py's import-time mkdir out
# of /app, and the temporary tree is removed in the same layer. The two
# storage-URI warnings this prints are the expected result of running without
# the redis addon present, not a fault.
RUN set -eu; \
    export DB_PASSWORD=build-gate-placeholder; \
    export SECRET_KEY=0000000000000000000000000000000000000000000000000000000000000000; \
    export FERNET_KEY="$(/app/code/venv/bin/python -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())')"; \
    export ENDURAIN_HOST=http://localhost:8080 ENVIRONMENT=production; \
    export BACKEND_DIR=/app/code/upstream/backend; \
    export DATA_DIR=/tmp/import-gate/data LOGS_DIR=/tmp/import-gate/logs FRONTEND_DIR=/tmp/import-gate/frontend; \
    cd /app/code/upstream/backend/app; \
    /app/code/venv/bin/python -c "import main; assert main.app is not None; print('==> runtime app import gate OK')"; \
    rm -rf /tmp/import-gate

# No ENTRYPOINT: Cloudron packages start with CMD so the platform can
# override the start command without also overriding a baked-in entry
# script (ADR 0001). No HEALTHCHECK: Cloudron manages health itself via
# the manifest's healthCheckPath. No USER: start.sh runs as root and
# drops privileges to the cloudron user itself via gosu, after it has
# re-asserted ownership of /app/data on every boot.
CMD [ "/app/code/start.sh" ]
