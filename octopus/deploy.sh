#!/usr/bin/env bash
# Octopus post-deployment script for the velobits-infra package step.
#
# Runs on the Oracle VM's Tentacle from the package's custom installation
# directory (e.g. /opt/velobits/development). By the time this executes,
# Octopus has already:
#   1. extracted the deployment package into this directory (purged first),
#   2. substituted project variables into octopus/env.template
#      ("Substitute Variables in Templates" feature).
#
# Full project setup: docs/octopus-deployment.md
set -euo pipefail

# Resolve the package root regardless of the caller's working directory.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── Render .env ───────────────────────────────────────────────────────────────
# Fail fast if a required Octopus variable was left unbound: Octostache leaves
# unmatched tokens in place, so any surviving "#{" means a variable is missing
# in Octopus. Safe to print — unbound lines still hold the token, not a value.
if grep -n '#{' octopus/env.template; then
  echo "[deploy] ERROR: unbound Octopus variables above — define them as project variables scoped to this environment (see docs/octopus-deployment.md)." >&2
  exit 1
fi
umask 077
cp octopus/env.template .env
echo "[deploy] .env rendered ($(grep -c '=' .env) entries, mode 600)"

COMPOSE=(docker compose -f docker-compose.yml -f octopus/docker-compose.deploy.yml)

# `config -q` validates the merged file — and catches docker compose < 2.24,
# which can't parse the !reset tag used by the deploy override.
echo "[deploy] $(docker compose version)"
"${COMPOSE[@]}" config -q

echo "[deploy] pulling pinned images"
"${COMPOSE[@]}" pull --quiet

echo "[deploy] starting stack"
"${COMPOSE[@]}" up -d --remove-orphans

# ── Health gates ──────────────────────────────────────────────────────────────
# keycloak-dev has a container healthcheck (mgmt port 9000 /health/ready).
echo "[deploy] waiting for keycloak-dev to report healthy (max 300s)"
deadline=$((SECONDS + 300))
while :; do
  status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' keycloak-dev 2>/dev/null || echo missing)
  if [ "$status" = "healthy" ]; then
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "[deploy] ERROR: keycloak-dev is '$status' after 300s" >&2
    docker logs --tail 100 keycloak-dev >&2 || true
    exit 1
  fi
  sleep 5
done
echo "[deploy] keycloak-dev healthy"

# keycloak-bootstrap is a one-shot (realm import / IdPs / SMTP / service
# account) that re-runs idempotently on every deploy; it must exit 0.
echo "[deploy] waiting for keycloak-bootstrap to finish (max 300s)"
rc=$(timeout 300 docker wait keycloak-bootstrap || echo timeout)
if [ "$rc" != "0" ]; then
  echo "[deploy] ERROR: keycloak-bootstrap exit status: $rc" >&2
  docker logs --tail 100 keycloak-bootstrap >&2 || true
  exit 1
fi
echo "[deploy] keycloak-bootstrap completed"

# Reclaim space from superseded image layers (dangling only — running images
# and pinned tags are untouched).
docker image prune -f >/dev/null

echo "[deploy] done — stack is up:"
"${COMPOSE[@]}" ps
