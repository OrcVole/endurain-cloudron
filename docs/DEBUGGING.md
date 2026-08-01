# Debugging and gate evidence

Evidence tables for this package, newest first. Every row states an invariant and a proof: a log
line, a hash, a count, an exit code. An inference is not a proof and does not belong in a proof
cell.

## Gate 0: install, health, first run. PASS

Run against a throwaway install on a community Cloudron (9.x), from the published image pinned by
digest in the manifest. Every later gate cites this digest; if the image is rebuilt, the ladder
restarts here.

| Invariant | Proof |
| --- | --- |
| Test what you ship | The registry digest of the pushed tag and the `RepoDigests` entry of the image the rig actually pulled are the same value, `sha256:c37b8939…99b7f`. The install log names that digest rather than a tag |
| Install completes | `cloudron install` ran through subdomain registration, image download, addon setup, reverse proxy and the health check without intervention |
| Health, from outside | `GET /api/v1/about` over the public origin returns 200 with the expected version JSON |
| Application surface | `GET /` returns the SPA (200, `<title>Endurain</title>`) and `GET /env.js` returns 200, so the runtime frontend config the package builds at boot is being served |
| Init and privileges | PID 1 is `tini`; the application process runs as `cloudron` |
| No restart loop | `RestartCount` 0 on the rig, and the log contains exactly two `starting uvicorn` lines for the two deliberate boots (install, then the restart below) |
| Logs clean | No EACCES, EROFS, traceback or missing-variable complaints from the app. The single pattern match in the combined log is the **redis addon's** own `Failed to write PID file: Permission denied`, immediately followed by `Ready to accept connections`: it belongs to the addon container, not this package |
| Addons wired | SMTP resolved from the sendmail addon at boot; the OIDC provider record was created from the addon's environment; Postgres and Redis both in use with no connection retries |
| Secret modes | `secret-key`, `fernet-key`, `admin-initial-password` and `.admin-provisioned` are all `600 cloudron:cloudron` |
| Secret idempotency across restart | sha256 of `secret-key` (`5da8188e…`) and `fernet-key` (`b0164f81…`) identical before and after `cloudron restart`; the second boot logs `existing secret found` for both, and `generating new secret` appears only on the first |
| First-run work runs exactly once | `neutralised the seeded 'admin' account` appears once across both boots. The second boot re-checked the credential, found the seeded password no longer works, and correctly did nothing |
| OIDC sync is idempotent | First boot `created the 'cloudron' identity provider`; second boot `refreshed the 'cloudron' identity provider's connection details and credentials from the current environment`. Addon credentials can rotate, so refresh-every-boot is the intended behaviour rather than a no-op |

Note on the restart check: it exercises the reworked provisioning guard on a real install. The guard
now asks the database whether the seeded credential still works rather than trusting its own marker
file, so a second boot doing nothing is a positive result rather than an absence of one.

One operational note for anyone repeating this: `cloudron exec` failed once immediately after the
restart with `AggregateError [ETIMEDOUT]` against the rig's API. The app was healthy throughout (a
direct HTTPS request returned 200 in the same window), so this is the CLI's own connection, not the
application. Retry it rather than treating it as evidence of anything.

## Ladder status

Gates 0 to 4 all pass against image digest `sha256:7ceeb119…`, package version 0.1.1.

The manifest carrying the new `healthCheckPath` has been applied to a real install and the platform
has polled it: the install's own "wait for health check" phase completed against
`/api/v1/public/server_settings`, and the platform's stored manifest and reported state read back as

```
healthCheckPath : /api/v1/public/server_settings
version         : 0.1.1
memoryLimit     : 1610612736 (1.50 GiB)
health          : healthy
runState        : running
```

That also means the application is now running at the **shipped** memory limit rather than the 2 GiB
the test install was created with, so the sizing verdict below describes the configuration that
actually ships.

## Gate 4: memory. PASS at `memoryLimit` 1.5 GiB

The application's primary store is the platform's PostgreSQL addon, in its own container, and nothing
inside this cgroup is memory-mapped. `memory.peak` is therefore the counter the verdict is read
against, and the 80 per cent rule applies as written. The page cache in this cgroup stayed between 11
and 60 MiB throughout, which confirms it is not expanding to fill the limit the way a memory-mapped
store's would.

**Measured against the shipped limit, not the installed one.** The test install was created with 2 GiB
while the manifest ships 1.5 GiB, so the loaded run below was taken with the cgroup's `memory.max`
set to the manifest's exact value, and restored afterwards. Sizing a package by measuring a limit it
does not ship is how a verdict ends up describing something nobody installs.

