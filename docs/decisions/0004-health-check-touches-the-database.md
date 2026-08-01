# ADR 0004: The health check reads the database

Status: accepted, 2026-08-01.

## Context

The obvious health endpoint for this application is `GET /api/v1/about`. It is unauthenticated,
static, cheap, on the primary port, and returns the version as JSON. It was the manifest's
`healthCheckPath` through gates 0 to 3 and it worked.

Gate 4 showed what it cannot see.

Driving concurrent activity uploads left the application with forty-two database connections
`idle in transaction` and every request needing a database session waiting indefinitely. The
application was, from a user's point of view, completely dead: no login, no upload, no page that
reads anything. It did not recover on its own, and it stayed that way until it was restarted.

Throughout, `GET /api/v1/about` returned 200 in about a second, because it touches nothing. The
platform's health check was therefore green for the entire outage, the dashboard reported the app as
`running`, and nothing would ever have restarted it. A measured comparison during the failure:

| Path | Reads the database | Result while wedged |
| --- | --- | --- |
| `/api/v1/about` | no | **200**, about 1 second |
| `/api/v1/public/server_settings` | yes | **hangs** until the client gives up |

The underlying leak is an upstream fault and is reported in `docs/FOR-UPSTREAM.md`. This decision is
about what the package should do while that fault exists, and about what it should do in general,
since any future dependency failure has the same shape.

## Decision

`healthCheckPath` is `/api/v1/public/server_settings`, which is public, cheap, reads one row from the
database, and is served by the same process on the same port.

The reasoning is that a health check exists to answer "should the platform restart this", and an
endpoint that touches no dependency cannot answer that question. It can only report that a process is
running, which is the one thing the platform already knows. A health check that reads the database
turns a permanent silent wedge into an automatic restart, which is the recovery an operator would
perform by hand anyway.

## Alternatives considered

**Keeping `/api/v1/about` and documenting the failure mode.** Rejected. Documentation does not restart
anything at three in the morning, and the operator most likely to hit this is the one least likely to
have read the note.

**A deeper check that also exercises Redis or the mail relay.** Rejected as disproportionate. The
database is the dependency whose failure makes the application useless; Redis backs rate limiting and
degrades to process-local memory, and mail is asynchronous. A health check should be the narrowest
thing that distinguishes "usable" from "not usable".

**Adding a purpose-built health route by patching upstream.** Rejected. This package builds from
upstream source without patching it, an existing public endpoint does the job, and carrying a patch
would create a merge burden at every version bump for no additional signal.

## Consequences

The health check now fails when the database is unreachable, which is a deliberate change of
behaviour. If the platform's PostgreSQL addon is briefly unavailable, the app will be restarted rather
than left running in a state where it cannot serve a request. That is the intended trade: a restart is
cheap and idempotent here, because `start.sh` re-asserts everything it needs on every boot and the
seeded-secret path is a no-op on a warm volume.

There is no first-boot restart-loop risk from this. The listener is not opened until migrations and
provisioning have finished, so by the time anything can answer the health check at all, the database
is by construction reachable.

The check costs one indexed single-row read per poll. That was measured at roughly one second per
request on a host that was, at the time, running at three and a half times its core count, so the cost
is dominated by scheduling rather than by the query.

Standing gate: any future change to `healthCheckPath` must be re-tested against the failure this ADR
exists for, by wedging the database path deliberately and confirming the check goes red. A health
check is only worth what it detects, and this one was chosen by observing a real failure rather than
by reasoning about which endpoint looked tidiest.
