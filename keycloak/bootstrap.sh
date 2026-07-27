#!/usr/bin/env bash
# Idempotent Keycloak realm + client bootstrap helper.
#
# Keycloak currently runs but no users are provisioned. This script exists
# so future automation (user migration, service onboarding) can call it
# from CI / one-shot containers. The dev compose imports realm-export.json
# automatically via Keycloak's --import-realm flag; this script is a
# safety net for environments where that flag isn't available (prod).
#
# Usage:
#   ./bootstrap.sh                       # full bootstrap (idempotent)
#   ./bootstrap.sh --skip-realm-import   # only rotate client secrets
#
# Required env:
#   KEYCLOAK_URL            (default: http://localhost:8080)
#   KEYCLOAK_ADMIN          (default: admin)
#   KEYCLOAK_ADMIN_PASSWORD (required)
#
# Optional env:
#   KEYCLOAK_REALM               (default: Velobits)
#   REALM_EXPORT_PATH            (default: ./realm-export-dev.json relative to this script)
#   KEYCLOAK_HEALTH_URL          full readiness URL to poll instead of the default
#                                $KEYCLOAK_URL/realms/master probe (e.g. the KC 26
#                                management port: http://keycloak:9000/health/ready)
#   KEYCLOAK_FRONTEND_CLIENT_ID  clientId of the Authorization Code + PKCE client whose
#                                sessions trigger backchannel logout (NOT the service account)
#   BACKCHANNEL_LOGOUT_URL       URL Keycloak calls on SLO; registered on the frontend client
#
# Exit codes:
#   0  success / already bootstrapped
#   1  missing required env
#   2  Keycloak not reachable
#   3  admin auth failed
#   4  realm import returned unexpected HTTP status

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-Velobits}"
REALM_EXPORT_PATH="${REALM_EXPORT_PATH:-$(dirname "$0")/realm-export-dev.json}"

if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  echo "[bootstrap] FATAL: KEYCLOAK_ADMIN_PASSWORD not set" >&2
  exit 1
fi

# ── 1. Wait for Keycloak to be reachable ─────────────────────────────────────
# KC 26 with start-dev does not expose /health/ready at port 8080 unless
# --health-enabled=true is set (and even then it lives on the management
# interface :9000). Probing the TARGET realm's OIDC discovery endpoint would
# deadlock the fresh-import path — the realm doesn't exist until step 4 of
# THIS script imports it. Probe the master realm instead: it returns 200
# exactly when the server is up and serving realms, regardless of whether the
# target realm has been imported yet. Set KEYCLOAK_HEALTH_URL to a reachable
# management-port endpoint (e.g. http://keycloak:9000/health/ready) to poll a
# real health endpoint instead.
READY_URL="${KEYCLOAK_HEALTH_URL:-$KEYCLOAK_URL/realms/master}"
echo "[bootstrap] waiting for Keycloak at $READY_URL ..."
for i in {1..60}; do
  if curl -fsS "$READY_URL" >/dev/null 2>&1; then
    break
  fi
  if [[ $i -eq 60 ]]; then
    echo "[bootstrap] FATAL: Keycloak not reachable after 60 attempts" >&2
    exit 2
  fi
  sleep 2
done
echo "[bootstrap] Keycloak is ready"

# ── 2. Acquire admin token ───────────────────────────────────────────────────
ADMIN_TOKEN=$(curl -fsS -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=$KEYCLOAK_ADMIN" \
  -d "password=$KEYCLOAK_ADMIN_PASSWORD" \
  "$KEYCLOAK_URL/realms/master/protocol/openid-connect/token" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || {
  echo "[bootstrap] FATAL: admin token request failed" >&2
  exit 3
}
echo "[bootstrap] admin token acquired"

# ── 3. Check whether realm already exists ────────────────────────────────────
REALM_STATUS=$(curl -fsS -o /dev/null -w "%{http_code}" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM" || true)

# ── 4. Import realm from JSON (skipped if realm already exists) ──────────────
if [[ "$REALM_STATUS" == "200" ]]; then
  echo "[bootstrap] realm '$KEYCLOAK_REALM' already exists — skipping import"
elif [[ "${1:-}" != "--skip-realm-import" ]]; then
  echo "[bootstrap] importing realm from $REALM_EXPORT_PATH ..."
  IMPORT_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "@$REALM_EXPORT_PATH" \
    "$KEYCLOAK_URL/admin/realms")
  if [[ "$IMPORT_CODE" == "201" ]]; then
    echo "[bootstrap] realm imported"
  elif [[ "$IMPORT_CODE" == "409" ]]; then
    echo "[bootstrap] realm already exists (409) — skipping"
  else
    echo "[bootstrap] FATAL: realm import failed with HTTP $IMPORT_CODE" >&2; exit 4
  fi
