# ─────────────────────────────────────────────────────────────────────────────
# velobits-auth — self-contained production Keycloak image for auth.velobits.dev
#
# One multi-stage Dockerfile, layered so each concern is isolated and the build
# cache is reused aggressively. Build tools (Node, Maven, JDK) live only in the
# theme stage and never reach the final image.
#
#   STAGE 1  theme    Node + Maven + JDK  ─▶  velobits.jar
#     layer 1a  toolchain      apt install (cached until this line changes)
#     layer 1b  install        COPY source + npm ci (keycloakify's postinstall
#                              `sync-extensions` crawls src/, so source must be
#                              present — deps can't be cached ahead of it)
#     layer 1c  build          vite + keycloakify build
#
#   STAGE 2  builder  Keycloak            ─▶  optimized build (kc.sh build)
#     layer 2a  provider       COPY the jar into providers/
#     layer 2b  augment        kc.sh build (Postgres + health/metrics baked in)
#
#   STAGE 3  runtime  Keycloak            ─▶  the shippable image
#     layer 3a  optimized dist COPY from builder
#     layer 3b  realm import   COPY realm-export-prod.json into data/import/
#
# Build context is the REPO ROOT (see docker-compose-prod.yml) so this file can
# reach both keycloak-theme/ and keycloak/. A root .dockerignore keeps it small.
# Rebuild when the theme source, the realm export, or the Keycloak version change.
# ─────────────────────────────────────────────────────────────────────────────


# ══ STAGE 1 — theme: compile the Keycloakify velobits theme into a jar ════════
# Toolchain mirrors builder.Dockerfile (Node 22 + JDK 17 + Maven). keycloakify
# shells out to Maven to package the resources-only jar; the Debian JDK 17 vs
# CI's temurin 21 difference doesn't affect a resources-only artifact.

# ── layer 1a: toolchain ──
FROM node:22-bookworm-slim AS theme
RUN apt-get update \
 && apt-get install -y --no-install-recommends maven openjdk-17-jdk-headless \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /work

# ── layer 1b: install ──
# Full theme source is copied BEFORE npm ci because keycloakify's postinstall
# hook (`sync-extensions`) crawls src/ — it fails if only package*.json is
# present. Same order the dev keycloak-theme-builder uses. npm ci needs network.
COPY keycloak-theme/ ./
RUN npm ci

# ── layer 1c: build ──
# `build-keycloak-theme` = tsc -b + vite build + keycloakify build.
# Output: /work/dist_keycloak/velobits.jar (name pinned in vite.config.ts).
RUN npm run build-keycloak-theme \
 && test -f dist_keycloak/velobits.jar


# ══ STAGE 2 — builder: augment Keycloak (optimized build) ═════════════════════
# DB vendor + feature flags are baked here so the runtime needs no `build` step.
# Connection details stay runtime env. KC_HEALTH_ENABLED exposes /health on the
# management port (9000) for the compose healthcheck.
FROM quay.io/keycloak/keycloak:26.0.8 AS builder
ENV KC_DB=postgres
ENV KC_HEALTH_ENABLED=true
ENV KC_METRICS_ENABLED=true

# ── layer 2a: provider ──
COPY --from=theme /work/dist_keycloak/velobits.jar /opt/keycloak/providers/

# ── layer 2b: augment ──
RUN /opt/keycloak/bin/kc.sh build


# ══ STAGE 3 — runtime: the shippable, environment-agnostic image ══════════════
# Hostname / proxy / DB-connection settings are supplied at runtime
# (docker-compose-prod.yml), never baked. `--import-realm` is idempotent —
# Keycloak skips it once the realm already exists.
FROM quay.io/keycloak/keycloak:26.0.8

# ── layer 3a: optimized distribution ──
COPY --from=builder /opt/keycloak/ /opt/keycloak/

# ── layer 3b: realm import ──
COPY keycloak/realm-export-prod.json /opt/keycloak/data/import/realm.json

ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
CMD ["start", "--optimized", "--import-realm"]
