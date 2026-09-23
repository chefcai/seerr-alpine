# seerr-alpine — multi-stage minimal build of seerr on Alpine Linux
#
# Pattern mirrors chefcai/jellyfin-alpine and chefcai/ttyd-alpine:
#   - Build happens in GitHub Actions, not on the deploying host.
#   - Final image is alpine + nodejs (LTS) + only the runtime artifacts
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

# Fetch the exact resolved ref -- a full commit SHA passed in from CI, or a
# branch/tag name for local/manual builds -- rather than re-resolving a
# possibly-moved tag at build time. `preview-new-oidc` is a tag upstream
# force-moves as they iterate, so re-resolving it here (instead of using
# the SHA the workflow already resolved for tagging) risked a tag/content
# mismatch if it moved between the two steps. See
# https://github.com/chefcai/seerr-alpine/issues/3
RUN git init -q /build \
 && git -C /build remote add origin "${SEERR_REPO}" \
 && git -C /build fetch --depth 1 origin "${SEERR_REF}" \
 && git -C /build checkout -q FETCH_HEAD \
 && printf '{"commitTag": "%s"}\n' "$(git -C /build rev-parse HEAD)" > /build/committag.json \
 && cat /build/committag.json

# Full install (devDeps needed for `pnpm build`).
RUN pnpm install --frozen-lockfile

# Build server (tsc -> dist/) + next (.next/).
#
# COMMIT_TAG must be exported into the build env: next.config.ts reads
# `process.env.COMMIT_TAG || 'local'` and bakes that string into the SPA bundle.
# Without this, the SPA ships with `commitTag: "local"` while the runtime
# server reads the real SHA from committag.json — the mismatch fires
# Jellyseerr's "Updated, please reload" banner in an infinite loop.
# Reuse the JSON file we wrote above so we don't re-shell-out to git here.
RUN COMMIT_TAG=$(node -p "require('./committag.json').commitTag") pnpm build \
 && rm -rf .next/cache

# Wipe node_modules and re-install from scratch with --prod so the pnpm
# content-addressable store ONLY contains packages reachable from the prod tree.
# `pnpm prune --prod` alone doesn't shrink .pnpm enough — it leaves transitive
# devDeps (typescript, swc/core-gnu, react-native, jsc-android, three, ace-builds,
# react-devtools, etc.) in the store even after pruning the symlinks.
#
# `--ignore-scripts` skips seerr's `prepare` hook (which requires devDep `husky`),
# but it also skips native module install scripts. So we explicitly rebuild the
# native deps we know the runtime needs (sqlite3 via typeorm, bcrypt for auth,
# sharp for next/image) so their .node binaries are present.
RUN rm -rf node_modules \
 && pnpm install --prod --frozen-lockfile --ignore-scripts \
 && pnpm rebuild sqlite3 bcrypt sharp

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

# Strip docs, tests, type declarations, source maps, and ESM duplicates of
# runtime CJS code. `*.d.ts` is TypeScript-only — Node never reads it. The
# `esm/` directories under `next/dist/` and `date-fns/` are ESM mirrors of the
# CJS the seerr server actually loads via require().
RUN set -e; \
    cd node_modules; \
    find . \( -name '*.md' -o -name '*.markdown' -o -name '*.map' -o -name '*.d.ts' -o -name '*.d.ts.map' \) -type f -delete; \
    find . -type d \( -name 'docs' -o -name 'doc' -o -name 'examples' -o -name 'example' -o -name '__tests__' -o -name 'test' -o -name 'tests' \) -prune -exec rm -rf {} +; \
    find . -type f \( -name 'CHANGELOG*' -o -name 'HISTORY*' -o -name 'AUTHORS' -o -name 'CONTRIBUTORS' -o -name '.travis.yml' -o -name '.eslintrc*' -o -name '.prettierrc*' -o -name 'tsconfig.json' \) -delete; \
    find .pnpm -type d -path '*/next/dist/esm'      -prune -exec rm -rf {} +; \
    find .pnpm -type d -path '*/date-fns/esm'       -prune -exec rm -rf {} +; \
    true

# Drop transitive packages that pnpm keeps because their parent declared them as
# a runtime dep, but which are never reachable from a Node-based seerr server:
#   - react-native + jsc-android + @react-native/* — RN is for mobile, not SSR.
#   - typescript — only needed for `tsc` at build time; runtime is JS.
# If any of these turn out to be loaded by a code path we hit (the container
# would crash with MODULE_NOT_FOUND on startup), revert this stage.
RUN set -e; \
    cd node_modules/.pnpm; \
    rm -rf react-native@* \
           jsc-android@* \
           @react-native+* \
           react-devtools-core@* \
           typescript@* ; \
    true

