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

## A stated libc and Python floor

This package builds Endurain from source rather than from the published container image, so it does
not depend on upstream's own Alpine base; it does depend on knowing what libc and Python version
Endurain is actually developed and tested against. A stated minimum, for example in the project's
own contributing or deployment documentation, would make that a documented fact for every packager
to build against, rather than something each one infers from the Dockerfile, the lockfile or trial
and error.