| Invariant | Idle | Loaded (worst case, at the shipped 1.5 GiB) |
| --- | --- | --- |
| `memory.current` | 202 MiB | 364 MiB |
| `memory.peak` | 266 MiB | **384 MiB**, 25 per cent of the limit |
| `memory.stat anon` | 189 MiB | 279 MiB |
| page cache (`file`) | 11 MiB | 60 MiB |
| `memory.swap.current` | 0 | 0 |
| `oom_kill` | 0 | **0** |
| Application process RSS | 241 MB | 297 MB |
| Health after the run | green | green, including the database-backed path in 1.2 s |

### The load recipe, so it can be repeated

Two phases, the second deliberately overlapping the first, because the peak of this application is
concurrent ingest rather than any single operation:

1. **Sequential ingest:** 30 activities of 1500 track points each, uploaded one at a time through the
   API-key path. All returned 201. This barely moved the needle: peak rose from 266 to 267 MiB.
2. **Concurrent ingest:** 18 activities of 1500 points, three at a time. Peak 298 MiB.
3. **Worst case:** a bulk import of 20 activities of **3000** points each, triggered and left to run
   in the background, **while** 18 more concurrent uploads were driven against the same instance.
   Peak 384 MiB.

The library finished at 141 activities, up from 1, so the load demonstrably landed rather than
silently failing, which is the check that stops a low peak being mistaken for a good result.

### Verdict

All three checks hold:

- `oom_kill` was zero for the entire run, the application stayed healthy throughout, and the load is
  verifiable in the data rather than only in the status codes.
- The loaded high-water mark is **384 MiB, 25 per cent of the 1.5 GiB limit**, comfortably inside the
  80 per cent bound.
- The worst-case bound clears with real margin. The observed peak already includes the heaviest
  combination this application offers. Adding room for a pathologically large single activity, a
  multi-hour recording at ten to twenty times the size of these fixtures, and a busier multi-user
  instance on top, puts a defensible worst case near 700 to 800 MiB. That leaves roughly 750 MiB of
  headroom against the shipped limit.

`memoryLimit` therefore stays at 1610612736 (1.5 GiB). It is not changed as a result of this gate,
which is worth stating explicitly: the provisional value was set by reasoning before any measurement,
and the measurement agreed with it rather than the value being retrofitted to the measurement.

### Host conditions, recorded because they qualify the numbers

The first attempt at this gate was **abandoned rather than recorded**. The rig was running at a load
average of 42 across 12 cores, with an unrelated application's bundled analytical database consuming
6 days 12 hours of CPU time, and uploads could not complete. Numbers taken then would have been
unrepresentative in an unknowable direction, and a sizing verdict is exactly the kind of figure later
readers trust without re-reading its caveats.

The run recorded above was taken after that was resolved, at a load average between 12 and 16 with
roughly a quarter of the host's CPU idle and 30 GiB of its memory free. Still a shared host, so it is
stated rather than glossed. CPU contention lengthens each request and therefore *increases*
concurrency overlap, which biases a memory reading upward rather than down: the figures above are if
anything conservative.

### An operational note for anyone repeating this

`cloudron exec` becomes unreliable while the box is busy, failing with `AggregateError [ETIMEDOUT]`
or simply hanging past a two minute timeout. Every sampling call here has its own timeout and is
retried, and one measurement cycle was discarded for it. That is the documented behaviour rather than
a fault, but it has a sharp edge worth naming: a hung `exec` that returns an empty string turns into
a *silently wrong* reading rather than an obvious error. One login attempt in this run failed with a
422 for exactly that reason, the password having been read as empty, and it would have been easy to
misread as an authentication problem with the application.

## Gate 3: update and restore. PASS

Both legs run for real against the platform: an actual `cloudron update` between two built package
versions, and an actual in-place restore from an actual backup. Neither was simulated, and the
instance held Gate 2's data throughout, so the data is the canary rather than an afterthought.

Baseline captured before either operation: secret digests, modes and ownership, per-store counts, and
the sha256 of every stored file.

| Invariant | Update, 0.1.0 to 0.1.1 | Restore, in place from backup |
| --- | --- | --- |
| `secret-key` sha256 | `2e0e57b0…` unchanged | `2e0e57b0…` unchanged |
| `fernet-key` sha256 | `4fb4fbfe…` unchanged | `4fb4fbfe…` unchanged |
| Secret modes | all `600 cloudron:cloudron` | all four files `600 cloudron:cloudron`, re-asserted by the boot |
| Boot path | `existing secret found` twice, `generating new secret` zero times | same |
| Which build is serving | boot logs `package_revision=0.19.0-5`, so the image really was swapped | same revision after restore |
| Activities / gear / weight / users / API keys | 1 / 1 / 1 / 2 / 1, all unchanged | 1 / 1 / 1 / 2 / 1, all unchanged |
| Stored files | user image `9785fa0c…` and activity file `94b62fc4…` unchanged | both unchanged |
| Identity provider | intact | intact, and `sso_enabled` still true |
| Platform task | update task completed, backup taken automatically first | backup and restore tasks both completed |

