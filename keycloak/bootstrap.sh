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
#   KEYCLOAK_REALM          (default: fixmytext)
#   REALM_EXPORT_PATH       (default: ./realm-export.json relative to this script)
#
# Exit codes:
#   0  success / already bootstrapped
#   1  missing required env
#   2  Keycloak not reachable
#   3  admin auth failed

set -euo pipefail

KEYCLOAK_URL="${KEYCLOAK_URL:-http://localhost:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
# Sprint 5b: default realm is now Velobits-Dev. The legacy 'fixmytext' realm
# name is no longer the default. Production uses Velobits-Prod (override via env).
KEYCLOAK_REALM="${KEYCLOAK_REALM:-Velobits-Dev}"
# Sprint 5b: dual realm exports. Dev imports realm-export-dev.json by default;
# prod imports realm-export-prod.json via REALM_EXPORT_PATH override.
REALM_EXPORT_PATH="${REALM_EXPORT_PATH:-$(dirname "$0")/realm-export-dev.json}"

if [[ -z "${KEYCLOAK_ADMIN_PASSWORD:-}" ]]; then
  echo "[bootstrap] FATAL: KEYCLOAK_ADMIN_PASSWORD not set" >&2
  exit 1
fi

# ── 1. Wait for Keycloak to be reachable ─────────────────────────────────────
echo "[bootstrap] waiting for Keycloak at $KEYCLOAK_URL ..."
for i in {1..60}; do
  if curl -fsS "$KEYCLOAK_URL/health/ready" >/dev/null 2>&1; then
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

if [[ "$REALM_STATUS" == "200" ]]; then
  echo "[bootstrap] realm '$KEYCLOAK_REALM' already exists — nothing to do"
  exit 0
fi

# ── 4. Import realm from JSON ────────────────────────────────────────────────
if [[ "${1:-}" != "--skip-realm-import" ]]; then
  echo "[bootstrap] importing realm from $REALM_EXPORT_PATH ..."
  curl -fsS -X POST \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "@$REALM_EXPORT_PATH" \
    "$KEYCLOAK_URL/admin/realms"
  echo "[bootstrap] realm imported"
fi

# ── Configure SMTP via Admin API (env vars not interpolated in realm JSON) ─────
if [ -n "${SMTP_HOST:-}" ] && [ -n "${SMTP_USERNAME:-}" ]; then
  echo "[bootstrap] configuring realm SMTP..."
  curl -fsS -X PUT \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"smtpServer\": {
        \"host\": \"${SMTP_HOST}\",
        \"port\": \"${SMTP_PORT:-587}\",
        \"from\": \"${EMAIL_FROM:-noreply@fixmytext.local}\",
        \"auth\": true,
        \"user\": \"${SMTP_USERNAME}\",
        \"password\": \"${SMTP_PASSWORD}\",
        \"ssl\": false,
        \"starttls\": true
      }
    }" \
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
    curl -fsS -X POST \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"alias\": \"google\",
        \"providerId\": \"google\",
        \"enabled\": true,
        \"trustEmail\": true,
        \"config\": {
          \"clientId\": \"${GOOGLE_OAUTH_CLIENT_ID}\",
          \"clientSecret\": \"${GOOGLE_OAUTH_CLIENT_SECRET}\",
          \"defaultScope\": \"openid email profile\"
        }
      }" \
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
    curl -fsS -X POST \
      -H "Authorization: Bearer $ADMIN_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"alias\": \"github\",
        \"providerId\": \"github\",
        \"enabled\": true,
        \"trustEmail\": true,
        \"config\": {
          \"clientId\": \"${GH_OAUTH_CLIENT_ID}\",
          \"clientSecret\": \"${GH_OAUTH_CLIENT_SECRET}\"
        }
      }" \
      "$KEYCLOAK_URL/admin/realms/$KEYCLOAK_REALM/identity-provider/instances" \
      || echo "[bootstrap] GitHub IdP creation failed (non-fatal)"
    echo "[bootstrap] GitHub IdP configured"
  else
    echo "[bootstrap] GitHub IdP already exists"
  fi
fi

echo "[bootstrap] done"