fi

# ── Configure SMTP via Admin API (env vars not interpolated in realm JSON) ─────
if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_USERNAME:-}" ]; then
  echo "[bootstrap] configuring realm SMTP..."
  # Use heredoc + os.environ so secrets never appear in /proc/<pid>/cmdline.
  SMTP_JSON=$(SMTP_HOST="$SMTP_HOST" SMTP_PORT="${SMTP_PORT:-587}" \
    EMAIL_FROM="${EMAIL_FROM:-noreply@fixmytext.local}" \
    SMTP_USERNAME="$SMTP_USERNAME" SMTP_PASSWORD="${SMTP_PASSWORD:-}" \
    SMTP_USE_SSL="${SMTP_USE_SSL:-false}" SMTP_USE_STARTTLS="${SMTP_USE_STARTTLS:-true}" \
    python3 - <<'PYEOF'
import json, os
print(json.dumps({'smtpServer': {
    'host': os.environ['SMTP_HOST'],
    'port': os.environ.get('SMTP_PORT', '587'),
    'from': os.environ.get('EMAIL_FROM', 'noreply@fixmytext.local'),
    'auth': True,
    'user': os.environ['SMTP_USERNAME'],
    'password': os.environ.get('SMTP_PASSWORD', ''),
    'ssl': os.environ.get('SMTP_USE_SSL', 'false') == 'true',
    'starttls': os.environ.get('SMTP_USE_STARTTLS', 'true') == 'true',
}}))
PYEOF
  )
  curl -fsS -X PUT \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$SMTP_JSON" \
    "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM" || echo "[bootstrap] SMTP config failed (non-fatal)"
  echo "[bootstrap] SMTP configured"
fi

