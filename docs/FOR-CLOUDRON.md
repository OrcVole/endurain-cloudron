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

## The per-app CPU graph reads in core units, and the reader has to know the core count

Not a bug, and the underlying numbers are right. This is about what the presentation asks the reader
to supply from memory.

The per-app CPU graph follows the Docker convention in which 100 per cent means one core, the same as
`docker stats` and the same as `top` for a multithreaded process. On a twelve core host the ceiling is
therefore 1200 per cent. The sentence that makes it click, and which is not on the screen:

> 500 per cent is not five times the machine. It is 100 per cent of each of five cores, out of the
> twelve there are. Five twelfths of the box, not five boxes.

That is the right unit for the job the graph does, which is comparing applications against each
other, and changing it would squash a typical application into an unreadable sliver. The gap is
context rather than unit: without the core count in view, a number above 100 per cent is not
interpretable, and the natural reading of "percent" is that it stops at 100.

A worked example from this packaging round, on a twelve core host running 92 containers. One
application's graph had earlier shown roughly 700 per cent during a genuine runaway, which was
correct and was seven cores. Later, with that resolved, the host looked alarming and was not:

| Figure | Value |
| --- | --- |
| Load average | 15.78, steady over 1, 5 and 15 minutes |
| CPU idle | 80 per cent, `iowait` 0, `steal` 0 |
| Memory pressure (`/proc/pressure/memory`) | 0.00 |
| Available memory | 33 GiB of 62 GiB |

The machine was healthy. The load average was high because Linux counts processes that are runnable
**or** blocked in uninterruptible sleep, and 92 containers' worth of health checks, schedulers and
database background threads hold it in the teens on an idle host. Neither the load average nor a
per-app core-unit percentage answers the question an operator actually arrives with, which is whether
the machine is in trouble.

Three suggestions, in increasing order of effort:

1. **Put the core count on the axis.** Labelling the maximum `1200% (12 cores)`, or drawing a ceiling
   line, removes the ambiguity entirely and is about as small a change as a graph can take.
2. **Offer cores as an alternative unit.** "5.0 of 12 cores" is unambiguous in a way that "500%" will
   never be, however conventional the percentage is.
3. **On the system view, show machine-normalised CPU beside the load average**, with a note that the
   load average is not a utilisation figure. The per-app graphs are good at comparing applications
   and structurally cannot answer the question about the host; that gap is where operators guess.

Offered because the cost is real and easy to watch: it sends people looking for a fault in their
applications, or opening tickets with their hypervisor provider, before they get as far as checking
the idle column in `vmstat`.