### The restore was made falsifiable

A restore that changes nothing proves nothing: if the data had simply never been touched, every count
above would still have matched. So a marker was planted **after** the backup was taken, a second
weight entry of 99.9 on a different date, and the restore was checked for both directions at once:

- The marker is **gone** after the restore, so the restore genuinely replaced state rather than
  no-opping.
- The pre-backup entry of 78.4 **survived**, so it replaced state with the right state.

That pairing is what turns "the app came back up" into evidence.

### The encrypted-data canary

`FERNET_KEY` byte-identity is the invariant this package cares most about, because the key encrypts
Strava and Garmin tokens, MFA secrets, identity-provider link tokens and the identity provider's own
client secret, and there is no upstream re-encryption tool. It is unchanged across both operations,
and independently corroborated: the provisioned identity provider still works after the restore,
which it could not if its stored client secret had been encrypted under a key that no longer existed.

### What the gate taught

**A package version bump is enough to exercise the update path.** The reference allows two release
candidates of the same upstream version, and that is what was used: 0.1.0 to 0.1.1, same upstream
0.19.0. What is being proven is the package's own update path, and waiting for an upstream release to
prove it is how an update drill ends up permanently owed.

**Bake the packaging revision into the image.** A running container could not previously say which
build it was; the platform reports its own app version and the manifest pins a digest, but neither
answers that question from inside. A `build-info` file written at build time and logged on the first
line of the boot makes the update leg self-evidencing: the log says which revision is serving, rather
than the digest having to be correlated by hand.

**`cloudron restore` takes `--backup`, not `--backup-id`.** A small thing, recorded because the
obvious guess fails and the error message is the only hint.

## Gate 2: functional flows. PASS

Flows enumerated before testing, chosen so that every declared addon is exercised by at least one of
them, and driven through the public origin with real credentials rather than against internals.

| Flow | Proof |
| --- | --- |
| A. Activity upload, browser session | `POST /activities/create/upload` 201; parsed to 218 m over 15.0 s with the track's own name; visible in the user's activity list; `GET /activities_streams/activity_id/1/all` returns **6 stream series of 4 waypoints each**; the stored file's sha256 is **identical** to the uploaded fixture |
| B. Health weight entry | `POST /health/weight` 201, then `GET /health/weight` returns the row with the value as sent. This is the surface a future weight bridge would target |
| C. Gear | `POST /gears` 201, then `GET /gears` lists it back with the nickname as sent |
| D. Profile image | `POST /profile/image` 201; `photo_path` on the profile changes from null to the stored path; the stored file's sha256 is **identical** to the uploaded PNG |
| E. Rate limiting (redis addon) | 14 requests to a `SENSITIVE`-limited route returned **ten 307s then four 429s**, matching the documented ten per minute exactly |
| F. Mail (sendmail addon) | The addon's SMTP host answered `EHLO` with 250, advertised `AUTH`, and the addon supplied a username; the conversation completed and closed cleanly |
| G. Device pipeline, API key only | A minted key with `activities:upload` scope uploaded a **TCX** file with no browser session: 201, parsed to 50 m over 20.0 s, stored byte-identical. Different parser from flow A, so both file-format paths are proven |
| H. Background scheduler | Thumbnails were generated for both activities without any user action, which exercises the in-process scheduler and the image pipeline |

| I. Delete | `DELETE /activities/{id}/delete` 200; the activity leaves the list, and **both** its stored file and its generated thumbnail are removed from disk. Deleting does not orphan artefacts under `/app/data` |
| J. Server-side tile fetch and reverse geocoding | An activity over central Edinburgh produced a 620 kB thumbnail with full OpenStreetMap detail, and the card reports "City of Edinburgh, United Kingdom". Both are outbound calls made by the application itself |

### Addon and service coverage

| Component | Exercised by |
| --- | --- |
| postgresql | Every flow; activities, users, gear, weight and settings all round-trip |
| redis | Flow E, proven at the storage layer rather than by behaviour alone |
| sendmail | Flow F |
| localstorage | Flows A, D and G, all three verified byte-for-byte under `/app/data` |
| oidc | Gate 1 |
| uvicorn process and in-process scheduler | Flows A to G, and H respectively |