# ── Configure Google identity provider ─────────────────────────────────────
if [ -n "${GOOGLE_OAUTH_CLIENT_ID:-}" ] && [ -n "${GOOGLE_OAUTH_CLIENT_SECRET:-}" ]; then
  echo "[bootstrap] configuring Google identity provider..."
  # Check if already exists
  GOOGLE_STATUS=$(curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/identity-provider/instances/google" || true)
  if [ "$GOOGLE_STATUS" != "200" ]; then
    GOOGLE_JSON=$(python3 -c "
import json, os
print(json.dumps({'alias': 'google', 'providerId': 'google', 'enabled': True,
    'trustEmail': False, 'config': {'clientId': os.environ['GOOGLE_OAUTH_CLIENT_ID'], 'clientSecret': os.environ['GOOGLE_OAUTH_CLIENT_SECRET'],
    'defaultScope': 'openid email profile'}}))
")
    curl -fsS -X POST \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$GOOGLE_JSON" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/identity-provider/instances" \
      || echo "[bootstrap] Google IdP creation failed (non-fatal)"
    echo "[bootstrap] Google IdP configured"
  else
    echo "[bootstrap] Google IdP already exists"
  fi
fi

# ── Configure GitHub identity provider ─────────────────────────────────────
if [ -n "${GH_OAUTH_CLIENT_ID:-}" ] && [ -n "${GH_OAUTH_CLIENT_SECRET:-}" ]; then
  echo "[bootstrap] configuring GitHub identity provider..."
  GH_STATUS=$(curl -fsS -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/identity-provider/instances/github" || true)
  if [ "$GH_STATUS" != "200" ]; then
    GH_JSON=$(python3 -c "
import json, os
print(json.dumps({'alias': 'github', 'providerId': 'github', 'enabled': True,
    'trustEmail': False, 'config': {'clientId': os.environ['GH_OAUTH_CLIENT_ID'], 'clientSecret': os.environ['GH_OAUTH_CLIENT_SECRET']}}))
")
    curl -fsS -X POST \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$GH_JSON" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/identity-provider/instances" \
      || echo "[bootstrap] GitHub IdP creation failed (non-fatal)"
    echo "[bootstrap] GitHub IdP configured"
  else
    echo "[bootstrap] GitHub IdP already exists"
  fi
fi

# ── Disable the "Update Account Information" page on social first-login ───────
# The built-in "first broker login" flow's review-profile step defaults to
# "missing", which lets a Google/GitHub user edit username/email on first
# sign-in. Not a security hole (linking to an existing account still requires
# downstream email/password verification), but the fields shouldn't be
# editable there. Set it to "off" so Keycloak uses the provider's attributes
# as-is. Done here (not in realm-export.json) because the built-in flow isn't
# part of the export, and the compose --import-realm OVERWRITE would otherwise
# reset it to the default. Idempotent.
echo "[bootstrap] disabling review-profile page on first broker login..."
REVIEW_CFG_ID=$(curl -fsS \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/authentication/flows/first%20broker%20login/executions" \
  | python3 -c "import json,sys
execs=json.load(sys.stdin)
print(next((e.get('authenticationConfig','') for e in execs if e.get('providerId')=='idp-review-profile'), ''))" 2>/dev/null || true)
if [ -n "$REVIEW_CFG_ID" ]; then
  curl -fsS -X PUT \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"id\":\"$REVIEW_CFG_ID\",\"alias\":\"review profile config\",\"config\":{\"update.profile.on.first.login\":\"off\"}}" \
    "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/authentication/config/$REVIEW_CFG_ID" \
    && echo "[bootstrap] review-profile set to off" \
    || echo "[bootstrap] review-profile config update failed (non-fatal)"
else
  echo "[bootstrap] review-profile execution has no config id — skipping (non-fatal)"
fi

# ── Dedicated service account for account-svc ─────────────────────────────
# Creates an OIDC client with serviceAccountsEnabled=true in the product realm
# and grants it the manage-users role from realm-management so account-svc can
# create/update users without using the master-realm admin-cli credentials.
# Idempotent: re-running updates the client secret if the client already exists.
if [ -n "${KEYCLOAK_SERVICE_ACCOUNT_SECRET:-}" ]; then
  SA_CLIENT_ID="${KEYCLOAK_SERVICE_ACCOUNT_ID:-account-svc}"
  echo "[bootstrap] provisioning service account '$SA_CLIENT_ID' ..."

  # Check whether client already exists.
  SA_LIST=$(curl -s \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients?clientId=$SA_CLIENT_ID&max=1")
  SA_UUID=$(echo "$SA_LIST" | python3 -c \
    "import json,sys; c=json.load(sys.stdin); print(c[0]['id'] if c else '')" 2>/dev/null || true)

  if [ -z "$SA_UUID" ]; then
    # Create the client.
    SA_CREATE_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(KEYCLOAK_SERVICE_ACCOUNT_SECRET="$KEYCLOAK_SERVICE_ACCOUNT_SECRET" \
             SA_CLIENT_ID="$SA_CLIENT_ID" python3 -c "
import json, os
print(json.dumps({
    'clientId': os.environ['SA_CLIENT_ID'],
    'name': 'Account Service',
    'description': 'Service account for account-svc Keycloak Admin API calls',
    'enabled': True,
    'serviceAccountsEnabled': True,
    'clientAuthenticatorType': 'client-secret',
    'secret': os.environ['KEYCLOAK_SERVICE_ACCOUNT_SECRET'],
    'standardFlowEnabled': False,
    'directAccessGrantsEnabled': False,
    'publicClient': False,
    'protocol': 'openid-connect',
}))")" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients")
    echo "[bootstrap] service account client created (HTTP $SA_CREATE_CODE)"

    # Fetch the newly created client's UUID.
    SA_LIST=$(curl -s \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients?clientId=$SA_CLIENT_ID&max=1")
    SA_UUID=$(echo "$SA_LIST" | python3 -c \
      "import json,sys; c=json.load(sys.stdin); print(c[0]['id'] if c else '')" 2>/dev/null || true)
  else
    # Update the client secret (idempotent re-run).
    curl -sS -o /dev/null -X PUT \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$(KEYCLOAK_SERVICE_ACCOUNT_SECRET="$KEYCLOAK_SERVICE_ACCOUNT_SECRET" python3 -c "
import json, os; print(json.dumps({'secret': os.environ['KEYCLOAK_SERVICE_ACCOUNT_SECRET']}))")" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients/$SA_UUID/client-secret" \
      || echo "[bootstrap] secret update failed (non-fatal)"
    echo "[bootstrap] service account '$SA_CLIENT_ID' already exists — secret refreshed"
  fi

  if [ -n "$SA_UUID" ]; then
    # Get the service account user ID.
    SA_USER_ID=$(curl -s \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients/$SA_UUID/service-account-user" \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)

    # Get realm-management client UUID (holds fine-grained admin roles).
    REALM_MGMT_UUID=$(curl -s \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients?clientId=realm-management&max=1" \
      | python3 -c "import json,sys; c=json.load(sys.stdin); print(c[0]['id'] if c else '')" 2>/dev/null || true)

    if [ -n "$SA_USER_ID" ] && [ -n "$REALM_MGMT_UUID" ]; then
      # Fetch manage-users and view-users roles from realm-management.
      MANAGE_USERS_ROLE=$(curl -s \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients/$REALM_MGMT_UUID/roles/manage-users")
      VIEW_USERS_ROLE=$(curl -s \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients/$REALM_MGMT_UUID/roles/view-users")

      # Assign both roles to the service account user.
      ROLE_ASSIGN_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST \
        -H "Authorization: Bearer $ADMIN_TOKEN" \
        -H "Content-Type: application/json" \
        -d "[$MANAGE_USERS_ROLE,$VIEW_USERS_ROLE]" \
        "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/users/$SA_USER_ID/role-mappings/clients/$REALM_MGMT_UUID")
      echo "[bootstrap] realm-management roles assigned (HTTP $ROLE_ASSIGN_CODE)"
    else
      echo "[bootstrap] WARNING: could not resolve SA user or realm-management client — roles not assigned"
    fi

  fi
else
  echo "[bootstrap] KEYCLOAK_SERVICE_ACCOUNT_SECRET not set — skipping service account setup"
fi

# ── Register backchannel logout URL on the OIDC frontend client ────────────
# IMPORTANT: must be on the Authorization Code + PKCE client that issues user
# sessions (KEYCLOAK_FRONTEND_CLIENT_ID), NOT the service-account client.
# Keycloak only calls backchannelLogoutUrl on the client that authenticated the
# user. The service-account client uses client_credentials and never has user
# sessions — registering the URL there means it is never called.
if [ -n "${BACKCHANNEL_LOGOUT_URL:-}" ] && [ -n "${KEYCLOAK_FRONTEND_CLIENT_ID:-}" ]; then
  echo "[bootstrap] registering backchannel logout URL on frontend client '$KEYCLOAK_FRONTEND_CLIENT_ID' ..."
  FRONTEND_CLIENT_LIST=$(curl -s \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients?clientId=$KEYCLOAK_FRONTEND_CLIENT_ID&max=1")
  FRONTEND_UUID=$(echo "$FRONTEND_CLIENT_LIST" | python3 -c \
    "import json,sys; c=json.load(sys.stdin); print(c[0]['id'] if c else '')" 2>/dev/null || true)

  if [ -n "$FRONTEND_UUID" ]; then
    CLIENT_REP=$(curl -s \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients/$FRONTEND_UUID")
    PATCHED_REP=$(echo "$CLIENT_REP" | BACKCHANNEL_LOGOUT_URL="$BACKCHANNEL_LOGOUT_URL" python3 -c "
import json, os, sys
rep = json.load(sys.stdin)
rep.setdefault('attributes', {})['backchannel.logout.url'] = os.environ['BACKCHANNEL_LOGOUT_URL']
rep.setdefault('attributes', {})['backchannel.logout.session.required'] = 'true'
rep.setdefault('attributes', {})['backchannel.logout.revoke.offline.tokens'] = 'false'
# Disable front-channel logout so Keycloak uses back-channel SLO (server-to-server)
# instead of requiring a browser to load an iframe. Front-channel fails for
# server-initiated logouts (admin API / token revocation) since there is no
# browser involved.
rep['frontchannelLogout'] = False
print(json.dumps(rep))")
    curl -sS -o /dev/null -X PUT \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$PATCHED_REP" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/clients/$FRONTEND_UUID" \
      || echo "[bootstrap] backchannel logout URL update failed (non-fatal)"
    echo "[bootstrap] backchannel logout URL set to $BACKCHANNEL_LOGOUT_URL"
  else
    echo "[bootstrap] WARNING: frontend client '$KEYCLOAK_FRONTEND_CLIENT_ID' not found — backchannel logout URL not registered"
  fi
elif [ -n "${BACKCHANNEL_LOGOUT_URL:-}" ]; then
  echo "[bootstrap] WARNING: BACKCHANNEL_LOGOUT_URL set but KEYCLOAK_FRONTEND_CLIENT_ID is unset — backchannel logout URL not registered"
fi

echo "[bootstrap] done"
