# seerr-alpine

A footprint-minimized Docker image for [seerr](https://github.com/seerr-team/seerr)
(an Overseerr/Jellyseerr fork with built-in OIDC support), built on Alpine Linux.

Same pattern as [`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine),
[`chefcai/ttyd-alpine`](https://github.com/chefcai/ttyd-alpine), and
[`chefcai/bazarr-alpine`](https://github.com/chefcai/bazarr-alpine): the image is
assembled in GitHub Actions and published to `ghcr.io`, so small/resource-constrained
homelab hosts never hold intermediate build artifacts.

## Upstream tracking

This image tracks the **`preview-new-oidc`** branch of
[`seerr-team/seerr`](https://github.com/seerr-team/seerr), not `main`. That
branch is where the project is staging its built-in OIDC (OpenID Connect)
authentication support — at the time of writing, OIDC has not yet been merged
into mainline. Tracking `preview-new-oidc` is how the homelab gets a working
OIDC-capable seerr today, ahead of the upstream release.

**When OIDC merges into upstream `main`, this build should pivot to `main`.**
Two places need updating in lockstep:

1. `Dockerfile` — change the `ARG SEERR_REF=preview-new-oidc` default to
   `ARG SEERR_REF=main`.
2. `.github/workflows/build.yml` — update the `git ls-remote …
   preview-new-oidc` line (in the *Get seerr commit SHA from upstream tag*
   step) so the daily skip-check resolves `main` instead. Also update the
   `cron`/`concurrency` comments that reference `preview-new-oidc` for
   accuracy.

After the pivot, the image's runtime entrypoint (`node dist/index.js`), the
shrink approach, and the `chefcai/seerr-alpine` package name all stay the same
— consumers don't need to change anything.

## Result

| | Size | Δ vs upstream |
|---|---:|---:|
| `ghcr.io/seerr-team/seerr:preview-new-oidc` (upstream) | **1.36 GB** | — |
| `ghcr.io/chefcai/seerr-alpine` (before iter 8) | **490 MB** | **−64 % (−870 MB)** |
| `ghcr.io/chefcai/seerr-alpine:latest` (iter 8) | **354 MB** | **−74 % (−1.0 GB)** |

Iter 8 (compressed 138.9 MB → 92.5 MB):
- `next.config.ts` is converted to a plain-JS `next.config.mjs` at build time
  (the build fails if the conversion leaves TypeScript syntax behind). With no
  TypeScript config to transpile at server start, the Next.js SWC native
  compiler `@next/swc-linux-x64-musl` (~124 MB) is removed from the runtime tree.
- Runtime uses Alpine's `nodejs` (LTS, v22.x — matches the `node:22-alpine`
  builder and upstream's `engines` field) instead of `nodejs-current`, which is
  v23.x in Alpine 3.22 (end-of-life).

## Why

Many homelab hosts run with a small amount of storage and no expansion path. The
upstream image ships a lot that doesn't run at runtime:

- the full source tree (`src/`, `server/`, `cypress.config.ts`, …)
- ~1.3 GB of `node_modules`, including devDependencies (Cypress, ESLint,
  Prettier, TypeScript, ts-node, …)
- platform-specific native prebuilds for `darwin-arm64`, `darwin-x64`,
  `win32-arm64`, `win32-x64`, `linux-arm`, `linux-x64-glibc` — none reachable
  from an Alpine (musl) runtime
- duplicate ESM mirrors of CJS code, `*.d.ts` declarations, the `.next/cache`
  build directory
- transitive devDeps that survive `pnpm install --prod` because some upstream
  package mis-declares them as runtime deps: `react-native` (79 MB),
  `jsc-android` (31 MB), `react-devtools-core` (18 MB), `ace-builds` (57 MB),
  `@swc/core` (60 MB), duplicate `@formatjs/intl-displaynames` (31 MB),
  `typescript` (31 MB), …

`node dist/index.js` only needs `dist/`, `.next/` (without `cache/`), `public/`,
production `node_modules`, plus `seerr-api.yml` for the API docs route.

## How it shrinks the image

Multi-stage Dockerfile:

1. **Builder stage** (`node:22-alpine`): `git clone --depth 1` the upstream
   source at the tracked branch (default `preview-new-oidc`), `pnpm install`,
   `pnpm build`, then **wipe `node_modules` entirely** and run a fresh
   `pnpm install --prod --frozen-lockfile --ignore-scripts` so the pnpm
   content-addressable store is rebuilt with prod-reachable packages only.
   `pnpm rebuild sqlite3 bcrypt sharp` puts the native `.node` binaries back.
2. **Aggressive prune**: drop arch-specific binaries (keep musl-x64 only for
   `sharp/libvips`; `next-swc` and `@swc/core` are removed entirely); strip `*.d.ts`, `*.map`, `*.md`,
   `docs/`, `test/`, `examples/`, `CHANGELOG*`, ESM mirrors of CJS code, and
   the transitive devDeps listed above that pnpm refuses to drop on its own.
3. **Runtime stage** (`alpine:3.22`): `apk add nodejs tzdata`, copy
   only the runtime artifacts from the builder stage, drop privileges to
   `seerr` (UID 13001 / GID 13000 — homelab-wide PUID/PGID convention used by
   sonarr, radarr, jellyfin, etc.).

Net effect: same `node dist/index.js` entrypoint, same upstream commit SHA,
none of the build-time weight.

## Image

```
ghcr.io/chefcai/seerr-alpine:latest
ghcr.io/chefcai/seerr-alpine:<seerr-commit-sha>   # 12-char short SHA
```

Builds dispatched from a non-`main` branch (`gh workflow run build.yml --ref <branch>`)
publish only `:branch-<branch-name>`; `:latest` and the version tag are published from `main` only.

## Usage

In `docker-compose.yml`:

```yaml
seerr:
  image: ghcr.io/chefcai/seerr-alpine:latest
  container_name: seerr
  init: true
  environment:
    - TZ=UTC  # override to your local zone
  ports:
    - "5055:5055"
  volumes:
    - /path/to/seerr-config:/app/config
  restart: unless-stopped
  healthcheck:
    test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/status || exit 1
    interval: 1m30s
    timeout: 10s
    retries: 3
    start_period: 30s
```

The bind-mounted `/app/config` directory must be owned by whatever UID/GID
you pass via `PUID`/`PGID` (default **1000:1000** if unset). On a host where
it isn't:

```bash
sudo chown -R 1000:1000 /path/to/seerr-config
```

## Build pipeline

The `.github/workflows/build.yml` workflow runs on:

- every push to `main`
- manual `workflow_dispatch`
- a daily cron at **06:45 UTC** (staggered after the other `*-alpine` repos:
  bazarr 06:00, jellyfin 06:15, ttyd 06:30)

The scheduled run resolves the current `preview-new-oidc` HEAD SHA against
ghcr's manifest API and **skips the build** if that SHA tag is already
published, so no work happens on quiet upstream days.

A `concurrency:` group serializes runs on `main` and cancels older in-flight
runs when a newer one starts — this prevents the parallel-push race where a
slower-finishing build can overwrite `:latest` with stale bits.

GitHub Actions cache (`type=gha,mode=max`) keeps iteration on the Dockerfile
fast: the expensive `pnpm install` and Next build layers are reused unless
their inputs change.

## Pinning to a different upstream branch or fork

Both `SEERR_REF` and `SEERR_REPO` are build args:

```bash
docker build \
  --build-arg SEERR_REF=main \
  --build-arg SEERR_REPO=https://github.com/Fallenbagel/jellyseerr.git \
  -t my-seerr-alpine .
```

(If you change the default `SEERR_REF`, also update the `git ls-remote` line
in `.github/workflows/build.yml` so the daily skip-check resolves the right
branch.)

## Files

- `Dockerfile` — multi-stage build
- `.github/workflows/build.yml` — CI build, daily rebuild, version-skip, push to ghcr.io
- `README.md` — this file
