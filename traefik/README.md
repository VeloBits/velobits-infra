# Traefik — VeloBits Edge Reverse Proxy

Traefik is the **edge layer** of the VeloBits platform.

## Responsibility

```
INTERNET → Traefik (subdomain rules) → Kong (path → microservice) → backend services
```

Traefik uses the **file provider** (`traefik/rules/` for dev,
`traefik/rules-prod/` for prod) rather than Docker labels. Rules therefore live
in this repo for every product, not in each product's compose file — it avoids
Docker API-version compatibility issues on newer daemons, and it keeps the
public hostname map in one reviewable place.

## Hostname convention

**This table is the source of truth.** Product repos reference these names; they
do not invent their own.

| Role | Production | Development |
|---|---|---|
| Identity (Keycloak) | `auth.velobits.dev` | `auth-dev.velobits.dev` |
| Product **API** | `api.<app>.velobits.dev` | `api-dev.<app>.velobits.dev` |
| Product frontend | `<app>.velobits.dev` | `<app>-dev.velobits.dev` |
| Frontend sub-app | `<app>-<sub>.velobits.dev` | `<app>-dev-<sub>.velobits.dev` |
| Traefik dashboard | — | `traefik.velobits.dev` |

`<app>` is the product slug: `fixmytext`, `toggleflow`, and later `chat` /
`notes`. So the FixMyText API is `api.fixmytext.velobits.dev` in production and
`api-dev.fixmytext.velobits.dev` in development.

**Why APIs are second-level.** Each product owns its own API namespace instead
of competing for one shared `api.velobits.dev`. Identity stays first-level
because it is genuinely org-wide, not per-product.

**The cost of that choice — read before adding a new API name:**

1. A `*.velobits.dev` certificate does **not** cover `api.<app>.velobits.dev`.
   The dev mkcert cert lists each one explicitly (see [rules/tls.yml](rules/tls.yml));
   add `"*.<app>.velobits.dev"` there when onboarding a product.
2. A `*.velobits.dev` DNS record does not cover it either — each API name needs
   its own A record (or a `*.<app>.velobits.dev` wildcard).
3. On Cloudflare, set API records to **DNS only** (grey cloud). The free
   Universal SSL edge cert covers `velobits.dev` and `*.velobits.dev` only, so a
   proxied second-level name serves a mismatched cert. Proxying anyway needs
   Advanced Certificate Manager (paid). Let's Encrypt on Traefik (`certResolver: le`)
   fronts these names directly instead.

### Current routes

| Host | Upstream | Environment |
|---|---|---|
| `auth-dev.velobits.dev` | `keycloak-dev:8080` | dev |
| `api-dev.fixmytext.velobits.dev` | `kong:8000` | dev |
| `fixmytext-dev.velobits.dev` | `fixmytext-router:3100` | dev |
| `fixmytext-dev-{editor,analytics,content,shell}.velobits.dev` | host ports 3101–3104 | dev |
| `api-dev.toggleflow.velobits.dev` | `toggleflow-api-dev:4000` | dev |
| `toggleflow-dev.velobits.dev` | host port 3200 | dev |
| `velobits.dev` | `velobits-website-dev:3000` | dev |
| `traefik.velobits.dev` | `api@internal` (dashboard) | dev |
| `auth.velobits.dev` | `velobits-auth:8080` | prod |
| `api.fixmytext.velobits.dev` | `kong-prod:8000` | prod |

## Local development

Traefik routes by `Host` header, so the browser needs these names to resolve to
localhost. Add the ones you need to `/etc/hosts` (Windows:
`C:\Windows\System32\drivers\etc\hosts`):

```bash
sudo tee -a /etc/hosts <<EOF
127.0.0.1 auth-dev.velobits.dev
127.0.0.1 api-dev.fixmytext.velobits.dev
127.0.0.1 fixmytext-dev.velobits.dev
127.0.0.1 traefik.velobits.dev
EOF
```

You also need the mkcert certificate — `:80` redirects to `:443` and `.dev` is
HSTS-preloaded, so plain HTTP can never work:

```bash
mkcert -install
mkcert -cert-file traefik/certs/velobits-dev.crt -key-file traefik/certs/velobits-dev.key \
  "*.velobits.dev" velobits.dev "*.toggleflow.velobits.dev" "*.fixmytext.velobits.dev" \
  localhost 127.0.0.1
docker compose up -d
# https://auth-dev.velobits.dev                      → Keycloak login
# https://api-dev.fixmytext.velobits.dev/health      → Kong-routed health check
```

Without the hosts entries everything is still reachable on direct localhost
ports: Keycloak at `http://localhost:8080`, Kong at `http://localhost:8000`.

## Adding a new route

Add a router and a service to a file in `traefik/rules/` (dev) or
`traefik/rules-prod/` (prod). Dev rules terminate TLS with the shared mkcert
store (`tls: {}`); prod rules request their own Let's Encrypt certificate:

```yaml
http:
  routers:
    my-service-dev:
      rule: "Host(`api-dev.myapp.velobits.dev`)"
      priority: 10
      entryPoints:
        - websecure          # :80 always redirects here
      service: my-service-dev-svc
      tls: {}                # prod: tls: { certResolver: le }
  services:
    my-service-dev-svc:
      loadBalancer:
        servers:
          - url: "http://my-service:8000"    # container on velobits-proxy-net
```

Checklist for a new product API name: add the router, add
`"*.<app>.velobits.dev"` to the mkcert command in [rules/tls.yml](rules/tls.yml)
and regenerate, add the `/etc/hosts` line, and for prod create the DNS record as
**DNS only**.

The upstream must be reachable from the Traefik container — that means joining
`velobits-proxy-net` (product gateways do) or, for a process on the host,
`http://host.docker.internal:<port>`.

Traefik hot-reloads `rules/` changes (`watch: true`). Two caveats:

- **Static** config (`traefik.yml`, entry points, providers) is *not* hot-reloaded
  — `docker compose restart traefik`.
- Docker Desktop on Windows often drops bind-mount change events, so after
  editing any Traefik file: `docker restart velobits-traefik`.

CI asserts every router in `rules/` actually loads as `enabled` (a typo'd
matcher silently disables a router rather than failing), so a broken rule fails
the build rather than 404ing at runtime.

## Production

`docker-compose-prod.yml` runs Traefik with its static config as CLI flags
instead of a mounted file, and differs from dev in three ways:

1. Let's Encrypt HTTP-01 (`certResolver: le`) instead of the mkcert store, with
   `acme.json` in a named volume so restarts don't re-issue and hit rate limits.
2. Rules come from `traefik/rules-prod/`.
3. `:80` serves the ACME challenge as well as the HTTPS redirect — it must stay
   open to the internet.

DNS for every hostname in `rules-prod/` must point at the host **before** the
rule is deployed: Traefik requests the certificate as soon as the router loads,
and issuance failures back off. See
[docs/octopus-deployment.md](../docs/octopus-deployment.md) for the deploy path.
