# ADR 0001: Build from source on cloudron/base

- Status: Accepted
- Date: 2026-08-01

## Context

Endurain publishes its own container image, but three things about it are awkward for a Cloudron
package. It is built on Alpine and linked against musl libc, while Cloudron's platform tooling, the
file manager, the web terminal, the log viewer, depends on utilities that `cloudron/base` provides
on a glibc, Ubuntu-derived image; a Cloudron app's final build stage has to be `cloudron/base` for
that tooling to work, whatever earlier stages do. The image is also ENTRYPOINT-only: it declares an
`ENTRYPOINT` and no `CMD`, where Cloudron packages are expected to start with `CMD` rather than
`ENTRYPOINT`, so that the platform can override the start command without also overriding a
baked-in entry script. And it runs as a fixed, image-defined `appuser` rather than a UID Cloudron
controls, where Cloudron expects to be able to reassert ownership under its own user on every boot.

The registry hosting the published image has also moved twice in about a year, from
`ghcr.io/joaovitoriasilva` to `ghcr.io/endurain-project`; both are stale at the time of this
decision, and the canonical location has since become Codeberg's own container registry, under the
project's Codeberg organisation. Depending on the container image at all, then, means depending on
wherever it currently lives, which has not been a fixed point. The project's Codeberg source
repository, `https://codeberg.org/endurain-project/endurain`, is the more stable dependency of the
two: a pinned git tag does not move even if the registry hosting built images does again. Taken
together, the upstream image is not a base this package can extend; at minimum its entrypoint, its
UID and its base OS would all need replacing, which is most of the work of a from-source build in
any case.

## Decision

Build Endurain from source, from the pinned upstream git tag, onto `cloudron/base`, rather than
starting from or adapting the upstream image. The build is a two-stage `podman` build, with both
stages starting from the pinned `cloudron/base` digest. It clones the exact upstream tag pinned in
`ARG ENDURAIN_VERSION`, mirrored in the manifest's `upstreamVersion` field, and verifies that the
tag resolves to the pinned commit before doing anything else with the checked-out tree; a mismatch
fails the build rather than silently building a moved tag.

Inside that tree, the Python backend is installed with `uv`, pinned to the exact version,
`0.11.18`, that the project's own `required-version` in its `pyproject.toml` demands, fetched by
URL and verified against a pinned SHA256 rather than installed from a package index. `uv` then
manages its own CPython 3.13 interpreter and virtual environment inside the copied source tree,
using `uv sync --frozen` against the project's own lockfile, so the interpreter Endurain runs under
is the one `uv` fetches, not whatever Python happens to be preinstalled on `cloudron/base`. The
frontend needs Node 24 and `cloudron/base` provides only Node 22.14.0, which is below the floor
upstream's `package.json` declares, so the builder stage fetches the Node 24 tarball by pinned URL
and verifies it against a pinned SHA256, exactly as it does for `uv`. That is a builder-stage
addition only: the runtime stage never needs Node, because uvicorn serves the built static
directory. The pinned Node version bundles npm 11, which matters independently of the version
floor, since the base's own npm 10 rejects upstream's lockfile outright.

## Alternatives considered

Carrying the upstream image's musl runtime in place, replacing only its entrypoint and its user,
was considered and rejected. It still leaves an Alpine and musl runtime beneath Cloudron's
glibc-oriented platform tooling, and the entrypoint and UID contract would need replacing
regardless, which is most of the adaptation work this decision already requires; carrying a whole
musl application runtime turns out to be heavier, in image size and in ongoing maintenance, than
building from source directly onto `cloudron/base`, for no offsetting benefit once the entrypoint
and UID work has to happen anyway.

Copying the upstream image's Python virtual environment onto `cloudron/base`, instead of rebuilding
it, was also considered and rejected. A virtual environment built against Alpine's musl libc and
its compiled wheels is not portable onto an Ubuntu-derived, glibc image; native extensions would
need rebuilding regardless, which removes the appeal of copying it in the first place. Building the
environment fresh with `uv`, directly on `cloudron/base`, from the project's own lockfile, is both
simpler and the only option that reliably works.

## Consequences

The package tracks upstream source tags rather than upstream container tags, so a version bump
means changing `ARG ENDURAIN_VERSION` and the expected commit and then rebuilding; it does not
depend on the upstream image registry being reachable, or continuing to exist at all. The build
takes longer than pulling a prebuilt image would, since it compiles the frontend and resolves the
Python environment on every build rather than reusing upstream's own build output. This package is
also responsible for its own base-image security posture above `cloudron/base` itself, since none
of the upstream image's own layers are reused; patching `cloudron/base` remains Cloudron's job, but
everything installed on top of it is this package's. Pinning `uv` by version and SHA256, rather
than trusting whatever a package index would resolve to, means that pin has to be revisited
deliberately when upstream's `required-version` moves; it is recorded in `AGENTS.md`'s "Pinned
upstream" section, not only in the Dockerfile, so there is one place to check it.
