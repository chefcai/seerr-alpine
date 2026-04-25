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

# Shallow-clone the source at the same ref the upstream image is built from.
RUN git clone --depth 1 --branch "${SEERR_REF}" "${SEERR_REPO}" /build

# Full install (devDeps needed for `pnpm build`).
RUN pnpm install --frozen-lockfile

# Build server (tsc -> dist/) + next (.next/).
RUN pnpm build

# Strip devDeps and the next.js build cache.
# `--ignore-scripts` is required: seerr's `prepare` lifecycle (`node bin/prepare.js`)
# does `require('husky')`, which would crash mid-prune since husky is a devDep
# being removed.
RUN pnpm prune --prod --ignore-scripts \
 && rm -rf .next/cache

# Drop platform-specific prebuilds we don't need on a Linux/musl runtime.
RUN find node_modules -type d \( \
        -path '*/prebuilds/darwin-*' -o \
        -path '*/prebuilds/win32-*'  -o \
        -path '*/prebuilds/linux-arm*' -o \
        -path '*/prebuilds/linux-x64-glibc*' \
    \) -prune -exec rm -rf {} + 2>/dev/null || true \
 && find node_modules -type d -name '@next+swc-linux-x64-gnu*' -prune -exec rm -rf {} + 2>/dev/null || true

# ---- Stage 2: runtime ------------------------------------------------------
FROM alpine:3.22

# nodejs-current = v22.x in alpine 3.22 (matches the builder).
# tini for PID 1, tzdata so TZ env behaves.
RUN apk add --no-cache \
        nodejs-current \
        tini \
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

# Config dir — bind-mounted at runtime.
RUN mkdir -p /app/config && chown -R seerr:seerr /app/config

USER seerr
EXPOSE 5055
ENV NODE_ENV=production

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "dist/index.js"]
