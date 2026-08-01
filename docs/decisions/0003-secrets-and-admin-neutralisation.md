# ADR 0003: Secrets and admin-account neutralisation

- Status: Accepted
- Date: 2026-08-01

## Context

This package has to generate and manage two categories of sensitive material that behave very
differently if something goes wrong, a signing key that can be rotated at the cost of an
inconvenience, and an encryption key that cannot be rotated at all without upstream tooling that
does not exist yet. It also inherits a seeded administrator credential from upstream that is public
knowledge from the moment the schema exists.

`SECRET_KEY` signs Endurain's sessions and tokens. If it changes, existing sessions and tokens stop
validating and users have to log in again: a rotate-safe failure, unwelcome but not destructive.
`FERNET_KEY` is different in kind, not degree. It encrypts data at rest: Strava OAuth tokens, the
per-user Strava API client credentials that Endurain's per-user Strava integration requires, Garmin
Connect tokens, MFA setup secrets, identity-provider link tokens, and the map tile server's API
key. Upstream ships no re-encryption tool, so there is no supported way to decrypt existing rows
under an old `FERNET_KEY` and re-encrypt them under a new one. Losing byte-identity on this key
does not just log users out; it makes every one of those secrets permanently unreadable, and
silently so, since decryption failures surface per-row rather than as one obvious event.

Separately, upstream's first database migration seeds a live `admin` / `admin` account. That
credential is documented upstream and therefore public knowledge as soon as the schema exists, so
an installation is briefly reachable with it unless something intervenes before the app first
serves a request.

## Decision

Generate `SECRET_KEY` and `FERNET_KEY` once, on first run only, into `/app/data/.secrets`
(directory mode `0700`, file mode `0600`), and re-assert ownership and both modes on every boot,
not only on first run, because a restore can and does reset them. Neither key is ever regenerated
if it is already present; a missing key on anything other than a genuinely first run is treated as
a fault to investigate, not a reason to generate a replacement.

Endurain reads secrets through its own `<VAR>_FILE` convention, `SECRET_KEY_FILE` and
`FERNET_KEY_FILE`, rather than as inline environment variable values. The package copies the
generated files from `/app/data/.secrets` into `/run/secrets` on every boot and points the `_FILE`
variables at those copies, rather than at `/app/data/.secrets` directly, because the application's
own safe-path checks for file-based configuration do not include `/app/data` among their allowed
roots; `/run/secrets` is regenerated from the `/app/data/.secrets` originals every time, so the
originals remain the single source of truth. `FERNET_KEY` byte-identity, meaning the file's exact
contents are unchanged, is treated as a standing gate, checked across an ordinary restart, across a
package update, and across a restore from backup, on the reasoning that any of the three is a
plausible place for a key to be silently regenerated or lost, and only one of them is likely to be
exercised often in normal operation.

Upstream's seeded `admin` / `admin` account gets a generated password before the application ever
serves its first request, written using Endurain's own password hasher so the credential is
indistinguishable, from the database's point of view, from one a user set themselves. The generated
plaintext password is written once to `/app/data/.secrets/admin-initial-password` for the operator
to read and then delete. This replacement is marker-guarded: it runs once, and a marker records
that it has run, so that an operator who has since changed the `admin` password themselves never
has it silently overwritten by a later boot. The marker itself is what is checked, not merely
whether the current password looks like the generated one, since an operator could plausibly change
it back to something that happens to collide. Failure of this step on first run fails the boot
loudly; an app that came up successfully but silently left `admin` / `admin` live would be a worse
outcome than one that refuses to come up at all until the fault is fixed.

Whether there is anything to neutralise is decided by testing the seeded credential itself, not by
inspecting how the account is labelled. Provisioning asks the application's own password verifier
whether the publicly known seeded password still opens the account, and neutralises any account
that still holds it whatever its recorded access level says. The first implementation instead
compared the account's access level against the application's access-level enumeration, which was
wrong in a way that failed silently and in the dangerous direction: the value returned by the
application's own read schema is a plain string while the enumeration is not a string enumeration,
so the comparison never matched, every install took the "nothing to neutralise" branch, and the
marker was written recording that the work had been done. The smoke test caught it by asking the
only question that settles the matter, which is whether `admin` / `admin` can still log in. The
general rule this package now follows is that a security guard should test the condition it
actually cares about, because a guard phrased as a proxy for that condition can be wrong without
anything appearing to go wrong.

Following that rule to its conclusion changes what the marker file is for. The credential check now
runs on every boot rather than only when the marker is absent, and the marker records that
provisioning has run rather than standing as proof that the credential is safe. The distinction is
not academic: the marker lives on the data volume while the fact it would vouch for lives in the
database, and those are separate persistence domains. A database restored to a point before
neutralisation, or an addon reprovisioned behind a surviving volume, leaves a stale marker
asserting that the seeded credential was dealt with when it is live again. One query per boot
removes the whole class of question. Where the two disagree the package says so in its log and
replaces the password rather than quietly repairing it, because both plausible causes are things an
operator should know about. The consequence worth stating plainly is that an operator who
deliberately sets the admin password back to `admin` will find it replaced on the next boot: that is
intended, since the whole point is that this particular password is public knowledge.

The order of the two writes is also deliberate. The password file is written before the database
commit, not after. `upsert_password_hash()` commits immediately, so writing the file afterwards
leaves a failure mode that locks the operator out of their own installation: a committed password
that exists nowhere readable. In the chosen order both failure modes are recoverable. A failed file
write aborts the boot with the seeded credential still in place, which is bad but obvious and
fixable; a failed commit leaves a file naming a password that was never set, and the next boot finds
the seeded credential still live, regenerates, and overwrites it.

`SECRET_KEY` is validated on every boot in the same way `FERNET_KEY` is, and for the same reason.
The seeding test is only "exists and is non-empty", which cannot distinguish a complete key from a
partial one, so an interrupted first write leaves a short value that every later boot accepts as
already seeded. A truncated `FERNET_KEY` announces itself by failing to load; a truncated
`SECRET_KEY` does not fail at all, it silently weakens the key that signs every session token, which
is precisely what makes it worth an explicit check. Neither key is ever regenerated in response to
failing its check.

## Alternatives considered

Letting the operator set both keys through install-time configuration fields, instead of generating
them, was considered and rejected for `FERNET_KEY` and `SECRET_KEY` alike. It moves a step that
needs to be exact, an operator pasting or mistyping a key, into the one place a mistake is least
recoverable, first install, for no real benefit over generating a strong key automatically.

Neutralising the seeded admin account by disabling it, rather than setting a generated password on
it, was also considered and rejected. Cloudron's own first-run flow expects a working credential to
hand to the operator, matching how other seeded-admin packages on the platform behave, and a
disabled account would need a separate, non-standard recovery path.

## Consequences

There is a standing, explicit gate: prove `FERNET_KEY` byte-identity across restart, update and
restore, every time any of the three is exercised, recorded as ongoing evidence in
`docs/DEBUGGING.md` and `docs/PACKAGING-NOTES.md` rather than treated as settled once and
forgotten. Because there is no upstream re-encryption tool, this package cannot offer key rotation
for `FERNET_KEY` as a feature; that gap is a candidate for `docs/FOR-UPSTREAM.md` once this round's
notes are gathered. The marker guard means a support request along the lines of "the admin password
reset itself" should be treated as a bug in the marker check, not as expected behaviour, and
investigated as such. Every boot also does slightly more work, re-asserting ownership and modes on
`/app/data/.secrets` and refreshing the `/run/secrets` copies, in exchange for the package never
trusting that a previous boot left the filesystem the way it expects.
