[0.2.1]

- Email fix: on installs whose mail certificate carries no name that resolves inside the app's container (for example a wildcard for the primary domain whose public address does not accept mail connections), 0.2.0 left email disabled. The app now still connects to the mail server by its internal name and verifies the certificate against a name the certificate genuinely carries (the concrete name, or "my." under a wildcard). Certificate and hostname verification stay fully on. The boot log now says which host mail connects to and which name it verifies against, or that email is disabled and why. Installs where email already worked are unaffected.

[0.2.0]

- Upstream Endurain 0.19.4 to 0.20.1. Security: fixes six advisories, two of them High. GHSA-69pf-842h-jm7g (High): route-map thumbnails and user photos were served without authentication; they now come only from signed, expiring URLs. GHSA-5pxq-cv3v-89qg (High): the Strava OAuth callback allowed an integration to be hijacked by stealing the state value. GHSA-xqfv-wgw6-xf2x (Medium): activity streams, laps, sets and workout steps were readable by any signed-in user. GHSA-jwrv-j6hh-fw3c (Medium): the activity hide_* privacy flags were not enforced in API responses. GHSA-464j-c746-pg75 (Medium): rate limiting could be bypassed with an arbitrary Bearer header. GHSA-7mf8-q8fp-38x8 (Medium): a missing ownership check let users attach activities to another user's gear.
- WARNING, one-way migration: the first start on 0.20 migrates the database and the files under /app/data and cannot be undone by downgrading. Thumbnails are converted from PNG to WebP and the PNG files are deleted; activity media and user photo records are rewritten, and a record whose file is missing is removed. Cloudron takes a backup before the update; restoring that backup is the only way back. The application is unhealthy while the migration runs, which grows with the number of activities, so expect a pause after the update rather than an instant start.
- ACTION REQUIRED for device clients: the upload route is now POST /api/v1/activities/upload (it answers 202 and imports in the background). The old /api/v1/activities/create/upload no longer exists. Re-point Gadgetbridge, OpenTracks, FitoTrack and any other client; some companion apps may not support the new route yet, so check before updating if you rely on them.
- ACTION REQUIRED for imports from disk: bulk and Strava-export folders are now per user, under storage/activity_files/bulk_import/<user id>/ and strava_import/<user id>/ (or upload the archive on the Import page). Files left in the old shared folders are not picked up.
- Email: upstream replaced its mail library and now verifies the mail server's certificate and refuses to send credentials without TLS, which would have silently disabled email with the previous wiring. Mail now goes over STARTTLS on the sendmail addon's STARTTLS port with the addon credentials and a verified certificate; the host name is worked out at boot (see mailhost.py) and the boot log says if email had to be left off. Only the newest password-reset link works, and mail is sent in the background, so the API no longer reports delivery failures.
- Background jobs are enabled (JOBS_ENABLED=true): uploads, imports and email are queued durably in PostgreSQL and retried.
- The Redis addon is kept, now as the application's shared state store (STATE_URI) so rate-limit and lockout state still survives a restart; the Redis event bus is not used. Build tool uv 0.12.23 to 0.12.24 as upstream requires; the image now installs upstream's distributed extra for the Redis client.
- Packaging: the provisioning script follows upstream's move of its code under modules/; the two environment variables upstream now refuses (RATE_LIMIT_STORAGE_URI, AUTH_SECURITY_STORAGE_URI) are no longer set. Base image (6.0.1) and the builder-only Node.js (24.22.1) are unchanged from 0.1.4.

[0.1.4]

- Base image cloudron/base 6.0.0 to 6.0.1: Ubuntu security updates, including the removal of the compromised eMudhra emSign ECC Root CA - G3 from the trusted certificates.
- Upstream Endurain 0.19.3 to 0.19.4: the Strava visibility rule is now applied consistently across profile, activity and public views, including activity laps, sets and workout steps; activity files can be selected in the file picker on iOS. No security items in the release notes.
- The frontend build's Node.js (builder stage only; the runtime ships no Node) moves from 24.15.0 to 24.22.1, the 2026-10-20 security release.

[0.1.3]

- Base image cloudron/base 5.0.0 to 6.0.0 (Ubuntu 26.04). No Node change: the frontend build already used its own pinned Node 24.15.0 in the builder stage, and the runtime ships no Node. Python is unchanged: the uv-managed CPython 3.13.13 is bundled, not the base's.
- Upstream Endurain 0.19.2 to 0.19.3: dependency updates and maintenance; upstream moved from Codeberg to GitHub, so the package now builds from the GitHub repository (same commits for earlier tags) and the page's content security policy allows api.github.com for the in-app update check instead of codeberg.org. Build tool uv updated to 0.12.23 as upstream requires. No security items in the release notes.

[0.1.2]

- Update endurain 0.19.0 -> 0.19.2
- Security: fixed proxy client IP detection to prevent bypass of IP-based access controls and rate limiting behind a reverse proxy; fixed activity map tile server routing to prevent leakage of user location data to unauthorised external providers; fixed SSO token exchange to ensure the authenticated user is correctly identified
- Breaking: Users model decoupled from auth tables and legacy ORM relationships removed; existing installs require a database schema migration
- Routine features and fixes
- No packaging changes: auth topology, workspace layout and secrets handling unchanged; base and built images digest-pinned

[0.1.1]

- Bake the packaging revision into the image and log it at boot, so a running container identifies its own build
- Copy the built frontend into the runtime tree instead of symlinking it, which the application's static file server refused to serve
- Enable single sign-on in server settings when the Cloudron identity provider is first provisioned, so the login page offers it
- Allow server-side OpenID Connect calls to the platform's own identity provider, which the application's SSRF guard blocked because the dashboard resolves to a private address inside the container
- Validate SECRET_KEY on every boot the way FERNET_KEY already was, and re-assert the modes of the files provisioning writes
- Answer a stop signal during the boot sequence instead of waiting out the platform's grace period

[0.1.0]

- Initial community package of Endurain 0.19.0
- PostgreSQL, Redis, sendmail and OIDC through Cloudron addons; single sign-on lands in Endurain's native OIDC login
- First-run neutralisation of the upstream seeded admin account with a generated password stored in /app/data/.secrets
- All user files under /app/data; the Fernet encryption key is seeded once and guarded across update and restore
