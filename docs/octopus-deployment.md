# Octopus Deployment Runbook — any-branch deploys to the Oracle VM

Manual, branch-based deployments of this stack to the Oracle Cloud Ubuntu VM,
managed through Octopus Deploy **Development** and **Production** environments.
Everything here runs on free tiers.

```
GitHub Actions ("Deploy via Octopus", any branch, manual trigger)
  │  builds theme jar → zips runtime files + theme source → velobits-infra.<version>.zip
  ▼
Octopus Cloud (free Starter tier)          release + channel + lifecycle
  │  polling Tentacle — VM dials OUT to Octopus :10943; no inbound ports
  ▼
Oracle Ubuntu VM (Tentacle target, roles: velobits-docker-host)
     extract package → render .env from sensitive variables → deploy.sh
     ├─ Development: docker-compose.yml + deploy override
     │    start-dev stack, CI-prebuilt theme jar, bootstrap sidecar
     └─ Production:  docker-compose-prod.yml
          velobits-auth image BAKED ON THE VM (keycloak-theme/prod.Dockerfile:
          theme jar + kc.sh build + prod realm), Traefik + Let's Encrypt :443

     database: BOTH environments use a remote managed Postgres (Aiven free
     plan) with separate databases per environment — the VM runs no database
     container. (The local Postgres services in the compose files exist only
     for laptop quickstarts, parked behind the `local-db` profile on deploys.)
```

Building the production image on the VM (instead of pushing to a registry)
keeps everything free and always matches the VM's CPU architecture; Docker's
layer cache makes unchanged rebuilds near-instant. If you later want registry
distribution, see "Upgrade path" at the end.

