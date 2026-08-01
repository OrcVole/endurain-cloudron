# For Upstream

Notes for the Endurain project, offered in the spirit of packaging feedback rather than complaint:
Endurain has been straightforward to package, and everything below is offered as something that
would help every deployment method, not only this one, from a project that is clearly already
thinking about deployment and operations.

**Status: to be completed at the end of this packaging round.** The points below are seeded now,
while they are fresh, and will be gathered into whatever form is most useful to send upstream, an
issue, a discussion post, or a pull request, once the round that produced them is finished.

## The seeded admin / admin credential

The first database migration seeds a live `admin` account with the well-known password `admin`.
Every deployment method has to independently notice this and do something about it before first
serving a request, or ship an instance that is briefly, or not so briefly, reachable with a
credential anyone can look up in the source. A first-boot randomised password, or a forced password
change on first login, would remove that foot-gun once, upstream, for every deployment method at
the same time, rather than leaving each one to solve it separately, as this package has had to.

## A documented health-check commitment

`/api/v1/about` currently works well as an orchestrator health check: unauthenticated, static, and
on the primary port, which is exactly what a platform health check needs. It would help to have
that stated as a deliberate, documented commitment rather than left as an incidental property of an
endpoint that happens to suit, so that packagers and orchestrator authors can rely on it without
independently rediscovering that it is safe to poll.

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
