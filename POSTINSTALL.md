## First steps

1. Sign in with username `admin`. The initial password was generated during
   installation and stored in `/app/data/.secrets/admin-initial-password`; open it
   with the Cloudron File manager (Files, `.secrets`, `admin-initial-password`).
2. Change that password immediately in Endurain under Settings, then delete the file.

`<sso>`
Cloudron single sign-on is wired into Endurain's own OpenID Connect login: use the
"Cloudron" button on the login page. Accounts created through SSO start as standard
users; promote them from the admin account if needed. The `admin` account itself stays
local.
</sso>
`<nosso>`
This installation has single sign-on turned off, so Endurain manages its own accounts:
sign in with the `admin` account above and add users inside the app. Turning single
sign-on on later, from the app's Single Sign-On settings in Cloudron, adds a "Cloudron"
button to the login page and leaves existing local accounts working.
</nosso>

## Devices and apps

Endurain accepts FIT, GPX and TCX uploads. For automatic upload from Gadgetbridge,
OpenTracks, FitoTrack and similar, create an API key in Endurain (Settings, API keys)
and point the app at:

`$CLOUDRON-APP-ORIGIN/api/v1/activities/upload`

with the key in the `X-API-Key` header; that endpoint needs no other header. The route
changed in Endurain 0.20: **every device client must be re-pointed from the old
`/api/v1/activities/create/upload` to this one**, and some companion apps may not know the new route
yet. The upload now answers `202` and imports in the background. Clients
that sign in to the wider JSON API (rather than using an API key) must send
`X-Client-Type: mobile` on their requests, including login.

## Importing from the server's disk

Bulk and Strava-export imports from disk now use one folder per user, in the Cloudron File manager
under `storage/activity_files/bulk_import/<user id>/` (Strava exports: `.../strava_import/<user id>/`),
or upload the archive on Endurain's Import page. Files left in the old, shared `bulk_import` folder
are no longer picked up: move them.

## Integrations

Strava and Garmin Connect are linked per user under Settings. Strava requires each
user to register their own (free) Strava API application; the values are stored
encrypted. Reverse geocoding uses the public Nominatim service by default and the map
tile server is configurable by the admin in Server settings.