# Iter 7: more dead weight that survives a clean prod install.
#   - ace-builds (57M): code editor only used in seerr's notification-template
#     settings UI. The server boots and runs without it; the page that needs it
#     would 404 on the asset, not crash the process.
#   - @swc/core-linux-x64-musl (60M): SWC compiler used by Next.js at build
#     time. Runtime SSR uses the precompiled .next bundles, not @swc/core.
#     (@next/swc-linux-x64-musl is removed in iter 8 below.)
#   - @formatjs/intl-displaynames@6.6.8 (31M): older duplicate; the newer
#     6.8.13 is the version actually imported by seerr's i18n setup. The 6.6.8
#     copy is only kept by pnpm to satisfy a peer-dep range from a transitive
#     package that doesn't actually load it at runtime.
RUN set -e; \
    cd node_modules/.pnpm; \
    rm -rf ace-builds@* \
           @swc+core-linux-x64-musl@* \
           @formatjs+intl-displaynames@6.6.8 ; \
    true

# Iter 8: drop the Next.js SWC native compiler (@next/swc-linux-x64-musl,
# ~124 MB) from the runtime tree.
#
# At runtime `next({ dev: false })` only needs SWC for one thing: transpiling
# a TypeScript `next.config.ts` when the server boots. Everything else it
# serves was compiled by `pnpm build` above. So we emit a plain-JS
# `next.config.mjs` here (drop the type-only import and the `: NextConfig`
# annotation), sanity-check it loads under Node, and ship that instead of the
# .ts file. With no .ts config to transpile, SWC is never loaded.
#
# If upstream's next.config.ts grows real TypeScript syntax beyond the type
# annotation, the grep guard below fails the build loudly rather than
# shipping a broken config.
RUN set -e; \
    sed -e '/^import type /d' \
        -e 's/const nextConfig: NextConfig =/const nextConfig =/' \
        next.config.ts > next.config.mjs; \
    if grep -nE 'NextConfig|: [A-Z][A-Za-z]+ =' next.config.mjs; then echo 'next.config.ts has TS syntax the sed transform does not handle' >&2; exit 1; fi; \
    node -e "import('/build/next.config.mjs').then(m => { if (!m.default || !m.default.images) process.exit(1); console.log('next.config.mjs OK'); })"; \
    cd node_modules/.pnpm; \
    rm -rf @next+swc-linux-x64-musl@*

# ---- Stage 2: runtime ------------------------------------------------------
FROM alpine:3.22

# `nodejs` (LTS) = v22.x in alpine 3.22, matching the node:22-alpine builder
# and upstream's engines field (node ^22.19). The previous `nodejs-current`
# package is v23.x in 3.22 -- an odd-numbered, end-of-life Node release --
# and was never the same major as the builder.
# tzdata so TZ env behaves. PID 1 is provided by docker compose `init: true`.
#
# UID/GID 13001:13000 by default at build time (homelab-wide convention used
# by sonarr, radarr, jellyfin, etc.) -- fully overridable at runtime via the
# PUID/PGID env vars, see entrypoint.sh and
# https://github.com/chefcai/seerr-alpine/issues/1
RUN apk add --no-cache \
        nodejs \
        tzdata \
        su-exec \
    && addgroup -g 13000 seerr \
    && adduser -D -u 13001 -G seerr seerr

WORKDIR /app

# Copy only what `node dist/index.js` needs at runtime.
COPY --from=builder --chown=seerr:seerr /build/dist           ./dist
COPY --from=builder --chown=seerr:seerr /build/.next          ./.next
COPY --from=builder --chown=seerr:seerr /build/public         ./public
COPY --from=builder --chown=seerr:seerr /build/node_modules   ./node_modules
COPY --from=builder --chown=seerr:seerr /build/package.json   ./package.json
COPY --from=builder --chown=seerr:seerr /build/next.config.mjs ./next.config.mjs
COPY --from=builder --chown=seerr:seerr /build/committag.json ./committag.json
COPY --from=builder --chown=seerr:seerr /build/seerr-api.yml  ./seerr-api.yml

# Config dir — bind-mounted at runtime.
RUN mkdir -p /app/config && chown -R seerr:seerr /app/config

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# NOTE: intentionally stays as root here -- entrypoint.sh drops to
# PUID:PGID (default 1000:1000) via su-exec at container start. See
# https://github.com/chefcai/seerr-alpine/issues/1
EXPOSE 5055
ENV NODE_ENV=production

ENTRYPOINT ["/entrypoint.sh"]
CMD ["node", "dist/index.js"]
