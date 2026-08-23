# Endurain for Cloudron

This repository packages Endurain as a Cloudron application: a `CloudronManifest.json`, a container
build from upstream source, and the glue that maps Cloudron's managed services onto Endurain's own
configuration.

## What Endurain is

[Endurain](https://endurain.com) is a self-hosted fitness tracking platform for endurance sports:
running, cycling, hiking, swimming, gym sessions and more. It accepts FIT, GPX and TCX activity
uploads, synchronises with Strava and Garmin Connect, tracks gear and body composition, and lets
users follow one another within a single instance. It is developed in the open at
[codeberg.org/endurain-project/endurain](https://codeberg.org/endurain-project/endurain).

## What this package provides

This package runs Endurain on Cloudron as a single process, uvicorn serving both the API and the
built frontend, and connects it to the following Cloudron addons.

| Addon | Used for |
|---|---|
| `postgresql` | The application database |
| `redis` | Rate-limit and authentication-lockout state (upstream treats this as disposable) |
| `sendmail` | Outgoing mail, for example password resets |
| `oidc` | Optional Cloudron single sign-on, fed into Endurain's own OpenID Connect login |
| `localstorage` | Persistent storage under `/app/data`: uploaded activity files and package secrets |

Single sign-on is optional rather than mandatory. Cloudron's `oidc` addon provisions an identity
provider record inside Endurain itself, so the platform login appears as an ordinary "Cloudron"
option on Endurain's own login page, alongside local accounts. Nothing about the app's
authentication, its JSON API, its mobile clients or its device uploads sits behind Cloudron's
`proxyAuth`; see [the auth topology decision
record](docs/decisions/0002-auth-topology-native-oidc-no-proxyauth.md) for why.

Upstream Endurain seeds a live `admin` / `admin` account on its first database migration. This
package replaces that password with a generated one before the application ever serves a request,
so no installation is reachable with the well-known default; see [the secrets and
admin-neutralisation decision record](docs/decisions/0003-secrets-and-admin-neutralisation.md).

Endurain's long-lived API keys, available since upstream 0.18.0, let devices and companion apps,
such as Gadgetbridge, OpenTracks and FitoTrack, upload activities directly to an instance without a
browser session; see [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Installation

### From the Cloudron dashboard

1. Open the Cloudron dashboard and go to **App Store**.
2. Use the **Add custom app** dropdown and choose **Community app**.
3. Paste the raw URL of this package's `CloudronVersions.json`:

   ```
   https://raw.githubusercontent.com/OrcVole/endurain-cloudron/main/CloudronVersions.json
   ```

4. Follow the prompts to choose a location and complete the install.

An app installed this way stays on the community channel: Cloudron polls that URL and updates the
installation automatically whenever a new version is published here, the same as an app installed
from the official App Store.

### From the command line

With the `cloudron` CLI installed and logged in to the target Cloudron instance:

```
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/endurain-cloudron/main/CloudronVersions.json \
  --location endurain.example.com
```

Replace `endurain.example.com` with the subdomain to install under.

## First run

Sign in with the username `admin`. The initial password is generated during installation and
written to `/app/data/.secrets/admin-initial-password`; open it from the Cloudron File Manager
(**Files**, `.secrets`, `admin-initial-password`). Change that password from within Endurain under
**Settings** immediately after signing in, then delete the file.

## Configuration notes

Single sign-on is optional: installing with or without the `oidc` addon configured both work, local
Endurain accounts keep working either way, and the built-in `admin` account stays local regardless
of SSO.

Strava sync is linked per user, from within Endurain under **Settings**. Each user registers their
own free Strava API application on Strava's developer site and enters its client ID and secret
there; those values, and the tokens that follow from them, are stored encrypted. Garmin Connect
sync is likewise linked per user under **Settings**, with the resulting credentials and tokens also
stored encrypted.

Reverse geocoding uses the public Nominatim service by default. The map tile server is configurable
by the instance admin under Server settings, so a self-hosted or commercial tile provider can
replace the default.

Programmatic clients that sign in to the JSON API, as opposed to browser sessions and as opposed
to API-key uploads, must send an `X-Client-Type: mobile` header on their requests, including
login. Endurain treats a missing header as invalid credentials and returns a 401, which is worth
knowing before assuming a wrong password is the cause; see [the auth topology decision
record](docs/decisions/0002-auth-topology-native-oidc-no-proxyauth.md). The API-key upload
endpoint below is the exception: it authenticates with the key alone.

API keys, created under **Settings, API keys**, let devices and companion apps upload activities
without a browser session. Point Gadgetbridge, OpenTracks, FitoTrack or similar at:

```
https://endurain.example.com/api/v1/activities/create/upload
```

with the key in an `X-API-Key` header. See [`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md) for
device-specific notes.

## Links

- Cloudron forum announcement and discussion: <https://forum.cloudron.io/topic/15768/endurain-community-package-now-available>
- Upstream project: <https://codeberg.org/endurain-project/endurain>
- Upstream issue raised by this packaging work: <https://codeberg.org/endurain-project/endurain/issues/858>

## Known issues

Two faults in the application itself, found while packaging and verified on a real installation, are
worth knowing about before you rely on this for anything important. Both are reported upstream with
evidence in [`docs/FOR-UPSTREAM.md`](docs/FOR-UPSTREAM.md); neither is caused by the packaging, and
neither can be fixed from outside the application.

**Uploading several activities at once can wedge the instance.** Concurrent uploads can leave database
connections stranded in an open transaction, after which every request that needs the database waits
indefinitely: no login, no upload, no page that reads anything. The application does not recover on
its own. Restarting it clears the condition immediately and loses nothing.

This package mitigates the operational half of that. Its health check reads the database rather than
returning a static response, so an instance in this state is detected and restarted automatically by
the platform instead of sitting there looking healthy (see
[ADR 0004](docs/decisions/0004-health-check-touches-the-database.md)). The underlying leak still needs
an upstream fix. If you are importing a backlog, upload a few at a time rather than in parallel.

**Two activities sharing a start time break later uploads at that timestamp.** The duplicate check
assumes at most one activity per start time and raises an error when it finds two, which the upload
path itself can produce. Once that has happened, any further upload with that same start time fails
with a server error until one of the duplicates is deleted.

**The API documentation is public.** `/docs` and `/openapi.json` are served without authentication, as
they are upstream by default. No data is exposed, but every installation publishes its complete API
surface. There is no supported way to turn that off from the packaging layer.

## Backups

Backups are entirely platform-native; the package adds no `backupCommand` and no `persistentDirs`.
Cloudron's `postgresql` addon dumps the application database logically as part of the regular app
backup, and `/app/data`, which holds uploaded activity files together with the package's generated
secrets, rides the standard file backup provided by the `localstorage` addon.

Redis holds only rate-limit and authentication-lockout state, which upstream itself documents as
disposable. It is not specially preserved: a fresh, empty Redis simply lets that state rebuild from
normal traffic after a restore.

## Building from source

The published image is not a repackage of an upstream container; it is built from Endurain's source
at a pinned tag, onto `cloudron/base`. The build is exercised with rootless `podman`:

```
podman build \
  --build-arg ENDURAIN_VERSION=0.19.0 \
  --build-arg ENDURAIN_COMMIT=bc88c2a72c286e1dc1eae636ef14550b696c3fe2 \
  -t endurain-cloudron:local .
```

`ENDURAIN_VERSION` and `ENDURAIN_COMMIT` are a pinned pair: the upstream version number, without
its `v` prefix, matching the manifest's `upstreamVersion`, and the exact commit that version's git
tag must resolve to. The build clones tag `v${ENDURAIN_VERSION}` from the upstream Codeberg
repository and verifies the checked-out commit against `ENDURAIN_COMMIT` before doing anything else
with the tree; a mismatch, for instance a moved or re-tagged release, fails the build rather than
silently building different code than the one that was reviewed. See [the build-from-source
decision record](docs/decisions/0001-build-from-source-on-cloudron-base.md) for the reasoning.

## Repository map

| Path | Contents |
|---|---|
| `docs/decisions/` | Decision records for the build method, the auth topology and the secrets handling |
| `docs/PACKAGING-NOTES.md` | The verified-versus-assumed log for this package, newest entry first |
| `docs/DEBUGGING.md` | Gate-ladder evidence: the status codes, hashes and log lines behind claims made elsewhere |
| `docs/INTEGRATIONS.md` | Device uploads, Strava and Garmin linking, and integrations planned but not yet shipped |
| `docs/FOR-CLOUDRON.md` | Platform observations from this packaging round, written for Cloudron itself |
| `docs/FOR-UPSTREAM.md` | Notes for the Endurain project, on points that would help every deployment method |
| `test/` | Release-gate tooling, including the secret and anonymity scanner run before every publish |

## Licence

This package is distributed under AGPL-3.0-or-later, matching Endurain's own licence. It is an
unofficial community package: it is not produced, reviewed or endorsed by the Endurain project.
"Endurain" is a registered trademark of its author; the name and logo are used here nominatively,
to identify the software this package runs, for a free, non-commercial community package, in line
with the project's
[`TRADEMARK.md`](https://codeberg.org/endurain-project/endurain/src/branch/master/TRADEMARK.md).

## Support

Packaging issues, meaning anything about how this package builds, configures or runs Endurain on
Cloudron, belong on this repository's issue tracker at
[github.com/OrcVole/endurain-cloudron](https://github.com/OrcVole/endurain-cloudron). Bugs in
Endurain itself, meaning anything that would also reproduce outside Cloudron, belong upstream at
[codeberg.org/endurain-project/endurain](https://codeberg.org/endurain-project/endurain).
