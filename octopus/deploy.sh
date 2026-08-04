#!/usr/bin/env bash
# Octopus post-deployment script for the velobits-infra package step.
#
# Runs on the VM's Tentacle from the package's custom installation directory
# (/opt/velobits/velobits-infra/development or .../production). Octopus invokes it
# from the step's post-deployment script as:
#
#   DEPLOY_ENV=$(get_octopusvariable "Octopus.Environment.Name") bash octopus/deploy.sh
#
# By then Octopus has already extracted the package (purging the directory
# first) and substituted project variables into octopus/env.*.template.
#
# What runs depends on the environment:
#   Development  docker-compose.yml + octopus/docker-compose.deploy.yml
#                start-dev stack; the theme jar is PREBUILT by CI and shipped
#                in the package, and the bootstrap sidecar provisions
#                IdPs/SMTP/service account idempotently.
#   Production   docker-compose-prod.yml
#                immutable velobits-auth image (theme + kc.sh build + prod
#                realm baked in, keycloak-theme/prod.Dockerfile) built ON THIS
#                HOST from the packaged sources — native CPU arch, no registry
#                account needed. Traefik terminates TLS via Let's Encrypt.
#
# Full project setup: docs/octopus-deployment.md
set -euo pipefail

# Resolve the package root regardless of the caller's working directory.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Select the stack ──────────────────────────────────────────────────────────
env_lc=$(printf '%s' "${DEPLOY_ENV:-}" | tr '[:upper:]' '[:lower:]')
case "$env_lc" in
  development)
    TEMPLATE=octopus/env.dev.template
    COMPOSE=(docker compose -f docker-compose.yml -f octopus/docker-compose.deploy.yml)
    HEALTH_CONTAINER=keycloak-dev
    BOOTSTRAP_CONTAINER=keycloak-bootstrap
    BUILD_ON_HOST=0
    ;;
  production)
    TEMPLATE=octopus/env.prod.template
    COMPOSE=(docker compose -f docker-compose-prod.yml)
    HEALTH_CONTAINER=velobits-auth
    BOOTSTRAP_CONTAINER=""
    BUILD_ON_HOST=1
    ;;
  *)
    echo "[deploy] ERROR: DEPLOY_ENV must be 'Development' or 'Production' (got '${DEPLOY_ENV:-<unset>}')" >&2
    exit 1
    ;;
esac
echo "[deploy] environment: ${DEPLOY_ENV} — template: ${TEMPLATE}"

# ── Render .env ───────────────────────────────────────────────────────────────
# Fail fast if a required Octopus variable was left unbound: Octostache leaves
# unmatched tokens in place, so any surviving "#{" means a variable is missing
# in Octopus. Safe to print — unbound lines still hold the token, not a value.
# (Only the selected template matters; the other environment's template will
# legitimately contain unbound tokens here.)
if grep -n '#{' "$TEMPLATE"; then
  echo "[deploy] ERROR: unbound Octopus variables above — define them as project variables scoped to the ${DEPLOY_ENV} environment (see docs/octopus-deployment.md)." >&2
  exit 1
fi
umask 077
cp "$TEMPLATE" .env
echo "[deploy] .env rendered ($(grep -c '=' .env) entries, mode 600)"

# `config -q` validates the merged file — and, for the dev stack, catches
# docker compose < 2.24, which can't parse the !reset tag in the override.
echo "[deploy] $(docker compose version)"
"${COMPOSE[@]}" config -q

if [ "$BUILD_ON_HOST" = "1" ]; then
  # Keeps the repo-root build context lean; without it the context upload
  # includes the rendered .env and everything else in the package.
  if [ ! -f .dockerignore ]; then
    echo "[deploy] WARNING: .dockerignore missing from package — build context will be bloated" >&2
  fi
  echo "[deploy] building velobits-auth image on this host (--pull refreshes base images;"
  echo "[deploy] first build takes ~10 min for npm ci + kc.sh build, cached afterwards)"
  "${COMPOSE[@]}" build --pull
  echo "[deploy] pulling pinned images (traefik, postgres)"
  "${COMPOSE[@]}" pull --ignore-buildable --quiet
else
  echo "[deploy] pulling pinned images"
  "${COMPOSE[@]}" pull --quiet
fi

# Octopus purges + re-extracts this directory each deploy, so every
# bind-mounted file/dir gets a NEW inode. Running containers keep the deleted
# old inode — compose does not recreate them for mounted-content changes, so
# without an explicit recreate a redeploy would silently keep serving the old
# config.
echo "[deploy] starting stack"
if [ "$BUILD_ON_HOST" = "1" ]; then
  # Prod: velobits-auth is self-contained (no bind mounts) — compose restarts
  # it only when the freshly built image differs, otherwise zero downtime.
  # Traefik bind-mounts rules-prod/ from the package dir, so recreate it
  # unconditionally (stateless, ~1s blip; acme certs live in a named volume).
  "${COMPOSE[@]}" up -d --remove-orphans
  "${COMPOSE[@]}" up -d --force-recreate --no-deps traefik
else
  # Dev: package files are bind-mounted everywhere (traefik rules, realm
  # export, theme jar, bootstrap.sh) — recreate the stack so the shipped
  # config actually applies. Identity data lives on the remote (Aiven)
  # database, so recreation never touches it.
  "${COMPOSE[@]}" up -d --remove-orphans --force-recreate
fi

# ── Health gates ──────────────────────────────────────────────────────────────
# Both Keycloak services expose a container healthcheck (mgmt port 9000
# /health/ready), so gate on Docker's health status.
echo "[deploy] waiting for ${HEALTH_CONTAINER} to report healthy (max 300s)"
deadline=$((SECONDS + 300))
while :; do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$HEALTH_CONTAINER" 2>/dev/null || echo missing)
  if [ "$status" = "healthy" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "[deploy] ERROR: ${HEALTH_CONTAINER} is '$status' after 300s" >&2
    docker logs --tail 100 "$HEALTH_CONTAINER" >&2 || true
    exit 1
  fi
  sleep 5
done
echo "[deploy] ${HEALTH_CONTAINER} healthy"

# Dev only: keycloak-bootstrap is a one-shot (realm import / IdPs / SMTP /
# service account) that re-runs idempotently on every deploy; it must exit 0.
# Prod has no sidecar — the realm is baked into the image (--import-realm is
# idempotent) and the rest is provisioned per docs/keycloak-production-setup.md.
if [ -n "$BOOTSTRAP_CONTAINER" ]; then
  echo "[deploy] waiting for ${BOOTSTRAP_CONTAINER} to finish (max 300s)"
  rc=$(timeout 300 docker wait "$BOOTSTRAP_CONTAINER" || echo timeout)
  if [ "$rc" != "0" ]; then
    echo "[deploy] ERROR: ${BOOTSTRAP_CONTAINER} exit status: $rc" >&2
    docker logs --tail 100 "$BOOTSTRAP_CONTAINER" >&2 || true
    exit 1
  fi
  echo "[deploy] ${BOOTSTRAP_CONTAINER} completed"
fi

# Reclaim space from superseded image layers (dangling only — running images
# and pinned tags are untouched; matters on prod where each source change
# produces a new velobits-auth build).
docker image prune -f >/dev/null

echo "[deploy] done — stack is up:"
"${COMPOSE[@]}" ps
