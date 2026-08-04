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
| `traefik` | `:80` (all interfaces), dashboard `127.0.0.1:8090` | Edge routing for `*.velobits.dev` |
| `keycloak-dev` | `127.0.0.1:8080` | Velobits realm (auto-imported) |
| `keycloak-dev-db` | internal only | Keycloak's own Postgres 16 |
| `keycloak-bootstrap` | one-shot | Provisions IdPs / SMTP / service account via Admin API |

## The `velobits-net` network contract

This stack **creates** the shared Docker network `velobits-net`
(fixed name, attachable). Product stacks join it as an external network:

```yaml
# in a product repo's docker-compose.yml
networks:
  velobits-net:
    external: true
```

DNS names on the shared network:

| Name | Provided by | Consumed by |
|---|---|---|
| `keycloak-dev:8080` | this repo | product backends (JWKS, Admin API) |
| `kong:8000` | `fixmytext-backend` | Traefik router + Keycloak backchannel logout |

**Start order:** this stack first (it creates the network), then the product
stack. If you need the product stack without this one, create the network
manually: `docker network create velobits-net`.

## Local development with subdomains (optional)

Traefik routes by `Host` header. Add these `/etc/hosts` entries to use the
`*.velobits.dev` subdomains locally:

```bash
sudo tee -a /etc/hosts <<EOF
127.0.0.1 auth-dev.velobits.dev
127.0.0.1 api-dev.velobits.dev
127.0.0.1 develop-fixmytext.velobits.dev
EOF
```

| URL | Routed to |
|---|---|
| `http://auth-dev.velobits.dev` | `keycloak-dev` |
| `http://api-dev.velobits.dev` | `kong` (fixmytext-backend stack) |
| `http://develop-fixmytext.velobits.dev` | frontend dev server on the host |

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
theme jar, packages the runtime files, and creates an Octopus release —
feature branches can only reach the **Development** environment; `main`
releases promote **Development → Production** from the Octopus portal.
Runtime secrets live in Octopus sensitive variables (never in git); the
GitHub↔Octopus connection uses OIDC, so no API key is stored anywhere.

Setup and day-to-day lifecycle: [docs/octopus-deployment.md](docs/octopus-deployment.md).

### Branch protection

Import [.github/rulesets/main-branch.json](.github/rulesets/main-branch.json)
via **Settings → Rules → Rulesets → New ruleset → Import a ruleset**. It
requires PRs into `main` with the "Traefik & Keycloak Config Validation",
"Keycloak Realm Import Gate", and "CodeQL Analysis" checks green (the import
gate reports "skipped" when `keycloak/**` didn't change, which satisfies the
requirement).
