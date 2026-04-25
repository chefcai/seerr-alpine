# seer-alpine

A footprint-minimized Docker image for [seerr](https://github.com/seerr-team/seerr)
(an Overseerr/Jellyseerr fork with built-in OIDC support), built on Alpine Linux.

Same pattern as [`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine)
and [`chefcai/ttyd-alpine`](https://github.com/chefcai/ttyd-alpine): the image is
assembled in GitHub Actions and published to `ghcr.io`, so the eMMC-bound homelab
host (`squirttle`) never holds intermediate build artifacts.

## Why

`squirttle` is a Wyse 5020 with only ~12 GB of eMMC storage and no expansion path.
The upstream `ghcr.io/seerr-team/seerr:preview-new-oidc` image is ~1.36 GB and ships:

- the full source tree (`src/`, `server/`, `cypress.config.ts`, etc.)
- 1.3 GB of `node_modules` including devDependencies (Cypress, ESLint, Prettier,
  TypeScript, ts-node, …)
- platform-specific native prebuilds for darwin-arm64, darwin-x64, win32-arm64,
  win32-x64, linux-arm, glibc-linux — none of which are reachable from an Alpine
  (musl) runtime
- the `.next/cache` directory (build-time only)

None of that is needed at runtime. `node dist/index.js` only reads from `dist/`,
`.next/` (without `cache/`), `public/`, and production `node_modules`.

## How it shrinks the image

Multi-stage Dockerfile:

1. **Builder stage** (`node:22-alpine`): `git clone --depth 1` the upstream source
   at the same ref the upstream image is built from, install with `pnpm`, run
   `pnpm build`, then `pnpm prune --prod` and delete `.next/cache` plus all
   non-linux-musl prebuilds.
2. **Runtime stage** (`alpine:3.22`): `apk add nodejs-current tini tzdata`, copy
   only the runtime artifacts from the builder stage, drop privileges to a
   non-root `seerr` user (UID 13001 / GID 13000 to match the rest of the
   homelab's volume permissions).

Net effect: same `node dist/index.js` entrypoint, none of the build-time weight.

## Image

```
ghcr.io/chefcai/seer-alpine:latest
ghcr.io/chefcai/seer-alpine:<seerr-commit-sha>
```

The CI workflow tags `latest` and the short SHA of whichever
`seerr-team/seerr@preview-new-oidc` commit was current at build time, so
deployments can pin to a known build.

## Usage

In `docker-compose.yml`:

```yaml
seer-alpine:
  image: ghcr.io/chefcai/seer-alpine:latest
  container_name: seer-alpine
  init: true
  environment:
    - TZ=America/New_York
  ports:
    - "5056:5055"
  volumes:
    - /home/haadmin/config/seer-alpine-config:/app/config
  restart: unless-stopped
  healthcheck:
    test: wget --no-verbose --tries=1 --spider http://localhost:5055/api/v1/status || exit 1
    interval: 1m30s
    timeout: 10s
    retries: 3
    start_period: 30s
```

Port `5056` is used here so the alpine variant can run side-by-side with the
upstream `seerr` container on port `5055` for comparison.

## Build

The workflow runs on every push to `main` and can be re-run manually via
`workflow_dispatch`. It uses GitHub Actions cache (`type=gha,mode=max`) to
keep iteration on the Dockerfile fast — the expensive `pnpm install` layer is
reused across runs unless `pnpm-lock.yaml` (resolved during the build via the
shallow clone) changes.

To pin to a different upstream branch or fork, override the build args:

```bash
docker build \
  --build-arg SEERR_REF=main \
  --build-arg SEERR_REPO=https://github.com/Fallenbagel/jellyseerr.git \
  -t my-seer-alpine .
```

## Files

- `Dockerfile` — the multi-stage build
- `.github/workflows/build.yml` — CI build + push to ghcr.io
- `README.md` — this file
