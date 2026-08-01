# ADR 0002: Auth topology, native OIDC, no proxyAuth

- Status: Accepted
- Date: 2026-08-01

## Context

Cloudron offers two broad ways to add single sign-on to a packaged app: put the platform's
`proxyauth` addon in front of it as an authentication wall, or feed Cloudron's `oidc` addon into
the application's own login system as one more identity provider. Endurain already has a full
native authentication stack: JWT access and refresh tokens with refresh rotation, optional
multi-factor authentication, an API-key mechanism for long-lived device access, and native support
for external OpenID Connect identity providers with PKCE. It is not a thin app that lacks its own
auth and needs a wall put in front of it; it is an app whose auth Cloudron needs to plug into.

`proxyauth` also does not fit Endurain's surface area. Endurain ships native mobile and
companion-app clients that authenticate directly against its JSON API, not through a browser
redirect, and a `proxyauth` wall in front of those routes would break them. Device uploads, from
Gadgetbridge, OpenTracks, FitoTrack and similar, authenticate with a long-lived `X-API-Key` header
against an upload endpoint that is never expected to see a browser session, so the same wall would
break exactly the automation those devices exist for. Endurain's own auth routes have to stay
reachable on terms Endurain itself defines, since `proxyauth` reserves `/login` and `/logout` and
would collide with routes the app already uses for its own login. Endurain's WebSocket connections
do not fit a proxy built around HTTP request and redirect authentication either. For all of these
reasons, `proxyauth` is not used anywhere in this package.

## Decision

Wire Cloudron single sign-on into Endurain's native OpenID Connect support instead. On every boot,
the package provisions an identity provider record inside Endurain from the `oidc` addon's
environment variables, under the fixed slug `cloudron`. Re-provisioning on every boot, rather than
only on first run, matters because the addon's client credentials rotate; a stale record would
silently stop authenticating.

This half of provisioning is deliberately fail-soft: a problem synchronising the identity-provider
record is logged and swallowed rather than aborting the boot, so a misconfigured or briefly
unreachable `oidc` addon can never prevent local-account users from logging in. That is the
opposite failure mode from the admin-account neutralisation this same provisioning step also
performs, which is fail-hard on first run, deliberately, because a silent failure there would be
far worse; see [the secrets and admin-neutralisation decision
record](0003-secrets-and-admin-neutralisation.md).

The resulting callback path is fixed by that slug, `/api/v1/public/idp/callback/cloudron`, which is
what the manifest's `addons.oidc.loginRedirectUri` declares. The manifest also sets `optionalSso:
true`, so the app installs and works with no identity provider configured at all; Endurain's local
accounts are a complete authentication system on their own, and Cloudron SSO is an addition to
them, not a replacement.

Because there is no `proxyauth` wall, several classes of route stay open at the network layer,
among them the upload endpoint, Endurain's own auth routes, and the public identity-provider
callback routes. This is intentional, not an oversight: every one of those routes is protected by
Endurain's own mechanism, a bearer token, an API key, or the OIDC state and PKCE exchange, rather
than by a layer in front of the app. Network-open here means reachable, not unauthenticated.

## Alternatives considered

Putting `proxyauth` in front of the whole app, and letting Endurain's native auth stand behind it
as a second layer, was considered and rejected. It would not add meaningful defence in depth,
because the routes that matter most, the API used by mobile clients and device uploads, would
either have to be excluded from `proxyauth` with a `path` rule, at which point it protects nothing
that was not already protected, or left included and broken. Since the exclusion list would end up
covering most of the app's actual traffic, the addon would not be doing useful work.

Putting `proxyauth` in front of only the web UI, excluding the API paths, was also considered. It
was rejected as the same trade-off with extra moving parts: a second login system placed in front
of a first one that already works, for a subset of routes chosen by a path prefix that has to be
kept in step with Endurain's own routing by hand.

## Consequences

Cloudron SSO credentials, and the identity-provider record built from them, are re-asserted on
every boot rather than once, which is slightly more work per boot in exchange for never running
with a stale client secret after Cloudron rotates one. A finding surfaced during this work is worth
recording here because it affects anyone scripting against the API through this package: Endurain
requires an `X-Client-Type` header, for example `X-Client-Type: mobile`, on programmatic JSON API
requests including login, and treats a missing header as invalid credentials, returning a plain 401
indistinguishable from an actually wrong password or API key at the protocol level; only knowing to
check the header explains it. This is recorded as a finding in `docs/FOR-UPSTREAM.md`. Because SSO
is optional, the post-install and configuration documentation also has to cover both paths, with
and without an identity provider configured, rather than assuming one.
