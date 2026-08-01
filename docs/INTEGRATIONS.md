# Integrations

Practical notes on getting other tools talking to this Endurain instance. This is not upstream API
reference documentation; it covers what this package specifically adds or assumes, and points at
[`POSTINSTALL.md`](../POSTINSTALL.md) and the upstream project for the rest.

## Device uploads

Endurain accepts FIT, GPX and TCX activity files. Two patterns work for getting activity data into
an instance without using the web UI.

Gadgetbridge can export FIT files from a paired device and, separately, upload directly to an
Endurain instance using an Endurain API key. FIT is the preferred format where a device or app
offers a choice, because it carries the full sensor payload, heart rate, cadence, power and similar
per-sample data, rather than only the track. Where FIT is not on offer, Endurain still accepts GPX.

OpenTracks and FitoTrack export GPX. Neither currently uploads directly to an Endurain instance the
way Gadgetbridge does; export from the app and import through Endurain's own upload flow, or a
synced folder, in the meantime.

For any client that does upload directly, create an API key in Endurain first, under **Settings,
API keys**, then point the client at the upload endpoint:

```
https://endurain.example.com/api/v1/activities/create/upload
```

with the key in an `X-API-Key` header. That endpoint authenticates with the key alone and needs no
other header. Clients that instead sign in to Endurain's wider JSON API (a session with a username
and password, as the mobile app does) also need an `X-Client-Type: mobile` header on their
requests, including login; without it, Endurain responds as though the credentials themselves were
wrong rather than pointing at the missing header, so it is worth checking for first if an
otherwise-correct login is being rejected.

## Strava and Garmin Connect

Both are linked per user, from within Endurain under **Settings**, not at the instance level. For
Strava, each user registers their own free application on Strava's developer site and enters its
client ID and client secret into Endurain; Endurain then handles the OAuth exchange per user.
Garmin Connect linking works similarly, without a separate developer application to register.

In both cases, the resulting tokens are stored encrypted (see [the secrets and admin-neutralisation
decision record](decisions/0003-secrets-and-admin-neutralisation.md) for what protects them and
what depends on that protection). Strava additionally stores each user's own client credentials
encrypted alongside their tokens, since those credentials are themselves per-user under this model,
not a single instance-wide value.

## Planned: wger bridge

Not yet shipped. Recorded here as a design, so the reasoning is not lost between packaging rounds.

[wger](https://wger.de) is a self-hosted training and body-metrics tracker with its own REST API.
The design under consideration is a one-way sync of body-weight and body-measurement entries from
Endurain to a wger instance, implemented as a small external bridge script driven by a scheduler
outside the application (this package never patches Endurain itself), reading from Endurain's API
and writing through wger's REST API with a wger API token held by the operator.

This is marked planned rather than in progress because it is not yet practical to package: there is
no wger Cloudron package for this bridge to talk to, so there is nothing to test it against inside
the Cloudron environment for the moment. It becomes worth building once a wger Cloudron package
exists to pair it with; until then this section stands as a design note, not a commitment to a
date.
