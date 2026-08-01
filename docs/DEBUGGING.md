# Debugging and gate evidence

Evidence tables for this package, newest first. Every row states an invariant and a proof: a log
line, a hash, a count, an exit code. An inference is not a proof and does not belong in a proof
cell.

The gate ladder proper (gates 0 to 4, against a real install) has not run yet. What follows is the
local evidence gathered before first install.

## Local smoke suite

`test/smoke.sh IMAGE` runs the package the way the platform does: read-only root filesystem, tmpfs
at `/run` and `/tmp`, state on a volume at `/app/data`, addon credentials supplied only through the
environment, and no OIDC variables, so the `optionalSso` path is what gets exercised.

Two of the flags it passes to podman are workarounds for the local container runtime rather than
part of the platform contract, and both are commented in the script: an explicit tmpfs at
`/run/secrets` (Fedora and RHEL bind-mount a read-only directory there through
`/usr/share/containers/mounts.conf`, which Docker does not read) and `curl --retry-all-errors`
(rootless podman resets connections during the boot window instead of refusing them, and curl does
not treat a reset as retryable).

Result against the shipping image, all nineteen assertions:

| Invariant | Proof |
| --- | --- |
| Health endpoint answers unauthenticated | `GET /api/v1/about` returns 200 within the retry window |
| Correct version is serving | `/api/v1/about` reports `v0.19.0` |
| Init is correct for the whole boot | `ps -p 1 -o comm=` reports `tini` |
| Privileges are dropped | the python process runs as `cloudron` |
| Seeded credential is dead | `POST /api/v1/auth/login` with `admin`/`admin` returns 401 |
| Generated credential exists and works | password read from `/app/data/.secrets/admin-initial-password`; login returns 200 |
| Authenticated identity resolves | `GET /api/v1/profile` returns 200 with user id 1 |
| Activity upload parses and persists | `POST /api/v1/activities/create/upload` returns 201; the activity list then returns one activity |
| Secret files are locked down | `secret-key` and `fernet-key` are both `600 cloudron:cloudron` |
| Restart does not regenerate secrets | sha256 of both keys unchanged across a restart; logs show the existing-secret branch for both |
| Restart does not invalidate the credential | the generated admin password still returns 200 afterwards |
| No secret reaches the logs | neither key value nor the generated password appears in the container log |
| A stop during migrations is answered | `podman stop -t 20` completes in 0s with exit 143 |

### The mid-migration stop, and why it is asserted rather than assumed

The last row is a regression test for a defect found by the pre-install review panel. `CMD` runs
`start.sh` directly, which is correct for Cloudron (an `ENTRYPOINT` breaks debug mode), but it left
bash as PID 1 for the entire pre-serve sequence: secret seeding, the frontend tree rebuild,
`alembic upgrade head`, and provisioning. Bash running non-interactively does not act on SIGTERM
while it waits for a foreground child, and PID 1 has no default disposition for it, so a stop
arriving in that window was not delayed, it was ignored until the platform gave up and sent
SIGKILL. The platform restarts an app on update and after configuration changes, and a first boot
running migrations is exactly when that is most likely.

The fix re-execs `start.sh` under `tini -g` on its first line, so tini is PID 1 for the whole script
and signals reach the process group rather than stopping at a shell that is not listening.

Measured on both images, stopping deterministically during `alembic upgrade head` (the test polls
for the migration log line rather than sleeping a fixed interval, because a fixed sleep either
arrives before the window or after it):

| Image | PID 1 | `podman stop -t 20` | Exit code |
| --- | --- | --- | --- |
| Before the fix | `start.sh` | 20s, the entire grace period | 137 (SIGKILL) |
| After the fix | `tini` | 0s | 143 (SIGTERM) |

The before row is the evidence that the assertion has teeth. A test that has never been observed to
fail is not yet known to be a test.

## Secret and anonymity scan

`test/secret-scan.sh IMAGE` scans two surfaces, the publishable file set and the built image,
because the image is what the world actually pulls.

| Invariant | Proof |
| --- | --- |
| No box specifics, identities or credential shapes in the publishable files | 23 files scanned, no hits |
| The base image's inert SSH host keys are the known ones | 3 found, 3 pinned-ok by sha256, 3 expected |
| No credential shapes in our own code or configuration in the image | no hits outside third-party packages |
| Third-party documentation examples are accounted for, not hidden | 9 shape hits in 5 site-packages files, counted and reported on every run |

Those nine are vendor documentation: sample tokens in Apprise's plugin docstrings, Amazon's
published example access key ID, a PEM header used as a parser constant, and a base64 font blob in
Pillow that happens to contain an access-key-shaped run of characters. The shape scan is relaxed
inside site-packages only; the identity and token scans still cover it in full, and the count is
printed on every run so a suppression cannot pass unnoticed.

This paragraph is deliberately written without quoting any of those example values. An earlier
draft named Amazon's literal example key, and the scanner duly flagged this file: documentation
about a credential shape is still a credential shape to a pattern matcher. Describe the examples,
do not reproduce them.

## Build-time gates

| Invariant | Proof |
| --- | --- |
| The venv and interpreter resolve on the runtime stage | `runtime import gate OK` in the build log |
| The application's real module graph imports | `runtime app import gate OK`: `import main` builds the FastAPI app with every router |
| Node is the pinned version | build fails unless `node --version` reports `v24.15.0` |

The application import gate was added after the panel observed that the named-module list covered
eleven of the forty-seven declared runtime dependencies and never imported the application itself,
so it could pass while something the app genuinely imports was missing. It is safe at build time
because the import opens no database connection and starts no scheduler, both verified rather than
assumed.

## Compatibility

| Invariant | Proof |
| --- | --- |
| The platform PostgreSQL addon (14.x) runs this release | full Alembic chain base to head applied cleanly in 3.2s against Postgres 14; app booted; login succeeded |

Upstream's reference compose pins Postgres 18. Nothing in the schema chain or the login path needed
it, which is what makes the addon usable and avoids bundling a database.
