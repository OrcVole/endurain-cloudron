`<upstream>0.19.2</upstream>

Endurain is a self-hosted fitness tracking platform for endurance sports: running,
cycling, hiking, swimming, gym work and more. Upload activities as FIT, GPX or TCX
files, sync automatically from Strava and Garmin Connect, follow other users, track
body composition and health data, and keep every GPS track and heart-rate stream on
your own server.

This package runs Endurain on Cloudron with:

- PostgreSQL, Redis and outgoing email provided by Cloudron addons, so backups and
  updates are handled by the platform.
- Optional Cloudron single sign-on through Endurain's native OpenID Connect support.
  Local accounts keep working either way.
- The upstream seeded `admin` account is protected on first run: this package replaces
  the well-known default password with a generated one before the app ever serves a
  request (see the post-install message).
- Long-lived API keys (an Endurain feature since 0.18.0) let devices and apps such as
  Gadgetbridge, OpenTracks or FitoTrack upload activities directly to your instance.

Endurain is developed by the Endurain project (<https://endurain.com>), licensed
AGPL-3.0-or-later. This is an unofficial community package; "Endurain" is a registered
trademark of its author, used here nominatively for a free, non-commercial community
package in line with the project's trademark policy.
