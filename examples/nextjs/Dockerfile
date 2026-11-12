# syntax=docker/dockerfile:1
# Canonical Next.js 16+ Standalone Multi-Stage Dockerfile (ZFS / overlay2 optimized)
#
# Unified single-stage builder avoids cross-stage dependency copies that can
# stall on ZFS + overlay2 (metacopy: false).
#
# Once your org publishes bun-node-alpine / node-alpine-runner, you can swap the
# base stages below to:
#   FROM git.gt-web-dev.com/gt-dev/bun-node-alpine:24-1.4@sha256:<PUBLISHED_DIGEST> AS builder
#   FROM git.gt-web-dev.com/gt-dev/node-alpine-runner:24@sha256:<PUBLISHED_DIGEST> AS runner

FROM oven/bun:1.4.4-alpine@sha256:4cf82f5686b196504fe119db3fcd9185b191f82ece82c40680e597228ec6070a AS bun-source

FROM node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5 AS builder
WORKDIR /app

# Install musl compatibility and optionally trust internal CI registry CA cleanly
RUN --mount=type=secret,id=internal_ca,required=false \
    apk add --no-cache libc6-compat ca-certificates && \
    if [ -s /run/secrets/internal_ca ]; then \
      cp /run/secrets/internal_ca /usr/local/share/ca-certificates/gt-internal-ca.crt && \
      update-ca-certificates; \
    fi

COPY --from=bun-source /usr/local/bin/bun /usr/local/bin/bun
RUN ln -sf /usr/local/bin/bun /usr/local/bin/bunx && chmod 0755 /usr/local/bin/bun

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS="--max-old-space-size=2048" \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# 1. Dependency layer (invalidated only when manifests or lockfile change)
COPY --link package.json bun.lock .npmrc* ./
RUN --mount=type=cache,id=bun-cache,target=/root/.bun/install/cache,sharing=locked \
    bun install --frozen-lockfile --ignore-scripts

# 2. Compilation layer (omit public/ images/docs unless imported at build time)
COPY --link next.config.ts tsconfig.json postcss.config.* ./
COPY --link src ./src

# Enable experimental.turbopackFileSystemCacheForBuild: true in next.config.ts
RUN --mount=type=cache,id=nextjs-cache,target=/app/.next/cache,sharing=locked \
    node ./node_modules/next/dist/bin/next build

# 3. Minimal non-root production runner
FROM node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5 AS runner
WORKDIR /app

RUN apk add --no-cache libc6-compat ca-certificates && \
    addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 --ingroup nodejs nextjs

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME="0.0.0.0" \
    NODE_OPTIONS="--max-old-space-size=256"

# Copy static assets directly from context so media changes never bust next build
COPY --link --chown=nextjs:nodejs public ./public
COPY --from=builder --link --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --link --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:3000/api/health').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

CMD ["node", "server.js"]
