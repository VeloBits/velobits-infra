# velobits Keycloak theme

Keycloakify v11 login theme for the VeloBits realms, built on
[@oussemasahbeni/keycloakify-login-shadcn](https://github.com/Oussemasahbeni/keycloakify-shadcn-starter)
(shadcn/ui + Tailwind v4 + React 19). Compiles to `dist_keycloak/velobits.jar`,
which docker-compose mounts into `/opt/keycloak/providers/` (jar themes are
Keycloak providers — NOT the legacy `/opt/keycloak/themes/` directory).

## Prerequisites

- Node >= 20
- JDK + Apache Maven (`keycloakify build` shells out to `mvn` for jar
  packaging). CI uses temurin-21 + the runner's Maven. On Windows either
  `choco install openjdk maven`, or use portable installs and put them on
  PATH for the build shell (a working pair lives in `C:\Users\dev\tools\`:
  `jdk21\jdk-21.0.11+10` and `apache-maven-3.9.16`).
- Docker (only for `npx keycloakify start-keycloak`)

## Commands

```bash
npm ci                          # also runs `keycloakify sync-extensions` (postinstall)
npm run storybook               # develop pages against mock kcContext (port 6006)
npm run build-keycloak-theme    # tsc + vite build + keycloakify build → dist_keycloak/velobits.jar
npx keycloakify start-keycloak  # throwaway Keycloak 26.0.8 with the theme + dev realm
```

## How customization works (sync-extensions ownership)

All theme sources are inherited from the npm extension package: they are
copied into `src/` by `sync-extensions` but **git-ignored** (see
`src/.gitignore`). To customize a file, first take ownership:

```bash
npx keycloakify own --path "login/pages/register/Page.tsx"
```

The file becomes tracked; edit it freely. `--revert` restores the upstream
version. Never edit an un-owned file — the next `npm install` overwrites it.

Currently owned (velobits-specific):

- `login/i18n.ts` — en-only string overrides (Sign in / Sign up / Reset
  password), ported from the legacy fixmytext theme.
- `login/pages/login-idp-link-confirm/Page.tsx` — drops the "Review profile"
  button so social logins can only LINK to an existing account
  (one-identity-per-email invariant).

## Runtime branding (no rebuild)

`SHADCN_THEME_*` env vars on the Keycloak container override the defaults
baked into the jar (see `environmentVariables` in [vite.config.ts](vite.config.ts)):
app name, logos, layout (`centered-card` default), color preset/base, radius,
font. Point logo URLs at files in `public/` via `%BASE_URL%/file.svg`.

## Follow-ups

- Email theme: realms currently use the stock `keycloak` email theme (same
  as the legacy setup, which never overrode email templates). To restyle,
  wire [keycloakify-emails](https://github.com/timofei-iatsenko/keycloakify-emails)
  (jsx-email) into the plugin's `postBuild` — the starter repo has 15
  reference templates; the email theme lands in the same velobits.jar.
- Palette: the theme ships the neutral preset. To port the legacy dark
  VS Code tokens exactly, own `login/index.css` and map them onto the shadcn
  CSS variables (iterate in Storybook).
- Supply chain: the extension is a personal-scope npm package — keep the
  exact-version pin fresh via Renovate and review bumps before merging.
