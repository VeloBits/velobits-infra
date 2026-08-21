# velobits-infra

Shared VeloBits platform infrastructure: the **Traefik edge proxy** and the
**Keycloak identity provider** (Velobits realms). Extracted from
`fixmytext-backend` with full git history preserved.

```
velobits-infra/
├── docker-compose.yml     ← dev stack: Traefik + Keycloak (+ its own Postgres)
├── keycloak/              ← realm exports, bootstrap.sh, login/email themes
├── traefik/               ← static config reference + file-provider rules
├── octopus/               ← Octopus deploy assets (deploy.sh, env template, override)
└── docs/
    ├── keycloak-production-setup.md   ← prod provisioning runbook
    └── octopus-deployment.md          ← CD runbook: any-branch deploys via Octopus
```

## Responsibility

```
INTERNET → Traefik (subdomain rules) → product gateways (Kong) → backend services
                     └→ Keycloak (auth.velobits.dev / auth-dev.velobits.dev)
```

This repo owns everything **org-level**: the `*.velobits.dev` edge and the
shared identity realms (`Velobits` / `Velobits-Prod`). Product-level
gateway config (Kong routes, per-endpoint rate limits) stays in each product
repo — for FixMyText that is `fixmytext-backend/gateway/kong/`.

## Quickstart (dev)

```bash
cp .env.example .env    # fill in KEYCLOAK_DEV_* at minimum
docker compose up -d
```

Brings up:

| Service | Address | Purpose |
|---|---|---|
| `traefik` | `:80` → redirects to `:443`, dashboard at `https://traefik.velobits.dev` | Edge routing for `*.velobits.dev` |
| `keycloak-dev` | `127.0.0.1:8080` | Velobits realm (auto-imported) |
| `keycloak-dev-db` | internal only | Keycloak's own Postgres 16 |
| `keycloak-bootstrap` | one-shot | Provisions IdPs / SMTP / service account via Admin API |

## The `velobits-proxy-net` network contract

This stack **creates** two fixed-name Docker networks (neither is declared
`external` here — creating them is this repo's job):

| Network | Purpose |
|---|---|
| `velobits-net` | this stack's private segment: Keycloak ↔ its own Postgres |
| `velobits-proxy-net` | the cross-stack seam: Traefik ↔ product gateways ↔ Keycloak |

Product stacks join **`velobits-proxy-net`** as external:

```yaml
# in a product repo's docker-compose.yml
networks:
  velobits-proxy-net:
    name: velobits-proxy-net
    external: true
```

DNS names on `velobits-proxy-net` (compose registers each service's *service
name* as a network alias, so the name below is the compose service key — not
necessarily `container_name`):

| Name | Provided by | Consumed by |
|---|---|---|
| `keycloak-dev:8080` | this repo (dev) | product backends (JWKS, Admin API) |
| `velobits-auth:8080` | this repo (prod) | product backends (JWKS, Admin API) |
| `kong:8000` | `fixmytext-backend` (dev) | Traefik router + Keycloak backchannel logout |
| `kong-prod:8000` | `fixmytext-backend` (prod) | Traefik router + Keycloak backchannel logout |

Any product service that validates tokens must be **on this network** — a
backend that only joins its own project network cannot resolve `keycloak-dev`.

**Start order:** this stack first (it creates the networks), then the product
stack. If you need a product stack without this one, create the shared network
manually: `docker network create velobits-proxy-net`.

## Local development with subdomains (optional)

Traefik routes by `Host` header. Add these `/etc/hosts` entries to use the
`*.velobits.dev` subdomains locally:

```bash
sudo tee -a /etc/hosts <<EOF
127.0.0.1 auth-dev.velobits.dev
127.0.0.1 api-dev.fixmytext.velobits.dev
127.0.0.1 fixmytext-dev.velobits.dev
127.0.0.1 traefik.velobits.dev
EOF
```

| URL | Routed to |
|---|---|
| `https://auth-dev.velobits.dev` | `keycloak-dev` |
| `https://api-dev.fixmytext.velobits.dev` | `kong` (fixmytext-backend stack) |
| `https://fixmytext-dev.velobits.dev` | frontend router (`fixmytext-router:3100`) |
| `https://traefik.velobits.dev` | Traefik dashboard |

Product APIs are second-level names (`api-dev.<app>.velobits.dev`) so each
product owns its own API namespace — the full convention, and the certificate
and DNS consequences of it, are documented in
[traefik/README.md](traefik/README.md). These URLs are **https only**: `:80`
redirects to `:443` and `.dev` is HSTS-preloaded, so you also need the mkcert
certificate (same doc).

Without the hosts entries everything still works via direct localhost ports:
Keycloak at `http://localhost:8080`, Kong at `http://localhost:8000`.

Routing rules live in [traefik/rules/](traefik/rules/) (file provider,
hot-reloaded). See [traefik/README.md](traefik/README.md) for adding routes.

## Keycloak

See [keycloak/README.md](keycloak/README.md) for realms, clients, and the
bootstrap contract, and
[docs/keycloak-production-setup.md](docs/keycloak-production-setup.md) for
production provisioning.

Secrets shared with product stacks (keep the `.env` files in sync):

- `KEYCLOAK_SERVICE_ACCOUNT_ID` / `KEYCLOAK_SERVICE_ACCOUNT_SECRET` — created
  here by `bootstrap.sh`, used by `account-svc` in `fixmytext-backend`.

## CI

`.github/workflows/ci.yml` validates on every push/PR:

1. Traefik file-provider rules actually load as `enabled` routers (API check).
2. Keycloak realm exports are valid JSON.
3. `docker compose config` renders.
4. Realm import gate: boots the pinned Keycloak image with
   `realm-export-dev.json` and asserts the import succeeds (runs only when
   `keycloak/**` changes).

`codeql.yml` scans the Actions workflows (`actions` language) on push/PR and
weekly. Renovate keeps image tags and action digests updated (renovate.json).

## CD (Octopus Deploy)

`.github/workflows/deploy.yml` is a **manual, any-branch** pipeline: run it
from the Actions tab on whichever branch you want deployed. It builds the
theme jar, packages the runtime files + theme source, and creates an Octopus
release — feature branches can only reach the **Development** environment
(dev stack, prebuilt jar); `main` releases promote **Development →
Production** from the Octopus portal, where the deploy bakes the
`velobits-auth` image on the target host (`docker-compose-prod.yml` +
`keycloak-theme/prod.Dockerfile`).
Runtime secrets live in Octopus sensitive variables (never in git); the
GitHub↔Octopus connection uses OIDC, so no API key is stored anywhere.
Deployed environments use a **remote Aiven Postgres** (separate database per
environment) — the local Postgres containers in the compose files only run in
laptop quickstarts, so the VM holds no identity data.

Setup and day-to-day lifecycle: [docs/octopus-deployment.md](docs/octopus-deployment.md).

### Branch protection

Import [.github/rulesets/main-branch.json](.github/rulesets/main-branch.json)
via **Settings → Rules → Rulesets → New ruleset → Import a ruleset**. It
requires PRs into `main` with the "Traefik & Keycloak Config Validation",
"Keycloak Realm Import Gate", and "CodeQL Analysis" checks green (the import
gate reports "skipped" when `keycloak/**` didn't change, which satisfies the
requirement).
