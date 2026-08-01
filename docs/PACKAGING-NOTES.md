# Packaging notes (verified-versus-assumed log, newest first)

Anonymised. Box-specific detail lives in the maintainer's local notes, not here.

---

## 2026-08-01: initial packaging round, recon through local build

Recon at upstream tag v0.19.0, followed by a local compatibility gate and the first
build of the package. Evidence: command output on the packaging workstation; nothing in
this entry is inferred from documentation alone.

**Validated (decisions that held up):**

- **The platform PostgreSQL addon (14.x) runs Endurain v0.19.0.** The full Alembic chain
  from base to head applied cleanly against a throwaway Postgres 14 in 3.2 seconds, the
  application booted against it, `GET /api/v1/about` returned the version JSON, and a
  real login succeeded. Upstream's reference compose pins Postgres 18; nothing in the
  schema chain or the login path needed it.
- **The upstream `_FILE` secret convention accepts `/run/secrets`** (read from
  `core/config.py`: `_is_safe_path()` allows `/run/secrets`, `/var/run/secrets`,
  `/secrets`, and not `/app/data`), which is why the package bridges its persisted keys
  into `/run/secrets` copies at boot.
- **`TRUSTED_PROXIES` is a bare comma-separated string, not JSON.** The field is
  `Annotated[list[str], NoDecode]` with a validator that splits on commas; a JSON array
  would be read as one malformed entry and abort startup. An empty value parses to an
  empty list, so an unset proxy variable is safe.
- **`SMTP_SECURE=false` is a real code path** (`core/apprise.py` builds a plain
  `mailto://` URL), matching a plain SMTP relay port with STARTTLS disabled.

**Surfaced (things that were wrong or missing, and are now fixed):**

- **The seeded `admin`/`admin` login "fails" without an `X-Client-Type` header.** A
  login with correct credentials and no header returns 401 "Not authenticated",
  indistinguishable from a wrong password. Recon had missed the header entirely; the
  package documentation, the smoke test and the integration notes all carry it now.
- **The built frontend ships a placeholder `env.js`** (`frontend/public/env.js`), so a
  symlink farm over the dist directory would have linked it back into the read-only
  image and the boot-time write of the real runtime `env.js` would have failed with
  EROFS. The farm now excludes `env.js` alongside `index.html` and writes both as real
  files. Found in review before the first container ever ran.
- **Upstream pins its build tool hard**: `[tool.uv] required-version = "==0.11.18"`
  refuses any other uv. The build fetches exactly that uv release and verifies its
  sha256 before use; a floating uv would break the build the day the pin moves.
- **Web-session write requests need `X-CSRF-Token`.** The CSRF middleware rejects any
  POST with `X-Client-Type: web` and no matching token header, outside a short exempt
  list. The login response carries `csrf_token` for exactly this purpose; the smoke
  test uses it. API-key uploads are exempt by construction (different auth dependency).
- **Admin neutralisation silently did nothing, and said so in the past tense.** The step
  that replaces the seeded `admin`/`admin` password decided whether there was anything to
  do by comparing the account's access level against the application's access-level
  enumeration. The application's read schema returns that field as a plain string while
  the enumeration is not a string enumeration, so the comparison never matched: every
  install logged "no seeded admin account found; nothing to neutralise", wrote the marker
  recording that the work was complete, and left `admin`/`admin` live permanently. The
  guard now tests the seeded credential itself through the application's own password
  verifier, and neutralises any account still holding it regardless of how that account
  is labelled. Caught by the smoke test asking the only question that settles it, which
  is whether `admin`/`admin` can still log in; it had survived both drafting and review.
  The transferable rule: a security guard should test the condition it actually cares
  about, because a guard phrased as a proxy can be wrong without anything appearing to go
  wrong.
- **A standalone script that reuses the application's ORM inherits the application's
  import side effects.** Provisioning imported only the handful of modules it names, so
  the first query raised `InvalidRequestError: expression 'PasswordResetToken' failed to
  locate a name`: the mapper for the users table resolves its relationship targets
  against the class registry on first use, and the application only ever gets away with a
  partial import because building its router transitively imports the whole model tree.
  Upstream had already solved this for Alembic with an `_import_all_models()` helper that
  globs and imports every `models.py`; the package reproduces that helper rather than
  importing it, because the module it lives in is an Alembic script that is not valid to
  import outside an Alembic run.

**Environment note for anyone smoke-testing locally with podman:**

- **Podman on Fedora and RHEL will mount a read-only directory over `/run/secrets`.**
  Those distributions ship `/usr/share/containers/mounts.conf` containing
  `/usr/share/rhel/secrets:/run/secrets` for subscription management, and podman honours
  it by bind-mounting that path read only, on top of any tmpfs the container asks for at
  `/run`. Any package using the `/run/secrets` `_FILE` convention therefore dies at boot
  with `cp: cannot create regular file '/run/secrets/...': Read-only file system` under a
  local podman run, while being entirely correct on the platform, because Docker does not
  read `mounts.conf`. Mounting an explicit tmpfs at `/run/secrets` shadows the bind and
  restores real behaviour; the smoke test does this and says why.
- **Waiting for a container to finish booting needs `curl --retry-all-errors`.** Rootless
  podman's port forwarder accepts a connection on a published port and then resets it
  while nothing is listening inside the container yet, so curl reports error 56, "Recv
  failure: Connection reset by peer", rather than a connection refusal. `--retry` covers
  only timeouts and 5xx, and `--retry-connrefused` adds refusals alone, so a readiness
  loop built from those two ends on its first attempt, about a second into a boot that
  takes roughly forty seconds. The symptom is badly misleading: assertions fail against a
  container that is up, healthy and merely still starting, and unrelated assertions that
  do not go through the published port pass in the same run.

**Still open:**

- Install-phase health behaviour during a long first-boot migration window on the
  platform: the listener is deliberately not started until migrations and provisioning
  finish, so the platform sees connection-refused during that window. Expected to fall
  within the install-phase grace on an empty database (migrations measured at about
  three seconds); unverified for large restored databases.
- Runtime SQL beyond login and upload paths on Postgres 14: exercised further by the
  gate ladder's functional flows.

---

## <YYYY-MM-DD>: <short title of the round of work>

One paragraph of context: what was being done, why, and what kind of evidence the round produced.

**Validated (decisions that held up):**

- **<The decision>.** What was tested, how, and the observed result that confirms it. Prefer the
  concrete: a status code, a hash, a count, a log line.

**Surfaced (things that were wrong or missing, and are now fixed):**

- **<The finding>.** The symptom first, then the cause established by evidence rather than
  inference, then the fix that landed and where it landed (which file, which ADR).

**Still open:**

- <The question>, and what would settle it. Mark anything unproven as unverified rather than
  writing it as a fact.

---

## Conventions for this file

- Newest first, so the top of the file is always the current state of knowledge.
- Every claim carries its evidence. "It works" is not an entry; "a 4 MiB upload returned 200 and the
  downloaded bytes were sha256-identical" is.
- Distinguish verified from assumed explicitly. An assumption written as a fact is the single most
  expensive thing this document can contain.
- Anything that generalises beyond this application gets harvested into the private field guide at
  the end of the round. This file is the application's record; the field guide is the doctrine.
- Gate ladder evidence tables live in `docs/DEBUGGING.md` or the relevant ADR. This file records what
  the gates taught, not the raw runs.
