# Traefik — VeloBits Edge Reverse Proxy

Traefik is the **edge layer** of the VeloBits platform.

## Responsibility

```
INTERNET → Traefik (subdomain → container) → Kong (path → microservice) → Backend services
```

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

For a new container, add these labels to its `docker-compose.yml` entry:

```yaml
my-service:
  # ... existing config ...
  labels:
    - "traefik.enable=true"
    - "traefik.http.routers.my-service.rule=Host(`my-service-dev.velobits.dev`)"
    - "traefik.http.services.my-service.loadbalancer.server.port=8000"
```

That's it. Traefik picks up the labels automatically (`watch: true`).

## Production deployment

Production adds:
1. TLS entry point on `:443`
2. Let's Encrypt for cert provisioning
3. A `prod` profile in docker-compose with `auth.velobits.dev`, `api.velobits.dev`, `fixmytext.velobits.dev` services
4. Real DNS records pointing at the production server
