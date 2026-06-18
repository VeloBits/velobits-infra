# Keycloak Production Setup Runbook

This runbook covers everything required to bring a production Keycloak instance to
feature-parity with the dev stack: realm import, SMTP, social IdPs, and the
bootstrap script quirks that burned us in dev.

---

## Background — What the Dev Stack Does Automatically

In dev, `docker compose --profile dev up` runs a `keycloak-bootstrap` one-shot container
that calls `bootstrap.sh` after Keycloak is healthy. It handles:

- Realm import (idempotent — skips if realm already exists)
- SMTP configuration via the Admin API
- Google and GitHub OAuth IdP provisioning

**None of this runs automatically in production.** Production Keycloak must be
bootstrapped manually (or via CI) using the same script.

---

## Pre-Requisites

| Item | Where to get it |
|---|---|
| Production Keycloak URL | e.g. `https://auth.velobits.dev` |
| Admin credentials | Set during KC initial deployment; store in your secrets manager |
| Gmail App Password (or transactional email service) | [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords) — one app password per environment. **Do not reuse the dev password.** |
| Google OAuth Client ID + Secret | [console.cloud.google.com](https://console.cloud.google.com) → OAuth 2.0 Clients → add `https://auth.velobits.dev/realms/Velobits-Prod/broker/google/endpoint` as an authorised redirect URI |
| GitHub OAuth Client ID + Secret | [github.com/settings/developers](https://github.com/settings/developers) → New OAuth App → set callback to `https://auth.velobits.dev/realms/Velobits-Prod/broker/github/endpoint` |
| `realm-export-prod.json` | `backend/infrastructure/keycloak/realm-export-prod.json` |

---

## Step 1 — Import the Production Realm

If the realm does not exist yet, import it:

```bash
export KEYCLOAK_URL=https://auth.velobits.dev
export KEYCLOAK_ADMIN=admin
export KEYCLOAK_ADMIN_PASSWORD=<prod-admin-password>
export KEYCLOAK_REALM=Velobits-Prod
export REALM_EXPORT_PATH=backend/infrastructure/keycloak/realm-export-prod.json

bash backend/infrastructure/keycloak/bootstrap.sh
```

`bootstrap.sh` is idempotent — safe to re-run. If the realm already exists it skips
the import and proceeds directly to SMTP + IdP configuration.

---

## Step 2 — Configure SMTP

Set these additional env vars before running the script (or re-run it with them set):

```bash
export SMTP_HOST=smtp.gmail.com          # or your transactional provider (SendGrid, Postmark, etc.)
export SMTP_PORT=587
export SMTP_USERNAME=noreply@fixmytext.app
export SMTP_PASSWORD=<app-password>
export EMAIL_FROM="FixMyText <noreply@fixmytext.app>"
```

The script PATCHes `smtpServer` on the realm via the Admin API. Verify in the Keycloak
admin console under **Realm settings → Email**.

> **Recommended for production:** Use a transactional email provider (SendGrid, Postmark,
> AWS SES) instead of a raw Gmail SMTP credential. Gmail has daily send limits and
> app passwords can be revoked without notice.

---

## Step 3 — Configure Social IdPs

```bash
export GOOGLE_OAUTH_CLIENT_ID=<google-client-id>
export GOOGLE_OAUTH_CLIENT_SECRET=<google-client-secret>
export GH_OAUTH_CLIENT_ID=<github-client-id>
export GH_OAUTH_CLIENT_SECRET=<github-client-secret>
```

Run `bootstrap.sh` with all vars set. The script checks for existing IdPs before
creating them — re-running is safe.

---

## Step 4 — Verify

1. **SMTP**: In the Keycloak admin console → **Realm settings → Email → Test connection**.
2. **Social login**: Open `https://app.fixmytext.app/app/login`, click the Google or
   GitHub button, and complete the OAuth flow.
3. **Email verification**: Register a new account — the verification email should
   arrive within 30 seconds.
4. **Password reset**: Click "Forgot Password?" on the login page and confirm the
   reset email arrives.

---

## Known Bugs Fixed in Dev (already in `bootstrap.sh` — do not revert)

### Bug 1 — Health check used wrong endpoint
`bootstrap.sh` originally waited on `$KEYCLOAK_URL/health/ready`. Keycloak 26 with
`start-dev` does not expose this endpoint at port 8080 without `--health-enabled=true`.

**Fix (2026-06-17):** Changed to the OIDC discovery endpoint:
```bash
curl -fsS "$KEYCLOAK_URL/realms/$KEYCLOAK_REALM/.well-known/openid-configuration"
```

### Bug 2 — Script exited early if realm already existed
The "realm already exists" branch previously did `exit 0`, which skipped SMTP and
IdP provisioning entirely. This meant re-running the script on an existing realm never
configured email or social login.

**Fix (2026-06-17):** Changed to `skipping import` (no exit). SMTP and IdP blocks
now always run regardless of whether the realm was just created or already existed.

---

## CI Integration (future)

To automate this as part of your production deploy pipeline:

```yaml
- name: Bootstrap Keycloak
  run: |
    bash backend/infrastructure/keycloak/bootstrap.sh
  env:
    KEYCLOAK_URL: ${{ secrets.KC_PROD_URL }}
    KEYCLOAK_ADMIN: ${{ secrets.KC_PROD_ADMIN }}
    KEYCLOAK_ADMIN_PASSWORD: ${{ secrets.KC_PROD_ADMIN_PASSWORD }}
    KEYCLOAK_REALM: Velobits-Prod
    REALM_EXPORT_PATH: backend/infrastructure/keycloak/realm-export-prod.json
    SMTP_HOST: ${{ secrets.SMTP_HOST }}
    SMTP_PORT: 587
    SMTP_USERNAME: ${{ secrets.SMTP_USERNAME }}
    SMTP_PASSWORD: ${{ secrets.SMTP_PASSWORD }}
    EMAIL_FROM: ${{ secrets.EMAIL_FROM }}
    GOOGLE_OAUTH_CLIENT_ID: ${{ secrets.GOOGLE_OAUTH_CLIENT_ID }}
    GOOGLE_OAUTH_CLIENT_SECRET: ${{ secrets.GOOGLE_OAUTH_CLIENT_SECRET }}
    GH_OAUTH_CLIENT_ID: ${{ secrets.GH_OAUTH_CLIENT_ID }}
    GH_OAUTH_CLIENT_SECRET: ${{ secrets.GH_OAUTH_CLIENT_SECRET }}
```

Run this step **after** Keycloak is deployed and healthy, **before** any service
that depends on KC auth starts.

---

## Checklist Before Going Live

- [ ] Admin password rotated from dev default
- [ ] SMTP verified via test-connection in admin console
- [ ] Verification email received in test account
- [ ] Password reset email received in test account
- [ ] Google OAuth flow completes end-to-end
- [ ] GitHub OAuth flow completes end-to-end
- [ ] `backend/.env` production credentials are **not** in git history (`security-env-leak` incident)
- [ ] Google OAuth redirect URI matches prod domain (not `localhost`)
- [ ] GitHub OAuth callback URL matches prod domain (not `localhost`)