### What the flows taught

**Rate-limit state is genuinely in the addon, and it is keyed by the real client address.** The Redis
key created by flow E is `LIMITS:LIMITER/<client-ip>//api/v1/public/idp/login/cloudron/10/1/minute`.
Two things follow. The limiter is not silently falling back to process-local memory, which is the
failure the application warns about at startup and which no amount of observing 429s would
distinguish. And the address in the key is the **external client address**, not the platform's
internal proxy address, which proves the forwarded-header handling and `TRUSTED_PROXIES` are correct
end to end. A package that got that wrong would rate-limit every user on the rig as though they were
one client.

**Mail was verified by conversation, not by delivery, and deliberately so.** The seeded admin account
carries an address at upstream's own domain, so triggering a password reset would have sent mail to a
third party. Reachability, `EHLO`, advertised `AUTH` and the addon's credentials together prove the
wiring this package is responsible for. An end-to-end delivery test needs an address the operator
owns and is left as an explicit, named gap rather than quietly skipped.

**`/docs` and `/openapi.json` are served publicly, without authentication.** Not a data exposure, and
it is upstream's default rather than something this package configures, but it does publish the
complete API surface of every installation. Worth knowing, and worth stating in the operator
documentation rather than being discovered.

**Two route-shaped traps for anyone testing this API.** `PUT /profile/photo` is named like an upload
and is actually *Delete Profile Photo*, taking no body and returning 204 whether or not a photo
exists; the upload is `POST /profile/image`. And because the SPA's catch-all answers any unmatched
path with `index.html` and a 200, a mistyped API path looks like a success. Read `/openapi.json`,
which this application serves and which is authoritative, rather than guessing paths. Doing that from
the start would have saved three wrong turns in this gate alone.

**A near-miss worth recording, because it nearly became a false finding.** The first activity
thumbnails rendered as a route drawn on flat pale blue with no map under it, which reads exactly like
a failed server-side tile fetch, and this package rewrites a Content-Security-Policy, so there was a
plausible culprit to hand. The thumbnails were correct. The test fixture is a track in the North Sea,
and open water is what OpenStreetMap looks like there. Re-running with a route through central
Edinburgh produced a 620 kB thumbnail full of streets. The lesson is cheap to state and was nearly
expensive: before blaming the package for a blank map, check whether the coordinates are somewhere
that looks like anything. Test fixtures placed in plausible-sounding empty ocean make poor evidence.

### Not exercised, and why

Hairpin behaviour is not applicable here: nothing in the backend calls the application's own public
origin, so no `/etc/hosts` fallback was needed or added. `ENDURAIN_HOST` is used for the JWT issuer
and audience and for the frontend's API base, not for server-side self-calls. Recorded because
"fallback unused" is evidence that the packaging can stay simpler.

FIT files are not covered. GPX and TCX are, through two different parsers, but no valid FIT fixture
was available to synthesise by hand. The dependency is present and imports at build time; the parse
path itself is unproven and is named here rather than implied.

## Gate 1: auth and SSO. PASS

Closed after a real Cloudron user signed in through a real browser and landed inside the
application. Three defects were found and fixed on the way, all of them in the half of the flow
that no HTTP request from outside can reach.

| Invariant | Proof |
| --- | --- |
| Sign-in works end to end | A real Cloudron user completed the browser flow and landed signed in, confirmed by the operator |
| The callback path matches the manifest | Observed in the app's log: `GET /api/v1/public/idp/callback/cloudron?code=…&state=…&iss=…` returning 307, exactly the `loginRedirectUri` the manifest declares. The platform's own addon setup logs the same path back |
| The whole sequence, in order | `GET /public/idp` 200, then `GET /public/idp/login/cloudron` with a PKCE challenge 307, then the callback 307, then `POST /public/idp/session/{id}/tokens` 200 |
| An account exists for the identity | The application's own user list reports two users: the local `admin` account, and a second account created by the sign-in with `access_type=regular`, active, email verified. The session is the application's own, not a proxy artefact |
| SSO does not fence the device pipeline | An upload carrying only `X-API-Key`, no browser session, returns 201 and parses the activity, with SSO active |
| Credential-less access is refused | The same upload with no header, and with an invalid key, returns 401 |
| Public paths stay open | `/api/v1/about`, `/` and `/env.js` all 200 without a session |
| Protected paths stay protected | `/api/v1/profile` and `/api/v1/profile/api_keys` both 401 without a session |
| Local login survives alongside SSO (`optionalSso`) | Login with the generated admin password returns 200 while SSO is enabled; `local_login_enabled` is true |
| The seeded credential is dead | `admin`/`admin` returns 401 |
| No unintended proxyAuth | Not declared, and every endpoint above answers directly rather than redirecting to a platform login page |

