# Keycloak (VeloBits realms)

Identity provider for the FixMyText microbackend. Keycloak is active — the
`Velobits-Dev` realm handles all auth in the development environment; the
`Velobits-Prod` realm is imported on the production instance.

## Files

| File | Purpose |
|---|---|
| `realm-export-dev.json` | Dev realm definition: `Velobits-Dev`, clients, roles, token lifespans |
| `realm-export-prod.json` | Prod realm definition: `Velobits-Prod` — imported during production provisioning |
| `bootstrap.sh` | Idempotent post-boot helper: realm import, SMTP + social IdPs (Google, GitHub), `account-svc` service account (with `manage-users`/`view-users` roles), and backchannel-logout URL registration via Admin API |

## Realms at a glance

### Dev (`Velobits-Dev`)

- **Default signature algorithm**: `RS256`
- **JWKS URL**: `http://localhost:8080/realms/Velobits-Dev/protocol/openid-connect/certs`
- **OIDC discovery**: `http://localhost:8080/realms/Velobits-Dev/.well-known/openid-configuration`
- **Access token lifespan**: 300 s (5 min)
- **SSO session**: idle 2 h, max 30 days
- **Email verification**: required
- **Self-registration**: allowed (gated by rate-limited `/auth/register` in account-svc)
- **Brute force protection**: enabled (5 failures → 1-min lockout)
- **Password policy**: min 8 chars, ≥1 uppercase, ≥1 lowercase, ≥1 digit,
  not username, not email, hashed with `pbkdf2-sha256` at 600,000 iterations

### Prod (`Velobits-Prod`)

Same as Dev except:
- **Self-registration** via Keycloak's own UI: **disabled** — registration must go through account-svc's `/auth/register` endpoint
- **sslRequired**: `all` (dev uses `external`)
- **Password policy**: stricter — min 12 chars and also requires ≥1 special character (otherwise same: upper/lower/digit, not username, not email, pbkdf2-sha256 @ 600,000 iterations)
- **OTP policy**: TOTP, HmacSHA256, 6 digits, 30 s period (available for users to enable)

### Clients

| Client | Realm | Type | Flow | Used by |
|---|---|---|---|---|
| `develop-fixmytext` | Dev | Public (PKCE) | Authorization Code | React SPA login/signup |
| `fixmytext` | Prod | Public (PKCE) | Authorization Code | React SPA (prod) |
| `fixmytext-backend` | Both | Confidential (service account) | Client credentials | Admin API (user creation, verification email) |
| `develop-chat` / `chat` | Dev / Prod | Public (PKCE) | — (disabled) | Disabled placeholder for a future VeloBits product (Chat) |
| `develop-notes` / `notes` | Dev / Prod | Public (PKCE) | — (disabled) | Disabled placeholder for a future VeloBits product (Notes) |

The `develop-chat`/`develop-notes` (dev) and `chat`/`notes` (prod) clients are
`enabled: false` placeholders reserved for future VeloBits products. They have no
active flows yet — standard flow is disabled and they exist only to claim the
client IDs and redirect URIs ahead of time.

#### `develop-fixmytext` redirect URIs

The dev frontend client registers both the Vite (`/auth/callback`) and Next.js
(`/app/auth/callback`) callback paths plus the silent-renew callback, on both the
localhost and `velobits.dev` hosts:

- `http://localhost:3000/auth/callback`
- `http://localhost:3000/app/auth/callback`
- `http://localhost:3000/app/auth/silent-callback`
- `http://develop-fixmytext.velobits.dev/auth/callback`
- `http://develop-fixmytext.velobits.dev/app/auth/callback`
- `http://develop-fixmytext.velobits.dev/app/auth/silent-callback`

#### Front-channel logout disabled

`develop-fixmytext` sets `frontchannelLogout: false`. Keycloak performs single
logout via **back-channel SLO** (server-to-server POST to the
`backchannel.logout.url`, `http://account-svc:8000/api/v1/auth/backchannel-logout`
in dev). Front-channel logout is disabled because server-initiated logouts
(Admin API / token revocation) have no browser to load the front-channel iframe.

The `fixmytext-backend` client secret in the realm export files is a placeholder
(`PLACEHOLDER_ROTATED_ON_FIRST_BOOT` / `PLACEHOLDER_ROTATED_ON_PRODUCTION_PROVISION`).
Rotate it on first start and store the real value externally (1Password / GitHub secret).

### User profile

The dev realm ships a declarative `userProfileConfig` defining four attributes —
`username`, `email`, `firstName`, `lastName`:

- `username`: length 3–255, prohibited-characters + IDN-homograph validations
- `email`: email-format validation, max length 255, **required** for the `user` role
- `firstName` / `lastName`: max length 255, person-name prohibited-characters validation

Each attribute grants view/edit permission to both the `admin` and `user` roles.
New self-registrations receive the realm default role `user` (`defaultRoles: ["user"]`),
which is the standard VeloBits role shared across products.

### Admin API authentication (account-svc)

`account-svc` talks to the Keycloak Admin API (user creation, verification email)
using a dual strategy in `services/account-svc/app/services/keycloak_admin.py`:

1. **Preferred — dedicated service account.** When `KEYCLOAK_SERVICE_ACCOUNT_ID`
   and `KEYCLOAK_SERVICE_ACCOUNT_SECRET` are set, it uses the `client_credentials`
   grant against the **product realm** token endpoint. `bootstrap.sh` provisions
   this client (default clientId `account-svc`, overridable via
   `KEYCLOAK_SERVICE_ACCOUNT_ID`) and assigns it the `manage-users` + `view-users`
   roles from `realm-management`, so no master-realm credentials are needed.
2. **Fallback — master admin-cli.** When the service account is not configured,
   it uses the `password` grant against the **master realm** with
   `KEYCLOAK_ADMIN` / `KEYCLOAK_ADMIN_PASSWORD`.

Admin tokens are cached for their lifetime to avoid hammering the token endpoint.

## Local dev

`docker compose --profile dev up` starts Keycloak with the dev realm
auto-imported via `--import-realm`. The admin console is at
http://localhost:8080 (log in with `KEYCLOAK_DEV_ADMIN_PASSWORD` from `.env`).

Social IdPs (Google, GitHub) and SMTP are configured by the `keycloak-bootstrap`
service on first boot. Set the relevant env vars in `.env`:

```
GOOGLE_OAUTH_CLIENT_ID=
GOOGLE_OAUTH_CLIENT_SECRET=
GH_OAUTH_CLIENT_ID=
GH_OAUTH_CLIENT_SECRET=
SMTP_HOST=
SMTP_PORT=587
SMTP_USERNAME=
SMTP_PASSWORD=
EMAIL_FROM=
```

## Production provisioning

1. Stand up a Keycloak instance (separate from dev).
2. Set `REALM_EXPORT_PATH=/path/to/realm-export-prod.json` and run `bootstrap.sh`.
3. Rotate the `fixmytext-backend` client secret.
4. Set `KEYCLOAK_REALM=Velobits-Prod` in all service `.env` files.
5. Configure `KEYCLOAK_JWKS_URL`, `KEYCLOAK_ISSUER`, `KEYCLOAK_AUDIENCE` in each service.

## Production hardening (TODO)

- HA Keycloak with external Infinispan cache
- TLS termination at reverse proxy (Keycloak behind it)
- External secret store for client secrets (Vault / SOPS / cloud KMS)
- Backup strategy for the Keycloak Postgres database
- Set OTP policy to required for admin accounts
