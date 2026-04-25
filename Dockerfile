# seer-alpine — multi-stage minimal build of seerr on Alpine Linux
#
# Pattern mirrors chefcai/jellyfin-alpine and chefcai/ttyd-alpine:
#   - Build happens in GitHub Actions, not on squirttle's eMMC.
#   - Final image is alpine + nodejs-current + only the runtime artifacts
#     needed by `node dist/index.js`.
#
# Baseline (upstream): ghcr.io/seerr-team/seerr:preview-new-oidc = 1.36 GB
# Goal: shrink by dropping devDeps, source tree, .next/cache, and platform-
# specific prebuilds for non-target archs.

ARG SEERR_REF=preview-new-oidc
ARG SEERR_REPO=https://github.com/seerr-team/seerr.git

# ---- Stage 1: builder ------------------------------------------------------
FROM node:22-alpine AS builder
ARG SEERR_REF
ARG SEERR_REPO

WORKDIR /build

# Toolchain for native modules (sqlite3, bcrypt, sharp, next-swc).
RUN apk add --no-cache \
        python3 \
        make \
        g++ \
        git \
        libc6-compat \
    && corepack enable

# Shallow-clone the source at the same ref the upstream image is built from,
# then write committag.json from the cloned SHA — upstream's CI generates this
# file at build time and the runtime references it for version display.
RUN git clone --depth 1 --branch "${SEERR_REF}" "${SEERR_REPO}" /build \
 && printf '{"commitTag": "%s"}\n' "$(git -C /build rev-parse HEAD)" > /build/committag.json \
 && cat /build/committag.json

# Full install (devDeps needed for `pnpm build`).
RUN pnpm install --frozen-lockfile

# Build server (tsc -> dist/) + next (.next/).
RUN pnpm build \
 && rm -rf .next/cache

# Wipe node_modules and re-install from scratch with --prod so the pnpm
# content-addressable store ONLY contains packages reachable from the prod tree.
# `pnpm prune --prod` alone doesn't shrink .pnpm enough — it leaves transitive
# devDeps (typescript, swc/core-gnu, react-native, jsc-android, three, ace-builds,
# react-devtools, etc.) in the store even after pruning the symlinks.
# `--ignore-scripts` skips seerr's `prepare` hook (which requires devDep `husky`).
RUN rm -rf node_modules \
 && pnpm install --prod --frozen-lockfile --ignore-scripts

# Drop prebuilds and arch-specific binaries we don't need on linux/musl/x64.
RUN set -e; \
    cd node_modules; \
    # Native module prebuilds for other OS/arch.
    find . -type d \( \
        -path '*/prebuilds/darwin-*'           -o \
        -path '*/prebuilds/win32-*'            -o \
        -path '*/prebuilds/linux-arm*'         -o \
        -path '*/prebuilds/linux-x64-glibc*'   -o \
        -path '*/prebuilds/android-*' \
    \) -prune -exec rm -rf {} +; \
    # next-swc and @swc/core: keep musl-x64 only.
    find . -type d -name '@next+swc-linux-x64-gnu*'        -prune -exec rm -rf {} +; \
    find . -type d -name '@next+swc-linux-arm*'            -prune -exec rm -rf {} +; \
    find . -type d -name '@next+swc-darwin-*'              -prune -exec rm -rf {} +; \
    find . -type d -name '@next+swc-win32-*'               -prune -exec rm -rf {} +; \
    find . -type d -name '@swc+core-linux-x64-gnu*'        -prune -exec rm -rf {} +; \
    find . -type d -name '@swc+core-linux-arm*'            -prune -exec rm -rf {} +; \
    find . -type d -name '@swc+core-darwin-*'              -prune -exec rm -rf {} +; \
    find . -type d -name '@swc+core-win32-*'               -prune -exec rm -rf {} +; \
    # sharp libvips: keep musl-x64 only.
    find . -type d -name '@img+sharp-libvips-linux-x64*'   -prune -exec rm -rf {} +; \
    find . -type d -name '@img+sharp-libvips-linux-arm*'   -prune -exec rm -rf {} +; \
    find . -type d -name '@img+sharp-libvips-darwin-*'     -prune -exec rm -rf {} +; \
    find . -type d -name '@img+sharp-linux-x64*'           -prune -exec rm -rf {} +; \
    find . -type d -name '@img+sharp-linux-arm*'           -prune -exec rm -rf {} +; \
    find . -type d -name '@img+sharp-darwin-*'             -prune -exec rm -rf {} +; \
    find . -type d -name '@img+sharp-win32-*'              -prune -exec rm -rf {} +; \
    true

# Strip docs, tests, and TypeScript declaration/source-map files from prod modules.
RUN set -e; \
    cd node_modules; \
    find . \( -name '*.md' -o -name '*.markdown' -o -name '*.map' \) -type f -delete; \
    find . -type d \( -name 'docs' -o -name 'doc' -o -name 'examples' -o -name 'example' -o -name '__tests__' -o -name 'test' -o -name 'tests' \) -prune -exec rm -rf {} +; \
    find . -type f \( -name 'CHANGELOG*' -o -name 'HISTORY*' -o -name 'AUTHORS' -o -name 'CONTRIBUTORS' -o -name '.travis.yml' -o -name '.eslintrc*' -o -name '.prettierrc*' -o -name 'tsconfig.json' \) -delete; \
    true

# ---- Stage 2: runtime ------------------------------------------------------
FROM alpine:3.22

# nodejs-current = v22.x in alpine 3.22 (matches the builder).
# tzdata so TZ env behaves. PID 1 is provided by docker compose `init: true`.
RUN apk add --no-cache \
        nodejs-current \
        tzdata \
    && addgroup -g 13000 seerr \
    && adduser -D -u 13001 -G seerr seerr

WORKDIR /app

# Copy only what `node dist/index.js` needs at runtime.
COPY --from=builder --chown=seerr:seerr /build/dist           ./dist
COPY --from=builder --chown=seerr:seerr /build/.next          ./.next
COPY --from=builder --chown=seerr:seerr /build/public         ./public
COPY --from=builder --chown=seerr:seerr /build/node_modules   ./node_modules
COPY --from=builder --chown=seerr:seerr /build/package.json   ./package.json
COPY --from=builder --chown=seerr:seerr /build/next.config.js ./next.config.js
COPY --from=builder --chown=seerr:seerr /build/committag.json ./committag.json
COPY --from=builder --chown=seerr:seerr /build/seerr-api.yml  ./seerr-api.yml

# Config dir — bind-mounted at runtime.
RUN mkdir -p /app/config && chown -R seerr:seerr /app/config

USER seerr
EXPOSE 5055
ENV NODE_ENV=production

CMD ["node", "dist/index.js"]