### The before-and-after that closed it

The same callback request, on the same install, either side of the SSRF fix:

| Time | Request | Result |
| --- | --- | --- |
| Before | `GET /api/v1/public/idp/callback/cloudron?code=…` | **400 Bad Request** (`URL resolves to a non-public address`) |
| After | the same request | **307**, followed by a 200 token exchange |

### Three defects, and why local testing could not see any of them

1. **The provider was created but SSO was never switched on.** The login page draws its SSO button
   only when the server-settings row has `sso_enabled`, and that column defaults to false. The
   provider existed, the public provider endpoint listed it, and the redirect worked when driven by
   hand; a human saw a login form with no button.
2. **The server-side token exchange was blocked by the application's own SSRF guard.** An app
   container reaches the dashboard over the internal bridge, so the issuer hostname resolves inside
   the container to an RFC1918 address (measured: `172.18.0.1`) while resolving publicly from
   everywhere else. Every browser-facing step therefore succeeded and only the token exchange
   failed. Fixed by allowlisting the issuer hostname alone, never the bridge CIDR.
3. **The frontend was not being served at all** (recorded under Gate 0's rerun): symlinked assets
   were refused by Starlette, so the page loaded and the application was blank.

The common thread is worth stating plainly, because it shaped the rest of this package's testing.
Every one of these lived in a place an HTTP request from outside cannot reach: a database column, a
DNS answer that differs by vantage point, and a static-file resolver's security check. A gate that
only issues requests will pass while any of them is broken.

## Superseded: Gate 1 while it was open

Everything that can be established without a human is below. The gate reference is explicit that a
real sign-in by a real user in a real browser is required and that the gate may not be closed on
command-line evidence alone, so it stays open.

Declared architecture, written down before testing: the `oidc` addon feeding the application's own
native OpenID Connect login, no `proxyAuth` anywhere, `optionalSso: true`, predicted callback
`/api/v1/public/idp/callback/cloudron`.

| Invariant | Proof |
| --- | --- |
| Public paths stay open with SSO active | `/api/v1/about`, `/` and `/env.js` all return 200 with no session |
| Protected paths are protected | `/api/v1/profile` and `/api/v1/profile/api_keys` both return 401 with no session |
| The provisioned provider is visible to the login page | `GET /api/v1/public/idp` returns 200 and one provider: id 1, name `Cloudron`, slug `cloudron` |
| SSO initiation reaches the platform's own IdP | `GET /api/v1/public/idp/login/cloudron` with a valid PKCE challenge returns 307 to the dashboard's `/openid/auth`, carrying `response_type=code`, `scope=openid profile email`, and a client id and state |
| The callback path matches the prediction | The `redirect_uri` in that redirect is exactly the manifest's `loginRedirectUri` under the app origin, `…/api/v1/public/idp/callback/cloudron`. Observed, not inferred |
| Local login still works beside SSO (`optionalSso`) | `POST /api/v1/auth/login` with the generated admin password returns 200 with a token set |
| The seeded credential is dead on the rig too | the same endpoint with `admin`/`admin` returns 401 |
| API keys can be minted | `POST /api/v1/profile/api_keys` returns 201 with step-up (current password) supplied |
| **SSO does not fence the device pipeline** | `POST /api/v1/activities/create/upload` with only an `X-API-Key` header, no browser session, returns 201 and parses the activity |
| The same path is refused without a credential | no header returns 401; an invalid key returns 401 |

Two observations worth recording even though the gate is on course to pass.

`GET /api/v1/public/idp/login/{slug}` returns **422 without PKCE parameters**, which is the
application enforcing OAuth 2.1 on its own frontend rather than a fault. Anyone testing this route by
hand will hit that 422 first and should not read it as a broken provider.

The application demands PKCE from its own client but does **not forward** `code_challenge` to the
upstream provider: the outbound authorize URL carries `state` and a client id and no challenge. That
is coherent, because the package is a confidential client holding a client secret from the addon and
the PKCE exchange protects the app's own token issuance step, but it is upstream's design choice
rather than something this package configures, and it is the kind of detail worth knowing before
someone reports it as a finding.

A note on method, since it produced a false positive here: a guessed API path returned **200 with
the SPA's HTML**, because the single-page application's catch-all answers any unmatched path. A 200
from this app is therefore not evidence that a route exists. Check the content type, or read the
router, before believing a status code.

## Local evidence, gathered before first install

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
