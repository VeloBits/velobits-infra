# Traefik — VeloBits Edge Reverse Proxy

Traefik is the **edge layer** of the VeloBits platform.

## Responsibility

```
INTERNET → Traefik (subdomain/path rules) → Kong (path → microservice) → Backend services
```

In local dev, Traefik uses the file provider rules in `gateway/traefik/rules/`
instead of Docker labels. This avoids Docker API-version compatibility issues
with newer Docker daemons.

Traefik routes by **Host header**:

| Host | Container | Environment |
|---|---|---|
| `auth-dev.velobits.dev` | `keycloak-dev` | dev |
| `api-dev.velobits.dev` | `kong` | dev |
| `develop-fixmytext.velobits.dev` | frontend dev container | dev |
| `auth.velobits.dev` | `keycloak-prod` | prod |
| `api.velobits.dev` | `kong-prod` | prod |
| `fixmytext.velobits.dev` | `frontend-prod` | prod |
| `chat.velobits.dev`, `notes.velobits.dev` | future products | prod |

## Local development

Traefik routes by `Host` header, so your browser needs the hostnames to resolve to localhost. Add these to `/etc/hosts`:

```bash
sudo tee -a /etc/hosts <<EOF
127.0.0.1 auth-dev.velobits.dev
127.0.0.1 api-dev.velobits.dev
127.0.0.1 develop-fixmytext.velobits.dev
EOF
```

Then:

```bash
docker compose --profile dev up --build
# Open http://auth-dev.velobits.dev → Keycloak login screen
# Open http://api-dev.velobits.dev/health → Kong-routed health check
```

The Traefik dashboard is at `http://127.0.0.1:8090` (dev-only; localhost-bound for safety).

## Adding a new subdomain route

For a new local-dev route, add a router and service to
`gateway/traefik/rules/*.yml`:

```yaml
http:
  routers:
    my-service:
      rule: "Host(`my-service-dev.velobits.dev`)"
      entryPoints:
        - web
      service: my-service-svc
  services:
    my-service-svc:
      loadBalancer:
        servers:
          - url: "http://my-service:8000"
```

That's it. Traefik picks up file changes automatically (`watch: true`).

## Production deployment

Production adds:
1. TLS entry point on `:443`
2. Let's Encrypt for cert provisioning
3. A `prod` profile in docker-compose with `auth.velobits.dev`, `api.velobits.dev`, `fixmytext.velobits.dev` services
4. Real DNS records pointing at the production server