| Piece | What it costs |
|---|---|
| Octopus Cloud **Starter** | Free — up to 10 targets, 10 projects, 10 users ([pricing](https://octopus.com/pricing/overview)) |
| GitHub Actions | Free minutes on the org plan (this workflow uses ~5 min/run) |
| Secret storage | Octopus **sensitive variables** (AES-encrypted, log-masked) + GitHub **OIDC** (no stored API key) — $0 |
| Oracle VM | Always-free Ampere A1 shape you already have |
| Production database | [Aiven for PostgreSQL free plan](https://aiven.io/free-postgresql-database) — no time limit, 1 GB storage, automated backups |

Repo files that make this work:

- [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) — the manual pipeline
- [octopus/deploy.sh](../octopus/deploy.sh) — runs on the VM per deploy; picks the stack from `DEPLOY_ENV`
- [octopus/env.dev.template](../octopus/env.dev.template) / [octopus/env.prod.template](../octopus/env.prod.template) — Octopus-variable → `.env` mapping per environment
- [octopus/docker-compose.deploy.yml](../octopus/docker-compose.deploy.yml) — deploy-time override for the dev stack
- [docker-compose-prod.yml](../docker-compose-prod.yml) + [keycloak-theme/prod.Dockerfile](../keycloak-theme/prod.Dockerfile) — the production stack and its baked image

---

## Part 1 — Octopus Cloud instance (once)

1. Sign up at [octopus.com/start](https://octopus.com/start) → **Cloud** →
   instance name e.g. `velobits` → you get `https://velobits.octopus.app`.
   The free Starter tier is selected automatically while you stay ≤10
   targets/projects/users.
2. Stay in the default space (`Default`) or create a `VeloBits` space — if you
   do, set the `OCTOPUS_SPACE` repo variable to match (Part 5).

## Part 2 — Environments, lifecycles, project, channels (once)

**Environments** (Infrastructure → Environments → Add):

1. `Development`
2. `Production`

**Lifecycles** (Deploy → Lifecycles):

| Lifecycle | Phases | Used by |
|---|---|---|
| `Velobits standard` | Phase 1 `Development` → Phase 2 `Production` | Release channel (main) |
| `Development only` | Phase 1 `Development` | Feature branches channel |

Leave "automatic deployment" off in both phases — releases deploy only when
you (or the pipeline) say so. Promotion Development → Production is enforced
by the phase order: Octopus refuses to deploy to Production until the release
succeeded in Development.

**Project** (Projects → Add): name `velobits-infra` (the workflow references
this exact name), default lifecycle `Velobits standard`.

**Channels** (project → Channels) — this is what makes "any branch → dev only,
main → promotable" work:

| Channel | Lifecycle | Version rule (package `velobits-infra`) |
|---|---|---|
| `Release` (make default) | `Velobits standard` | Pre-release tag: `^$` (no tag — only `1.0.N` from main) |
| `Feature branches` | `Development only` | Pre-release tag: `.+` (branch builds like `0.0.N-my-branch`) |

The pipeline versions main builds as `1.0.<run>` and branch builds as
`0.0.<run>-<branch-slug>`, so the pre-release tag alone routes each release to
the right channel — a feature-branch release physically cannot be promoted to
Production.

## Part 3 — Deployment process (once)

Project → Process → **Add step → Package → Deploy a Package**:

| Setting | Value |
|---|---|
| Step name | `Deploy velobits stack` |
| On targets in roles | `velobits-docker-host` |
| Package feed / ID | Built-in feed / `velobits-infra` |

Click **Configure features** and enable all three:

1. **Custom Installation Directory** →
   `/opt/velobits/velobits-infra/#{Octopus.Environment.Name | ToLower}`
   and tick **Purge this directory before installation** (safe: runtime state
   lives in Docker volumes; `.env` is re-rendered every deploy).
2. **Substitute Variables in Templates** → target files (one per line):

   ```
   octopus/env.dev.template
   octopus/env.prod.template
   ```

3. **Custom Deployment Scripts** → *Post-deployment script*, Bash:

   ```bash
   DEPLOY_ENV=$(get_octopusvariable "Octopus.Environment.Name") bash octopus/deploy.sh
   ```

   `deploy.sh` uses `DEPLOY_ENV` to pick the stack: the dev compose files and
   `env.dev.template` in Development, `docker-compose-prod.yml` (with an
   on-VM image build) and `env.prod.template` in Production.

Optional but recommended before going live: **Add step → Manual Intervention
Required**, scoped to the `Production` environment only, placed *before* the
package step — gives you an explicit approval click on every prod deploy.

## Part 4 — Project variables (once, then on rotation)

Project → Variables. Names map 1:1 to the templates; each environment has its
own variable set — scope every value to its environment. Mark 🔒 rows
**sensitive** (type: Sensitive) — encrypted at rest, masked in logs.

**Scoped to `Development`** ([octopus/env.dev.template](../octopus/env.dev.template)):

| Variable | Value | 🔒 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `velobits-dev` — keep it stable (prefixes volume/label names) | |
| `KC_HOSTNAME` | `auth-dev.velobits.dev` | |
| `KEYCLOAK_DEV_ADMIN_USER` | `admin` (optional, default) | |
| `KEYCLOAK_DEV_ADMIN_PASSWORD` | `openssl rand -base64 32` | 🔒 |
| `KEYCLOAK_DEV_DB_URL` | JDBC form of the Aiven URI, **dev database**: `jdbc:postgresql://<host>:<port>/keycloak_dev?sslmode=require` | |
| `KEYCLOAK_DEV_DB_USER` | from the Aiven console | |
| `KEYCLOAK_DEV_DB_PASSWORD` | from the Aiven console | 🔒 |
| `KEYCLOAK_SERVICE_ACCOUNT_ID` | `account-svc` (optional) | |
| `KEYCLOAK_SERVICE_ACCOUNT_SECRET` | shared with product stack `.env` | 🔒 |
| `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` | optional | 🔒 secret |
| `GH_OAUTH_CLIENT_ID` / `_SECRET` | optional | 🔒 secret |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `EMAIL_FROM` | optional | 🔒 password |

**Scoped to `Production`** ([octopus/env.prod.template](../octopus/env.prod.template)) —
deliberately small: `KC_HOSTNAME` is fixed in `docker-compose-prod.yml`, and
SMTP / social IdPs / `account-svc` are provisioned per
[keycloak-production-setup.md](keycloak-production-setup.md), not per deploy:

| Variable | Value | 🔒 |
|---|---|---|
| `COMPOSE_PROJECT_NAME` | `velobits-prod` — keep it stable (prefixes volume names, e.g. the ACME cert store) | |
| `ACME_EMAIL` | ops email for Let's Encrypt expiry notices | |
| `KEYCLOAK_PROD_ADMIN_USER` | optional (default `admin`) | |
| `KEYCLOAK_PROD_ADMIN_PASSWORD` | **not** the dev value | 🔒 |
| `KEYCLOAK_PROD_DB_URL` | JDBC form of the Aiven service URI: `jdbc:postgresql://<host>:<port>/defaultdb?sslmode=require` | |
| `KEYCLOAK_PROD_DB_USER` | from the Aiven console (`avnadmin`, or a dedicated user) | |
| `KEYCLOAK_PROD_DB_PASSWORD` | from the Aiven console | 🔒 |

**The database for BOTH environments is a remote Aiven managed Postgres**
(free plan: no time limit, 1 GB storage, automated backups included) — the VM
runs no database container. A single free service hosts both environments:
create two databases on it in the Aiven console (e.g. `keycloak_dev` and
`keycloak_prod`) and point each environment's `*_DB_URL` at its own database.
Keep `sslmode=require` in the URLs (Aiven enforces TLS), restrict **allowed
IP addresses** to the VM's public IP instead of the default open-to-all, and
pick the Aiven region closest to the Oracle VM. If dev load ever interferes
with prod (they share the service's 1 CPU/1 GB), move prod to its own
service/plan — only the URL variables change.

Omitted optional variables render empty and the stack degrades gracefully
(same contract as `.env.example`). If a **required** one is missing,
`deploy.sh` fails fast with the unbound token name printed in the task log.

## Part 5 — Connect GitHub to Octopus with OIDC (once)

No API key is stored in GitHub — the workflow exchanges a GitHub-signed OIDC
token for a short-lived Octopus token per run
([docs](https://octopus.com/docs/octopus-rest-api/openid-connect/github-actions)).

One **org-wide** service account serves all VeloBits repos: Octopus service
accounts are instance-level (permissions come from team membership), and a
single account can hold **one OIDC identity per repo** — onboarding the next
repo is just another identity + its GitHub variables, no new account.

1. Octopus → Configuration → Users → **Service Accounts** → Add:
   `github-actions-velobits-oidc`. Grant it a team/role that can *create
   releases, push packages, and deploy* in your space (e.g. Project Deployer +
   Package Publisher, or Space Manager while solo).
2. On the service account → **OIDC Identities → Add** (one per repo):
   - Issuer: `https://token.actions.githubusercontent.com`
   - Subject: `repo:VeloBits@146367091/velobits-infra@1308719371:ref:*`
     (wildcard covers *any branch*, which this pipeline needs; supported since
     Octopus 2024.1 — Cloud is always current. GitHub embeds the immutable
     org and repo IDs in the subject, so a plain
     `repo:VeloBits/velobits-infra:ref:*` will NOT match — find a repo's IDs
     with `gh api repos/VeloBits/<repo> --jq '.id,.owner.id'` or copy the
     presented subject from a failed login's error message. Future repos each
     get their own identity — avoid a single `repo:VeloBits*` catch-all so a
     rogue workflow in one repo can't be broadened accidentally.)
3. Copy the service account **ID** shown on that page.
4. GitHub → **Organization** Settings → Secrets and variables → Actions →
   **Variables** (org-level, so every VeloBits repo inherits them —
   repo-level works too if you prefer):

   | Variable | Value |
   |---|---|
   | `OCTOPUS_URL` | `https://velobits.octopus.app` |
   | `OCTOPUS_SERVICE_ACCOUNT_ID` | the ID from step 3 |
   | `OCTOPUS_SPACE` | only if not `Default` |

Fallback (if you'd rather skip OIDC): create an API key on the service
account, store it as **secret** `OCTOPUS_API_KEY`, and in
[deploy.yml](../.github/workflows/deploy.yml) replace the login step's
`service_account_id` input with `api_key: ${{ secrets.OCTOPUS_API_KEY }}`.
OIDC is strictly better: nothing long-lived to leak or rotate.

## Part 6 — Prepare the Oracle VM (once)

SSH in, then:

**1. Docker Engine + Compose v2.24+** (the deploy override uses the compose
`!reset` tag):

```bash
curl -fsSL https://get.docker.com | sudo sh
docker compose version   # want >= 2.24
```

**2. Install the Tentacle** (Ubuntu/Debian,
[official docs](https://octopus.com/docs/infrastructure/deployment-targets/tentacle/linux)):

```bash
sudo apt-key adv --fetch-keys https://apt.octopus.com/public.key
sudo add-apt-repository "deb https://apt.octopus.com/ stable main"
sudo apt-get update && sudo apt-get install -y tentacle
```

**3. Configure it in POLLING mode** — the Tentacle dials out to Octopus Cloud
on port 10943; you open **no inbound ports** on the Oracle NSG for deploys:

```bash
sudo /opt/octopus/tentacle/configure-tentacle.sh
```

Interactive answers:

| Prompt | Answer |
|---|---|
| Instance name | `velobits` (default fine) |
| Kind | **Polling** |
| Octopus URL | `https://velobits.octopus.app` |
| API key | a temporary key from *your* user (Profile → API Keys) — used once for registration, revoke afterwards |
| Space | `Default` (or yours) |
| Register as | Deployment target |
| Environments | `Development,Production` (same box serves both for now — see caveats) |
| Roles | `velobits-docker-host` |
| Name | `oracle-vm-1` |

Verify: Octopus → Infrastructure → Deployment targets → `oracle-vm-1` shows
**Healthy** in both environments.

**4. Oracle network for the app itself** (not for deploys): allow ingress TCP
80 **and** 443 in the VCN security list / NSG — production terminates TLS on
443 and Let's Encrypt's HTTP-01 challenge needs 80. For Production, DNS for
`auth.velobits.dev` must point at this host's public IP *before* the first
deploy, or ACME issuance fails. Docker publishes ports via its own iptables
chains, so the Ubuntu host firewall usually needs no extra rules — if a port
is still unreachable after opening the NSG, check `/etc/iptables/rules.v4`
(Oracle images ship a restrictive default).

> The Tentacle service runs as root by default, which also grants it Docker
> access. Locking it down to a dedicated user in the `docker` group is a
> worthwhile later hardening step (docker-group membership is still
> root-equivalent, but it keeps Octopus file paths contained).

## Part 7 — The deployment lifecycle, day to day

**Deploy any branch to Development**

1. Push your branch.
2. GitHub → Actions → **Deploy via Octopus** → *Run workflow* → pick the
   branch → Run. (Leave "Deploy to Development" ticked.)
3. The run builds the jar, pushes `velobits-infra.0.0.<run>-<branch>.zip`,
   creates a release in **Feature branches**, deploys to **Development**, and
   waits for `deploy.sh`'s health gates (Keycloak healthy + bootstrap exit 0).
   Green workflow = the stack is actually up, not just copied.

**Ship main to Production**

1. Merge to `main`, run the same workflow from `main` → release `1.0.<run>`
   in the **Release** channel deploys to Development.
2. Verify Development, then in the Octopus portal: project → Releases →
   `1.0.<run>` → **Deploy to Production** (approve the manual intervention if
   you added it). Only Release-channel versions offer this button.
3. A Production deploy runs `docker compose -f docker-compose-prod.yml build
   --pull` **on the VM**: the packaged theme source + prod realm are baked
   into the `velobits-auth` image ([prod.Dockerfile](../keycloak-theme/prod.Dockerfile)),
   then the stack starts and the deploy gates on the Keycloak healthcheck.
   First build ≈ 10 min (npm ci + `kc.sh build`); unchanged layers are cached
   after that. The `Velobits-Prod` realm imports on first boot (idempotent).

**What restarts on each deploy** — Octopus purges and re-extracts the install
directory, so bind mounts point at new inodes; `deploy.sh` therefore
recreates what depends on them. Development: the whole stack is recreated
(~60–90 s). Production: Traefik is recreated (~1 s blip; ACME certs persist
in a volume) and `velobits-auth` restarts **only** if the rebuilt image
actually differs — an unchanged prod redeploy is zero-downtime for Keycloak.
The database isn't on the VM in either environment (remote Aiven Postgres),
so deploys and recreations never touch identity data.

**Roll back** — Octopus keeps every release + package: open the previous
release → *Deploy to …* → done. Rollback is just re-deploying a known-good
version (data in Docker volumes is untouched; on prod the image is rebuilt
from that release's packaged sources, hitting the Docker layer cache).

**Audit** — every deploy records who, what version, which commit (version →
run number → Actions run), full task log, and variable snapshot (sensitive
values stay masked).

## Securing secrets — the free setup

| Secret | Lives in | Protection |
|---|---|---|
| Keycloak admin/DB passwords, OAuth secrets, SMTP | Octopus **sensitive variables** | AES-encrypted at rest, masked as `****` in task logs, write-only via UI/API, included in the free tier |
| GitHub → Octopus credential | **nowhere** | OIDC federation (Part 5) — short-lived per-run token, nothing stored |
| `.env` on the VM | rendered per deploy by `deploy.sh` | mode `600`, owner root; recreated (and the directory purged) every deploy |
| Anything in git | — | nothing: `.gitignore` blocks `.env*`; the template holds only variable *names* |

Practices this setup enforces or expects:

- **Different values per environment** — scoping in the variable table makes
  dev/prod separation structural, not disciplinary.
- **Rotation** = edit the variable in Octopus → redeploy the current release.
  No file to touch on the server, no git history risk (remember the
  `security-env-leak` incident checklist item in the
  [Keycloak prod runbook](keycloak-production-setup.md)).
- **Least exposure**: values exist decrypted only inside the Tentacle process
  during a deploy and in the root-only `.env`/container environment on the box
  you already control.
- If you ever *do* want secrets versioned in git instead, the free-tier answer
  is [SOPS](https://github.com/getsops/sops) + [age](https://github.com/FiloSottile/age)
  — but with Octopus in the loop it's redundant; keep one source of truth.

## Caveats & production notes

- **One VM, two environments**: both stacks own port 80 (prod also 443) and
  both declare the `velobits-net` network, so Development and Production
  **cannot run side-by-side on the same host**. Registering the one VM in
  both environments is fine to exercise the full promotion flow, but a
  Production deploy will conflict with a running dev stack (and vice versa).
  When Production goes live, add a second always-free Oracle VM as the
  Production target: install a Tentacle there, register it only in
  `Production` with the same `velobits-docker-host` role, and remove the
  first VM from `Production` — zero pipeline changes.
- **Prod builds happen on the VM**: `npm ci` + vite + `kc.sh build` want
  ~2–4 GB of RAM. The target is an Ampere A1 (4 OCPU / 24 GB, **arm64**) —
  plenty. The arm64 part matters: images built on a stock GitHub runner are
  amd64 and will NOT run on this host, which is exactly why the deploy builds
  natively on the VM. Any future registry-built image must be
  `--platform linux/arm64`.
- **Post-deploy provisioning**: the prod stack intentionally has no bootstrap
  sidecar. After the first Production deploy, configure SMTP / social IdPs /
  `account-svc` per [keycloak-production-setup.md](keycloak-production-setup.md)
  (admin console, or run `keycloak/bootstrap.sh` ad-hoc against
  `https://auth.velobits.dev`), and rotate the bootstrap admin.
- **Re-running a failed workflow attempt** produces version `…​.2` (attempt
  suffix) — expected, keeps packages unique.
- **Compose < 2.24 on the VM** fails fast in `deploy.sh` at `config -q`
  (cannot parse `!reset` in the dev override): upgrade via `get.docker.com`.
- **Upgrade path — registry-distributed image**: if on-VM builds ever become
  a burden (tiny VM, slow deploys), build `velobits-auth` in the workflow
  with `docker buildx` (multi-arch: `linux/amd64,linux/arm64`), push to a
  registry (GHCR private storage is limited on the free plan — ~500 MB —
  which a Keycloak image exceeds; Docker Hub's free tier includes one private
  repo), and switch the prod deploy to `pull` + `up -d`. Keep
  `keycloak/realm-export-prod.json` out of any *public* image — realm exports
  can carry client secrets.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Task log: `unbound Octopus variables` + token names | Add the listed variables (Part 4), scoped to the failing environment; redeploy the same release. |
| `create-release` can't find channel | Channel names must match the workflow exactly: `Release`, `Feature branches`. |
| Login step: `Could not find matching identity` / `Access denied` | The registered OIDC subject must match what GitHub presents, including the immutable IDs: `repo:VeloBits@146367091/velobits-infra@1308719371:ref:*` (the error message prints the exact presented subject — copy from there); check service account permissions. |
| Target unhealthy in Octopus | `sudo systemctl status "Tentacle: velobits"` on the VM; polling needs outbound 10943 open (default-open on Oracle egress). |
| Keycloak never healthy | `docker logs keycloak-dev` (dev) / `docker logs velobits-auth` (prod) — usually a bad DB credential after rotation: rotate in the Aiven console AND the Octopus variable together, then redeploy. |
| Keycloak can't reach the database | Aiven **allowed IP addresses** must include the VM's public IP; URL must be the JDBC form with `sslmode=require` and the right per-environment database name; check the Aiven service is powered on (free services may be shut down if unused for an extended period). |
| Port 80/443 unreachable from internet | Oracle NSG/security-list ingress rule missing, or the image's default iptables INPUT rules (see Part 6.4). |
| Prod image build fails / OOM-killed | The on-VM build needs ~2–4 GB RAM (npm ci + vite + `kc.sh build`). Use a bigger shape or the registry upgrade path (Caveats). |
| Browser shows Traefik default cert on auth.velobits.dev | ACME issuance failed: DNS not pointing at the VM, port 80 closed (HTTP-01), or rate-limited. `docker logs velobits-traefik-prod`; the acme.json volume persists issued certs across restarts. |
| `unknown flag: --ignore-buildable` during prod deploy | docker compose too old on the VM — upgrade via `get.docker.com` (>= 2.24 required anyway). |
