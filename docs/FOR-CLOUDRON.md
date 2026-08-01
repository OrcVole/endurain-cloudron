# For Cloudron

Verified platform observations from this packaging round, the kind of thing that would make
Cloudron a better fit for this class of application generally, not only for Endurain. This is
written for Cloudron, not for Endurain's maintainers; see [`docs/FOR-UPSTREAM.md`](FOR-UPSTREAM.md)
for observations aimed at the application instead.

**Status: to be completed at the end of this packaging round.** The two entries below are seeded
now, while they are fresh, but this document is not final until the round that produced them is.

## The postgresql addon's PostgreSQL 14.x, against an upstream referencing 18

Endurain's own documentation and examples reference PostgreSQL 18. Cloudron's `postgresql` addon
provides 14.x. This worked here: the full Alembic migration chain, application boot, the health
check and an authenticated login were all exercised against the addon's PostgreSQL 14 during this
round, with nothing in that chain failing or behaving differently than expected. So this is not a
report of a problem with this package.

It is worth recording as a platform observation anyway, because the gap between what an addon
offers and what a fast-moving upstream is developed and tested against is a standing risk, even
where it happens not to bite on this particular application, at this particular version. Some
application, at some version, will use a feature, an extension, a planner behaviour or a migration
construct that 14.x genuinely lacks. Knowing that in advance, rather than discovering it
mid-packaging, would be useful.

## Install-phase health behaviour during a pre-serve migration step

Placeholder. This package's start script runs `alembic upgrade head` as a distinct step before
uvicorn is ever started, rather than inside the application's own startup lifecycle, so the full
migration chain finishes before anything is listening on `httpPort` at all. That leaves a window,
however long the pending migrations take, where the container is running but nothing yet answers
`healthCheckPath`. This needs verifying against a real install before it is written up properly:
whether Cloudron's install-phase health polling simply retries patiently through that window, or
whether there is a timeout worth knowing about for an unusually long migration chain. Recorded here
as a placeholder so it is not forgotten before the round ends.
