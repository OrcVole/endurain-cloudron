[0.1.0]
* Initial community package of Endurain 0.19.0
* PostgreSQL, Redis, sendmail and OIDC through Cloudron addons; single sign-on lands in Endurain's native OIDC login
* First-run neutralisation of the upstream seeded admin account with a generated password stored in /app/data/.secrets
* All user files under /app/data; the Fernet encryption key is seeded once and guarded across update and restore
