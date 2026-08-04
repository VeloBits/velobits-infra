# Octopus Deployment Runbook — any-branch deploys to the Oracle VM

Manual, branch-based deployments of this stack to the Oracle Cloud Ubuntu VM,
managed through Octopus Deploy **Development** and **Production** environments.
Everything here runs on free tiers.

```
GitHub Actions ("Deploy via Octopus", any branch, manual trigger)
  │  builds theme jar → zips runtime files → velobits-infra.<version>.zip
  ▼
Octopus Cloud (free Starter tier)          release + channel + lifecycle
  │  polling Tentacle — VM dials OUT to Octopus :10943; no inbound ports
  ▼
Oracle Ubuntu VM (Tentacle target, roles: velobits-docker-host)
     extract package → render .env from sensitive variables → deploy.sh
     → docker compose up -d → health gates (Keycloak + bootstrap)
```

| Piece | What it costs |
|---|---|
| Octopus Cloud **Starter** | Free — up to 10 targets, 10 projects, 10 users ([pricing](https://octopus.com/pricing/overview)) |
| GitHub Actions | Free minutes on the org plan (this workflow uses ~5 min/run) |
| Secret storage | Octopus **sensitive variables** (AES-encrypted, log-masked) + GitHub **OIDC** (no stored API key) — $0 |
| Oracle VM | Always-free ARM/AMD shape you already have |

Repo files that make this work:

- [.github/workflows/deploy.yml](../.github/workflows/deploy.yml) — the manual pipeline
- [octopus/deploy.sh](../octopus/deploy.sh) — runs on the VM per deploy
- [octopus/env.template](../octopus/env.template) — Octopus-variable → `.env` mapping
- [octopus/docker-compose.deploy.yml](../octopus/docker-compose.deploy.yml) — deploy-time compose override

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
   `/opt/velobits/#{Octopus.Environment.Name | ToLower}`
   and tick **Purge this directory before installation** (safe: runtime state
   lives in Docker volumes; `.env` is re-rendered every deploy).
2. **Substitute Variables in Templates** → target files: `octopus/env.template`
3. **Custom Deployment Scripts** → *Post-deployment script*, Bash:

   ```bash
   bash octopus/deploy.sh
   ```

Optional but recommended before going live: **Add step → Manual Intervention
Required**, scoped to the `Production` environment only, placed *before* the
package step — gives you an explicit approval click on every prod deploy.

## Part 4 — Project variables (once, then on rotation)

Project → Variables. Names map 1:1 to
[octopus/env.template](../octopus/env.template); scope each value to an
environment. Mark 🔒 rows **sensitive** (type: Sensitive) — encrypted at rest,
masked in logs.

| Variable | Development value | Production value | 🔒 |
|---|---|---|---|
| `COMPOSE_PROJECT_NAME` | `velobits-dev` | `velobits-prod` | |
| `KC_HOSTNAME` | `auth-dev.velobits.dev` | `auth.velobits.dev` | |
| `KEYCLOAK_DEV_ADMIN_USER` | `admin` (optional) | e.g. `vb-admin` | |
| `KEYCLOAK_DEV_ADMIN_PASSWORD` | `openssl rand -base64 32` | different value | 🔒 |
| `KEYCLOAK_DEV_DB_USER` | `keycloak` | `keycloak` | |
| `KEYCLOAK_DEV_DB_PASSWORD` | `openssl rand -base64 24` | different value | 🔒 |
| `KEYCLOAK_SERVICE_ACCOUNT_ID` | `account-svc` (optional) | `account-svc` | |
| `KEYCLOAK_SERVICE_ACCOUNT_SECRET` | shared with product stack | different value | 🔒 |
| `BACKCHANNEL_LOGOUT_URL` | (omit → kong dev default) | `https://api.velobits.dev/api/v1/auth/backchannel-logout` | |
| `KEYCLOAK_FRONTEND_CLIENT_ID` | (omit → `local-velobits`) | `fixmytext` | |
| `GOOGLE_OAUTH_CLIENT_ID` / `_SECRET` | optional | optional | 🔒 secret |
| `GH_OAUTH_CLIENT_ID` / `_SECRET` | optional | optional | 🔒 secret |
| `SMTP_HOST` / `SMTP_PORT` / `SMTP_USERNAME` / `SMTP_PASSWORD` / `EMAIL_FROM` | optional | optional | 🔒 password |

Omitted optional variables render empty and the stack degrades gracefully
(same contract as `.env.example`). If a **required** one is missing,
`deploy.sh` fails fast with the unbound token name printed in the task log.

## Part 5 — Connect GitHub to Octopus with OIDC (once)

No API key is stored in GitHub — the workflow exchanges a GitHub-signed OIDC
token for a short-lived Octopus token per run
([docs](https://octopus.com/docs/octopus-rest-api/openid-connect/github-actions)).

1. Octopus → Configuration → Users → **Service Accounts** → Add:
   `github-actions-velobits-infra`. Grant it a team/role that can *create
   releases, push packages, and deploy* in your space (e.g. Project Deployer +
   Package Publisher, or Space Manager while solo).
2. On the service account → **OIDC Identities → Add**:
   - Issuer: `https://token.actions.githubusercontent.com`
   - Subject: `repo:VeloBits/velobits-infra:ref:*`
     (wildcard covers *any branch*, which this pipeline needs; supported since
     Octopus 2024.1 — Cloud is always current)
3. Copy the service account **ID** shown on that page.
4. GitHub repo → Settings → Secrets and variables → Actions → **Variables**:

   | Repo variable | Value |
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

**4. Oracle network for the app itself** (not for deploys): to serve traffic,
allow ingress TCP 80 (and 443 later) in the VCN security list / NSG. Docker
publishes ports via its own iptables chains, so the Ubuntu host firewall
usually needs no extra rules — if 80 is still unreachable after opening the
NSG, check `/etc/iptables/rules.v4` (Oracle images ship a restrictive
default).

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

**Roll back** — Octopus keeps every release + package: open the previous
release → *Deploy to …* → done. Rollback is just re-deploying a known-good
version (data in Docker volumes is untouched).

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

- **One VM, two environments**: `docker-compose.yml` pins container names
  (`velobits-traefik`, `keycloak-dev`…), the `velobits-net` network name, and
  host ports 80/8080 — so Development and Production **cannot run
  side-by-side on the same host**. Registering the one VM in both
  environments is fine to exercise the promotion flow, but a Production
  deploy will replace the running dev stack. When Production goes live,
  either add a second always-free Oracle VM as the Production target (install
  a second Tentacle there, register it only in `Production`, remove the first
  VM from `Production`) — zero pipeline changes — or parameterize the compose
  names/ports.
- **This stack is dev-flavored**: Keycloak runs `start-dev` and imports
  `realm-export-dev.json`. Promote-to-Production gives you process parity
  (approvals, prod secrets, audit), but before real traffic follow
  [keycloak-production-setup.md](keycloak-production-setup.md) (prod realm,
  `start --optimized`, TLS at the edge, transactional SMTP).
- **Re-running a failed workflow attempt** produces version `…​.2` (attempt
  suffix) — expected, keeps packages unique.
- **Compose < 2.24 on the VM** fails fast in `deploy.sh` at `config -q`
  (cannot parse `!reset`): upgrade Docker via `get.docker.com`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Task log: `unbound Octopus variables` + token names | Add the listed variables (Part 4), scoped to the failing environment; redeploy the same release. |
| `create-release` can't find channel | Channel names must match the workflow exactly: `Release`, `Feature branches`. |
| Login step: `Access denied` / no token exchanged | OIDC subject must be `repo:VeloBits/velobits-infra:ref:*` (exact org/repo case); check service account permissions. |
| Target unhealthy in Octopus | `sudo systemctl status "Tentacle: velobits"` on the VM; polling needs outbound 10943 open (default-open on Oracle egress). |
| Keycloak never healthy | `docker logs keycloak-dev` — usually a bad DB password after rotation (rotate DB password requires wiping the `keycloak-dev-pgdata` volume or updating Postgres user in place). |
| Port 80 unreachable from internet | Oracle NSG/security-list ingress rule missing, or the image's default iptables INPUT rules (see Part 6.4). |
