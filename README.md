# seer-alpine

A footprint-minimized Docker image for [seerr](https://github.com/seerr-team/seerr)
(an Overseerr/Jellyseerr fork with built-in OIDC support), built on Alpine Linux.

Same pattern as [`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine),
[`chefcai/ttyd-alpine`](https://github.com/chefcai/ttyd-alpine), and
[`chefcai/bazarr-alpine`](https://github.com/chefcai/bazarr-alpine): the image is
assembled in GitHub Actions and published to `ghcr.io`, so the eMMC-bound homelab
host (`squirttle`) never holds intermediate build artifacts.

## Result

| | Size | Δ vs upstream |
|---|---:|---:|
| `ghcr.io/seerr-team/seerr:preview-new-oidc` (upstream) | **1.36 GB** | — |
| `ghcr.io/chefcai/seer-alpine:latest` | **590 MB** | **−57 % (−770 MB)** |

For perspective, that puts seer-alpine in the same weight class as
`ghcr.io/chefcai/jellyfin-alpine:latest` (~600 MB).

## Why

`squirttle` is a Wyse 5020 with only ~12 GB of eMMC and no expansion path. The
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
   `next-swc`, `@swc/core`, `sharp/libvips`); strip `*.d.ts`, `*.map`, `*.md`,
   `docs/`, `test/`, `examples/`, `CHANGELOG*`, ESM mirrors of CJS code, and
   the transitive devDeps listed above that pnpm refuses to drop on its own.
3. **Runtime stage** (`alpine:3.22`): `apk add nodejs-current tzdata`, copy
   only the runtime artifacts from the builder stage, drop privileges to
   `seerr` (UID 13001 / GID 13000 — homelab-wide PUID/PGID convention used by
   sonarr, radarr, jellyfin, etc.).

Net effect: same `node dist/index.js` entrypoint, same upstream commit SHA,
none of the build-time weight.

## Image

```
ghcr.io/chefcai/seer-alpine:latest
ghcr.io/chefcai/seer-alpine:<seerr-commit-sha>   # 12-char short SHA
```

## Usage

In `docker-compose.yml`:

```yaml
seerr:
  image: ghcr.io/chefcai/seer-alpine:latest
  container_name: seerr
  init: true
  environment:
    - TZ=America/New_York
  ports:
    - "5055:5055"
  volumes:
    - /home/haadmin/config/seerr-config:/app/config
  restart: unless-stopped
  healthcheck:
    test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/status || exit 1
    interval: 1m30s
    timeout: 10s
    retries: 3
    start_period: 30s
```

The bind-mounted `/app/config` directory must be owned by **UID 13001 / GID
13000** (the homelab convention). On a host where it isn't:

```bash
sudo chown -R 13001:13000 /home/haadmin/config/seerr-config
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
  -t my-seer-alpine .
```

(If you change the default `SEERR_REF`, also update the `git ls-remote` line
in `.github/workflows/build.yml` so the daily skip-check resolves the right
branch.)

## Files

- `Dockerfile` — multi-stage build
- `.github/workflows/build.yml` — CI build, daily rebuild, version-skip, push to ghcr.io
- `README.md` — this file
