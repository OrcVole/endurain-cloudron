# For Upstream

Notes for the Endurain project, offered in the spirit of packaging feedback rather than complaint:
Endurain has been straightforward to package, and everything below is offered as something that
would help every deployment method, not only this one, from a project that is clearly already
thinking about deployment and operations.

**Status: filed, 2026-08-01.**

- The duplicate-start-time defect is Codeberg issue
  [#858](https://codeberg.org/endurain-project/endurain/issues/858).
- The transaction leak that can leave an instance permanently unable to serve requests was sent
  **privately by email**, as the project's `SECURITY.md` asks, because any authenticated user can
  use it to deny service to every user of an instance. It is described below for this package's own
  record; please do not lift it into a public issue ahead of the maintainer.
- The remaining points are packaging observations rather than defects, and were offered alongside
  the packaging announcement rather than as issues, since the project asks that issues be opened one
  thing at a time and its maintainer is a single person working in their spare time.

## The seeded admin / admin credential

The first database migration seeds a live `admin` account with the well-known password `admin`.
Every deployment method has to independently notice this and do something about it before first
serving a request, or ship an instance that is briefly, or not so briefly, reachable with a
credential anyone can look up in the source. A first-boot randomised password, or a forced password
change on first login, would remove that foot-gun once, upstream, for every deployment method at
the same time, rather than leaving each one to solve it separately, as this package has had to.

## A documented health-check commitment

*Written early in the packaging work, and then substantially revised by what the round found. The
original text recommended `/api/v1/about` as the natural health endpoint. It is kept in amended form
rather than deleted, because the reasoning that made it look right is exactly the reasoning that
makes this class of mistake common.*

`/api/v1/about` looks like an ideal orchestrator health check: unauthenticated, static, cheap, on the
primary port. Its problem is precisely that it is static. Because it touches no dependency, it cannot
distinguish a working instance from one that is completely unable to serve a request, which is not
hypothetical here: see the transaction-leak section below, where it returned 200 throughout an
outage that made the application useless.

Two things would help packagers and orchestrator authors:

1. State plainly, in the deployment documentation, that `/api/v1/about` is a **process liveness**
   check only and must not be relied on to detect a broken instance.
2. Offer, or document, an endpoint that touches the database and is safe to poll. This package now
   uses `/api/v1/public/server_settings`, which is public, cheap and reads one row, but it chose that
   by reading the router rather than from any documented commitment, so a future refactor could
   silently take it away.

## The X-Client-Type header and its 401

A JSON API request without an `X-Client-Type` header is rejected the same way a request with a
wrong password or a wrong API key is rejected: a 401, indistinguishable from a credentials failure
at the protocol level. This cost real time to diagnose while packaging, since the natural first
assumption when a request is rejected as unauthorised is that the credentials are wrong. A distinct
status, a 400 with a hint naming the missing header, rather than folding it into the same 401 as an
actual authentication failure, would save the next integrator that time.

## Thumbnail generation writes its PNG without the atomic pattern used elsewhere

`generate_activity_thumbnail()` writes to its final path directly
(`image.save(str(output_path), "PNG")` in
`backend/app/activities/activity/thumbnail.py`), while every other write path under the data
directory, in `core/file_uploads.py`, goes through a temporary `.part` file and an `os.replace()`.
The scheduler calls the thumbnail path unattended, on an hourly interval, for the life of the
process, so it writes with no user action and no quiet period.

That combination matters to any platform that backs up a running application by walking its data
directory, which is how Cloudron works: there is no pause and no post-backup hook, so a walk that
reads a thumbnail during the window when it is being written captures a truncated PNG. The restored
file then exists on disk, so the `is_file()` check treats it as present and the hourly regeneration
job passes over it, leaving one activity with a permanently broken thumbnail that nothing detects.

Routing thumbnail writes through the same `.part`-then-rename helper the upload paths already use
would close the window entirely, and is a small change against code that already exists in the
project. Having the regeneration job verify an existing thumbnail rather than only test for its
presence would additionally let an instance heal a file damaged some other way.

## Concurrent activity uploads leave connections idle in transaction, and the application never recovers

This is the most serious thing found while packaging, and it is reproducible with nothing more exotic
than a user importing a backlog of activities.

Forty-eight uploads of a 2000-point GPX file, six at a time through
`POST /api/v1/activities/create/upload`, left the application permanently unable to serve any request
that needs a database session. Inspecting the database during the failure:

```
connections to app db: 46
  active               1
  idle                 3
  idle in transaction  42
waiting                45
```

Forty-two sessions sat in `idle in transaction`, so every later request waited on a connection that
was never going to be returned. `max_connections` was 500, so this is not connection exhaustion at
the server: it is transactions opened and neither committed nor rolled back on the upload path under
concurrency. None of the failing uploads appears in the application log at all, which suggests they
were lost before the request handler logged them.

The application does not recover on its own. Restarting it clears the state completely and
immediately (back to one active and two idle connections), which points at the process holding the
sessions rather than anything persistent.

What makes this severe rather than merely annoying is the second half. **`GET /api/v1/about`
continues to return 200 throughout**, in about a second, because it does not touch the database. Any
orchestrator using it as a health check sees a perfectly healthy application. The platform this
package targets reported the app as `running` for as long as the wedge lasted, and would never have
restarted it. A user's instance can therefore be completely dead and monitored as healthy
indefinitely.

Two suggestions, offered separately because they are independent:

1. The upload path should ensure its transaction is closed on every exit, including error paths, so
   that concurrency cannot leak sessions. A pool timeout would also convert a permanent hang into a
   visible error.
2. A health endpoint that deliberately touches no dependency is a reasonable thing to offer, but it
   would help operators enormously to also have one that checks the database, or for the documented
   health endpoint to do so. This package has switched its own health check to
   `/api/v1/public/server_settings` for exactly this reason: it is public, cheap, and reads the
   database, so a wedge like the above is detected and the platform restarts the app automatically.

## A stated libc and Python floor

This package builds Endurain from source rather than from the published container image, so it does
not depend on upstream's own Alpine base; it does depend on knowing what libc and Python version
Endurain is actually developed and tested against. A stated minimum, for example in the project's
own contributing or deployment documentation, would make that a documented fact for every packager
to build against, rather than something each one infers from the Dockerfile, the lockfile or trial
and error.
