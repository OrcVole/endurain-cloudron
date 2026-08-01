[0.1.1]
* Bake the packaging revision into the image and log it at boot, so a running container identifies its own build
* Copy the built frontend into the runtime tree instead of symlinking it, which the application's static file server refused to serve
* Enable single sign-on in server settings when the Cloudron identity provider is first provisioned, so the login page offers it
* Allow server-side OpenID Connect calls to the platform's own identity provider, which the application's SSRF guard blocked because the dashboard resolves to a private address inside the container
* Validate SECRET_KEY on every boot the way FERNET_KEY already was, and re-assert the modes of the files provisioning writes
* Answer a stop signal during the boot sequence instead of waiting out the platform's grace period

[0.1.0]
* Initial community package of Endurain 0.19.0
* PostgreSQL, Redis, sendmail and OIDC through Cloudron addons; single sign-on lands in Endurain's native OIDC login
* First-run neutralisation of the upstream seeded admin account with a generated password stored in /app/data/.secrets
* All user files under /app/data; the Fernet encryption key is seeded once and guarded across update and restore
