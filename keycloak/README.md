# Keycloak (VeloBits realms)

Identity provider for the FixMyText microbackend. Keycloak is active — the
`Velobits-Dev` realm handles all auth in the development environment; the
`Velobits-Prod` realm is imported on the production instance.

## Files

| File | Purpose |
|---|---|
| `realm-export-dev.json` | Dev realm definition: `Velobits-Dev`, clients, roles, token lifespans |
| `realm-export-prod.json` | Prod realm definition: `Velobits-Prod` — imported during production provisioning |
| `bootstrap.sh` | Idempotent post-boot helper: configures SMTP + social IdPs (Google, GitHub) via Admin API |

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
- **Password policy**: min 8 chars, not username, not email, pbkdf2-sha256

### Prod (`Velobits-Prod`)

Same as Dev except:
- **Self-registration** via Keycloak's own UI: **disabled** — registration must go through account-svc's `/auth/register` endpoint
- **sslRequired**: `all` (dev uses `external`)
- **OTP policy**: TOTP, HmacSHA1, 6 digits, 30 s period (available for users to enable)

### Clients

| Client | Realm | Type | Flow | Used by |
|---|---|---|---|---|
| `develop-fixmytext` | Dev | Public (PKCE) | Authorization Code | React SPA login/signup |
| `fixmytext` | Prod | Public (PKCE) | Authorization Code | React SPA (prod) |
| `fixmytext-backend` | Both | Confidential (service account) | Client credentials | Admin API (user creation, verification email) |

The `fixmytext-backend` client secret in the realm export files is a placeholder
(`PLACEHOLDER_ROTATED_ON_FIRST_BOOT` / `PLACEHOLDER_ROTATED_ON_PRODUCTION_PROVISION`).
Rotate it on first start and store the real value externally (1Password / GitHub secret).

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
