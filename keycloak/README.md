# Keycloak (FixMyText realm)

Identity provider for the microbackend. Keycloak currently **runs but is
idle**: the `fixmytext` realm exists, two clients are configured, no users
are provisioned, and no traffic flows through it. Activation (user
migration + frontend OIDC + monolith token verification flip) is TODO.

## Files

| File | Purpose |
|---|---|
| `realm-export.json` | Declarative realm definition: name, clients, role, token lifespans |
| `bootstrap.sh` | Idempotent post-boot helper (admin-API import + secret rotation) — usable in environments where Keycloak's `--import-realm` flag is unavailable |

## Realm at a glance

- **Realm**: `fixmytext`
- **Default signature algorithm**: `RS256` (JWKS at `/realms/fixmytext/protocol/openid-connect/certs`)
- **Access token lifespan**: 300s (5 min)
- **SSO session**: idle 30 min, max 30 days
- **Email verification**: required (`verifyEmail: true`)
- **Self-registration**: disabled (TODO — decide whether to enable when frontend OIDC is wired)
- **Default role**: `user`

### Clients

| Client | Type | Flow | Used by |
|---|---|---|---|
| `fixmytext-frontend` | Public (PKCE) | Authorization Code | TODO — React SPA login/signup |
| `fixmytext-backend` | Confidential (service account) | Client credentials | TODO — Admin API for user migration; future services for token introspection if needed |

The `fixmytext-backend` client secret in `realm-export.json` is a placeholder
(`PLACEHOLDER_ROTATED_ON_FIRST_BOOT`). The real secret is rotated when you
first start Keycloak and stored externally (1Password / GitHub repo secret).

## Local dev

`docker compose --profile dev up keycloak` starts Keycloak with the realm
auto-imported via the `--import-realm` flag. The admin console is at
http://localhost:8080 (log in with `KEYCLOAK_ADMIN_PASSWORD` from `.env`).

OIDC discovery: http://localhost:8080/realms/fixmytext/.well-known/openid-configuration

## Why it's idle for now

Activating Keycloak requires:
- Migrating existing User rows (~bcrypt hashes) into Keycloak via Admin API
- Switching `JWT_ALGORITHM=HS256` → `RS256` in the monolith
- Updating frontend to use OIDC redirect (or PKCE backchannel exchange)
- Adding Kong route for `/api/v1/auth/*` → Keycloak
- Configuring SMTP inside Keycloak for verification / reset emails

Setting up the realm now is cheap and de-risks the activation work — when
the migration lands, Keycloak is ready to accept traffic.

## Production hardening (TODO)

- HA Keycloak with external Infinispan cache
- TLS termination at Kong / reverse proxy (Keycloak behind it)
- External secret store for client secrets (Vault / SOPS / cloud KMS)
- Backup strategy for the Keycloak Postgres database
- Realm-level email server config (currently empty)
